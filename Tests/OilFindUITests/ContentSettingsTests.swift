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

    /// A pass over a large index runs for a long time, so the pane has to say how far along it is.
    /// Numbers are compared by their digits rather than their grouping, which follows the locale.
    func testProgressLineNamesThePhaseAndCountsAgainstItsTotal() {
        let scanning = ContentIndexProgress(phase: .scanning, done: 20_000, total: 2_710_281)
        let scanningLine = ContentSettings.progressText(scanning, chinese: true)
        XCTAssertNotEqual(scanningLine, L10n.text("contentBuilding", chinese: true),
                          "a running pass must not fall back to the plain sentence")
        let scanningDigits = scanningLine.filter(\.isNumber)
        XCTAssertTrue(scanningDigits.contains("20000") && scanningDigits.contains("2710281"),
                      "scanning must show the row count against the file index total: \(scanningLine)")

        let parsing = ContentIndexProgress(phase: .parsing, done: 5, total: 20)
        let parsingLine = ContentSettings.progressText(parsing, chinese: false)
        XCTAssertNotEqual(parsingLine, L10n.text("contentBuilding", chinese: false))
        XCTAssertTrue(parsingLine.contains("25"), "parsing must show a percentage: \(parsingLine)")
    }

    /// Before the first report arrives, and for a pass with nothing to count, there is no progress
    /// to show and the plain sentence is the honest answer.
    func testProgressLineFallsBackWhenThereIsNothingToCount() {
        XCTAssertEqual(ContentSettings.progressText(nil, chinese: true),
                       L10n.text("contentBuilding", chinese: true))
        let nothing = ContentIndexProgress(phase: .parsing, done: 0, total: 0)
        XCTAssertEqual(ContentSettings.progressText(nothing, chinese: false),
                       L10n.text("contentBuilding", chinese: false))
    }

    func testLocalizedCopyExistsInBothLanguages() {
        let keys = ["contentTitle", "contentEnabled", "contentImageText", "contentPrivacy",
                    "contentBuilding", "contentDone", "contentRebuild", "contentClear",
                    "contentScanning", "contentParsing"]
        for chinese in [true, false] {
            for key in keys {
                XCTAssertNotEqual(L10n.text(key, chinese: chinese), key,
                                  "\(key) is missing \(chinese ? "Chinese" : "English") copy")
            }
        }
    }
}
