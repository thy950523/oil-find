import Foundation

/// The database runs in WAL mode, so the sidecars are left behind if only the main file goes.
func removeContentDatabase(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
    }
}

/// A fresh database URL in the temp directory, named so leftovers are easy to spot.
func makeContentDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("content-" + UUID().uuidString + ".sqlite")
}
