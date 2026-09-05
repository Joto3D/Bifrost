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
                // Catches a Nexus "Mod Manager Download" click: the site
                // opens `nxm://valheim/mods/<id>/files/<id>?key=...&expires=...`,
                // which LaunchServices routes here once Bifrost has been
                // opened at least once (registering `CFBundleURLTypes`
                // from Info.plist — see the README). All the actual work
                // happens in `AppState.handleNexusLink`; this just hands
                // the URL off. Attached to the WindowGroup's content view
                // rather than the Scene itself — functionally identical,
                // and what this toolchain's SwiftUI actually exposes here.
                .onOpenURL { url in
                    guard url.scheme?.lowercased() == "nxm" else { return }
                    Task { await appState.handleNexusLink(url) }
                }
        }
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentMinSize)
    }
}
