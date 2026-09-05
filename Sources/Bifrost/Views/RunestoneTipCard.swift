import SwiftUI

/// A small rotating "Runestone" tip strip for Home: one line, mixing
/// genuinely useful Bifrost tips with short Valheim lore (see
/// `RunestoneTips`). Picks a fresh tip each time the view appears (i.e. each
/// app open, since `StatusPanel` isn't recreated while the app stays open),
/// plus a "next tip" button to roll again on demand.
struct RunestoneTipCard: View {
    @Environment(ThemeStore.self) private var themeStore
    @State private var index = Int.random(in: 0..<RunestoneTips.all.count)

    private var tip: RunestoneTips.Tip { RunestoneTips.all[index] }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            ZStack {
                Circle()
                    .fill(themeStore.current.surface.opacity(0.5))
                // Elder Futhark "Yr" — a small rune glyph standing in for a
                // dedicated icon asset.
                Text("ᛦ")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(themeStore.current.accentGradient)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(tip.isLore ? "Runestone Lore" : "Runestone Tip")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(tip.text)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button(action: nextTip) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Show another tip")
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .bifrostCard(cornerRadius: Theme.Radius.row)
    }

    private func nextTip() {
        guard RunestoneTips.all.count > 1 else { return }
        var newIndex = Int.random(in: 0..<RunestoneTips.all.count)
        while newIndex == index {
            newIndex = Int.random(in: 0..<RunestoneTips.all.count)
        }
        withAnimation(Theme.settle) { index = newIndex }
    }
}
