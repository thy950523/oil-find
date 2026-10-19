import Foundation
import XCTest
@testable import OilFindCore
@testable import OilFindApp

/// The manager is constructed with `indexURL: nil` throughout, so no test opens the user's real
/// content index in Application Support.
final class ContentSettingsTests: XCTestCase {
    private func makeSuite() -> (name: String, defaults: UserDefaults) {
        let name = "oilfind-content-settings-" + UUID().uuidString
        return (name, UserDefaults(suiteName: name)!)
    }

    func testManagerDefaultsToDisabledAndPersistsToggle() {
        let (suite, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = ContentManager(defaults: defaults, indexURL: nil)
        XCTAssertFalse(first.enabled)

        first.setEnabled(true)
        XCTAssertTrue(first.enabled)

        // A manager constructed on the same suite sees the persisted preference.
        let second = ContentManager(defaults: defaults, indexURL: nil)
        XCTAssertTrue(second.enabled)
    }

    func testDisablingProviderImmediatelyStopsHits() {
        let (suite, defaults) = makeSuite()
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = ContentManager(defaults: defaults, indexURL: nil)
        manager.setEnabled(true)
        XCTAssertTrue(manager.provider.isEnabled)

        manager.setEnabled(false)
        XCTAssertFalse(manager.provider.isEnabled)
    }

    func testLocalizedCopyExistsInBothLanguages() {
        let keys = ["contentTitle", "contentEnabled", "contentImageText", "contentPrivacy",
                    "contentBuilding", "contentDone", "contentRebuild", "contentClear"]
        for chinese in [true, false] {
            for key in keys {
                XCTAssertNotEqual(L10n.text(key, chinese: chinese), key,
                                  "\(key) is missing \(chinese ? "Chinese" : "English") copy")
            }
        }
    }
}
