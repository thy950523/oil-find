import Foundation
import SQLite3

// `ContentIndexError` lives in ContentSearch/Support/ContentCompression.swift (added in Task 1).

struct ContentChunk {
    let ordinal: Int
    let label: String
    let text: String
}

struct ContentFileRecord {
    let path: String
    let size: Int64
    let mtime: Int64
    let kind: UInt8
    let parser: String
}

/// A read-only or read-write connection. Each connection is confined to its caller's queue.
final class ContentIndex {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Oil Find/content/index.sqlite")

    let sql: AITopicSQL
    private let readOnly: Bool
    private var statements: [String: AITopicStatement] = [:]
    private var inTransaction = false

    init(url: URL, readOnly: Bool = false) throws {
        self.readOnly = readOnly
        if !readOnly {
            let directory = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        sql = try AITopicSQL(url, readOnly: readOnly)
        if !readOnly {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        try migrate()
    }

    private func migrate() throws {
        if readOnly { return }
        try sql.run("""
            PRAGMA journal_mode=WAL;
            PRAGMA foreign_keys=ON;
            CREATE TABLE IF NOT EXISTS files(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                path TEXT NOT NULL UNIQUE,
                size INTEGER NOT NULL,
                mtime INTEGER NOT NULL,
                kind INTEGER NOT NULL,
                parser TEXT NOT NULL,
                revision INTEGER NOT NULL DEFAULT 1);
            CREATE TABLE IF NOT EXISTS chunks(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                file INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL,
                label TEXT NOT NULL,
                folded BLOB NOT NULL,
                bytes INTEGER NOT NULL);   -- UNCOMPRESSED length of folded, so unpack is one exact pass
            CREATE INDEX IF NOT EXISTS chunks_file ON chunks(file);
            CREATE VIRTUAL TABLE IF NOT EXISTS chunk_fts USING fts5(grams, content='', contentless_delete=1, detail=none);
            """)
        // In-place migration for databases written by earlier builds.
        let columns = try sql.columns("files")
        for (name, definition) in [("size", "INTEGER NOT NULL DEFAULT 0"), ("mtime", "INTEGER NOT NULL DEFAULT 0"),
                                   ("kind", "INTEGER NOT NULL DEFAULT 0"), ("parser", "TEXT NOT NULL DEFAULT ''"),
                                   ("revision", "INTEGER NOT NULL DEFAULT 1")] where !columns.contains(name) {
            try sql.run("ALTER TABLE files ADD COLUMN \(name) \(definition)")
        }
    }

    func statement(_ query: String) throws -> AITopicStatement {
        if let existing = statements[query] { sqlite3_reset(existing.handle); sqlite3_clear_bindings(existing.handle); return existing }
        let created = try sql.prepare(query); statements[query] = created; return created
    }

    func count() throws -> Int {
        let statement = try statement("SELECT COUNT(*) FROM files")
        defer { sqlite3_reset(statement.handle) }
        guard try statement.next() else { return 0 }
        return Int(statement.int(0))
    }
}
