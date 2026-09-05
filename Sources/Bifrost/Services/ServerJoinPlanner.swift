import Foundation

/// Builds and applies the guided "Join a Server" flow's plan: which
/// installed mods stay enabled, which get disabled, and which land in the
/// "adds items" warning group — computed from `ModClassifier`'s
/// classification of each installed mod, with per-mod overrides layered on
/// top.
///
/// Deliberately never disables anything by itself: `buildPlan` is pure
/// computation over already-loaded state, and `apply` is the only thing
/// here that touches disk — and only when the guided flow's final "Apply"
/// step explicitly calls it. Bifrost's own multiplayer-safety stance is
/// "explain and let the user decide," never silent auto-disabling.
enum ServerJoinPlanner {
    /// One mod's entry in a built plan.
    struct Item: Sendable, Equatable, Identifiable {
        var id: String { fullName }
        let fullName: String
        let classification: ModClassification
        /// The plan's current decision for this mod — the group's default
        /// unless `buildPlan`'s `overrides` flipped it.
        let enabled: Bool
    }

    /// A built plan, grouped for the guided flow's Step 2 display.
    struct Plan: Sendable, Equatable {
        /// `.clientOnly` + `.serverSynced` — always enabled. No override is
        /// offered for this group: there's nothing risky here to opt out
        /// of.
        let keepEnabled: [Item]
        /// `.addsItems` — defaults to *enabled* (the safer default:
        /// disabling an items mod risks hiding/stranding inventory items
        /// already picked up), surfaced with a prominent warning and a
        /// per-mod override to disable anyway.
        let addsItemsWarning: [Item]
        /// `.worldAltering` + `.unknown` — defaults to *disabled*, with a
        /// per-mod override to keep enabled anyway.
        let disable: [Item]

        var isEmpty: Bool { keepEnabled.isEmpty && addsItemsWarning.isEmpty && disable.isEmpty }

        /// Every item across all three groups — what `apply` writes into
        /// the target profile's mod list.
        var allItems: [Item] { keepEnabled + addsItemsWarning + disable }
    }

    /// Builds a plan from `manifest`'s installed mods, classified against
    /// `index`. `overrides[fullName]`, when present, replaces that mod's
    /// group default with the given enabled state — this is how the
    /// guided flow's per-mod checkboxes feed back into a rebuilt plan.
    static func buildPlan(
        manifest: InstalledManifest,
        index: [ThunderstorePackage],
        overrides: [String: Bool] = [:]
    ) -> Plan {
        var keepEnabled: [Item] = []
        var addsItemsWarning: [Item] = []
        var disable: [Item] = []

        for mod in manifest.mods.sorted(by: { $0.fullName < $1.fullName }) {
            let classification = ModClassifier.classify(mod: mod, index: index)
            switch classification.modClass {
            case .clientOnly, .serverSynced:
                keepEnabled.append(Item(fullName: mod.fullName, classification: classification, enabled: overrides[mod.fullName] ?? true))
            case .addsItems:
                addsItemsWarning.append(Item(fullName: mod.fullName, classification: classification, enabled: overrides[mod.fullName] ?? true))
            case .worldAltering, .unknown:
                disable.append(Item(fullName: mod.fullName, classification: classification, enabled: overrides[mod.fullName] ?? false))
            }
        }

        return Plan(keepEnabled: keepEnabled, addsItemsWarning: addsItemsWarning, disable: disable)
    }

    /// Applies `plan` to `profileID`:
    ///  1. Takes a "pre-server" safety backup of the current saves FIRST,
    ///     via `saveBackup.backupNow` — surfaced back to the caller as
    ///     `backupOutcome` rather than swallowed, since a `.skipped` result
    ///     (no save data yet) is a normal, worth-showing thing to see here.
    ///  2. Writes the plan's per-mod enabled decisions into `profileID`'s
    ///     own mod list, marking it a guest profile (`ProfileStore.setMods`,
    ///     `Profile.isServerGuest`) so `StatusPanel` can offer a "Back to
    ///     my profile" hint afterward regardless of whether `profileID` was
    ///     freshly created or an existing profile the caller repurposed.
    ///  3. Reconciles the real install to match via `ProfileStore.apply` —
    ///     exactly the same enable/disable/report-missing behavior any
    ///     other profile switch gets.
    @discardableResult
    static func apply(
        plan: Plan,
        profileID: UUID,
        gameDir: URL,
        profileStore: ProfileStore,
        saveBackup: SaveBackup
    ) async throws -> (backupOutcome: SaveBackup.BackupOutcome, applyResult: ProfileStore.ApplyResult) {
        let backupOutcome = try await saveBackup.backupNow(reason: "pre-server")

        let mods = plan.allItems.map { Profile.ProfileMod(fullName: $0.fullName, enabled: $0.enabled) }
        try await profileStore.setMods(profileID: profileID, mods: mods, isServerGuest: true)

        let applyResult = try await profileStore.apply(profileID: profileID, gameDir: gameDir)
        return (backupOutcome, applyResult)
    }
}
