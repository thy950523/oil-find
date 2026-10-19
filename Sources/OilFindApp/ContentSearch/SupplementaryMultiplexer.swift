import Foundation
import OilFindCore

/// The host exposes a single supplementary provider slot, currently occupied by the app extension.
/// This fans the slot out to every provider instead of competing for it, including the content
/// search provider, so neither side has to know about the other.
final class SupplementaryMultiplexer: SupplementarySearchProvider {
    private let providers: [SupplementarySearchProvider]

    init(providers: [SupplementarySearchProvider]) { self.providers = providers }

    /// Enabled when any provider is enabled; only when every provider is disabled does the slot
    /// report itself disabled.
    var isEnabled: Bool { providers.contains { $0.isEnabled } }

    func prepareSearch(_ query: Query, options: SearchOptions, sources: [SearchSource],
                       isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit] {
        let work = providers.filter(\.isEnabled).map {
            $0.prepareSearch(query, options: options, sources: sources, isCancelled: isCancelled)
        }
        guard !work.isEmpty else { return { [] } }
        return { work.flatMap { $0() } }
    }

    // Lifecycle callbacks go to every provider, including disabled ones: otherwise a provider
    // disabled during a source change or a background scan would resume with stale state.
    func sourcesDidChange(_ sources: [SearchSource]) {
        for provider in providers { provider.sourcesDidChange(sources) }
    }

    func userActivity(visible: Bool, typing: Bool) {
        for provider in providers { provider.userActivity(visible: visible, typing: typing) }
    }

    func backgroundIndexingChanged(_ busy: Bool) {
        for provider in providers { provider.backgroundIndexingChanged(busy) }
    }
}
