import SwiftUI

/// Sheet-based first-run setup wizard: chains the existing services in
/// order — locate Valheim, install BepInEx, configure Steam's launch
/// options — gracefully skipping any step that's already satisfied.
/// Presented automatically from `MainWindow` the first time the app isn't
/// `readyToPlay`, and re-launchable any time from Settings.
struct SetupWizardView: View {
    private enum Step: Int, CaseIterable {
        case welcome, detectGame, installBepInEx, configureSteam, done

        var title: String {
            switch self {
            case .welcome: return "Welcome to Bifrost"
            case .detectGame: return "Locate Valheim"
            case .installBepInEx: return "Install BepInEx"
            case .configureSteam: return "Configure Steam"
            case .done: return "All Set"
            }
        }
    }

    /// Status of one step's underlying check/action.
    private enum StepStatus: Equatable {
        /// Not yet checked — the auto-run `.task` hasn't fired yet.
        case pending
        /// A check or action is in flight.
        case running
        /// Checked: this step needs an explicit user action, described by
        /// the associated message (shown as the step's body text).
        case idle(String)
        case success(String)
        /// Checked and found already satisfied — nothing to do.
        case skipped(String)
        case failure(String)

        /// Whether Continue may be pressed from this state.
        var canProceed: Bool {
            switch self {
            case .pending, .running: return false
            case .idle, .success, .skipped, .failure: return true
            }
        }
    }

    @Environment(AppState.self) private var appState
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .welcome

    @State private var located: GameLocator.LocatedGame?
    @State private var detectStatus: StepStatus = .pending

    @State private var installStatus: StepStatus = .pending
    @State private var installProgressLine: String?

