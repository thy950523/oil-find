import XCTest
@testable import OilFindApp

final class ContentIndexSchemaTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("content-" + UUID().uuidString + ".sqlite")
    }
    func testOpenCreatesTablesAndIsIdempotent() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        do { _ = try ContentIndex(url: url) }
        let index = try ContentIndex(url: url)
        let sql = try AITopicSQL(url, readOnly: true)
        XCTAssertEqual(try sql.tables().intersection(["files", "chunks"]), ["files", "chunks"])
        XCTAssertTrue(try sql.tables().contains("chunk_fts"))
        XCTAssertEqual(try index.count(), 0)
    }
    func testMissingColumnsAreAddedOnOpen() throws {
        let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        do { let sql = try AITopicSQL(url); try sql.run("CREATE TABLE files(id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE)") }
        _ = try ContentIndex(url: url)
        let sql = try AITopicSQL(url, readOnly: true)
        XCTAssertTrue(try sql.columns("files").isSuperset(of: ["size", "mtime", "kind", "parser", "revision"]))
    }
}
