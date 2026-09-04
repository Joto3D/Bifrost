import SwiftUI
import AppKit

@main
struct BifrostApp: App {
    @State private var appState = AppState()
    @State private var themeStore = ThemeStore()

    init() {
        // Headless diagnostics escape hatch: `swift run Bifrost --check`
        // runs the setup/Thunderstore checks and exits, before any UI
        // (window, activation policy, etc.) is touched.
        DebugCheck.runIfRequested()

        // SPM executables have no app bundle at dev time, so AppKit doesn't
        // automatically switch us into a regular foreground app with a menu
        // bar and a real window. Do that manually so `swift run` behaves
        // like a normal macOS app during development.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Bifrost") {
            MainWindow()
                .environment(appState)
                .environment(themeStore)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentMinSize)
    }
}
