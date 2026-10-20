import XCTest
@testable import OilFindCore
import DiskArbitration
import Combine
@testable import OilFindApp

final class ExternalDriveTests: XCTestCase {
    private let uuid = "0A000000-0000-0000-0000-000000000001"
    private let secondUUID = "0A000000-0000-0000-0000-000000000002"
    private var volume: ExternalVolume { .init(uuid: uuid, name: "T7 Shield", path: "/Volumes/T7 Shield", device: "disk7") }
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("external-drive-tests-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func store(path: String) -> IndexStore {
        var buffer = ScanBuffer()
        buffer.ids = [0, 1]; buffer.parents = [0, 0]; buffer.sizes = [0, 1024]; buffer.mtimes = [0, 1_790_000_000]; buffer.mtimesNsec = [0, 0]
        buffer.flags = [1, 0x80]; buffer.depths = [2, 3]; buffer.kinds = [1, 3]
        buffer.nameLens = [0, 9]; buffer.nameBytes = Array("README.md".utf8)
        return IndexStore(scan: ScanOutput(buffers: [buffer], count: 2, homeIndex: .max, elapsed: 0, finishedAt: 0), config: IndexConfig(rootPath: path))
    }
    final class Monitor: ExternalDriveMonitoring {
        var onChange: (() -> Void)?
        var beforeEject: ((String) -> Void)?
        var beforeUnmount: ((String) -> Void)?
        var starts = 0, stops = 0
        func start() { starts += 1 }
        func stop() { stops += 1 }
    }
    final class Index: ExternalDriveIndex {
        var store: IndexStore?
        var state: IndexManager.State = .loading
        var scannedCount = 0
        var onStateChange: ((IndexManager.State) -> Void)?
        var onIndexChange: (() -> Void)?
        var starts = 0, stops = 0
        func start() { starts += 1 }
        var onStop: (() -> Void)?
        func stop() { stops += 1; onStop?() }
        func complete(_ store: IndexStore) { self.store = store; state = .ready; onIndexChange?(); onStateChange?(.ready) }
    }
    private func waitUntil(_ description: String, timeout: TimeInterval = 10,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } while ProcessInfo.processInfo.systemUptime < deadline
        _ = try XCTUnwrap(condition() ? true : nil, "Timed out waiting for " + description, file: file, line: line)
    }
    private func assertRemains(_ description: String, duration: TimeInterval,
                               file: StaticString = #filePath, line: UInt = #line,
                               _ condition: () -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + duration
        repeat {
            _ = try XCTUnwrap(condition() ? true : nil, description, file: file, line: line)
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } while ProcessInfo.processInfo.systemUptime < deadline
        _ = try XCTUnwrap(condition() ? true : nil, description, file: file, line: line)
    }

    func testVolumeEligibilityUsesLocalUserVisibleIdentityAndExcludesSpecialVolumes() {
        XCTAssertTrue(volume.eligible())
        var candidate = volume; candidate.local = false; XCTAssertFalse(candidate.eligible())
        candidate = volume; candidate.startup = true; XCTAssertFalse(candidate.eligible())
        candidate = volume; candidate.visible = false; XCTAssertFalse(candidate.eligible())
        candidate = volume; candidate.diskImage = true
        XCTAssertFalse(candidate.eligible()); XCTAssertTrue(candidate.eligible(allowDiskImages: true))
        candidate = volume; candidate.timeMachine = true; XCTAssertFalse(candidate.eligible())
        candidate = volume; candidate.writable = false; XCTAssertTrue(candidate.eligible())
        candidate.optical = true; XCTAssertFalse(candidate.eligible())
        candidate = volume; candidate.uuid = "../../outside"; XCTAssertFalse(candidate.eligible())
        for role in ["Preboot", "Recovery", "VM", "Update", "Backup"] {
            candidate = volume; candidate.roles = [role]; XCTAssertFalse(candidate.eligible())
        }
        candidate = volume; candidate.path = "/System/Volumes/Hidden"; XCTAssertFalse(candidate.eligible())
        candidate = volume; candidate.path = "/"; XCTAssertFalse(candidate.eligible())
    }

    func testDiskArbitrationCFUUIDIsDecodedForPartitionUnmount() throws {
        let value = try XCTUnwrap(CFUUIDCreateFromString(kCFAllocatorDefault, uuid as CFString))
        let description: [String: Any] = [kDADiskDescriptionVolumeUUIDKey as String: value]
        XCTAssertEqual(ExternalVolumeMonitor.volumeUUID(in: description), uuid)
        XCTAssertNil(ExternalVolumeMonitor.volumeUUID(in: [kDADiskDescriptionVolumeUUIDKey as String: "not-a-uuid"]))
    }

    func testUUIDCatalogPersistenceSurvivesRenameAndRejectsInvalidRecords() throws {
        let persistence = ExternalDrivePersistence(directory: temporaryDirectory()), date = Date(timeIntervalSince1970: 42)
        let record = ExternalDriveRecord(id: uuid.lowercased(), name: "Renamed", path: "/Volumes/T7 1", lastConnected: date, enabled: false)
        persistence.save(.init(enabled: false, drives: [record, record, .init(id: "../../outside", name: "Bad", path: "/tmp", lastConnected: date)]))
        let loaded = persistence.load()
        XCTAssertFalse(loaded.enabled); XCTAssertEqual(loaded.drives.count, 1)
        XCTAssertEqual(loaded.drives.first?.id, uuid); XCTAssertEqual(loaded.drives.first?.name, "Renamed")
        XCTAssertEqual(loaded.drives.first?.path, "/Volumes/T7 1"); XCTAssertFalse(try XCTUnwrap(loaded.drives.first).enabled)
        XCTAssertEqual(persistence.indexURL(uuid), persistence.indexURL(uuid.lowercased()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: persistence.metadataURL.path))
    }

    func testPreEjectStopsWholeDeviceBeforeReturningAndWithdrawsSources() throws {
        var indexes: [Index] = []
        let catalog = ExternalDriveCatalog(directory: temporaryDirectory(), monitor: Monitor(),
                                          initialPreferences: .init(), makeIndex: { _, _, _ in
            let index = Index(); indexes.append(index); return index
        })
        defer { catalog.stop() }
        var second = volume; second.uuid = secondUUID; second.name = "Second"; second.path = "/Volumes/Second"
        catalog.updateMounted([volume, second])
        for index in indexes { index.complete(store(path: volume.path)) }
        catalog.prepareToEject(device: "disk7")
        XCTAssertTrue(indexes.allSatisfy { $0.stops == 1 }, "Approvals must synchronously release every partition on the device")
        try waitUntil("ejected drive rows") { catalog.rows.count == 2 && catalog.rows.allSatisfy { $0.status == .offline } }
        XCTAssertTrue(catalog.searchSources().isEmpty)
        catalog.updateMounted([])
        XCTAssertEqual(indexes.count, 2, "Disconnecting never creates an offline index")
    }

    func testPartitionUnmountLeavesSiblingOnlineAndMasterSwitchRestoresCancelledEject() throws {
        var second = volume; second.uuid = secondUUID; second.name = "Second"; second.path = "/Volumes/Second"
        var mounted = [volume, second], indexes: [Index] = [], indexesByID: [String: Index] = [:]
        let catalog = ExternalDriveCatalog(directory: temporaryDirectory(), monitor: Monitor(),
                                          initialPreferences: .init(), discover: { mounted }, makeIndex: { _, _, id in
            let index = Index(); indexes.append(index); indexesByID[id] = index; return index
        })
        defer { catalog.stop() }
        catalog.updateMounted(mounted)
        for (uuid, path) in [(uuid, volume.path), (secondUUID, second.path)] {
            try XCTUnwrap(indexesByID[uuid]).complete(store(path: path))
        }
        catalog.prepareToUnmount(uuid: uuid)
        XCTAssertEqual(indexes.map(\.stops).reduce(0, +), 1)
        try waitUntil("unmounted partition row") { catalog.rows.first { $0.id == self.uuid }?.status == .offline }
        let sibling = catalog.searchSources().first { $0.id == secondUUID }
        XCTAssertEqual(sibling?.isOnline, true)
        mounted = [second]; catalog.updateMounted(mounted)
        XCTAssertEqual(indexes.map(\.stops).reduce(0, +), 1)
        catalog.prepareToEject(device: "disk7")
        try waitUntil("ejected sibling row") { catalog.rows.first { $0.id == self.secondUUID }?.status == .offline }
        XCTAssertEqual(indexes.map(\.stops).reduce(0, +), 2)
        catalog.setEnabled(false); catalog.setEnabled(true)
        try waitUntil("still-mounted sibling to restart") { indexes.map(\.starts).reduce(0, +) == 3 }
        XCTAssertEqual(indexes.map(\.starts).reduce(0, +), 3, "A deliberate master switch resumes the still-mounted disk")
    }

    func testSlowUnrelatedAndDuplicateApprovalsCannotAutomaticallyRestartIndexing() throws {
        var indexes: [Index] = []
        let mounted = [volume]
        let catalog = ExternalDriveCatalog(directory: temporaryDirectory(), monitor: Monitor(),
                                          initialPreferences: .init(), discover: { mounted }, makeIndex: { _, _, _ in
            let index = Index(); indexes.append(index); return index
        })
        defer { catalog.stop() }
        catalog.updateMounted(mounted)
        let first = try XCTUnwrap(indexes.first)
        first.complete(store(path: volume.path))
        catalog.prepareToEject(device: "disk7")
        try waitUntil("ejected drive row") { catalog.rows.first?.status == .offline }
        catalog.prepareToEject(device: "unrelated-disk")
        catalog.prepareToUnmount(uuid: secondUUID)
        catalog.prepareToEject(device: "disk7")
        catalog.prepareToUnmount(uuid: uuid)
        XCTAssertEqual(first.stops, 1)
        // This is a negative temporal guarantee, so verify it throughout the observation window.
        try assertRemains("A slow eject must not restart indexing", duration: 2.1) { indexes.count == 1 && first.stops == 1 }
        XCTAssertEqual(indexes.count, 1, "A still-mounted path cannot prove a slow eject request has finished")
        catalog.setEnabled(false); catalog.setEnabled(true)
        try waitUntil("drive to restart after a cancelled eject") { indexes.count == 2 && indexes.last?.starts == 1 }
        XCTAssertEqual(indexes.count, 2)
        XCTAssertEqual(try XCTUnwrap(indexes.dropFirst().first).starts, 1, "A deliberate master switch restores a drive after another app rejects eject")
    }

    func testRemoveDeletesCatalogAndOnlyRecreatesAfterNextConnection() throws {
        let directory = temporaryDirectory(); var indexes: [Index] = []
        let catalog = ExternalDriveCatalog(directory: directory, monitor: Monitor(),
                                          initialPreferences: .init(), makeIndex: { _, _, _ in let index = Index(); indexes.append(index); return index })
        defer { catalog.stop() }
        catalog.updateMounted([volume])
        let first = try XCTUnwrap(indexes.first)
        first.complete(store(path: volume.path))
        let persistence = ExternalDrivePersistence(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: persistence.indexURL(uuid))
        catalog.remove(uuid)
        XCTAssertTrue(catalog.rows.isEmpty); XCTAssertTrue(catalog.searchSources().isEmpty)
        XCTAssertEqual(first.stops, 1); XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.indexURL(uuid).path))
        catalog.updateMounted([volume]); XCTAssertTrue(catalog.rows.isEmpty)
        catalog.updateMounted([]); catalog.updateMounted([volume])
        XCTAssertEqual(catalog.rows.count, 1); XCTAssertEqual(indexes.count, 2)
        L10n.snapshotChinese = true
        XCTAssertEqual(L10n.text("driveRemoveTitle", "T7 Shield"), "移除「T7 Shield」？")
        L10n.snapshotChinese = false
        XCTAssertEqual(L10n.text("driveRemoveTitle", "T7 Shield"), "Remove “T7 Shield”?")
        L10n.snapshotChinese = nil
    }

    func testProgressDoesNotInvalidateSearchUntilSourceStoreOrOnlineStateChanges() throws {
        var indexes: [Index] = [], changes = 0
        let catalog = ExternalDriveCatalog(directory: temporaryDirectory(), monitor: Monitor(),
                                          initialPreferences: .init(), makeIndex: { _, _, _ in let index = Index(); indexes.append(index); return index })
        defer { catalog.stop() }
        catalog.onSourcesChange = { changes += 1 }
        catalog.updateMounted([volume]); XCTAssertEqual(changes, 0)
        let first = try XCTUnwrap(indexes.first)
        first.scannedCount = 45_000; first.onStateChange?(.scanning)
        XCTAssertEqual(changes, 0)
        let current = store(path: volume.path); first.complete(current); XCTAssertEqual(changes, 1)
        first.onStateChange?(.ready); XCTAssertEqual(changes, 1)
        current.write { current.version += 1 }; first.onIndexChange?(); XCTAssertEqual(changes, 2)
        catalog.prepareToEject(device: "disk7")
        try waitUntil("source-withdrawal notification") { changes == 3 }
        XCTAssertEqual(changes, 3)
    }

    func testMasterAndDriveSwitchesPreserveSettingsAndDeleteOnlyDisabledCatalogs() throws {
        let directory = temporaryDirectory(), monitor = Monitor()
        var indexes: [Index] = []
        let catalog = ExternalDriveCatalog(directory: directory, monitor: monitor, initialPreferences: .init(), discover: { [self.volume] },
                                          makeIndex: { _, _, _ in let index = Index(); indexes.append(index); return index })
        defer { catalog.stop() }
        catalog.updateMounted([volume])
        let first = try XCTUnwrap(indexes.first)
        first.complete(store(path: volume.path))
        let db = ExternalDrivePersistence(directory: directory).indexURL(uuid)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("catalog".utf8).write(to: db)
        catalog.setEnabled(false)
        XCTAssertTrue(catalog.searchSources().isEmpty); XCTAssertEqual(first.stops, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: db.path))
        catalog.setEnabled(true)
        try waitUntil("index recreation after re-enabling") { indexes.count == 2 && indexes.last?.starts == 1 }
        XCTAssertEqual(indexes.count, 2); XCTAssertTrue(catalog.searchSources().isEmpty)
        try XCTUnwrap(indexes.dropFirst().first).complete(store(path: volume.path))
        catalog.setDriveEnabled(uuid, false)
        XCTAssertTrue(catalog.searchSources().isEmpty); XCTAssertEqual(try XCTUnwrap(catalog.rows.first).status, .disabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: db.path))
        catalog.setDriveEnabled(uuid, true); XCTAssertEqual(indexes.count, 3)
    }

    func testDisconnectRetainsCatalogAndReconnectUsesSameUUIDAcrossRename() throws {
        let directory = temporaryDirectory()
        var indexes: [Index] = [], urls: [URL] = []
        let catalog = ExternalDriveCatalog(directory: directory, monitor: Monitor(), initialPreferences: .init(),
                                          makeIndex: { _, url, _ in urls.append(url); let index = Index(); indexes.append(index); return index })
        defer { catalog.stop() }
        catalog.updateMounted([volume])
        let first = try XCTUnwrap(indexes.first)
        first.complete(store(path: volume.path))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let originalURL = try XCTUnwrap(urls.first)
        try Data("existing catalog".utf8).write(to: originalURL)
        catalog.updateMounted([])
        XCTAssertTrue(catalog.searchSources().isEmpty); XCTAssertEqual(indexes.count, 1)
        XCTAssertEqual(catalog.knownDrives.first?.isConnected, false)
        XCTAssertEqual(try Data(contentsOf: originalURL), Data("existing catalog".utf8))
        var renamed = volume; renamed.name = "Renamed"; renamed.path = "/Volumes/Renamed 1"
        catalog.updateMounted([renamed]); XCTAssertEqual(indexes.count, 2); XCTAssertEqual(originalURL, try XCTUnwrap(urls.dropFirst().first))
        XCTAssertTrue(catalog.searchSources().isEmpty, "An old mount path never becomes actionable")
        try XCTUnwrap(indexes.dropFirst().first).complete(store(path: renamed.path))
        XCTAssertEqual(catalog.searchSources().first?.displayName, "Renamed")
        XCTAssertEqual(catalog.searchSources().first?.store.rootPath, renamed.path)
    }

    func testUpgradeLoadsOldPreferencesAndCatalogWithoutRecreatingThem() throws {
        let directory = temporaryDirectory(), persistence = ExternalDrivePersistence(directory: temporaryDirectory())
        XCTAssertEqual(ExternalDriveCatalog().enabled, true)
        let legacy = ExternalDrivePersistence(directory: directory)
        let disabled = ExternalDriveRecord(id: secondUUID, name: "Disabled", path: "/Volumes/Disabled", lastConnected: Date(), enabled: false)
        legacy.save(.init(enabled: true, drives: [.init(id: uuid, name: volume.name, path: volume.path, lastConnected: Date()), disabled]))
        try Data("legacy catalog".utf8).write(to: legacy.indexURL(uuid))
        var urls: [URL] = []
        let catalog = ExternalDriveCatalog(directory: directory, monitor: Monitor(), discover: { [self.volume] },
                                          makeIndex: { _, url, _ in urls.append(url); return Index() })
        defer { catalog.stop() }
        catalog.start()
        try waitUntil("legacy preferences and mounted drive index") { catalog.ready && urls.count == 1 && catalog.rows.count == 2 }
        XCTAssertTrue(catalog.ready); XCTAssertTrue(catalog.enabled)
        XCTAssertEqual(catalog.rows.count, 2); XCTAssertEqual(catalog.rows.first { $0.id == secondUUID }?.status, .disabled)
        XCTAssertEqual(urls, [legacy.indexURL(uuid)])
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(urls.first)), Data("legacy catalog".utf8))
        XCTAssertTrue(persistence.load().enabled)
    }

    func testPublicSnapshotArgumentsHaveThreeRowsAndNoPersistentIO() throws {
        let directory = temporaryDirectory()
        let catalog = ExternalDriveCatalog(directory: directory, monitor: Monitor(), discover: { XCTFail("Snapshot discovery"); return [] })
        var arguments = ["--snapshot", "/tmp/settings.png", "--external-drives-sample", "--allow-external-disk-images"]
        try catalog.prepareArguments(&arguments)
        XCTAssertEqual(arguments, ["--snapshot", "/tmp/settings.png"])
        XCTAssertEqual(catalog.rows.map(\.status), [.connected, .indexing, .offline])
        XCTAssertEqual(catalog.knownDrives.map(\.isConnected), [true, true, false])
        XCTAssertTrue(catalog.allowDiskImages); XCTAssertTrue(catalog.searchSources().isEmpty)
        catalog.start(); catalog.stop(); XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testDisconnectedNotificationWaitsForApprovalCatalogSave() throws {
        let index = Index(), catalog = ExternalDriveCatalog(directory: temporaryDirectory(), monitor: Monitor(), initialPreferences: .init(),
                                                            makeIndex: { _, _, _ in index })
        defer { catalog.stop() }
        catalog.updateMounted([volume]); index.complete(store(path: volume.path))
        var saved = false, disconnected = false
        let observation = catalog.changes.sink {
            if catalog.knownDrives.first?.isConnected == false {
                XCTAssertTrue(saved, "An extension must never load a catalog while stop is saving")
                disconnected = true
            }
        }
        defer { observation.cancel() }
        defer { index.onStop = nil }
        index.onStop = {
            XCTAssertTrue(catalog.searchSources().isEmpty, "Sources are withdrawn synchronously")
            index.onStateChange?(.idle)
            XCTAssertTrue(catalog.knownDrives.first?.isConnected == true)
            saved = true
        }
        catalog.prepareToUnmount(uuid: uuid)
        try waitUntil("post-save disconnection notification") { disconnected }
        XCTAssertTrue(disconnected)
    }

    func testReenableDiscardsStaleDiscoveryAndStoppedIndexCallbacks() throws {
        let discoveryEntered = expectation(description: "First discovery entered")
        let releaseDiscovery = DispatchSemaphore(value: 0), lock = NSLock()
        let current = volume
        var stale = current; stale.name = "Stale"; stale.path = "/Volumes/Stale"
        let staleVolume = stale
        var discoveries = 0, indexes: [Index] = [], changes = 0
        let catalog = ExternalDriveCatalog(directory: temporaryDirectory(), monitor: Monitor(), initialPreferences: .init(),
                                          discover: {
            lock.lock(); discoveries += 1; let invocation = discoveries; lock.unlock()
            if invocation == 1 {
                discoveryEntered.fulfill()
                _ = releaseDiscovery.wait(timeout: .now() + 10)
                return [staleVolume]
            }
            return [current]
        }, makeIndex: { _, _, _ in let index = Index(); indexes.append(index); return index })
        defer { releaseDiscovery.signal(); catalog.stop() }
        catalog.onSourcesChange = { changes += 1 }
        catalog.updateMounted([current])
        let first = try XCTUnwrap(indexes.first)
        first.complete(store(path: current.path))
        catalog.start()
        let entered = XCTWaiter.wait(for: [discoveryEntered], timeout: 10)
        _ = try XCTUnwrap(entered == .completed ? true : nil, "First discovery must enter before toggling")
        catalog.setEnabled(false); catalog.setEnabled(true)
        XCTAssertEqual(first.stops, 1)
        XCTAssertEqual(indexes.count, 1, "Re-enabling must await fresh discovery")
        let disabledChanges = changes
        first.onStateChange?(.idle); first.onIndexChange?()
        XCTAssertEqual(changes, disabledChanges)
        XCTAssertTrue(catalog.searchSources().isEmpty)
        releaseDiscovery.signal()
        try waitUntil("fresh discovery to recreate the index") { indexes.count == 2 && indexes.last?.starts == 1 }
        let replacement = try XCTUnwrap(indexes.dropFirst().first)
        XCTAssertEqual(catalog.rows.first?.record.name, current.name)
        XCTAssertEqual(catalog.rows.first?.record.path, current.path)
        replacement.complete(store(path: current.path))
        let activeChanges = changes
        first.onStateChange?(.idle); first.onIndexChange?()
        XCTAssertEqual(changes, activeChanges)
        XCTAssertTrue(catalog.searchSources().first?.store === replacement.store)
    }

}
