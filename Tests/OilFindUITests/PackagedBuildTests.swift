import Foundation
import XCTest
@testable import OilFindApp

final class PackagedBuildTests: XCTestCase {
    private var utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    /// The build script writes this exact shape, and the settings pane shows whatever it parses to.
    func testParsesTheTimestampTheBuildScriptWrites() {
        XCTAssertEqual(PackagedBuild.parse("2026-10-21T00:15:03Z"), date(2026, 10, 21, 0, 15, 3))
    }

    /// A build that cannot say when it was made must hide the row rather than show a wrong date, so
    /// every shape that is not the expected one is absent rather than defaulted.
    func testRejectsAnythingThatIsNotATimestamp() {
        XCTAssertNil(PackagedBuild.parse(nil))
        XCTAssertNil(PackagedBuild.parse(""))
        XCTAssertNil(PackagedBuild.parse("2026-10-21"))
        XCTAssertNil(PackagedBuild.parse("yesterday"))
        XCTAssertNil(PackagedBuild.parse(1_761_000_000))
        XCTAssertNil(PackagedBuild.parse(Date()))
    }

    /// The time is shown in the reader's own zone, so the same instant reads differently in another
    /// one. Without this the date would be the packaging machine's local time wearing a UTC label.
    func testTextUsesTheGivenCalendarZone() {
        let instant = date(2026, 10, 21, 0, 15, 0)
        XCTAssertEqual(PackagedBuild.text(instant, calendar: utc), "2026-10-21 00:15")
        var shanghai = utc
        shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        XCTAssertEqual(PackagedBuild.text(instant, calendar: shanghai), "2026-10-21 08:15")
    }
}
