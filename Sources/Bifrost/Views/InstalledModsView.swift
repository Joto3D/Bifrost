import SwiftUI
import UniformTypeIdentifiers

/// Installed tab: lists every mod in Bifrost's manifest (not a live disk
/// scan) with per-mod enable/disable, update, and remove actions, plus
/// header-level "Check for updates" and "Open plugins folder" actions.
struct InstalledModsView: View {
    private enum IndexState {
        case idle
        case loading
        case loaded([ThunderstorePackage])
        case failed(String)
    }

    /// One pending "this name is already installed" decision, surfaced as
    /// a confirmation dialog while `installFiles` is mid-loop — the
    /// continuation is resumed from the dialog's own button actions
    /// (`true` for Replace, `false` for Skip/dismiss), which is what lets
    /// an `async` install loop await a UI decision without threading extra
    /// state through `ModManager`.
    private struct CollisionPrompt: Identifiable {
        let id = UUID()
        let fullName: String
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// The file types accepted by both the "Install from File…" picker and
    /// the whole-window drop target (see `MainWindow`).
    private static let importableContentTypes: [UTType] = [.zip, UTType(filenameExtension: "dll") ?? .data]

    @Environment(AppState.self) private var appState
    @State private var client = ThunderstoreClient()
    @State private var indexState: IndexState = .idle
    @State private var updates: [String: ModManager.UpdateInfo] = [:]
    @State private var busyFullNames: Set<String> = []
    @State private var pendingRemoval: InstalledManifest.InstalledMod?
    @State private var statusLine: String?
    @State private var profilesSheetPresented = false
    @State private var fileImporterPresented = false
    @State private var isInstallingFromFile = false
    @State private var collisionPrompt: CollisionPrompt?