    @State private var steamStatus: StepStatus = .pending

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 440)
        .presentationBackground(.regularMaterial)
        .task(id: step) {
            await runAutoStepIfNeeded()
        }
        .animation(Theme.settle, value: step)
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Capsule()
                        .fill(s.rawValue <= step.rawValue ? AnyShapeStyle(themeStore.current.accentGradient) : AnyShapeStyle(Color.secondary.opacity(0.25)))
                        .frame(width: s == step ? 22 : 7, height: 7)
                }
                Spacer()
            }
            Text(step.title)
                .font(Theme.titleFont(20))
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            if step != .welcome && step != .done {
                Button("Back") { goBack() }
                    .buttonStyle(.bordered)
            }
            Spacer()
            if step == .done {
                Button("Finish") {
                    Task { await appState.refresh() }
                    dismiss()
                }
                .buttonStyle(.aurora)
                .fixedSize()
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") { goForward() }
                    .buttonStyle(.aurora)
                    .fixedSize()
                    .disabled(!canContinue)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private var canContinue: Bool {
        switch step {
        case .welcome: return true
        case .detectGame: return detectStatus.canProceed
        case .installBepInEx: return installStatus.canProceed
        case .configureSteam: return steamStatus.canProceed
        case .done: return true
        }
    }

    private func goForward() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    private func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    // MARK: - Step content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .detectGame: detectGameStep
        case .installBepInEx: installBepInExStep
        case .configureSteam: configureSteamStep
        case .done: doneStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("This wizard gets Valheim ready to run with mods through Bifrost:")

            VStack(alignment: .leading, spacing: 8) {
                Label("Locate your Valheim install via Steam", systemImage: "1.circle")
                Label("Install the BepInEx mod loader", systemImage: "2.circle")
                Label("Point Steam's launch options at Bifrost's wrapper", systemImage: "3.circle")
            }
            .foregroundStyle(.secondary)

            Text("Any step that's already done is skipped automatically. Nothing here touches your save files or world data.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var detectGameStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Bifrost looks for Valheim (App ID 892970) through Steam's own library bookkeeping — never a guessed path.")
                .foregroundStyle(.secondary)

            switch detectStatus {
            case .pending, .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for Valheim…")
                }
            case .idle:
                EmptyView()
            case .success(let message), .skipped(let message):
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failure(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Button("Retry") { Task { await runDetectGame() } }
                }
            }
        }
    }

    private var installBepInExStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch installStatus {
            case .pending, .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(installProgressLine ?? "Checking…")
                }
            case .idle(let message):
                VStack(alignment: .leading, spacing: 12) {
                    Text(message)
                        .foregroundStyle(.secondary)
                    Button("Install BepInEx") { Task { await runInstallBepInEx() } }
                        .buttonStyle(.aurora)
                        .fixedSize()
                }
            case .success(let message), .skipped(let message):
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failure(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Button("Retry") { Task { await runInstallBepInEx() } }
                }
            }
        }
    }

    private var configureSteamStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch steamStatus {
            case .pending, .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking Steam's launch options…")
                }
            case .idle(let message):
                VStack(alignment: .leading, spacing: 12) {
                    Text(message)
                        .foregroundStyle(.secondary)
                    Button("Configure Steam") { Task { await runConfigureSteam() } }
                        .buttonStyle(.aurora)
                        .fixedSize()
                }
            case .success(let message), .skipped(let message):
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failure(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Button("Retry") { Task { await runConfigureSteam() } }
                }
            }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Setup complete", systemImage: "checkmark.seal.fill")
                .font(.title2.bold())
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 6) {
                Text(summaryLine(for: detectStatus, prefix: "Valheim — "))
                Text(summaryLine(for: installStatus, prefix: "BepInEx — "))
                Text(summaryLine(for: steamStatus, prefix: "Steam — "))
            }
            .font(.callout)

            Divider()

            Text("Head to the **Home** tab and use **Play Modded** to launch with mods.")
                .foregroundStyle(.secondary)
        }
    }

    private func summaryLine(for status: StepStatus, prefix: String) -> String {
        switch status {
        case .pending: return prefix + "not checked"
        case .running: return prefix + "in progress"
        case .idle: return prefix + "skipped for now"
        case .success(let message), .skipped(let message): return prefix + message
        case .failure(let message): return prefix + "⚠️ " + message
        }
    }

    // MARK: - Auto-run

    private func runAutoStepIfNeeded() async {
        switch step {
        case .welcome, .done:
            break
        case .detectGame:
            if detectStatus == .pending { await runDetectGame() }
        case .installBepInEx:
            if installStatus == .pending { checkBepInExStatus() }
        case .configureSteam:
            if steamStatus == .pending { await checkSteamStatus() }
        }
    }

    // MARK: - Detect game

    private func runDetectGame() async {
        detectStatus = .running
        let result = GameLocator.locate()
        located = result

        switch result {
        case .some(let game) where game.isValid:
            detectStatus = .success("Found at \(game.directory.path)")
        case .some:
            detectStatus = .failure("Found a Valheim folder, but it doesn't look complete (no valheim.app inside). Try verifying the game's files in Steam.")
        case .none:
            detectStatus = .failure("Couldn't locate Valheim. Make sure it's installed through Steam and has been launched at least once.")
        }
    }

    // MARK: - Install BepInEx

    private var resolvedGameDir: URL? {
        located?.directory ?? appState.status.gameFound
    }

    private func checkBepInExStatus() {
        guard let gameDir = resolvedGameDir else {
            installStatus = .failure("Valheim wasn't found — go back and retry the previous step.")
            return
        }
        if GameLocator.bepinexInstalled(at: gameDir) {
            installStatus = .skipped("BepInEx is already installed.")
        } else {
            installStatus = .idle("BepInEx isn't installed yet. This downloads the mod loader from Thunderstore and installs Bifrost's launch wrapper — your plugins and config are never touched.")
        }
    }

    private func runInstallBepInEx() async {
        guard let gameDir = resolvedGameDir else {
            installStatus = .failure("Valheim wasn't found — go back and retry the previous step.")
            return
        }
        installStatus = .running
        installProgressLine = nil

        let installer = BepInExInstaller()
        let manifestVersion = await appState.modManager.loaderVersion()
        do {
            let outcome = try await installer.install(
                gameDir: gameDir,
                launchDir: BepInExInstaller.defaultLaunchDir,
                manifestVersion: manifestVersion
            ) { progress in
                Task { @MainActor in installProgressLine = Self.describe(progress) }
            }
            try? await appState.modManager.setLoaderVersion(outcome.versionNumber)
            installStatus = .success("Installed BepInEx \(outcome.versionNumber).")
        } catch {
            installStatus = .failure("Install failed: \(error.localizedDescription)")
        }
    }

    private static func describe(_ progress: BepInExInstaller.Progress) -> String {
        switch progress {
        case .fetchingVersionInfo: return "Checking latest BepInEx version…"
        case .packAlreadyUpToDate(let version): return "BepInEx \(version) already up to date"
        case .downloading(let version): return "Downloading BepInEx \(version)…"
        case .extracting: return "Extracting…"
        case .copyingFiles: return "Copying files into place…"
        case .strippingQuarantine: return "Clearing quarantine flags…"
        case .installingWrapper: return "Installing launch wrapper…"
        case .done(let version): return "Installed BepInEx \(version)"
        }
    }

    // MARK: - Configure Steam

    private func checkSteamStatus() async {
        steamStatus = .running
        let configurator = SteamConfigurator()
        do {
            if try await configurator.isConfigured() {
                steamStatus = .skipped("Steam launch options already route through Bifrost.")
            } else {
                steamStatus = .idle("Steam's launch options for Valheim don't point at Bifrost yet. Configuring will quit Steam, back up your localconfig.vdf, splice in the launch option, and relaunch Steam.")
            }
        } catch {
            steamStatus = .failure("Couldn't read Steam's config: \(error.localizedDescription)")
        }
    }

    private func runConfigureSteam() async {
        steamStatus = .running
        let configurator = SteamConfigurator()
        do {
            let outcome = try await configurator.configure()
            switch outcome {
            case .alreadyConfigured:
                steamStatus = .skipped("Steam launch options already route through Bifrost.")
            case .configured(let backupURL):
                steamStatus = .success("Steam is configured. Your previous localconfig.vdf was backed up to \(backupURL.lastPathComponent).")
            }
        } catch {
            steamStatus = .failure("Couldn't configure Steam: \(error.localizedDescription)")
        }
    }
}
