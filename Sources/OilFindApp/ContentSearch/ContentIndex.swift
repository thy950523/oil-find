import Foundation
import SQLite3

/// Shared by every content search component.
enum ContentIndexError: Error, LocalizedError {
    case database(String)
    var errorDescription: String? { if case .database(let message) = self { return message }; return nil }
}

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
    /// False when the database could not be switched to WAL mode, which some network home
    /// directories refuse. Indexing still works, but readers and writers serialise instead of
    /// overlapping. Task 11 logs this.
    private(set) var usesWAL = true
    private let readOnly: Bool
    private var statements: [String: AITopicStatement] = [:]

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

    private func storedVersion() throws -> Int64 {
        let probe = try sql.prepare("PRAGMA user_version")
        let hasVersion = try step(probe)
        let version = hasVersion ? probe.int(0) : 0
        sqlite3_reset(probe.handle)
        return version
    }

    /// Each attempt already spends the wrapper's 1 s busy timeout before `BEGIN IMMEDIATE` returns
    /// `SQLITE_BUSY`, so bound the retry by wall clock rather than an attempt count: a second
    /// instance launched during a long rebuild must not freeze the caller. Non-BUSY errors rethrow
    /// immediately.
    private func beginImmediate() throws {
        let deadline = Date().addingTimeInterval(2)
        while true {
            do {
                try sql.run("BEGIN IMMEDIATE")
                return
            } catch {
                guard sqlite3_errcode(sql.db) == SQLITE_BUSY, Date() < deadline else { throw error }
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
    }

    private func migrate() throws {
        if readOnly {
            // A read-only instance must not run against an empty or stale database: every search
            // would otherwise fail with "no such table: chunks" instead of a clear error.
            guard try storedVersion() == Int64(Self.schemaVersion) else {
                throw ContentIndexError.database("Content index is not schema version \(Self.schemaVersion)")
            }
            return
        }
        // Neither pragma can run inside a transaction. A failed journal_mode conversion is reported
        // by returning the current mode, while a contended one raises SQLITE_BUSY because this
        // pragma does not invoke the busy handler. Either way indexing must still proceed with
        // serialised readers and writers, so record usesWAL instead of failing the open.
        do {
            let journal = try sql.prepare("PRAGMA journal_mode=WAL")
            usesWAL = (try step(journal)) && journal.text(0).lowercased() == "wal"
            sqlite3_reset(journal.handle)
        } catch {
            guard sqlite3_errcode(sql.db) == SQLITE_BUSY else { throw error }
            usesWAL = false
        }
        try sql.run("PRAGMA foreign_keys=ON")
        // BEGIN IMMEDIATE serialises two writable connections opening the same fresh database: the
        // loser waits, then re-probes the version below and skips the winner's rebuild.
        try beginImmediate()
        do {
            if try storedVersion() != Int64(Self.schemaVersion) {
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
                        -- Also covers WHERE file=? lookups, so no separate index on (file) is needed.
                        UNIQUE(file, ordinal));
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
            // Resetting a statement an outer loop is iterating would end that loop silently, so
            // this is thrown rather than asserted: asserts are stripped from release builds.
            guard sqlite3_stmt_busy(existing.handle) == 0 else {
                throw ContentIndexError.database("Re-entrant use of statement: \(query)")
            }
            sqlite3_reset(existing.handle); sqlite3_clear_bindings(existing.handle); return existing
        }
        let created = try sql.prepare(query); statements[query] = created; return created
    }

    func count() throws -> Int {
        let statement = try statement("SELECT COUNT(*) FROM files")
        defer { sqlite3_reset(statement.handle) }
        guard try step(statement) else { return 0 }
        return Int(statement.int(0))
    }
}

extension ContentIndex {
    /// `AITopicStatement.next()` throws the shared wrapper's error type; callers of this class
    /// should only ever see `ContentIndexError`.
    @discardableResult
    func step(_ statement: AITopicStatement) throws -> Bool {
        do { return try statement.next() }
        catch { throw ContentIndexError.database(error.localizedDescription) }
    }

    func file(path: String) throws -> (record: ContentFileRecord, id: Int64, revision: Int64)? {
        let statement = try statement("SELECT id, size, mtime, kind, parser, revision FROM files WHERE path=?")
        defer { sqlite3_reset(statement.handle) }
        statement.bind([path])
        guard try step(statement) else { return nil }
        let record = ContentFileRecord(path: path, size: statement.int(1), mtime: statement.int(2),
                                       kind: UInt8(truncatingIfNeeded: statement.int(3)), parser: statement.text(4))
        return (record, statement.int(0), statement.int(5))
    }

    // Do not add a second `file(path:)` overload that differs only in return type:
    // `try index.file(path: p)?.revision` would then be ambiguous, and the tests rely on it.
    @discardableResult
    func upsert(file record: ContentFileRecord) throws -> Int64 {
        if let existing = try file(path: record.path) {
            guard existing.record.size != record.size || existing.record.mtime != record.mtime
                || existing.record.kind != record.kind || existing.record.parser != record.parser else {
                return existing.id
            }
            let statement = try statement("UPDATE files SET size=?, mtime=?, kind=?, parser=?, revision=revision+1 WHERE id=?")
            defer { sqlite3_reset(statement.handle) }
            statement.bind([String(record.size), String(record.mtime), String(record.kind),
                            record.parser, String(existing.id)])
            _ = try step(statement)
            return existing.id
        }
        let statement = try statement("INSERT INTO files(path,size,mtime,kind,parser) VALUES(?,?,?,?,?)")
        defer { sqlite3_reset(statement.handle) }
        statement.bind([record.path, String(record.size), String(record.mtime),
                        String(record.kind), record.parser])
        _ = try step(statement)
        return sqlite3_last_insert_rowid(sql.db)
    }

    /// Metadata and chunks must commit together: `plan` decides whether to re-parse from the
    /// stored size/mtime/parser, so committing new metadata with old chunks would make every
    /// later sync skip the file and leave stale text searchable forever.
    @discardableResult
    func store(file record: ContentFileRecord, chunks: [ContentChunk]) throws -> Int64 {
        try transaction {
            let id = try upsert(file: record)
            try replaceChunks(file: id, chunks: chunks)
            return id
        }
    }

    func replaceChunks(file id: Int64, chunks: [ContentChunk]) throws {
        try transaction {
            // The `chunk_postings_delete` trigger drops the matching postings.
            let drop = try statement("DELETE FROM chunks WHERE file=?")
            drop.bind([String(id)]); _ = try step(drop); sqlite3_reset(drop.handle)
            // The blob column is last so the text binds can use one `bind` call.
            let insert = try statement("INSERT INTO chunks(file,ordinal,label,bytes,folded) VALUES(?,?,?,?,?)")
            let fts = try statement("INSERT INTO chunk_fts(rowid,grams) VALUES(?,?)")
            var seen = Set<Int>()
            for chunk in chunks {
                // The `UNIQUE(file, ordinal)` constraint would otherwise surface as a raw SQLite
                // string; throw before the row is written so the caller learns what is wrong.
                guard seen.insert(chunk.ordinal).inserted else {
                    throw ContentIndexError.database("Duplicate chunk ordinal \(chunk.ordinal)")
                }
                // Grams must come from the folded text: `AITopicIndex` builds document grams
                // from folded text (AITopicIndex.swift:274) and folds the query before gramming
                // it (:618), so gramming raw text here would make matches case-sensitive.
                let foldedText = AITopicIndex.fold(chunk.text)
                // Guards the `bytes` CHECK, which would reject this body anyway, so nothing is
                // compressed only to be refused by the constraint.
                guard foldedText.utf8.count <= ContentCompression.maxBodyBytes else {
                    throw ContentIndexError.database("Chunk body of \(foldedText.utf8.count) bytes exceeds the limit")
                }
                let folded = Data(foldedText.utf8)
                let packed = ContentCompression.pack(folded, compact: true)
                // `bytes` is the UNCOMPRESSED length: unpack decodes in one exact-size pass.
                insert.bind([String(id), String(chunk.ordinal), chunk.label, String(folded.count)])
                Self.bindBlob(packed, at: 5, into: insert)
                _ = try step(insert)
                let rowid = sqlite3_last_insert_rowid(sql.db)
                sqlite3_reset(insert.handle)
                let grams = try AITopicIndex.grams(foldedText, checkpoint: nil)
                fts.bind([String(rowid), grams]); _ = try step(fts); sqlite3_reset(fts.handle)
            }
        }
    }

    static func bindBlob(_ data: Data, at column: Int32, into statement: AITopicStatement) {
        // An empty array's base address is nil, and SQLite reads a nil pointer as SQL NULL, which
        // `folded BLOB NOT NULL` rejects. Use a non-null pointer with a zero length instead.
        let bytes = data.isEmpty ? [UInt8](repeating: 0, count: 1) : [UInt8](data)
        _ = bytes.withUnsafeBufferPointer {
            sqlite3_bind_blob(statement.handle, column, $0.baseAddress, Int32(data.count),
                              unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }

    func chunkCount(file id: Int64) throws -> Int {
        let statement = try statement("SELECT COUNT(*) FROM chunks WHERE file=?")
        defer { sqlite3_reset(statement.handle) }
        statement.bind([String(id)])
        guard try step(statement) else { return 0 }
        return Int(statement.int(0))
    }

    func removeFile(path: String) throws {
        // Probe outside the transaction so removing an absent path takes no write lock.
        guard let existing = try file(path: path) else { return }
        try transaction {
            // Cascades to `chunks`, whose delete trigger drops the postings.
            let drop = try statement("DELETE FROM files WHERE id=?")
            drop.bind([String(existing.id)]); _ = try step(drop); sqlite3_reset(drop.handle)
        }
    }

    /// Removes every file whose path starts with `prefix`. `prefix` must end with "/", otherwise a
    /// prefix such as "/Volumes/X" would also match "/Volumes/Xavier/…".
    ///
    /// A range query rather than `LIKE`: SQLite's default LIKE is ASCII-case-insensitive, which
    /// would delete `/Volumes/backup/…` for the prefix `/Volumes/Backup/`, and the range also
    /// uses the `UNIQUE(path)` index instead of scanning.
    func removeFiles(prefix: String) throws {
        // An empty prefix would otherwise match every path and wipe the whole index.
        guard !prefix.isEmpty else { return }
        let statement = try statement("SELECT path FROM files WHERE path >= ?1 AND path < ?2")
        statement.bind([prefix, prefix + "\u{10FFFF}"])
        var paths: [String] = []
        while try step(statement) { paths.append(statement.text(0)) }
        // Reset before writing: `BEGIN IMMEDIATE` while a SELECT is still active on this
        // connection is the lock pattern this project has already been bitten by.
        sqlite3_reset(statement.handle)
        // One transaction for the whole prefix, so a failure cannot leave half a volume gone.
        try transaction { for path in paths { try removeFile(path: path) } }
    }

    @discardableResult
    func transaction<T>(_ work: () throws -> T) throws -> T {
        // `sqlite3_get_autocommit` reports SQLite's own state, so unlike a separate flag it cannot
        // desynchronise when a best-effort ROLLBACK fails and leave the connection unusable.
        if sqlite3_get_autocommit(sql.db) == 0 { return try work() }
        try sql.run("BEGIN IMMEDIATE")
        do {
            let result = try work()
            try sql.run("COMMIT")
            return result
        } catch {
            try? sql.run("ROLLBACK")
            throw error
        }
    }
}
