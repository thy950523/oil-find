import AppKit
import Foundation
import OilFindCore

/// Publishes content matches as supplementary hits on file rows. The content index stores absolute
/// paths, never entry ids, because the file index renumbers ids on compaction; every hit is resolved
/// against a live store snapshot here.
final class ContentSearchProvider: SupplementarySearchProvider {
    /// Optional so a disabled manager can exist without opening a database.
    private let index: ContentIndex?
    var isEnabled = true
    private static let hitLimit = 200

    init(index: ContentIndex?) { self.index = index }

    /// The literals the user actually typed, ignoring filters such as `ext:` and `kind:`.
    /// Searching `query.raw` would ask the content index for the literal "ext:pdf 发票".
    static func terms(from query: Query) -> String {
        var seen = Set<String>()
        var terms: [String] = []
        for clause in query.clauses {
            for atom in clause.alternatives where !atom.negated {
                guard case .name(let needle, _) = atom.matcher else { continue }
                let term = String(decoding: needle, as: UTF8.self)
                guard !term.isEmpty, seen.insert(term).inserted else { continue }
                terms.append(term)
            }
        }
        return terms.joined(separator: " ")
    }

    func prepareSearch(_ query: Query, options: SearchOptions, sources: [SearchSource],
                       isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit] {
        guard isEnabled, let index else { return { [] } }
        let text = Self.terms(from: query)
        guard !text.isEmpty else { return { [] } }
        return {
            guard !isCancelled(),
                  let found = try? index.search(text, limit: Self.hitLimit, isCancelled: isCancelled),
                  !found.isEmpty else { return [] }
            var hits: [SupplementaryHit] = []
            hits.reserveCapacity(found.count)
            for hit in found {
                for source in sources {
                    // The version and the path resolution share one read lock: a rename landing
                    // between them would otherwise stamp a hit with a version that never matched
                    // this entry. The host drops hits whose version does not match its snapshot.
                    var entryID: UInt32?
                    var version: UInt64 = 0
                    source.store.read {
                        version = source.store.version
                        entryID = source.store.resolve(path: hit.path)
                    }
                    guard let entryID else { continue }
                    hits.append(Self.makeHit(hit: hit, source: source, entryID: entryID, version: version))
                    break
                }
            }
            return hits
        }
    }

    func sourcesDidChange(_ sources: [SearchSource]) {}
    func userActivity(visible: Bool, typing: Bool) {}

    /// Image chunks carry no label, so they take one from the file kind instead: the detail line
    /// reads "图片中文字：…" for images and "第 3 页：…" for documents.
    private static func makeHit(hit: ContentHit, source: SearchSource, entryID: UInt32,
                               version: UInt64) -> SupplementaryHit {
        let label = hit.label.isEmpty && hit.kind == 4 ? L10n.text("contentImageText") : hit.label
        let prefix = label.isEmpty ? "" : label + "："
        let text = prefix + hit.snippet
        // `highlight` ranges are UTF-16 offsets into the snippet; the prefix shifts every one, and
        // a range that no longer fits the presentation string is dropped rather than painted.
        let offset = (prefix as NSString).length
        let length = (text as NSString).length
        let highlights = hit.highlights.compactMap { range -> NSRange? in
            let shifted = NSRange(location: range.location + offset, length: range.length)
            return NSMaxRange(shifted) <= length ? shifted : nil
        }
        return SupplementaryHit(sourceID: source.id, entryID: entryID, detail: text,
                                highlights: highlights, thumbnail: hit.kind == 4,
                                sourceVersion: version)
    }
}
