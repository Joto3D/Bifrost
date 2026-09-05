import SwiftUI
import AppKit

/// A one-time subtle aurora shimmer sweep, played across whatever it's
/// attached to whenever `trigger` changes — used on Home's Play button area
/// to celebrate a modded launch's diagnostics confirming plugins actually
/// loaded (see `StatusPanel`). Purely decorative: it never gates, delays, or
/// reports anything, and is skipped entirely when the system's "reduce
/// motion" accessibility setting is on.
private struct AuroraCelebrationModifier: ViewModifier {
    @Environment(ThemeStore.self) private var themeStore
    let trigger: Int
    @State private var sweeping = false

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { proxy in
                    themeStore.current.accentGradient
                        .frame(width: max(proxy.size.width * 0.5, 1))
                        .blendMode(.plusLighter)
                        .opacity(sweeping ? 0.5 : 0)
                        .offset(x: sweeping ? proxy.size.width : -proxy.size.width * 0.5)
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
                .allowsHitTesting(false)
            }
            .onChange(of: trigger) { _, _ in
                playSweepOnce()
            }
    }

    /// Skips entirely under "reduce motion". Otherwise animates the sweep
    /// across ~1.5s and resets to idle afterward so the next celebration
    /// (a later launch) starts clean.
    private func playSweepOnce() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        sweeping = false
        withAnimation(.easeInOut(duration: 1.5)) {
            sweeping = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            sweeping = false
        }
    }
}

extension View {
    /// Plays `AuroraCelebrationModifier`'s shimmer sweep whenever `trigger`
    /// changes value — callers increment a counter each time they want the
    /// celebration to play (e.g. once per successful modded launch).
    func auroraCelebration(trigger: Int) -> some View {
        modifier(AuroraCelebrationModifier(trigger: trigger))
    }
}
