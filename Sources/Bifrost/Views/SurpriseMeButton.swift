import SwiftUI
import AppKit

/// Browse's toolbar dice button: rolls `SurpriseMe.pick` and hands the
/// result back to the caller (`ModBrowserView`, which selects it so
/// `ModDetailView` opens). Purely presentational beyond that — a small
/// bounce/shimmer plays on press, skipped under "reduce motion".
struct SurpriseMeButton: View {
    let action: () -> Void

    @Environment(ThemeStore.self) private var themeStore
    @State private var bounce = false

    var body: some View {
        Button {
            roll()
            action()
        } label: {
            Image(systemName: "die.face.5.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(bounce ? AnyShapeStyle(themeStore.current.accentGradient) : AnyShapeStyle(.primary))
                .rotationEffect(.degrees(bounce ? 24 : 0))
                .scaleEffect(bounce ? 1.2 : 1)
        }
        .help("Surprise me — open a random well-rated mod")
    }

    private func roll() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.35)) {
            bounce = true
        }
        withAnimation(Theme.settle.delay(0.22)) {
            bounce = false
        }
    }
}
