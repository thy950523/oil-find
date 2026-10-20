import Foundation

/// When the running bundle was packaged, for the settings pane.
///
/// `scripts/build-app.sh` writes the moment into the built bundle's `Info.plist` rather than the value
/// living in the repository, so the date describes the app in hand: whoever reports a problem can be
/// asked which build they have. A development build has no packaging step and therefore no date, and
/// the row is hidden instead of showing the moment the sources happened to be checked out.
enum PackagedBuild {
    static let date = parse(Bundle.main.object(forInfoDictionaryKey: "OilFindPackagedAt"))

    /// The build script writes UTC, so the value does not depend on the time zone of the machine that
    /// packaged the app. Anything else is treated as absent: a build that cannot say when it was made
    /// must not make the settings pane say something wrong.
    static func parse(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }

    /// Fixed rather than localized, and it includes the time: the date is quoted when reporting a
    /// problem with one specific build, and `2026-10-21 00:15` reads the same to everyone.
    static func text(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
