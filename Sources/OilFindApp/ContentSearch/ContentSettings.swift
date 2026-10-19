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

    @ViewBuilder private var statusLine: some View {
        if manager.indexing {
            Text(L10n.text("contentBuilding")).font(.footnote).foregroundStyle(.secondary)
        } else {
            Text(L10n.text("contentDone", String(manager.count)) + " · "
                + ByteCountFormatter.string(fromByteCount: manager.diskBytes, countStyle: .file))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}
