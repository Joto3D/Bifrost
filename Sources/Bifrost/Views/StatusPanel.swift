import SwiftUI

/// Home tab content: a "launcher hero" layout — the game title row, the
/// four setup prerequisites as a compact status grid, the profile picker,
/// and the big Play buttons. All logic is unchanged from the original
/// stacked-list layout; only the presentation is reorganized.
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
    @Environment(ThemeStore.self) private var themeStore
    @State private var launchStatusLine: String?
    @State private var diagnosticsTask: Task<Void, Never>?
    @State private var launchTask: Task<Void, Never>?
    @State private var isLaunching = false
    /// Set once per launch (see `play(modded:)`) so `Flavor.quip` shows the
    /// same secondary caption across that launch's phase updates instead of
    /// re-rolling on every status change.
    @State private var launchFlavorSeed: Int?
    /// Incremented once each time a modded launch's diagnostics confirm
    /// plugins loaded — drives the Play button area's one-time aurora
    /// shimmer (see `View.auroraCelebration`).
    @State private var celebrationPulse = 0

    @State private var thunderstoreClient = ThunderstoreClient()
    @State private var isApplyingProfile = false
    @State private var profileStatusLine: String?
    @State private var pendingProfileSwitch: PendingProfileSwitch?
    @State private var pendingMissingMods: PendingMissingMods?
    @State private var lastBackupDate: Date?

    /// Drives the guided "Join a Server" sheet (`ServerJoinSheetView`).
    @State private var serverJoinSheetPresented = false
    /// Whichever profile was active right before the guided flow's last
    /// successful `apply` switched away from it — powers "Back to my
    /// profile" below. Session-only (not persisted): a relaunch while a
    /// guest profile is active just hides the hint's specific target and
    /// falls back to the first non-guest profile instead.
    @State private var priorProfileIDBeforeGuest: UUID?

    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            titleRow

            RunestoneTipCard()

            statusGrid

            VStack(spacing: Theme.Spacing.s) {
                profileRow
                if appState.activeProfile?.isGuestProfile == true {
                    backToMyProfileHint
                }
                Text(modsSummaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            SagaCard()

            Spacer(minLength: 0)

            playSection

            footerMenu
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: 540)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Theme.settle, value: launchStatusLine)
        .animation(Theme.settle, value: appState.status)
        .task {
            await appState.refresh()
        }
        .task {
            lastBackupDate = await SaveBackup().list().first?.date
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
        .sheet(isPresented: $serverJoinSheetPresented) {
            ServerJoinSheetView(
                onApplied: { previousProfileID in priorProfileIDBeforeGuest = previousProfileID },
                onPlayModded: { play(modded: true) }
            )
        }
    }

    // MARK: - Title row

    private var titleRow: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.m) {
            ZStack {
                Circle()
                    .fill(themeStore.current.surface.opacity(0.5))
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(themeStore.current.accentGradient)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text("Valheim")
                    .font(Theme.titleFont(24))
                Text(gameCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            Button {
                Task { await appState.refresh() }
            } label: {
                if appState.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28, height: 28)
                }
            }
            .buttonStyle(.borderless)
            .disabled(appState.isRefreshing)
            .help("Refresh setup status")
        }
    }

    private var gameCaption: String {
        appState.status.gameFound?.path ?? "Not detected — Bifrost looks via Steam's library"
    }

    // MARK: - Status grid

    private var statusGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Spacing.m), GridItem(.flexible())], spacing: Theme.Spacing.m) {
            StatusPillCard(
                title: "Valheim found",
                ok: appState.status.gameFound != nil,
                subtitle: appState.status.gameFound != nil ? "Located via Steam" : "Could not locate Valheim",
                systemImage: "magnifyingglass"
            )
            StatusPillCard(
                title: "BepInEx installed",
                ok: appState.status.bepinexInstalled,
                subtitle: appState.status.bepinexInstalled ? "Mod loader present" : "Not installed",
                systemImage: "puzzlepiece.extension"
            )
            StatusPillCard(
                title: "Rosetta 2",
                ok: appState.status.rosettaOK,
                subtitle: appState.status.rosettaOK ? "x86_64 translation works" : "Not installed",
                systemImage: "cpu"
            )
            StatusPillCard(
                title: "Steam configured",
                ok: appState.status.steamConfigured,
                subtitle: appState.status.steamConfigured ? "Routes through Bifrost" : "Launch options not set",
                systemImage: "gearshape.2"
            )
        }
    }

    // MARK: - Profile row

    private var profileRow: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "person.2.crop.square.stack")
                .font(.caption)
                .foregroundStyle(.secondary)

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
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .bifrostCard(cornerRadius: Theme.Radius.row)
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

    /// Shown below the profile picker whenever the active profile is a
    /// guest one (`Profile.isGuestProfile`, set by `ServerJoinSheetView`)
    /// — an easy way back to whatever profile was active before, without
    /// having to remember its name in the picker.
    private var backToMyProfileHint: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "arrow.uturn.backward.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("You're on a server-join profile.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Back to my profile") {
                guard let target = profileToReturnTo() else { return }
                Task { await requestProfileSwitch(to: target) }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            .disabled(profileToReturnTo() == nil || isApplyingProfile)
            Spacer()
        }
    }

    /// `priorProfileIDBeforeGuest` when it's still a real profile,
    /// otherwise the first non-guest profile Bifrost knows about (covers a
    /// relaunch that landed on a guest profile with no in-session memory
    /// of what came before it).
    private func profileToReturnTo() -> UUID? {
        if let priorProfileIDBeforeGuest, appState.profiles.profiles.contains(where: { $0.id == priorProfileIDBeforeGuest }) {
            return priorProfileIDBeforeGuest
        }
        return appState.profiles.profiles.first { !$0.isGuestProfile }?.id
    }

    // MARK: - Play section

    private var playSection: some View {
        VStack(spacing: Theme.Spacing.m) {
            Button {
                play(modded: true)
            } label: {
                Label("Play Modded", systemImage: "shippingbox.fill")
            }
            .buttonStyle(.aurora)
            .disabled(!appState.status.readyToPlay || isLaunching)
            .help(appState.status.readyToPlay ? "" : "Finish setup above before playing modded")

            Button {
                play(modded: false)
            } label: {
                Label("Play Vanilla", systemImage: "play.fill")
            }
            .buttonStyle(.quiet)
            .disabled(appState.status.gameFound == nil || isLaunching)

            Button {
                serverJoinSheetPresented = true
            } label: {
                Label("Join a Server…", systemImage: "person.wave.2")
            }
            .buttonStyle(.quiet)
            .disabled(appState.status.gameFound == nil || isLaunching)

            Text(lastBackupCaption)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let launchStatusLine {
                VStack(alignment: .leading, spacing: 2) {
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
                    // The real status line above always stays primary — this
                    // is purely decorative flavor text alongside it (see
                    // `Flavor`), shown only while a launch is actually
                    // in-flight.
                    if isLaunching, let launchFlavorSeed {
                        Text(Flavor.quip(seed: launchFlavorSeed))
                            .font(.caption2)
                            .italic()
                            .foregroundStyle(.tertiary)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .auroraCelebration(trigger: celebrationPulse)
    }

    private var lastBackupCaption: String {
        guard let lastBackupDate else { return "Saves last backed up: never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Saves last backed up: \(formatter.localizedString(for: lastBackupDate, relativeTo: Date()))"
    }

    // MARK: - Footer menu

    private var footerMenu: some View {
        HStack {
            Spacer()
            Menu {
                Button {
                    if let gameDir = appState.status.gameFound {
                        Launcher.openPluginsFolder(gameDir: gameDir)
                    }
                } label: {
                    Label("Open Plugins Folder", systemImage: "folder")
                }
                .disabled(appState.status.gameFound == nil)

                Button {
                    if let gameDir = appState.status.gameFound {
                        Launcher.openBepInExLog(gameDir: gameDir)
                    }
                } label: {
                    Label("Open BepInEx Log", systemImage: "doc.text")
                }
                .disabled(appState.status.gameFound == nil)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: - Logic (unchanged)

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
        launchFlavorSeed = Int(Date().timeIntervalSince1970)

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
            if case .modsLoaded = diagnosis {
                celebrationPulse += 1
            }
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
        case .backingUpSaves:
            return "Backing up saves…"
        case .startingSteam(let silent):
            return silent ? "Starting Steam in the background…" : "Starting Steam…"
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
