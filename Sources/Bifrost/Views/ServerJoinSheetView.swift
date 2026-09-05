import SwiftUI

/// Guided "Join a Server" flow, opened from the Home tab's "Join a
/// Server…" button. Three steps:
///  1. Pick a target profile — a new "Server Guest" derived from the
///     current install (the default), or an existing profile.
///  2. Review the plan `ServerJoinPlanner.buildPlan` computes from the
///     current manifest: mods that stay enabled, mods that get disabled,
///     and a prominent warning for `.addsItems` mods (kept enabled by
///     default) — each group offers per-mod override checkboxes.
///  3. Apply: `ServerJoinPlanner.apply` takes a "pre-server" safety backup
///     first, then reconciles the target profile to the plan. Bifrost
///     never launches the game itself — this only offers a "Play Modded"
///     button wired to the same launcher `StatusPanel` uses.
///
/// Deliberately NOT silent auto-disabling: every risky mod the plan would
/// disable is shown before anything changes, with a way to keep it enabled
/// instead.
struct ServerJoinSheetView: View {
    private enum Step: Int { case chooseProfile, reviewPlan, apply }

    private enum TargetChoice: Hashable {
        case createNew
        case existing(UUID)
    }

    /// Called once `apply` succeeds, with whichever profile was active
    /// before this flow switched away from it (if any) — `StatusPanel`
    /// uses this to power its "Back to my profile" hint.
    let onApplied: (_ previousProfileID: UUID?) -> Void
    /// Called when the user taps "Play Modded" on the final step.
    /// `StatusPanel` wires this to its own existing launch action rather
    /// than this sheet launching anything itself.
    let onPlayModded: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .chooseProfile
    @State private var thunderstoreClient = ThunderstoreClient()
    @State private var index: [ThunderstorePackage] = []

    @State private var targetChoice: TargetChoice = .createNew
    @State private var newProfileName = "Server Guest"
    @State private var overrides: [String: Bool] = [:]
    @State private var priorProfileID: UUID?

    @State private var isApplying = false
    @State private var errorLine: String?
    @State private var backupSummaryLine: String?
    @State private var missingSummaryLine: String?
    @State private var didApply = false

