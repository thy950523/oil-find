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

/// A file as seen in the file index. `size`, `mtime` and `mtimeNsec` form the identity used by
/// incremental sync; `kind` is the file-index kind (3 = document, 4 = image) and `parser` is the
/// identifier of the `ContentParser` that produced its chunks.
struct ContentFileRecord {
    let path: String
    let size: Int64
    let mtime: Int64
    /// Nanosecond part of the modification time, 0..999_999_999. `mtime` alone is whole seconds,
    /// which cannot tell two edits inside one second apart.
    let mtimeNsec: Int64
    let kind: UInt8
    let parser: String

    /// `mtimeNsec` defaults to 0 so a caller that only cares about second resolution — most tests,
    /// and any future source of records without sub-second stamps — reads unchanged.
    init(path: String, size: Int64, mtime: Int64, mtimeNsec: Int64 = 0, kind: UInt8, parser: String) {
        self.path = path
        self.size = size
        self.mtime = mtime
        self.mtimeNsec = mtimeNsec
        self.kind = kind
        self.parser = parser
    }
}

/// A verified content match inside one file. `path` is the absolute path, never an entry id: the
/// file index renumbers entry ids on compaction, so a stored id would point at another file.
struct ContentHit {
    let path: String
    /// File-index kind (3 = document, 4 = image); the provider uses it to decide thumbnails.
    let kind: UInt8
    let label: String
    let snippet: String
    let highlights: [NSRange]
}

/// A read-only or read-write connection. Each connection is confined to its caller's queue.
final class ContentIndex {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Oil Find/content/index.sqlite")

    /// Bumped whenever the canonical schema changes. The index is derived and rebuildable, so a
    /// mismatch is repaired by rebuilding rather than migrated column by column.
    static let schemaVersion = 2

    let sql: AITopicSQL
    /// False when the database could not be switched to WAL mode, which some network home
    /// directories refuse. Indexing still works, but readers and writers serialise instead of
    /// overlapping. Task 11 logs this.
    private(set) var usesWAL = true
    private let readOnly: Bool
    private var statements: [String: AITopicStatement] = [:]

