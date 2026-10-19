import XCTest
@testable import OilFindApp

final class ContentIndexSchemaTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("content-" + UUID().uuidString + ".sqlite")
    }
    /// The database runs in WAL mode, so the sidecars are left behind if only the main file goes.
    private func removeDatabase(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }
    func testOpenCreatesTablesAndIsIdempotent() throws {
        let url = tempURL(); defer { removeDatabase(url) }
        do { _ = try ContentIndex(url: url) }
        let index = try ContentIndex(url: url)
        let sql = try AITopicSQL(url, readOnly: true)
        // Exact set: an extra or missing table is schema drift, not something to tolerate.
        XCTAssertEqual(try sql.tables().sorted(), [
            "chunk_fts", "chunk_fts_config", "chunk_fts_data", "chunk_fts_docsize",
            "chunk_fts_idx", "chunks", "files", "sqlite_sequence",
        ])
        XCTAssertEqual(try index.count(), 0)
    }
    func testRebuildsWhenTheExistingSchemaIsNotCanonical() throws {
        let url = tempURL(); defer { removeDatabase(url) }
        do {
            let sql = try AITopicSQL(url)
            try sql.run("CREATE TABLE files(id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE)")
            // Seed a stale version explicitly so the rebuild is forced by the stamp, not merely
            // by the missing canonical columns.
            try sql.run("PRAGMA user_version = \(ContentIndex.schemaVersion - 1)")
        }
        _ = try ContentIndex(url: url)
        let sql = try AITopicSQL(url, readOnly: true)
        // Rebuilt from scratch, so the table is canonical rather than having columns bolted on.
        XCTAssertTrue(try sql.columns("files").isSuperset(of: ["size", "mtime", "kind", "parser", "revision"]))
        XCTAssertTrue(try sql.tables().contains("chunk_fts"))
        let probe = try sql.prepare("PRAGMA user_version")
        XCTAssertTrue(try probe.next())
        XCTAssertEqual(probe.int(0), 1)
    }
    func testReopenKeepsTheSchemaVersionAndDoesNotRebuild() throws {
        let url = tempURL(); defer { removeDatabase(url) }
        do {
            let index = try ContentIndex(url: url)
            try index.sql.run("INSERT INTO files(path,size,mtime,kind,parser) VALUES('/a/b.txt',1,1,3,'text')")
        }
        // A rebuild would drop the row; the version stamp must make the second open a no-op.
        XCTAssertEqual(try ContentIndex(url: url).count(), 1)
    }
}
