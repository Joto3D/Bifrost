import SwiftUI

/// Home tab content: shows the four setup prerequisites and, once wiring
/// lands in a later phase, the actual play buttons.
struct StatusPanel: View {
    private struct PendingProfileSwitch: Identifiable {
        let id = UUID()
        let profileID: UUID
        let preview: ProfileStore.ApplyPreview
    }

    private struct PendingMissingMods: Identifiable {
        let id = UUID()
        let profileID: UUID
        let missing: [String]
    }

    @Environment(AppState.self) private var appState
    @State private var launchStatusLine: String?
    @State private var diagnosticsTask: Task<Void, Never>?
    @State private var launchTask: Task<Void, Never>?
    @State private var isLaunching = false

    @State private var thunderstoreClient = ThunderstoreClient()
    @State private var isApplyingProfile = false
    @State private var profileStatusLine: String?
    @State private var pendingProfileSwitch: PendingProfileSwitch?
    @State private var pendingMissingMods: PendingMissingMods?

    var body: some View {
        VStack(spacing: 24) {
            GroupBox("Setup Status") {
                VStack(alignment: .leading, spacing: 14) {
                    StatusRow(
                        title: "Valheim found",
                        ok: appState.status.gameFound != nil,
                        subtitle: appState.status.gameFound?.path ?? "Could not locate Valheim via Steam"
                    )
                    Divider()
                    StatusRow(
                        title: "BepInEx installed",
                        ok: appState.status.bepinexInstalled,
                        subtitle: appState.status.bepinexInstalled
                            ? "Mod loader is present"
                            : "BepInEx not installed"
                    )
                    Divider()
                    StatusRow(
                        title: "Rosetta 2 available",
                        ok: appState.status.rosettaOK,
                        subtitle: appState.status.rosettaOK
                            ? "x86_64 translation works"
                            : "Rosetta 2 is not installed"
                    )
                    Divider()
                    StatusRow(
                        title: "Steam launch options configured",
                        ok: appState.status.steamConfigured,
                        subtitle: appState.status.steamConfigured
                            ? "Launch options route through Bifrost"
                            : "Steam launch options not set"
                    )
                }
                .padding(8)
            }

            Text(modsSummaryLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            profileRow

            Button {
                Task { await appState.refresh() }
            } label: {
                if appState.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(appState.isRefreshing)

            HStack(spacing: 16) {
                Button {
                    play(modded: true)
                } label: {
                    Label("Play Modded", systemImage: "shippingbox.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!appState.status.readyToPlay || isLaunching)
                .help(appState.status.readyToPlay ? "" : "Finish setup above before playing modded")

                Button {
                    play(modded: false)
                } label: {
                    Label("Play Vanilla", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .disabled(appState.status.gameFound == nil || isLaunching)
            }

            if let launchStatusLine {
                HStack(spacing: 8) {
                    if isLaunching {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(launchStatusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isLaunching {
                        Button("Cancel", action: cancelLaunch)
                            .font(.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                    }
                }
            }

            HStack(spacing: 16) {
                Button {
                    if let gameDir = appState.status.gameFound {
                        Launcher.openPluginsFolder(gameDir: gameDir)
                    }
                } label: {
                    Label("Open Plugins Folder", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .disabled(appState.status.gameFound == nil)

                Button {
                    if let gameDir = appState.status.gameFound {
                        Launcher.openBepInExLog(gameDir: gameDir)
                    }
                } label: {
                    Label("Open BepInEx Log", systemImage: "doc.text")
                        .frame(maxWidth: .infinity)
                }
                .disabled(appState.status.gameFound == nil)
            }
        }
        .padding(24)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await appState.refresh()
        }
        .confirmationDialog(
            "Switch profile?",
            isPresented: Binding(
                get: { pendingProfileSwitch != nil },
                set: { if !$0 { pendingProfileSwitch = nil } }
            ),
            presenting: pendingProfileSwitch
        ) { pending in
            Button("Switch") {
                Task { await performProfileSwitch(profileID: pending.profileID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(profileSwitchMessage(for: pending.preview))
        }
        .confirmationDialog(
            "Install missing mods?",
            isPresented: Binding(
                get: { pendingMissingMods != nil },
                set: { if !$0 { pendingMissingMods = nil } }
            ),
            presenting: pendingMissingMods
        ) { pending in
            Button("Install Missing (\(pending.missing.count))") {
                Task { await installMissing(pending) }
            }
            Button("Not Now", role: .cancel) {}
        } message: { pending in
            Text("This profile also wants: \(pending.missing.joined(separator: ", "))")
        }
    }

    private var profileRow: some View {
        HStack(spacing: 8) {
            Picker("Profile", selection: profileSelection) {
                ForEach(appState.profiles.profiles.sorted(by: { $0.name < $1.name })) { profile in
                    Text(profile.name).tag(profile.id as UUID?)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 200)
            .disabled(appState.profiles.profiles.isEmpty || isApplyingProfile || appState.status.gameFound == nil)

            if isApplyingProfile {
                ProgressView().controlSize(.small)
            }

            if let profileStatusLine {
                Text(profileStatusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text(profileEnabledSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var profileSelection: Binding<UUID?> {
        Binding(
            get: { appState.profiles.activeProfileID },
            set: { newID in
                guard let newID, newID != appState.profiles.activeProfileID else { return }
                Task { await requestProfileSwitch(to: newID) }
            }
        )
    }

    private var profileEnabledSummary: String {
        guard let active = appState.activeProfile else { return "" }
        let enabledCount = active.mods.filter { $0.enabled }.count
        return "\(enabledCount) mod\(enabledCount == 1 ? "" : "s") enabled"
    }

    private func profileSwitchMessage(for preview: ProfileStore.ApplyPreview) -> String {
        var lines: [String] = []
        if !preview.toDisable.isEmpty {
            lines.append("Will disable: \(preview.toDisable.joined(separator: ", "))")
        }
        if !preview.missing.isEmpty {
            lines.append("Not installed yet: \(preview.missing.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    private func requestProfileSwitch(to profileID: UUID) async {
        profileStatusLine = nil
        do {
            let preview = try await appState.previewApplyProfile(id: profileID)
            if preview.isNoOp {
                await performProfileSwitch(profileID: profileID)
            } else {
                pendingProfileSwitch = PendingProfileSwitch(profileID: profileID, preview: preview)
            }
        } catch {
            profileStatusLine = "Couldn't preview profile switch: \(error.localizedDescription)"
        }
    }

    private func performProfileSwitch(profileID: UUID) async {
        guard let gameDir = appState.status.gameFound else { return }
        isApplyingProfile = true
        defer { isApplyingProfile = false }
        do {
            let result = try await appState.applyProfile(id: profileID, gameDir: gameDir)
            if !result.missing.isEmpty {
                pendingMissingMods = PendingMissingMods(profileID: profileID, missing: result.missing)
            }
        } catch {
            profileStatusLine = "Couldn't switch profile: \(error.localizedDescription)"
        }
    }

    private func installMissing(_ pending: PendingMissingMods) async {
        guard let gameDir = appState.status.gameFound else { return }
        isApplyingProfile = true
        defer { isApplyingProfile = false }
        do {
            let index = try await thunderstoreClient.fetchIndex(force: false)
            let result = try await appState.installMissingAndReapply(
                fullNames: pending.missing,
                profileID: pending.profileID,
                gameDir: gameDir,
                index: index
            )
            profileStatusLine = result.missing.isEmpty ? nil : "Still missing: \(result.missing.joined(separator: ", "))"
        } catch {
            profileStatusLine = "Couldn't install missing mods: \(error.localizedDescription)"
        }
    }

    private var modsSummaryLine: String {
        let modCount = appState.manifest.mods.count
        let modsText = "\(modCount) mod\(modCount == 1 ? "" : "s") installed"
        guard let loaderVersion = appState.manifest.loader?.version else { return modsText }
        return "\(modsText) · BepInEx \(loaderVersion)"
    }

    private func play(modded: Bool) {
        guard appState.status.gameFound != nil else { return }

        launchTask?.cancel()
        diagnosticsTask?.cancel()
        isLaunching = true
        launchStatusLine = nil

        launchTask = Task {
            await runLaunch(modded: modded)
        }
    }

    private func runLaunch(modded: Bool) async {
        defer { isLaunching = false }

        let finalPhase: Launcher.LaunchPhase
        do {
            finalPhase = try await Launcher.play(modded: modded) { phase in
                Task { @MainActor in launchStatusLine = Self.describe(phase) }
            }
        } catch {
            if Task.isCancelled { return }
            launchStatusLine = "Couldn't launch: \(error.localizedDescription)"
            return
        }
        if Task.isCancelled { return }

        launchStatusLine = Self.describe(finalPhase)

        guard finalPhase == .launched, let gameDir = appState.status.gameFound else { return }

        diagnosticsTask?.cancel()
        diagnosticsTask = Task {
            let diagnosis = await Diagnostics.watch(gameDir: gameDir, modded: modded)
            if Task.isCancelled { return }
            launchStatusLine = diagnosis.summary
        }
    }

    private func cancelLaunch() {
        launchTask?.cancel()
        diagnosticsTask?.cancel()
        isLaunching = false
        launchStatusLine = "Cancelled — Steam's launch (if any) is still whatever it was, Bifrost just stopped watching it."
    }

    private static func describe(_ phase: Launcher.LaunchPhase) -> String {
        switch phase {
        case .startingSteam:
            return "Starting Steam…"
        case .waitingForSteam:
            return "Waiting for Steam…"
        case .launching:
            return "Launching through Steam…"
        case .steamNeedsAttention(let task, let hint):
            return "Steam needs your attention (\(task)): \(hint)"
        case .launched:
            return "Launched through Steam — checking mods…"
        case .steamFailedToStart:
            return "Steam didn't start in time — make sure it's installed, then try again."
        case .launchNotConfirmed(let hint):
            return hint
        }
    }
}

private struct StatusRow: View {
    let title: String
    let ok: Bool
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
                .font(.system(size: 18))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            Spacer()
        }
    }
}
