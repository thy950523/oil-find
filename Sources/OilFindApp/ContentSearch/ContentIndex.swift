import Foundation
import SQLite3

// `ContentIndexError` lives in ContentSearch/Support/ContentCompression.swift (added in Task 1).

/// One unit of searchable text inside a file. `ordinal` orders chunks within the file; `label`
/// is the human-readable location, such as "第 3 页" or "第 1200 行附近".
struct ContentChunk {
    let ordinal: Int
    let label: String
    let text: String
}

/// A file as seen in the file index. `size` and `mtime` form the identity used by incremental
/// sync; `kind` is the file-index kind (3 = document, 4 = image) and `parser` is the identifier
/// of the `ContentParser` that produced its chunks.
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

    /// Bumped whenever the canonical schema changes. The index is derived and rebuildable, so a
    /// mismatch is repaired by rebuilding rather than migrated column by column.
    static let schemaVersion = 1

    let sql: AITopicSQL
    private let readOnly: Bool
    private var statements: [String: AITopicStatement] = [:]
    private var inTransaction = false

    init(url: URL, readOnly: Bool = false) throws {
        self.readOnly = readOnly
        if !readOnly {
            // `attributes` only applies when the directory is created, so verify the mode on every
            // open: an older build or a manual mkdir may have left it wider than 0700. Only chmod
            // when it is not already 0700; re-setting an already-correct directory can fail with
            // EPERM, which the system temp directory used by tests does.
            let directory = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let mode = (try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
                as? NSNumber)?.uint16Value
            if mode != 0o700 {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            }
        }
        sql = try Self.open(url, readOnly: readOnly)
        do {
            if !readOnly {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            try migrate()
        } catch let error as ContentIndexError {
            throw error
        } catch {
            throw ContentIndexError.database(error.localizedDescription)
        }
    }

    /// Surfaces open failures as this module's error type, so callers need not know about the
    /// shared SQLite wrapper.
    private static func open(_ url: URL, readOnly: Bool) throws -> AITopicSQL {
        do { return try AITopicSQL(url, readOnly: readOnly) }
        catch { throw ContentIndexError.database(error.localizedDescription) }
    }

    private func migrate() throws {
        if readOnly { return }
        // Neither pragma can run inside a transaction.
        try sql.run("PRAGMA journal_mode=WAL")
        try sql.run("PRAGMA foreign_keys=ON")
        // BEGIN IMMEDIATE serialises two writable connections opening the same fresh database:
        // the loser waits, then sees the winner's version and skips the rebuild.
        try sql.run("BEGIN IMMEDIATE")
        do {
            let probe = try sql.prepare("PRAGMA user_version")
            let hasVersion = try probe.next()
            let version = hasVersion ? probe.int(0) : 0
            sqlite3_reset(probe.handle)
            if version != Int64(Self.schemaVersion) {
                try sql.run("""
                    DROP TRIGGER IF EXISTS chunk_postings_delete;
                    DROP TABLE IF EXISTS chunk_fts;
                    DROP TABLE IF EXISTS chunks;
                    DROP TABLE IF EXISTS files;
                    """)
                try sql.run("""
                    CREATE TABLE files(
                        -- AUTOINCREMENT: chunks reference files.id; rowid reuse after a delete would let a stale chunk attach to a new file.
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        path TEXT NOT NULL UNIQUE,
                        size INTEGER NOT NULL,
                        mtime INTEGER NOT NULL,
                        kind INTEGER NOT NULL,
                        parser TEXT NOT NULL,
                        revision INTEGER NOT NULL DEFAULT 1);
                    CREATE TABLE chunks(
                        -- AUTOINCREMENT: FTS postings are keyed by chunks.id; rowid reuse after a delete would let a stale posting attach to a new chunk.
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        file INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                        ordinal INTEGER NOT NULL,
                        label TEXT NOT NULL,
                        folded BLOB NOT NULL,
                        -- UNCOMPRESSED length of folded, so unpack is one exact pass. The bound
                        -- matches ContentCompression.maxBodyBytes.
                        bytes INTEGER NOT NULL CHECK(bytes BETWEEN 0 AND 16777216),
                        UNIQUE(file, ordinal));
                    CREATE INDEX chunks_file ON chunks(file);
                    CREATE VIRTUAL TABLE chunk_fts USING fts5(grams, content='', contentless_delete=1, detail=none);
                    -- Postings have no cascade of their own; this covers every path that deletes
                    -- a chunk, including the file cascade.
                    CREATE TRIGGER chunk_postings_delete AFTER DELETE ON chunks BEGIN
                        DELETE FROM chunk_fts WHERE rowid = old.id;
                    END;
                    """)
                try sql.run("PRAGMA user_version = \(Self.schemaVersion)")
            }
            try sql.run("COMMIT")
        } catch {
            try? sql.run("ROLLBACK")
            throw error
        }
    }

    func statement(_ query: String) throws -> AITopicStatement {
        if let existing = statements[query] {
            // Resetting a statement that an outer loop is iterating would end that loop silently.
            assert(sqlite3_stmt_busy(existing.handle) == 0, "Re-entrant use of \(query)")
            sqlite3_reset(existing.handle); sqlite3_clear_bindings(existing.handle); return existing
        }
        let created = try sql.prepare(query); statements[query] = created; return created
    }

    func count() throws -> Int {
        let statement = try statement("SELECT COUNT(*) FROM files")
        defer { sqlite3_reset(statement.handle) }
        guard try statement.next() else { return 0 }
        return Int(statement.int(0))
    }
}
