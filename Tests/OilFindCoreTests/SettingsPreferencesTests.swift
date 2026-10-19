import XCTest
@testable import OilFindCore

final class SettingsPreferencesTests: XCTestCase {
    private func suite() -> (defaults: UserDefaults, name: String) {
        let name = "OilFindClearSettings-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    func testClearAllRemovesUserSettings() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(42, forKey: "hotKeyCode")
        defaults.set(true, forKey: "pinyinEnabled")
        defaults.set(["log"], forKey: "excludedExtensions")

        SettingsPreferences.clearAll(in: defaults)

        // Assert on the suite's own store rather than object(forKey:): the registration domain is
        // process-wide, so once any test calls register() these keys read back their registered
        // defaults even after the stored values are gone.
        let stored = defaults.persistentDomain(forName: name) ?? [:]
        XCTAssertNil(stored["hotKeyCode"])
        XCTAssertNil(stored["pinyinEnabled"])
        XCTAssertNil(stored["excludedExtensions"])
    }

    func testClearAllKeepsTheProTrialAnchors() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(1790000000.5, forKey: "proEvaluationStartedAt")
        defaults.set(1790003600.75, forKey: "proEvaluationLastSeenAt")
        defaults.set(1790003600.75, forKey: "proEvaluationEndedAt")

        SettingsPreferences.clearAll(in: defaults)

        // Wiping these would hand out a fresh Pro trial, which is not what "reset my settings" means.
        XCTAssertEqual(defaults.double(forKey: "proEvaluationStartedAt"), 1790000000.5)
        XCTAssertEqual(defaults.double(forKey: "proEvaluationLastSeenAt"), 1790003600.75)
        XCTAssertEqual(defaults.double(forKey: "proEvaluationEndedAt"), 1790003600.75)
    }

    func testClearAllKeepsTheLegacyCleanupStamp() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "legacyAuthorizationCleanupCompleted")

        SettingsPreferences.clearAll(in: defaults)

        // Otherwise the legacy authorization sweep runs again on the next launch.
        XCTAssertTrue(defaults.bool(forKey: "legacyAuthorizationCleanupCompleted"))
    }

    func testClearAllFallsBackToTheRegisteredDefaults() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        SettingsPreferences.register(in: defaults)
        defaults.set(99, forKey: "hotKeyCode")
        defaults.set("name", forKey: "sortKey")

        SettingsPreferences.clearAll(in: defaults)

        // removeObject only touches the application domain, so the registration domain still
        // supplies the defaults. This is what "restore to defaults" means; a clear that left the
        // settings unreadable would be a different bug.
        XCTAssertEqual(defaults.integer(forKey: "hotKeyCode"), Int(Shortcut.defaultKeyCode))
        XCTAssertEqual(SettingsPreferences.searchOptions(in: defaults).sort, .relevance)
    }
}
