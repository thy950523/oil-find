import SwiftUI

/// The "File contents" settings section, modelled on `AITopicSettings`: a master switch, the index
/// status, and the two maintenance buttons. Chinese and English follow the parent view's redraw
/// (the parent observes the model), so there is no language parameter and no observer here.
struct ContentSettings: View {
    @ObservedObject var manager: ContentManager

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 5) {
                Toggle(L10n.text("contentEnabled"), isOn: Binding(get: { manager.enabled }, set: { manager.setEnabled($0) }))
                Text(L10n.text("contentPrivacy")).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            statusLine
            HStack(spacing: 10) {
                // The same button doubles as the retry when the last pass hit unreadable files,
                // mirroring the retry affordance in the AI topics section.
                Button(L10n.text(manager.failed > 0 ? "action.retry" : "contentRebuild")) { manager.rebuild() }
                Button(L10n.text("contentClear")) { manager.clear() }
            }
        }
    }

    /// The line shown while a pass runs: which phase it is in and how far it has got. The plain
    /// sentence is the fallback for the moment before the first report arrives and for a pass with
    /// nothing to count, where "0 / 0" would tell the user less than "building" does.
    static func progressText(_ progress: ContentIndexProgress?, chinese: Bool) -> String {
        guard let progress, progress.total > 0 else {
            return L10n.text("contentBuilding", chinese: chinese)
        }
        let done = progress.done.formatted()
        let total = progress.total.formatted()
        switch progress.phase {
        case .scanning:
            return L10n.text("contentScanning", chinese: chinese, done, total)
        case .parsing:
            // Truncated rather than rounded: "100%" must mean the pass is done, not nearly done.
            let percent = Int((Double(progress.done) / Double(progress.total) * 100).rounded(.down))
            return L10n.text("contentParsing", chinese: chinese, done, total, String(percent))
        }
    }

    @ViewBuilder private var statusLine: some View {
        if manager.indexing {
            Text(Self.progressText(manager.progress, chinese: L10n.chinese))
                .font(.footnote).foregroundStyle(.secondary)
        } else {
            Text(L10n.text("contentDone", String(manager.count)) + " · "
                + ByteCountFormatter.string(fromByteCount: manager.diskBytes, countStyle: .file))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
