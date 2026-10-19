import Foundation
import OilFindCore

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

    func synchronize(store: IndexStore, isCancelled: () -> Bool) throws {
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
                                                   kind: kind,
                                                   parser: parser.identifier))
                }
            }
            candidates.append(contentsOf: batch)
            // Advance before testing the bound: testing first would skip the final partial batch.
            offset += step
            guard offset < total else { break }
            budget.checkpoint(isCancelled: isCancelled)
        }

        let plan = try index.plan(candidates: candidates, complete: complete)
        try index.apply(plan) { [unowned self] record in
            // Returning nil keeps the existing row and metadata, so a cancelled or locked file is
            // retried on the next run instead of being stored as empty.
            guard !isCancelled() else { return nil }
            guard let parser = parser(for: record.path, kind: record.kind) else { return nil }
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
