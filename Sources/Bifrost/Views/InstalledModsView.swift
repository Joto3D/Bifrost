import SwiftUI

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

    @Environment(AppState.self) private var appState
    @State private var client = ThunderstoreClient()
    @State private var indexState: IndexState = .idle
    @State private var updates: [String: ModManager.UpdateInfo] = [:]
    @State private var busyFullNames: Set<String> = []
    @State private var pendingRemoval: InstalledManifest.InstalledMod?
    @State private var statusLine: String?
    @State private var profilesSheetPresented = false

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
        .sheet(isPresented: $profilesSheetPresented) {
            ProfilesSheetView()
        }
    }

    private var header: some View {
        HStack {
            Text("Installed")
                .font(.title2.bold())

            Spacer()

            if let statusLine {
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                    onToggle: { enabled in Task { await setEnabled(mod, enabled: enabled) } },
                    onUpdate: { Task { await update(mod) } },
                    onRemove: { pendingRemoval = mod }
                )
            }
            .listStyle(.inset)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No mods installed yet")
                .font(.headline)
            Text("Install mods from the Browse tab.")
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
    let onToggle: (Bool) -> Void
    let onUpdate: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ModIconView(url: iconURL, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(mod.fullName)
                    .font(.body.weight(.semibold))
                Text("v\(mod.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let update {
                Button {
                    onUpdate()
                } label: {
                    Label("Update to \(update.latestVersion)", systemImage: "arrow.down.circle")
                }
                .disabled(isBusy)
            }

            Toggle("Enabled", isOn: Binding(
                get: { mod.enabled },
                set: { onToggle($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(isBusy)

            Button(role: .destructive) {
                onRemove()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(isBusy)

            if isBusy {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .opacity(isBusy ? 0.6 : 1)
    }
}
