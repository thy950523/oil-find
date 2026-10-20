import Foundation

/// Full Disk Access is user-visible state that can change while the app is running, so the
/// indexing scope has to follow it. Deciding the scope once at launch leaves the app indexing in
/// limited mode after the permission is granted, and reporting the directories that limited mode
/// excludes as unreadable, until the next launch.
public struct FullDiskAccessState {
    public private(set) var limited: Bool
    public init(limited: Bool) { self.limited = limited }
    /// Returns true when the reading changes the scope, which is the only case that needs a new
    /// index configuration. Repeated readings of an unchanged permission stay silent.
    public mutating func observe(granted: Bool) -> Bool {
        let next = !granted
        guard next != limited else { return false }
        limited = next
        return true
    }
}
