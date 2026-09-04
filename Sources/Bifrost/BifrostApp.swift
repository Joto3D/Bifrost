import SwiftUI
import AppKit

@main
struct BifrostApp: App {
    init() {
        // SPM executables have no app bundle at dev time, so AppKit doesn't
        // automatically switch us into a regular foreground app with a menu
        // bar and a real window. Do that manually so `swift run` behaves
        // like a normal macOS app during development.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 900, height: 600)
    }
}
