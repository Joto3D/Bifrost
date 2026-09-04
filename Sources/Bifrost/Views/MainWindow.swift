import SwiftUI

/// Top-level window content for Bifrost: the four main tabs, the shared
/// error alert, and the first-run setup wizard sheet.
struct MainWindow: View {
    @Environment(AppState.self) private var appState
    @State private var hasCheckedFirstRun = false

    var body: some View {
        @Bindable var appState = appState

        TabView {
            StatusPanel()
                .tabItem {
                    Label("Home", systemImage: "house")
                }

            ModBrowserView()
                .tabItem {
                    Label("Browse", systemImage: "magnifyingglass")
                }

            InstalledModsView()
                .tabItem {
                    Label("Installed", systemImage: "square.stack.3d.up")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
        .frame(minWidth: 900, minHeight: 600)
        .bifrostErrorAlert(appState)
        .sheet(isPresented: $appState.setupWizardPresented) {
            SetupWizardView()
        }
        .task {
            guard !hasCheckedFirstRun else { return }
            hasCheckedFirstRun = true
            await appState.refresh()
            if !appState.status.readyToPlay {
                appState.setupWizardPresented = true
            }
        }
    }
}
