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
    func testRebuildsWhenStoredVersionIsStale() throws {
        let url = tempURL(); defer { removeDatabase(url) }
        do {
            let sql = try AITopicSQL(url)
            try sql.run("CREATE TABLE files(id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE)")
            // Seed a stale version explicitly so the rebuild is forced by the stamp.
            try sql.run("PRAGMA user_version = \(ContentIndex.schemaVersion - 1)")
        }
        _ = try ContentIndex(url: url)
        let sql = try AITopicSQL(url, readOnly: true)
        // Rebuilt from scratch, so the table is canonical rather than having columns bolted on.
        XCTAssertTrue(try sql.columns("files").isSuperset(of: ["size", "mtime", "mtime_nsec", "kind", "parser", "revision"]))
        XCTAssertTrue(try sql.tables().contains("chunk_fts"))
        let probe = try sql.prepare("PRAGMA user_version")
        XCTAssertTrue(try probe.next())
        XCTAssertEqual(probe.int(0), Int64(ContentIndex.schemaVersion))
    }
    func testDeletingAFileCascadesToChunksAndFtsPostings() throws {
        let url = tempURL(); defer { removeDatabase(url) }
        let index = try ContentIndex(url: url)
        try index.sql.run("""
            INSERT INTO files(id, path, size, mtime, mtime_nsec, kind, parser) VALUES(1, '/a/b.txt', 1, 1, 0, 3, 'text');
            INSERT INTO chunks(id, file, ordinal, label, folded, bytes) VALUES(1, 1, 0, '第 1 页', X'00', 0);
            INSERT INTO chunk_fts(rowid, grams) VALUES(1, 'abc');
            """)
        let sql = try AITopicSQL(url, readOnly: true)
        XCTAssertEqual(try count("chunks", sql), 1)
        XCTAssertEqual(try count("chunk_fts", sql), 1)
        // Deleting the file must cascade to its chunks, and the AFTER DELETE trigger must clear the
        // posting through that cascade, which proves foreign_keys=ON and the trigger both hold.
        try index.sql.run("DELETE FROM files WHERE id = 1")
        XCTAssertEqual(try count("chunks", sql), 0)
        XCTAssertEqual(try count("chunk_fts", sql), 0)
    }
    private func count(_ table: String, _ sql: AITopicSQL) throws -> Int64 {
        let statement = try sql.prepare("SELECT COUNT(*) FROM \(table)")
        guard try statement.next() else { return 0 }
        return statement.int(0)
    }
    func testReopenKeepsTheSchemaVersionAndDoesNotRebuild() throws {
        let url = tempURL(); defer { removeDatabase(url) }
        do {
            let index = try ContentIndex(url: url)
            try index.sql.run("INSERT INTO files(path,size,mtime,mtime_nsec,kind,parser) VALUES('/a/b.txt',1,1,0,3,'text')")
        }
        // A rebuild would drop the row; the version stamp must make the second open a no-op.
        XCTAssertEqual(try ContentIndex(url: url).count(), 1)
    }
}
