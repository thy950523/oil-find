import Foundation
import OilFindCore

/// How far a sync pass has got, for the settings pane. A pass enumerates candidates from the file
/// index and then parses them; both phases know their total, so the pane can show real progress
/// instead of one unchanging sentence.
struct ContentIndexProgress: Equatable {
    enum Phase: Equatable {
        /// Walking the file index for candidates. `total` is the file index's row count.
        case scanning
        /// Parsing candidates. `total` is the candidate count, known once enumeration finishes.
        case parsing
    }

    let phase: Phase
    let done: Int
    let total: Int
}

/// Walks the file index, asks the matching parser for each document or image, and applies the
/// resulting diff. Candidates come from the file index rather than the file system, so the index's
/// scope, excluded folders and excluded extensions all apply automatically.
final class ContentIndexer {
    /// Parse failures seen by the last `synchronize`. Cancellation is not counted: it is a normal
    /// interruption, not a damaged file.
    private(set) var failedCount = 0
    /// Instance property rather than a constant so tests can shrink it and cover the final partial
    /// batch.
    var batchSize = 20_000

    private let index: ContentIndex
    private let parsers: [ContentParser]
    private let budget: AITopicWorkBudget

    init(index: ContentIndex,
         parsers: [ContentParser],
         budget: AITopicWorkBudget = AITopicWorkBudget(fraction: 0.10),
         batchSize: Int = 20_000) {
        self.index = index
        self.parsers = parsers
        self.budget = budget
        self.batchSize = batchSize
    }

    func synchronize(store: IndexStore, isCancelled: () -> Bool,
                     progress: (ContentIndexProgress) -> Void = { _ in }) throws {
        failedCount = 0
        var candidates: [ContentFileRecord] = []
        var offset = 0
        var complete = true
        let step = max(1, batchSize)

        while true {
            if isCancelled() {
                // A partial snapshot must not delete anything: see `ContentIndex.plan`.
                complete = false
                break
            }
            var total = 0
            var batch: [ContentFileRecord] = []
            // Reading in batches keeps the file index's reader lock from spanning a million entries,
            // which would block indexing and compaction. `count` grows while a scan runs, so it is
            // read inside the same lock and the batch size carries it out.
            store.read {
                total = store.count
                let end = min(offset + step, total)
                guard offset < end else { return }
                batch.reserveCapacity(end - offset)
                for position in offset..<end {
                    let kind = store.kind[position]
                    // Deleted entries stay in the SoA until compaction. Indexing one would
                    // resurrect a file the scanner already dropped.
                    guard kind == 3 || kind == 4,
                          store.flags[position] & (SiftFlag.dir | SiftFlag.deleted) == 0 else { continue }
                    let id = UInt32(position)
                    let path = store.path(id)
                    guard let parser = parser(for: path, kind: kind) else { continue }
                    batch.append(ContentFileRecord(path: path,
                                                   size: Int64(store.size(id)),
                                                   mtime: Int64(store.mtime[position]),
                                                   mtimeNsec: Int64(store.mtimeNsec[position]),
                                                   kind: kind,
                                                   parser: parser.identifier))
                }
            }
            candidates.append(contentsOf: batch)
            // Advance before testing the bound: testing first would skip the final partial batch.
            offset += step
            // Report the count read inside the lock rather than `offset`: the file index can grow
            // while this runs, and a `done` past its own `total` would read as a bar going backwards.
            progress(ContentIndexProgress(phase: .scanning, done: min(offset, total), total: total))
            guard offset < total else { break }
            budget.checkpoint(isCancelled: isCancelled)
        }

        let plan = try index.plan(candidates: candidates, complete: complete)
        // Parsing totals what actually needs work, not the candidate count: a pass over an unchanged
        // index parses nothing, and totalling the candidates would leave the pane at 0 of millions.
        let work = plan.added.count + plan.changed.count
        var parsed = 0
        // `complete` is false only when cancellation cut the enumeration short, and that pass ends
        // here: reporting a parsing phase that will never advance would flash a phase at the user.
        if complete { progress(ContentIndexProgress(phase: .parsing, done: 0, total: work)) }
        try index.apply(plan) { [unowned self] record in
            parsed += 1
            if complete { progress(ContentIndexProgress(phase: .parsing, done: parsed, total: work)) }
            // Returning nil keeps the existing row and metadata, so a cancelled or locked file is
            // retried on the next run instead of being stored as empty.
            guard !isCancelled() else { return nil }
            guard let parser = parser(for: record.path, kind: record.kind) else { return nil }
            // Charge the CPU budget here, immediately before the expensive work. The checkpoint
            // after each enumeration batch above only meters the cheap directory walk, so without
            // this one OCR and PDF decoding run back to back and pin a core for the whole pass.
            // `checkpoint` returns at once while the fraction is not exceeded, so it is free when
            // there is headroom; it sleeps only once the thread has spent more than its share.
            budget.checkpoint(isCancelled: isCancelled)
            do {
                return try parser.parse(url: URL(fileURLWithPath: record.path),
                                        budget: budget, isCancelled: isCancelled)
            } catch ContentParserError.cancelled {
                return nil
            } catch {
                failedCount += 1
                return nil
            }
        }
    }

    /// Parsers are selected by kind and lowercased extension, not by concrete type, so the indexer
    /// stays independent of the list it was built with.
    private func parser(for path: String, kind: UInt8) -> ContentParser? {
        let ext = (path as NSString).pathExtension.lowercased()
        return parsers.first {
            $0.kinds.contains(kind) && ($0.extensions.contains("*") || $0.extensions.contains(ext))
        }
    }
}
