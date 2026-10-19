import Combine
import Foundation
import OilFindCore

/// Owns the content index: its two SQLite connections, the indexer that fills them, and the state
/// the settings pane renders. The content index is derived from the file index, so this manager
/// reacts to file-index changes instead of scanning the file system itself.
final class ContentManager: ObservableObject {
    /// Persisted preference key. Kept as a constant so tests can construct managers on an isolated
    /// suite and read the same key back.
    static let enabledKey = "contentSearchEnabled"

    @Published private(set) var enabled: Bool
    @Published private(set) var indexing = false
    @Published private(set) var count = 0
    @Published private(set) var diskBytes: Int64 = 0
    @Published private(set) var failed = 0

    let provider: ContentSearchProvider
    /// Supplies the host's file index. `AppDelegate` installs it before the first `start()`; while
    /// the index is still loading it returns nil, in which case `start()` is a no-op.
    var storeProvider: (() -> IndexStore?)?

    private let defaults: UserDefaults
    private let indexURL: URL?
    private let writer: ContentIndex?
    private let reader: ContentIndex?
    private let indexer: ContentIndexer?
    /// Every database statement runs here. The worker and a clear share this one serial queue, so a
    /// delete can never overlap a sync.
    private let queue = DispatchQueue(label: "com.oiloil.find.content.index", qos: .utility)
    private let lock = NSLock()
    private var generation = 0
    private var cancelled = false

    /// `indexURL: nil` is completely lazy: no database is opened and no file is written. Tests pass
    /// nil so they never touch the user's real Application Support directory.
    init(defaults: UserDefaults = .standard, indexURL: URL? = ContentIndex.defaultURL) {
        self.defaults = defaults
        self.indexURL = indexURL
        let enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? false
        self.enabled = enabled
        var writer: ContentIndex?
        var reader: ContentIndex?
        var indexer: ContentIndexer?
        if let indexURL {
            // Open the writer first: it creates and migrates the schema the reader requires. Both
            // opens happen on the calling thread (main, at startup) and are bounded, because
            // `ContentIndex` gives up on the migration lock after 2 s, so a concurrent rebuild can
            // slow startup but cannot hang it.
            writer = try? ContentIndex(url: indexURL)
            reader = try? ContentIndex(url: indexURL, readOnly: true)
            if let writer {
                indexer = ContentIndexer(index: writer, parsers: [TextParser(), ImageOCRParser()])
            }
        }
        self.writer = writer
        self.reader = reader
        self.indexer = indexer
        // The provider searches through the read-only connection; when that could not be opened the
        // index is nil and every search returns nothing.
        provider = ContentSearchProvider(index: reader)
        provider.isEnabled = enabled
    }

    /// The master switch. The provider gate is flipped synchronously, so turning the switch off
    /// retracts content hits on the next render; persistence and the worker follow.
    func setEnabled(_ value: Bool) {
        enabled = value
        provider.isEnabled = value
        defaults.set(value, forKey: Self.enabledKey)
        if value { start() } else { stop() }
    }

    /// Called by `AppDelegate` whenever the file index changes. Content indexing is expensive, so
    /// bursts are coalesced: while a pass is already in flight the new state is picked up by that
    /// pass's next read, and starting a second one would only race it.
    func fileIndexChanged() {
        guard !indexing else { return }
        start()
    }

    /// Begins a sync pass when content search is on, the index is open and the host has a file
    /// index yet. The generation is bumped before the queue hop so a concurrent `stop()` can
    /// invalidate this run.
    func start() {
        guard enabled, let indexer, storeProvider?() != nil else { return }
        lock.lock(); generation += 1; let mine = generation; cancelled = false; lock.unlock()
        indexing = true
        queue.async { [weak self] in
            guard let self else { return }
            // The file index can disappear between the guard above and this hop (a rescan replaces
            // the store). Finishing the round with nothing to do still clears `indexing` below; an
            // early return here would leave the UI stuck on "indexing" forever.
            var hardFailure = false
            if let store = self.storeProvider?() {
                do { try indexer.synchronize(store: store, isCancelled: { self.isCancelled(mine) }) }
                catch { hardFailure = true }
            }
            // Read the count on this queue: it is the writer's owner, so no statement races it.
            let total = (try? self.writer?.count()) ?? 0
            let failures = indexer.failedCount + (hardFailure ? 1 : 0)
            let bytes = Self.diskBytes(at: self.indexURL)
            DispatchQueue.main.async {
                guard !self.isCancelled(mine) else { return }
                self.indexing = false
                self.count = total
                self.failed = failures
                self.diskBytes = bytes
            }
        }
    }

    /// Invalidates any in-flight run and stops reporting progress. The worker checks `isCancelled`
    /// between files and its backfill is dropped, so a stale pass cannot publish counts over a
    /// newer one. `indexing` is cleared here as well: the cancelled pass's backfill is skipped, so
    /// otherwise the pane would show a permanent "building" state after the feature is turned off.
    func stop() {
        lock.lock(); generation += 1; cancelled = true; lock.unlock()
        indexing = false
    }

    /// Stops any run and drops every indexed file.
    func clear() {
        stop()
        enqueueClear()
    }

    /// Rebuilds from scratch: drop everything, then index again.
    func rebuild() {
        clear()
        start()
    }

    /// The delete runs on the indexer's serial queue, so it can never overlap a sync.
    private func enqueueClear() {
        queue.async { [weak self] in
            guard let self, let writer = self.writer else { return }
            try? writer.clear()
            let total = (try? writer.count()) ?? 0
            let bytes = Self.diskBytes(at: self.indexURL)
            DispatchQueue.main.async {
                self.count = total
                self.diskBytes = bytes
            }
        }
    }

    /// True when the run identified by `mine` has been superseded, either by a newer `start()` or
    /// by `stop()`.
    private func isCancelled(_ mine: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled || generation != mine
    }

    /// The size of the database including its WAL sidecars; the main file alone understates a
    /// running index.
    private static func diskBytes(at url: URL?) -> Int64 {
        guard let url else { return 0 }
        return ["", "-wal", "-shm"].reduce(Int64(0)) { total, suffix in
            total + ((try? FileManager.default.attributesOfItem(atPath: url.path + suffix)[.size]
                as? NSNumber)?.int64Value ?? 0)
        }
    }
}