    private var plan: ServerJoinPlanner.Plan {
        ServerJoinPlanner.buildPlan(manifest: appState.manifest, index: index, overrides: overrides)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .chooseProfile: chooseProfileStep
                case .reviewPlan: reviewPlanStep
                case .apply: applyStep
                }
            }
            .navigationTitle("Join a Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .presentationBackground(.regularMaterial)
        .task {
            priorProfileID = appState.profiles.activeProfileID
            index = (try? await thunderstoreClient.fetchIndex(force: false)) ?? []
        }
    }

    // MARK: - Step 1

    private var chooseProfileStep: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Text("Joining someone else's server goes smoother when your risky mods match what they run. Bifrost can switch you to a profile with those mods set aside first.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                SectionHeader(title: "Target profile")

                Toggle(isOn: Binding(
                    get: { targetChoice == .createNew },
                    set: { if $0 { targetChoice = .createNew } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Create a new profile from my current mods")
                        Text("Recommended — leaves your regular profile untouched.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)

                if targetChoice == .createNew {
                    TextField("Profile name", text: $newProfileName)
                        .textFieldStyle(.roundedBorder)
                        .padding(.leading, 24)
                }

                ForEach(appState.profiles.profiles.sorted(by: { $0.name < $1.name })) { profile in
                    Toggle(isOn: Binding(
                        get: { targetChoice == .existing(profile.id) },
                        set: { if $0 { targetChoice = .existing(profile.id) } }
                    )) {
                        Text("Use existing profile: \(profile.name)")
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(Theme.Spacing.l)
            .bifrostCard()

            Spacer()

            HStack {
                Spacer()
                Button("Next") { step = .reviewPlan }
                    .buttonStyle(.aurora)
                    .frame(maxWidth: 160)
                    .disabled(!isTargetChoiceValid)
            }
        }
        .padding(Theme.Spacing.xl)
    }

    private var isTargetChoiceValid: Bool {
        switch targetChoice {
        case .createNew: return true // falls back to "Server Guest" if left blank
        case .existing: return true
        }
    }

    // MARK: - Step 2

    private var reviewPlanStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                if plan.isEmpty {
                    Text("No mods installed yet — nothing to plan.")
                        .foregroundStyle(.secondary)
                }

                if !plan.keepEnabled.isEmpty {
                    planGroup(
                        title: "Will stay enabled",
                        subtitle: "Client-only and server-sync mods — safe anywhere.",
                        items: plan.keepEnabled,
                        showsOverride: false
                    )
                }

                if !plan.addsItemsWarning.isEmpty {
                    addsItemsGroup
                }

                if !plan.disable.isEmpty {
                    planGroup(
                        title: "Will be disabled",
                        subtitle: "World-altering or unrecognized mods — risky if the server doesn't run them too.",
                        items: plan.disable,
                        showsOverride: true,
                        overrideLabel: "Keep enabled anyway"
                    )
                }
            }
            .padding(Theme.Spacing.xl)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Back") { step = .chooseProfile }
                Spacer()
                Button("Next") { step = .apply }
                    .buttonStyle(.aurora)
                    .frame(maxWidth: 160)
            }
            .padding(Theme.Spacing.l)
            .background(.regularMaterial)
        }
    }

    private var addsItemsGroup: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionHeader(title: "Adds items — will stay enabled", systemImage: "exclamationmark.triangle.fill")
            Text("Disabling one of these can hide or strand items already in your inventory. Bifrost leaves them enabled by default — put anything valuable in a chest first if you're not sure the server runs it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(plan.addsItemsWarning) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.fullName).font(.body.weight(.medium))
                        ModClassBadge(classification: item.classification)
                        Spacer()
                        Toggle("Disable anyway", isOn: Binding(
                            get: { !(overrides[item.fullName] ?? true) },
                            set: { overrides[item.fullName] = !$0 }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    }
                    Text("Items from \(item.fullName) in your character inventory may be lost — put them in a chest first. Consider leaving it enabled if the server runs it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(Theme.Spacing.m)
                .background {
                    RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                        .fill(Color.orange.opacity(0.12))
                }
            }
        }
        .padding(Theme.Spacing.l)
        .bifrostCard()
    }

    private func planGroup(
        title: String,
        subtitle: String,
        items: [ServerJoinPlanner.Item],
        showsOverride: Bool,
        overrideLabel: String = ""
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionHeader(title: title)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(items) { item in
                HStack {
                    Text(item.fullName)
                    ModClassBadge(classification: item.classification)
                    Spacer()
                    if showsOverride {
                        Toggle(overrideLabel, isOn: Binding(
                            get: { overrides[item.fullName] ?? item.enabled },
                            set: { overrides[item.fullName] = $0 }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    }
                }
            }
        }
        .padding(Theme.Spacing.l)
        .bifrostCard()
    }

    // MARK: - Step 3

    private var applyStep: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            if didApply {
                appliedSummary
            } else {
                Text("Applying will:")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 6) {
                    Label("Back up your current saves first (\"pre-server\")", systemImage: "externaldrive.badge.checkmark")
                    Label(targetDescription, systemImage: "person.2.crop.square.stack")
                    Label("Switch to that profile and reconcile enabled mods", systemImage: "checkmark.circle")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                if let errorLine {
                    Text(errorLine)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Spacer()

                HStack {
                    Button("Back") { step = .reviewPlan }
                        .disabled(isApplying)
                    Spacer()
                    if isApplying {
                        ProgressView().controlSize(.small)
                    }
                    Button("Apply") { Task { await apply() } }
                        .buttonStyle(.aurora)
                        .frame(maxWidth: 160)
                        .disabled(isApplying)
                }
            }
        }
        .padding(Theme.Spacing.xl)
    }

    private var appliedSummary: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Label("Ready to join", systemImage: "checkmark.seal.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.green)

            if let backupSummaryLine {
                Text(backupSummaryLine).font(.caption).foregroundStyle(.secondary)
            }
            if let missingSummaryLine {
                Text(missingSummaryLine).font(.caption).foregroundStyle(.orange)
            }

            Spacer()

            HStack {
                Button("Close") { dismiss() }
                Spacer()
                Button("Play Modded") {
                    onPlayModded()
                    dismiss()
                }
                .buttonStyle(.aurora)
                .frame(maxWidth: 160)
            }
        }
    }

    private var targetDescription: String {
        switch targetChoice {
        case .createNew:
            let name = newProfileName.trimmingCharacters(in: .whitespaces)
            return "Create \"\(name.isEmpty ? "Server Guest" : name)\" from your current mods"
        case .existing(let id):
            let name = appState.profiles.profiles.first { $0.id == id }?.name ?? "profile"
            return "Switch to \"\(name)\""
        }
    }

    private func apply() async {
        guard let gameDir = appState.status.gameFound else {
            errorLine = "Locate Valheim first (Home tab)."
            return
        }
        isApplying = true
        defer { isApplying = false }
        errorLine = nil

        do {
            let profileID: UUID
            switch targetChoice {
            case .createNew:
                let name = newProfileName.trimmingCharacters(in: .whitespaces)
                let created = await appState.profileStore.create(name: name.isEmpty ? "Server Guest" : name, mods: [], isServerGuest: true)
                profileID = created.id
            case .existing(let id):
                profileID = id
            }

            let result = try await ServerJoinPlanner.apply(
                plan: plan,
                profileID: profileID,
                gameDir: gameDir,
                profileStore: appState.profileStore,
                saveBackup: SaveBackup()
            )

            await appState.refreshManifest()
            await appState.refreshProfiles()

            backupSummaryLine = Self.describe(result.backupOutcome)
            missingSummaryLine = result.applyResult.missing.isEmpty
                ? nil
                : "Not installed yet: \(result.applyResult.missing.joined(separator: ", "))"
            didApply = true
            onApplied(priorProfileID)
        } catch {
            errorLine = "Couldn't apply: \(error.localizedDescription)"
        }
    }

    private static func describe(_ outcome: SaveBackup.BackupOutcome) -> String {
        switch outcome {
        case .created(let summary):
            return "Backed up saves (\(summary.fileCount) file\(summary.fileCount == 1 ? "" : "s")) before switching."
        case .skipped(let reason):
            return "Backup skipped: \(reason)"
        }
    }
}
