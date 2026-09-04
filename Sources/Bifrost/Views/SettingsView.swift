import SwiftUI
import AppKit

/// Settings tab: read-only paths Bifrost cares about (with a way to reveal
/// each in Finder), one-off maintenance actions, and an About footer.
struct SettingsView: View {
    private enum IndexRefreshState: Equatable {
        case idle
        case running
        case done(count: Int)
        case failed(String)
    }

    @Environment(AppState.self) private var appState
    @Environment(ThemeStore.self) private var themeStore
    @State private var indexRefreshState: IndexRefreshState = .idle
    @AppStorage(Launcher.startSteamSilentlyDefaultsKey) private var startSteamSilently = true

    var body: some View {
        Form {
            Section("Paths") {
                pathRow(title: "Valheim game folder", url: appState.status.gameFound)
                pathRow(title: "Bifrost app support folder", url: bifrostSupportDir)
                pathRow(title: "Launch wrapper script", url: wrapperScriptURL)
                pathRow(title: "Steam launch config (localconfig.vdf)", url: SteamConfigurator.realLocalConfigURL())
            }

            Section("Launch") {
                Toggle("Start Steam silently in the background", isOn: $startSteamSilently)
                Text("When Bifrost needs to start Steam, it starts minimized without opening the Steam window. Steam may still show windows for logins or client updates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Appearance") {
                ForEach(ThemePalette.all) { palette in
                    ThemeRow(
                        palette: palette,
                        isSelected: palette.id == themeStore.current.id
                    ) {
                        withAnimation(Theme.settle) {
                            themeStore.current = palette
                        }
                    }
                }
            }

            Section("Setup") {
                Button {
                    appState.setupWizardPresented = true
                } label: {
                    Label("Run Setup Wizard", systemImage: "wand.and.stars")
                }
            }

            Section("Maintenance") {
                HStack(spacing: 10) {
                    Button {
                        Task { await refreshThunderstoreIndex() }
                    } label: {
                        Label("Refresh Thunderstore Index", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(indexRefreshState == .running)

                    if indexRefreshState == .running {
                        ProgressView()
                            .controlSize(.small)
                    }

                    switch indexRefreshState {
                    case .done(let count):
                        Text("\(count) packages")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .failed(let message):
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    case .idle, .running:
                        EmptyView()
                    }
                }

                Button {
                    if let gameDir = appState.status.gameFound {
                        Launcher.openBepInExLog(gameDir: gameDir)
                    }
                } label: {
                    Label("Open BepInEx Log", systemImage: "doc.text")
                }
                .disabled(appState.status.gameFound == nil)

                Button {
                    Launcher.openWrapperLog()
                } label: {
                    Label("Open Wrapper Log", systemImage: "doc.text.below.ecg")
                }

                Button {
                    if let gameDir = appState.status.gameFound {
                        Launcher.openPluginsFolder(gameDir: gameDir)
                    }
                } label: {
                    Label("Open Plugins Folder", systemImage: "folder")
                }
                .disabled(appState.status.gameFound == nil)
            }

            Section {
                aboutFooter
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Paths

    private var bifrostSupportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Bifrost")
    }

    private var wrapperScriptURL: URL {
        BepInExInstaller.wrapperScriptURL(launchDir: BepInExInstaller.defaultLaunchDir)
    }

    @ViewBuilder
    private func pathRow(title: String, url: URL?) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(url?.path ?? "Not found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Reveal in Finder") {
                if let url { revealInFinder(url) }
            }
            .disabled(!canReveal(url))
        }
        .padding(.vertical, 2)
    }

    private func canReveal(_ url: URL?) -> Bool {
        guard let url else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: url.path) || fm.fileExists(atPath: url.deletingLastPathComponent().path)
    }

    private func revealInFinder(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
        }
    }

    // MARK: - Maintenance actions

    private func refreshThunderstoreIndex() async {
        indexRefreshState = .running
        let client = ThunderstoreClient()
        do {
            let packages = try await client.fetchIndex(force: true)
            indexRefreshState = .done(count: packages.count)
        } catch {
            indexRefreshState = .failed(error.localizedDescription)
        }
    }

    // MARK: - About

    private var aboutFooter: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.title2)
                .foregroundStyle(themeStore.current.accentGradient)
            VStack(alignment: .leading, spacing: 2) {
                Text("Bifrost \(appVersion)")
                    .font(Theme.headingFont(14))
                Text("Launches Valheim through Steam with BepInEx mods on Apple Silicon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private var appVersion: String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !version.isEmpty {
            return version
        }
        return "dev"
    }
}

// MARK: - Appearance

/// One row in the Appearance section's theme picker: a live swatch (an
/// accent-gradient capsule beside a small surface-tinted chip) plus the
/// palette's name. Tapping applies the palette immediately — `SettingsView`
/// wraps the assignment in `Theme.settle` so every themed view cross-fades
/// rather than popping to the new colors.
private struct ThemeRow: View {
    let palette: ThemePalette
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.m) {
                swatch
                Text(palette.displayName)
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(palette.accentGradient)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? palette.badgeTint.opacity(0.12) : Color.clear)
    }

    private var swatch: some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(palette.accentGradient)
                .frame(width: 36, height: 14)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(palette.surface.opacity(0.5))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(palette.secondaryAccent.opacity(0.6), lineWidth: 1)
                }
                .frame(width: 22, height: 14)
        }
    }
}
