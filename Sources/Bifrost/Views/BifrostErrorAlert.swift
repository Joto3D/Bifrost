import SwiftUI

/// One reusable alert modifier for every `AppState.lastError`, so views
/// that want a standard error surface can call `appState.reportError(...)`
/// instead of rolling their own `@State` + `.alert` pair. Attached once,
/// near the root of the view hierarchy (`MainWindow`).
extension View {
    func bifrostErrorAlert(_ appState: AppState) -> some View {
        modifier(BifrostErrorAlertModifier(appState: appState))
    }
}

private struct BifrostErrorAlertModifier: ViewModifier {
    let appState: AppState

    func body(content: Content) -> some View {
        content.alert(
            appState.lastError?.title ?? "Error",
            isPresented: Binding(
                get: { appState.lastError != nil },
                set: { isPresented in
                    if !isPresented { appState.lastError = nil }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.lastError?.message ?? "")
        }
    }
}