    /// Bounds the write lock to one batch of parses. `parse` can spend hundreds of milliseconds per
    /// image, so one transaction over the whole plan would hold the lock across hours of work and
    /// let the WAL grow without bound; a batch keeps a throw resumable, because earlier batches stay
    /// committed, and avoids one fsync per file on a large first sync.
    ///
    /// An instance property rather than a constant so tests can shrink it and exercise the chunk
    /// loop, including its final partial batch.
    var applyChunkSize = 256

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
                try run("BEGIN IMMEDIATE")
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
        try run("PRAGMA foreign_keys=ON")
        // BEGIN IMMEDIATE serialises two writable connections opening the same fresh database: the
        // loser waits, then re-probes the version below and skips the winner's rebuild.
        try beginImmediate()
        do {
            if try storedVersion() != Int64(Self.schemaVersion) {
                try run("""
                    DROP TRIGGER IF EXISTS chunk_postings_delete;
                    DROP TABLE IF EXISTS chunk_fts;
                    DROP TABLE IF EXISTS chunks;
                    DROP TABLE IF EXISTS files;
                    """)
                try run("""
                    CREATE TABLE files(
                        -- AUTOINCREMENT: chunks reference files.id; rowid reuse after a delete would let a stale chunk attach to a new file.
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        path TEXT NOT NULL UNIQUE,
                        size INTEGER NOT NULL,
                        mtime INTEGER NOT NULL,
                        -- Sub-second part of the modification time. Without it a second edit inside
                        -- the same second that leaves the size alone is indistinguishable from the
                        -- first, and the stale text stays searchable.
                        mtime_nsec INTEGER NOT NULL,
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
                try run("PRAGMA user_version = \(Self.schemaVersion)")
            }
            try run("COMMIT")
        } catch {
            try? run("ROLLBACK")
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

    /// Mirrors `step`: `AITopicSQL.run` throws the shared wrapper's error type, and callers of
    /// this class should only ever see `ContentIndexError`.
    func run(_ sql: String) throws {
        do { try self.sql.run(sql) }
        catch { throw ContentIndexError.database(error.localizedDescription) }
    }

    func file(path: String) throws -> (record: ContentFileRecord, id: Int64, revision: Int64)? {
        let statement = try statement("SELECT id, size, mtime, mtime_nsec, kind, parser, revision FROM files WHERE path=?")
        defer { sqlite3_reset(statement.handle) }
        statement.bind([path])
        guard try step(statement) else { return nil }
        let record = ContentFileRecord(path: path, size: statement.int(1), mtime: statement.int(2),
                                       mtimeNsec: statement.int(3),
                                       kind: UInt8(truncatingIfNeeded: statement.int(4)), parser: statement.text(5))
        return (record, statement.int(0), statement.int(6))
    }

    // Do not add a second `file(path:)` overload that differs only in return type:
    // `try index.file(path: p)?.revision` would then be ambiguous, and the tests rely on it.
    @discardableResult
    func upsert(file record: ContentFileRecord) throws -> Int64 {
        if let existing = try file(path: record.path) {
            guard existing.record.size != record.size || existing.record.mtime != record.mtime
                || existing.record.mtimeNsec != record.mtimeNsec
                || existing.record.kind != record.kind || existing.record.parser != record.parser else {
                return existing.id
            }
            let statement = try statement("UPDATE files SET size=?, mtime=?, mtime_nsec=?, kind=?, parser=?, revision=revision+1 WHERE id=?")
            defer { sqlite3_reset(statement.handle) }
            statement.bind([String(record.size), String(record.mtime), String(record.mtimeNsec),
                            String(record.kind), record.parser, String(existing.id)])
            _ = try step(statement)
            return existing.id
        }
        let statement = try statement("INSERT INTO files(path,size,mtime,mtime_nsec,kind,parser) VALUES(?,?,?,?,?,?)")
        defer { sqlite3_reset(statement.handle) }
        statement.bind([record.path, String(record.size), String(record.mtime),
                        String(record.mtimeNsec), String(record.kind), record.parser])
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

    /// Drops every indexed file. `chunks` cascades from `files` and the `chunk_postings_delete`
    /// trigger drops the matching FTS rows, so this one statement is the whole operation: deleting
    /// from `chunks` or `chunk_fts` separately would double up the work and can miss rows.
    func clear() throws {
        try run("DELETE FROM files")
    }

    @discardableResult
    func transaction<T>(_ work: () throws -> T) throws -> T {
        // `sqlite3_get_autocommit` reports SQLite's own state, so unlike a separate flag it cannot
        // desynchronise when a best-effort ROLLBACK fails and leave the connection unusable.
        if sqlite3_get_autocommit(sql.db) == 0 { return try work() }
        try run("BEGIN IMMEDIATE")
        do {
            let result = try work()
            try run("COMMIT")
            return result
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }
}

extension ContentIndex {
    /// Finds the files whose text contains every whitespace-separated term in `text`. The gram
    /// postings only narrow the candidate set, so every candidate is verified byte by byte before
    /// it is returned. Cancellation returns nothing rather than a partial result.
    func search(_ text: String, limit: Int, isCancelled: () -> Bool) throws -> [ContentHit] {
        let terms = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard limit > 0, !terms.isEmpty else { return [] }
        // The body is stored folded, so the terms must be folded before they are grammed or matched;
        // otherwise the match would be case-sensitive.
        let folded = terms.map { AITopicIndex.fold($0) }
        // Grams of every term, ANDed together. This is only a superset filter: the AND admits
        // false positives across grams and across chunks, which the byte scan below removes.
        let query = Set(try folded.flatMap { term in
            try AITopicIndex.grams(term, query: true, checkpoint: nil).components(separatedBy: " AND ")
        }).sorted().joined(separator: " AND ")
        guard !query.isEmpty else { return [] }
        if isCancelled() { return [] }

        let statement = try statement("""
            SELECT c.id, f.path, f.kind, c.ordinal, c.label, c.folded, c.bytes
            FROM chunk_fts JOIN chunks c ON c.id = chunk_fts.rowid
                           JOIN files f ON f.id = c.file
            WHERE chunk_fts MATCH ?
            ORDER BY rank
            """)
        defer { sqlite3_reset(statement.handle) }
        statement.bind([query])

        let needles = folded.map { [UInt8]($0.utf8) }
        var best: [String: ContentHit] = [:]
        var bestHighlights: [String: Int] = [:]
        while try step(statement) {
            if isCancelled() { return [] }
            // A NULL or undecodable body is skipped rather than fatal: one damaged chunk must not
            // abort the whole query.
            guard let body = try? ContentCompression.unpack(blob(statement, 5), bytes: Int(statement.int(6)))
            else { continue }
            let haystack = [UInt8](body)
            // Every term must literally occur, so a row matched only by the gram AND is rejected.
            var matchesAll = true
            for needle in needles where Self.byteRanges(of: needle, in: haystack).isEmpty {
                matchesAll = false
                break
            }
            guard matchesAll else { continue }

            let path = statement.text(1)
            let snippet = Self.snippet(text: String(decoding: body, as: UTF8.self), terms: folded)
            // One row per file: keep the chunk carrying the most highlights.
            if snippet.highlights.count > (bestHighlights[path] ?? -1) {
                best[path] = ContentHit(path: path,
                                        kind: UInt8(truncatingIfNeeded: statement.int(2)),
                                        label: statement.text(4),
                                        snippet: snippet.text,
                                        highlights: snippet.highlights)
                bestHighlights[path] = snippet.highlights.count
            }
            if best.count >= limit { break }
        }
        return best.values.sorted { $0.path < $1.path }
    }

    /// Non-overlapping occurrences of `needle` in `haystack`. A valid UTF-8 lead byte is never a
    /// continuation byte, so a match can never start in the middle of a multi-byte scalar.
    private static func byteRanges(of needle: [UInt8], in haystack: [UInt8]) -> [Range<Int>] {
        guard !needle.isEmpty, needle.count <= haystack.count else { return [] }
        var result: [Range<Int>] = []
        var i = 0
        let last = haystack.count - needle.count
        while i <= last {
            if haystack[i] == needle[0] {
                var j = 1
                while j < needle.count, haystack[i + j] == needle[j] { j += 1 }
                if j == needle.count {
                    result.append(i ..< i + needle.count)
                    // Non-overlapping: resume after the hit rather than one byte past it.
                    i += needle.count
                    continue
                }
            }
            i += 1
        }
        return result
    }

    /// A window of `text` centred on the first term, with the ranges of every term inside it.
    /// `before` and `after` are UTF-16 units, and the ranges are UTF-16 offsets into the decoded
    /// string: byte offsets do not map linearly onto them. At most 20 highlights are collected,
    /// and only those that fall inside the displayed window are kept.
    private static func snippet(text: String, terms: [String], before: Int = 40, after: Int = 60)
        -> (text: String, highlights: [NSRange]) {
        let ns = text as NSString
        let length = ns.length
        guard length > 0 else { return ("", []) }
        var first = Int.max
        for term in terms where !term.isEmpty {
            let found = ns.range(of: term)
            if found.location != NSNotFound, found.location < first { first = found.location }
        }
        guard first != Int.max else { return ("", []) }
        let start = max(0, first - before)
        let end = min(length, first + after)
        let window = NSRange(location: start, length: end - start)
        var highlights: [NSRange] = []
        for term in terms where !term.isEmpty {
            var search = NSRange(location: 0, length: length)
            while highlights.count < 20 {
                let found = ns.range(of: term, options: [], range: search)
                if found.location == NSNotFound { break }
                if found.location >= start, NSMaxRange(found) <= end {
                    highlights.append(NSRange(location: found.location - start, length: found.length))
                }
                let next = NSMaxRange(found)
                if next <= search.location { break }
                search = NSRange(location: next, length: length - next)
            }
            if highlights.count >= 20 { break }
        }
        highlights.sort { $0.location < $1.location }
        return (ns.substring(with: window), highlights)
    }

    /// `folded` is `BLOB NOT NULL`, so a NULL here means a corrupt row: return empty data, which
    /// `unpack` rejects, so the row is skipped instead of aborting the query.
    private func blob(_ statement: AITopicStatement, _ column: Int32) -> Data {
        guard sqlite3_column_type(statement.handle, column) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement.handle, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement.handle, column)))
    }
}

extension ContentIndex {
    /// The diff between a candidate snapshot of the file index and the rows already stored.
    /// `removed` is only populated for a complete enumeration: see `plan`.
    struct SyncPlan {
        var added: [ContentFileRecord] = []
        var changed: [ContentFileRecord] = []
        var unchanged: [ContentFileRecord] = []
        var removed: [String] = []
    }

    /// Classifies `candidates` against the stored rows. `size`, `mtime`, `mtimeNsec` and `parser`
    /// all equal means the file is already indexed exactly as it stands; any difference forces a
    /// re-parse, and an absent row is new.
    ///
    /// `complete` is false when the candidate enumeration could not finish. `removed` is computed
    /// only when `complete` is true, from a complete snapshot: deleting on a partial one would wipe
    /// every file the interrupted scan had not reached yet, so an incomplete enumeration deletes
    /// nothing.
    func plan(candidates: [ContentFileRecord], complete: Bool = true) throws -> SyncPlan {
        var result = SyncPlan()
        var seen = Set<String>()
        seen.reserveCapacity(candidates.count)
        for candidate in candidates {
            seen.insert(candidate.path)
            guard let existing = try file(path: candidate.path) else {
                result.added.append(candidate)
                continue
            }
            if existing.record.size == candidate.size, existing.record.mtime == candidate.mtime,
               existing.record.mtimeNsec == candidate.mtimeNsec,
               existing.record.parser == candidate.parser {
                result.unchanged.append(candidate)
            } else {
                result.changed.append(candidate)
            }
        }
        guard complete else { return result }
        // Swift has `for ... where` but no `while ... where`, so the membership test lives in the
        // body. The stored paths absent from the snapshot are the files the file system dropped.
        let statement = try statement("SELECT path FROM files")
        // `defer`, unlike `removeFiles(prefix:)`'s trailing reset, because nothing is written after
        // this scan. Without it a throwing `step` leaves the statement busy, and `statement(_:)`
        // then refuses to hand it out, silently disabling removal detection for the connection.
        defer { sqlite3_reset(statement.handle) }
        while try step(statement) {
            let path = statement.text(0)
            if !seen.contains(path) { result.removed.append(path) }
        }
        return result
    }

    /// Applies a plan. Deletions come first, as the spec requires; `removed` is disjoint from
    /// `added` and `changed` by construction, so the order is not load-bearing for correctness.
    ///
    /// A record whose parse returns nil keeps its existing row untouched: a transient failure
    /// (cancellation, a locked file) must not replace successfully indexed text with nothing, and
    /// the old metadata is what makes the next run classify the file as `changed` and retry it.
    /// Committing the metadata first would mark the file `unchanged` and never retry. An empty
    /// array is a different answer: the file parsed and genuinely has no text, so its chunks are
    /// cleared and its new metadata is stored.
    func apply(_ plan: SyncPlan, parse: (ContentFileRecord) -> [ContentChunk]?) throws {
        // Deletions do no parsing, so one transaction over the whole list is bounded by the delete
        // count, matching `removeFiles(prefix:)`. `removeFile` probes before its own transaction, so
        // no statement is active when this `BEGIN IMMEDIATE` runs.
        try transaction { for path in plan.removed { try removeFile(path: path) } }
        let records = plan.added + plan.changed
        var start = records.startIndex
        while start < records.endIndex {
            // `index(_:offsetBy:limitedBy:)` rather than integer arithmetic, so the chunking stays
            // correct if the collection type changes.
            let end = records.index(start, offsetBy: applyChunkSize, limitedBy: records.endIndex)
                ?? records.endIndex
            try transaction {
                for record in records[start..<end] {
                    guard let chunks = parse(record) else { continue }
                    try store(file: record, chunks: chunks)
                }
            }
            start = end
        }
    }
}