    /// Every `.cfg` file discovered under `BepInEx/config`, cached until
    /// the next `loadConfigs()` (initial load, "Check for Updates", or the
    /// Configs sheet's own Refresh button — see the type doc on
    /// `BepInExConfig`).
    @State private var discoveredConfigs: [BepInExConfig.DiscoveredConfig] = []
    /// Parsed `KeyboardShortcut` entries per associated mod full name, for
    /// the compact "⌨" line on each row.
    @State private var keybindsByFullName: [String: [BepInExConfig.Entry]] = [:]
    @State private var configsListPresented = false
    @State private var configEditorTarget: BepInExConfig.DiscoveredConfig?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task {
            await appState.refreshManifest()
            await appState.refreshProfiles()
            await loadIndexAndCheckUpdates(force: false)
            await loadConfigs()
        }
        .onChange(of: appState.pendingFileDrop) { _, dropped in
            guard !dropped.isEmpty else { return }
            appState.pendingFileDrop = []
            Task { await installFiles(dropped) }
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.fullName ?? "")?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { mod in
            Button("Remove", role: .destructive) {
                Task { await remove(mod) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { mod in
            Text("Deletes \(mod.files.count) file\(mod.files.count == 1 ? "" : "s") from BepInEx. Config files are left alone.")
        }
        .confirmationDialog(
            "\(collisionPrompt?.fullName ?? "") is already installed",
            isPresented: Binding(
                get: { collisionPrompt != nil },
                set: { isPresented in
                    guard !isPresented, let prompt = collisionPrompt else { return }
                    prompt.continuation.resume(returning: false)
                    collisionPrompt = nil
                }
            ),
            presenting: collisionPrompt
        ) { prompt in
            Button("Replace", role: .destructive) {
                prompt.continuation.resume(returning: true)
                collisionPrompt = nil
            }
            Button("Skip", role: .cancel) {
                prompt.continuation.resume(returning: false)
                collisionPrompt = nil
            }
        } message: { prompt in
            Text("Replacing removes \(prompt.fullName)'s currently installed files before installing the new ones.")
        }
        .sheet(isPresented: $profilesSheetPresented) {
            ProfilesSheetView()
        }
        .sheet(isPresented: $configsListPresented) {
            ConfigsListView(configs: discoveredConfigs, onSelect: { configEditorTarget = $0 }, onRefresh: { Task { await loadConfigs() } })
        }
        .sheet(item: $configEditorTarget) { config in
            ConfigEditorView(url: config.url, title: config.associatedFullName ?? config.fileName)
        }
        .fileImporter(
            isPresented: $fileImporterPresented,
            allowedContentTypes: Self.importableContentTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await installFiles(urls) }
            case .failure(let error):
                statusLine = "Couldn't open file picker: \(error.localizedDescription)"
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Installed")
                .font(Theme.titleFont(20))

            Spacer()

            if let statusLine {
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isInstallingFromFile {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                fileImporterPresented = true
            } label: {
                Label("Install from File…", systemImage: "tray.and.arrow.down")
            }
            .disabled(appState.status.gameFound == nil || isInstallingFromFile)

            Button {
                Task { await loadIndexAndCheckUpdates(force: true) }
            } label: {
                Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(isCheckingUpdates)

            Button {
                profilesSheetPresented = true
            } label: {
                Label("Profiles…", systemImage: "person.2.crop.square.stack")
            }

            Button {
                configsListPresented = true
            } label: {
                Label("Configs…", systemImage: "slider.horizontal.3")
            }
            .disabled(appState.status.gameFound == nil)

            Button {
                if let gameDir = appState.status.gameFound {
                    Launcher.openPluginsFolder(gameDir: gameDir)
                }
            } label: {
                Label("Open Plugins Folder", systemImage: "folder")
            }
            .disabled(appState.status.gameFound == nil)
        }
        .padding()
    }

    private var isCheckingUpdates: Bool {
        if case .loading = indexState { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        if appState.manifest.mods.isEmpty {
            emptyState
        } else {
            List(appState.manifest.mods.sorted { $0.fullName < $1.fullName }) { mod in
                InstalledModRow(
                    mod: mod,
                    iconURL: iconURL(for: mod.fullName),
                    update: updates[mod.fullName],
                    isBusy: busyFullNames.contains(mod.fullName),
                    keybinds: keybindsByFullName[mod.fullName] ?? [],
                    configURL: discoveredConfigs.first { $0.associatedFullName == mod.fullName }?.url,
                    onToggle: { enabled in Task { await setEnabled(mod, enabled: enabled) } },
                    onUpdate: { Task { await update(mod) } },
                    onRemove: { pendingRemoval = mod },
                    onEditConfig: { url in configEditorTarget = BepInExConfig.DiscoveredConfig(url: url, associatedFullName: mod.fullName) }
                )
            }
            .listStyle(.inset)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No mods yet — find some in Browse")
                .font(Theme.headingFont(15))
            Text("Installed mods, their versions, and their configs will show up here.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Or drop a mod's .zip/.dll file anywhere in this window, or use \u{201c}Install from File\u{2026}\u{201d} above.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func iconURL(for fullName: String) -> URL? {
        guard case .loaded(let packages) = indexState,
              let package = packages.first(where: { $0.fullName == fullName }) else {
            return nil
        }
        return client.iconURL(for: package)
    }

    private func loadIndexAndCheckUpdates(force: Bool) async {
        indexState = .loading
        do {
            let packages = try await client.fetchIndex(force: force)
            indexState = .loaded(packages)
            let available = await appState.modManager.updatesAvailable(index: packages)
            updates = Dictionary(uniqueKeysWithValues: available.map { ($0.fullName, $0) })
            statusLine = available.isEmpty ? "All mods up to date" : "\(available.count) update\(available.count == 1 ? "" : "s") available"
        } catch {
            indexState = .failed(error.localizedDescription)
            statusLine = "Couldn't check for updates: \(error.localizedDescription)"
        }
        await loadConfigs()
    }

    /// Rescans `BepInEx/config` for `.cfg` files, associates each with an
    /// installed mod (`BepInExConfig.associate`, using both `fullName` and
    /// the Thunderstore index's display `name` as match candidates where
    /// the index has loaded), and re-parses every associated file's
    /// `KeyboardShortcut` entries for the row-level "⌨" summary. Called on
    /// initial load, after "Check for Updates", and on demand from the
    /// Configs sheet's Refresh button.
    private func loadConfigs() async {
        guard let gameDir = appState.status.gameFound else {
            discoveredConfigs = []
            keybindsByFullName = [:]
            return
        }

        let namesByFullName: [String: String]
        if case .loaded(let packages) = indexState {
            namesByFullName = Dictionary(uniqueKeysWithValues: packages.map { ($0.fullName, $0.name) })
        } else {
            namesByFullName = [:]
        }
        let candidates = appState.manifest.mods.map { (fullName: $0.fullName, name: namesByFullName[$0.fullName] ?? "") }

        let configDir = gameDir.appendingPathComponent("BepInEx/config")
        let configs = BepInExConfig.discoverConfigs(in: configDir, candidates: candidates)
        discoveredConfigs = configs

        var keybinds: [String: [BepInExConfig.Entry]] = [:]
        for config in configs {
            guard let fullName = config.associatedFullName,
                  let text = try? String(contentsOf: config.url, encoding: .utf8) else { continue }
            let shortcuts = BepInExConfig.parse(text).keyboardShortcuts
            guard !shortcuts.isEmpty else { continue }
            keybinds[fullName, default: []] += shortcuts
        }
        keybindsByFullName = keybinds
    }

    private func setEnabled(_ mod: InstalledManifest.InstalledMod, enabled: Bool) async {
        guard let gameDir = appState.status.gameFound else { return }
        busyFullNames.insert(mod.fullName)
        defer { busyFullNames.remove(mod.fullName) }
        do {
            try await appState.modManager.setEnabled(fullName: mod.fullName, enabled: enabled, gameDir: gameDir)
            await appState.refreshManifest()
            await appState.syncActiveProfileWithManifest()
        } catch {
            statusLine = "Couldn't toggle \(mod.fullName): \(error.localizedDescription)"
        }
    }

    private func update(_ mod: InstalledManifest.InstalledMod) async {
        guard let gameDir = appState.status.gameFound, case .loaded(let packages) = indexState else { return }
        busyFullNames.insert(mod.fullName)
        defer { busyFullNames.remove(mod.fullName) }
        do {
            try await appState.modManager.update(fullName: mod.fullName, index: packages, gameDir: gameDir)
            await appState.refreshManifest()
            await appState.syncActiveProfileWithManifest()
            updates.removeValue(forKey: mod.fullName)
        } catch {
            statusLine = "Couldn't update \(mod.fullName): \(error.localizedDescription)"
        }
    }

    /// Installs every dropped/picked `.zip`/`.dll` file in `urls`, in
    /// order, then does the same manifest-refresh + profile-sync dance the
    /// other mutating actions (`setEnabled`, `update`, `remove`) already do
    /// so the Installed list, update badges, and active profile all stay
    /// in sync afterward. A name collision on any one file pauses that
    /// file (via `confirmReplace`'s dialog) without blocking the rest of
    /// the batch; any other failure is recorded and reported once at the
    /// end rather than aborting the remaining files.
    private func installFiles(_ urls: [URL]) async {
        guard let gameDir = appState.status.gameFound else {
            statusLine = "Can't install from file — locate the game directory first"
            return
        }
        guard !urls.isEmpty else { return }

        isInstallingFromFile = true
        defer { isInstallingFromFile = false }

        var installedCount = 0
        var skippedCount = 0
        var lastFailure: String?

        for url in urls {
            do {
                if try await installOneFile(url, gameDir: gameDir) != nil {
                    installedCount += 1
                } else {
                    skippedCount += 1
                }
            } catch {
                lastFailure = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }

        await appState.refreshManifest()
        await appState.syncActiveProfileWithManifest()
        await loadIndexAndCheckUpdates(force: false)

        var summary = installedCount > 0 ? "Installed \(installedCount) mod\(installedCount == 1 ? "" : "s") from file" : ""
        if skippedCount > 0 {
            summary += summary.isEmpty ? "Skipped \(skippedCount) file\(skippedCount == 1 ? "" : "s")" : ", skipped \(skippedCount)"
        }
        if let lastFailure {
            summary += summary.isEmpty ? "Couldn't install: \(lastFailure)" : " — \(lastFailure)"
        }
        if !summary.isEmpty {
            statusLine = summary
        }
    }

    /// Installs one file, handling a name collision by awaiting the user's
    /// replace/skip choice (`confirmReplace`) and retrying with
    /// `replaceExisting: true` only if they chose Replace. Returns the
    /// installed full name, or `nil` if the user chose to skip a
    /// collision (not an error — just nothing to count).
    private func installOneFile(_ url: URL, gameDir: URL) async throws -> String? {
        do {
            return try await appState.modManager.installFromFile(url: url, gameDir: gameDir)
        } catch ModManager.ModManagerError.nameCollision(let fullName) {
            guard await confirmReplace(fullName: fullName) else { return nil }
            return try await appState.modManager.installFromFile(url: url, gameDir: gameDir, replaceExisting: true)
        }
    }

    /// Suspends until the "already installed" confirmation dialog resolves
    /// (Replace -> `true`, Skip or dismiss -> `false`) — see
    /// `CollisionPrompt`.
    private func confirmReplace(fullName: String) async -> Bool {
        await withCheckedContinuation { continuation in
            collisionPrompt = CollisionPrompt(fullName: fullName, continuation: continuation)
        }
    }

    private func remove(_ mod: InstalledManifest.InstalledMod) async {
        guard let gameDir = appState.status.gameFound else { return }
        pendingRemoval = nil
        busyFullNames.insert(mod.fullName)
        defer { busyFullNames.remove(mod.fullName) }
        do {
            try await appState.modManager.uninstall(fullName: mod.fullName, gameDir: gameDir)
            await appState.refreshManifest()
            await appState.syncActiveProfileWithManifest()
        } catch {
            statusLine = "Couldn't remove \(mod.fullName): \(error.localizedDescription)"
        }
    }
}

private struct InstalledModRow: View {
    let mod: InstalledManifest.InstalledMod
    let iconURL: URL?
    let update: ModManager.UpdateInfo?
    let isBusy: Bool
    /// This mod's `KeyboardShortcut` entries from its associated `.cfg`
    /// file, if any were found — see `InstalledModsView.loadConfigs()`.
    let keybinds: [BepInExConfig.Entry]
    /// This mod's associated `.cfg` file, if `BepInExConfig.associate`
    /// matched one.
    let configURL: URL?
    let onToggle: (Bool) -> Void
    let onUpdate: () -> Void
    let onRemove: () -> Void
    let onEditConfig: (URL) -> Void

    var body: some View {
        HStack(spacing: 12) {
            ModIconView(url: iconURL, size: 40)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(mod.fullName)
                        .font(.body.weight(.semibold))
                    if mod.source == "local" {
                        Chip(text: "local", systemImage: "internaldrive")
                            .help("Installed from a local file — not checked against Thunderstore for updates")
                    }
                    if mod.source == "nexus" {
                        Chip(text: "nexus", systemImage: "link")
                            .help("Installed from Nexus Mods — update checks compare against Nexus, not Thunderstore")
                    }
                    if update != nil {
                        AuroraBadge(text: "Update", systemImage: "arrow.up.circle.fill")
                    }
                }
                Text("v\(mod.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !keybinds.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(keybinds) { entry in
                            Chip(text: "\(entry.key): \(entry.rawValue)", systemImage: "keyboard")
                        }
                    }
                }
            }

            Spacer()

            Toggle("Enabled", isOn: Binding(
                get: { mod.enabled },
                set: { onToggle($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(isBusy)

            if isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Menu {
                    if let update {
                        Button {
                            onUpdate()
                        } label: {
                            Label("Update to \(update.latestVersion)", systemImage: "arrow.down.circle")
                        }
                    }
                    if let configURL {
                        Button {
                            onEditConfig(configURL)
                        } label: {
                            Label("Edit Config", systemImage: "slider.horizontal.3")
                        }
                    }
                    Button(role: .destructive) {
                        onRemove()
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(isBusy)
            }
        }
        .padding(.vertical, 6)
        .opacity(isBusy ? 0.6 : 1)
    }
}
