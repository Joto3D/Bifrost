import SwiftUI
import UniformTypeIdentifiers

/// Top-level window content for Bifrost: the four main tabs, the shared
/// error alert, the first-run setup wizard sheet, and a whole-window drop
/// target for installing mods from local `.zip`/`.dll` files regardless of
/// which tab is active.
struct MainWindow: View {
    private enum Tab: Hashable {
        case home, browse, installed, settings
    }

    @Environment(AppState.self) private var appState
    @State private var hasCheckedFirstRun = false
    @State private var selectedTab: Tab = .home
    @State private var isDropTargeted = false
    /// Session-only dismiss state for `GameUpdateBanner` — reset on
    /// relaunch, same as `priorProfileIDBeforeGuest` in `StatusPanel`.
    @State private var gameUpdateBannerDismissed = false
    /// Quiet, self-clearing note for the background Thunderstore index
    /// refresh (see `IndexAutoRefresher`) — `nil` most of the time.
    @State private var indexAutoRefreshNote: String?

    var body: some View {
        @Bindable var appState = appState

        VStack(spacing: 0) {
            GameUpdateBanner(
                isDismissed: $gameUpdateBannerDismissed,
                onCheckModUpdates: {
                    selectedTab = .installed
                    appState.requestModUpdateCheck = true
                }
            )

            ZStack {
                TabView(selection: $selectedTab) {
                    StatusPanel()
                        .tabItem {
                            Label("Home", systemImage: "house")
                        }
                        .tag(Tab.home)

                    ModBrowserView()
                        .tabItem {
                            Label("Browse", systemImage: "magnifyingglass")
                        }
                        .tag(Tab.browse)

                    InstalledModsView()
                        .tabItem {
                            Label("Installed", systemImage: "square.stack.3d.up")
                        }
                        .tag(Tab.installed)

                    SettingsView()
                        .tabItem {
                            Label("Settings", systemImage: "gearshape")
                        }
                        .tag(Tab.settings)
                }

                if isDropTargeted {
                    dropOverlay
                }

                if case .inProgress(let message) = appState.nexusInstallState {
                    nexusInstallBanner(message)
                }

                if let indexAutoRefreshNote {
                    indexNoteBanner(indexAutoRefreshNote)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
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
        .task {
            guard let refreshTask = IndexAutoRefresher.refreshIfStale(client: ThunderstoreClient(), onStatus: { note in
                Task { @MainActor in
                    withAnimation(Theme.settle) { indexAutoRefreshNote = note }
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    withAnimation(Theme.settle) { indexAutoRefreshNote = nil }
                }
            }) else { return }
            await refreshTask.value
        }
    }

    private var dropOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
            VStack(spacing: Theme.Spacing.m) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.white)
                Text("Drop mod files to install")
                    .font(Theme.headingFont(18))
                    .foregroundStyle(.white)
                Text(".zip or .dll")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(Theme.Spacing.xl)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .transition(.opacity)
        .animation(Theme.settle, value: isDropTargeted)
    }

    /// A small non-blocking status pill for an in-flight `nxm://` install
    /// (see `AppState.handleNexusLink`) — deliberately much less intrusive
    /// than `dropOverlay` since it can appear at any time from outside the
    /// app (a browser click), not from an in-window gesture the user is
    /// already looking at.
    private func nexusInstallBanner(_ message: String) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(message)
                    .font(.caption)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 24)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
        .animation(Theme.settle, value: appState.nexusInstallState)
    }

    /// A small, self-clearing status pill for the background Thunderstore
    /// index refresh (see `IndexAutoRefresher`) — same non-blocking,
    /// bottom-of-window treatment as `nexusInstallBanner`, since this is
    /// likewise something that can happen at any time without the user
    /// having asked for it.
    private func indexNoteBanner(_ message: String) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption)
                Text(message)
                    .font(.caption)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 24)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
        .animation(Theme.settle, value: indexAutoRefreshNote)
    }

    /// Resolves every dropped item provider to a file `URL` off the main
    /// thread (item providers deliver asynchronously and provide no
    /// ordering guarantee relative to each other), then — once every
    /// provider has reported in — filters to `.zip`/`.dll` and hands them
    /// to `AppState.pendingFileDrop`, switching to the Installed tab so the
    /// user sees the install happen. Returns `true` as soon as at least one
    /// provider looks like a file URL, which is what tells SwiftUI to
    /// accept the drop and animate it away; the actual work happens in the
    /// completion handlers.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }

        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in fileProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let itemURL = item as? URL {
                    url = itemURL
                } else {
                    url = nil
                }
                guard let url else { return }
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            let supported = urls.filter { ["zip", "dll"].contains($0.pathExtension.lowercased()) }
            guard !supported.isEmpty else { return }
            appState.pendingFileDrop = supported
            selectedTab = .installed
        }
        return true
    }
}
