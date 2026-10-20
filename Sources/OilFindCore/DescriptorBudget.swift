import Darwin
import Foundation

/// How much of the process's descriptor table is in use.
///
/// A pass that opens one file per item — content indexing does, for hours — can fill the table
/// without noticing, because a failed open looks like an empty file rather than an error. The
/// damage is not confined to that pass: once `open` starts failing with `EMFILE`, a file scan
/// running in the same process cannot open directories either, and a directory it cannot open is
/// indistinguishable from one it already read, so the scan publishes a catalog that silently lost
/// whole subtrees. Callers therefore stop a long pass while there is still headroom instead of
/// discovering the limit through failures.
public enum DescriptorBudget {
    /// Number of descriptors the process currently holds, or nil when it cannot be read.
    public static func openCount() -> Int? {
        guard let directory = opendir("/dev/fd") else { return nil }
        defer { closedir(directory) }
        var count = 0
        while let entry = readdir(directory) {
            // Entries are the descriptor numbers themselves, so the dot entries are the only names
            // starting with a dot. Skipping them by first byte keeps the walk allocation-free: this
            // is called from inside parse loops, where building a String per descriptor would cost
            // more than the pass it is protecting.
            let name = withUnsafePointer(to: entry.pointee.d_name) { UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self) }
            if name.pointee == UInt8(ascii: ".") { continue }
            count += 1
        }
        return count
    }

    /// Soft `RLIMIT_NOFILE`, or nil when it cannot be read or is unlimited.
    public static func softLimit() -> Int? {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return nil }
        // `RLIM_INFINITY` is a sentinel, not a usable count: a caller comparing against it would never
        // see the table as tight, which is the correct reading of "no limit". The C macro is not
        // importable, so its value is spelled out here.
        let infinity = rlim_t((UInt64(1) << 63) - 1)
        guard limit.rlim_cur != infinity, limit.rlim_cur > 0 else { return nil }
        return Int(limit.rlim_cur)
    }

    /// True when the process holds at least `fraction` of its soft limit.
    ///
    /// False when either reading is unavailable: a pass that cannot measure the table must not stop
    /// on a guess, because stopping early is itself a cost.
    public static func isTight(fraction: Double = 0.5) -> Bool {
        guard let open = openCount(), let limit = softLimit() else { return false }
        return isTight(open: open, limit: limit, fraction: fraction)
    }

    /// The comparison behind `isTight`, split out so the threshold can be tested without changing the
    /// test process's own limits — which a test cannot do without also affecting every test that runs
    /// after it in the same process.
    static func isTight(open: Int, limit: Int, fraction: Double) -> Bool {
        Double(open) >= Double(limit) * fraction
    }
}
