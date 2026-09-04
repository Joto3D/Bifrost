import SwiftUI

/// Top-level window content for Bifrost. Placeholder tabs for now — each
/// will grow into a real feature area (mod browsing, install management,
/// launch configuration, etc.) as the app is built out.
struct MainWindow: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house")
                }

            BrowseView()
                .tabItem {
                    Label("Browse", systemImage: "magnifyingglass")
                }

            InstalledView()
                .tabItem {
                    Label("Installed", systemImage: "square.stack.3d.up")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

private struct HomeView: View {
    var body: some View {
        Text("Home")
            .font(.title)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BrowseView: View {
    var body: some View {
        Text("Browse")
            .font(.title)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct InstalledView: View {
    var body: some View {
        Text("Installed")
            .font(.title)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SettingsView: View {
    var body: some View {
        Text("Settings")
            .font(.title)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
