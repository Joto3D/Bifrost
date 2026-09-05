import Foundation
import Observation

/// App-wide observable state, injected into the view hierarchy via
/// `.environment`. Owns the setup-status checks that gate modded launches.
@MainActor
@Observable
final class AppState {
    private(set) var status: SetupStatus = .unknown
    private(set) var isRefreshing = false
    private(set) var manifest: InstalledManifest = .empty
    private(set) var profiles: ProfilesFile = .empty

    /// Drives `SetupWizardView`'s sheet from anywhere in the view
    /// hierarchy (`MainWindow` presents it automatically on first launch
    /// when not `readyToPlay`; `SettingsView`'s "Run setup wizard" button
    /// re-opens it on demand).
    var setupWizardPresented = false

    /// The single error currently surfaced to the user via the shared
    /// alert modifier (see `View.bifrostErrorAlert`), if any.
    var lastError: BifrostError?

    /// `.zip`/`.dll` files most recently dropped onto the window's
    /// whole-window drop target (see `MainWindow`), waiting to be
    /// installed. `MainWindow` sits above `InstalledModsView` in the view
    /// hierarchy and owns the drop target so dropping works regardless of
    /// which tab is active, but the actual install flow (progress,
    /// collision confirmation, manifest refresh) belongs with the rest of
    /// `InstalledModsView`'s mod-management state — this property is the
    /// hand-off between the two. `InstalledModsView` observes it, drains it
    /// via `installFiles`, and resets it to `[]` once processed.
    var pendingFileDrop: [URL] = []

    let modManager = ModManager()
    let profileStore: ProfileStore

    init() {
        profileStore = ProfileStore(modManager: modManager)
    }

    /// The currently active profile, if any (`profiles.activeProfileID`
    /// resolved against `profiles.profiles`).
    var activeProfile: Profile? {
        profiles.profiles.first { $0.id == profiles.activeProfileID }
    }

    /// Re-runs every setup check. Filesystem checks are cheap and run
    /// inline; the Rosetta probe shells out, so it's the only truly async
    /// step.
    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let located = GameLocator.locate()
        let gameFound = (located?.isValid == true) ? located?.directory : nil

        let bepinexInstalled: Bool
        if let gameDir = located?.directory {
            bepinexInstalled = GameLocator.bepinexInstalled(at: gameDir)
        } else {
            bepinexInstalled = false
        }

        let rosettaOK = await Self.checkRosetta()
        let steamConfigured = GameLocator.steamConfiguredForModdedLaunch()

        status = SetupStatus(
            gameFound: gameFound,
            bepinexInstalled: bepinexInstalled,
            rosettaOK: rosettaOK,
            steamConfigured: steamConfigured
        )

        await refreshManifest()
        await refreshProfiles()
    }

    /// Reloads the installed-mods manifest from disk. Called after
    /// `refresh()` and by the Browse/Installed views after any operation
    /// (install/uninstall/update/toggle) so both stay in sync without
    /// needing to pass state between them directly.
    func refreshManifest() async {
        manifest = await modManager.loadManifest()
    }

    /// Reloads `profiles.json` (auto-migrating a "Default" profile from the
    /// current manifest on first run — see `ProfileStore.loadOrMigrate`).
    func refreshProfiles() async {
        profiles = await profileStore.loadOrMigrate()
    }

    /// Computes what applying `profileID` would do, without changing
    /// anything — used to decide whether switching needs to confirm with
    /// the user first (see `ProfileStore.previewApply`).
    func previewApplyProfile(id: UUID) async throws -> ProfileStore.ApplyPreview {
        try await profileStore.previewApply(profileID: id)
    }

    /// Applies `profileID` (see `ProfileStore.apply`): enables/disables
    /// installed mods to match the profile's desired state, marks it
    /// active, then refreshes both the manifest and the profiles list.
    /// Returns the profile mods that aren't installed yet, for the caller
    /// to offer installing.
    @discardableResult
    func applyProfile(id: UUID, gameDir: URL) async throws -> ProfileStore.ApplyResult {
        let result = try await profileStore.apply(profileID: id, gameDir: gameDir)
        await refreshManifest()
        await refreshProfiles()
        return result
    }

    /// Installs every mod in `fullNames` (each resolved via
    /// `ModManager.resolve`/`install` so its own dependencies come along
    /// too), then re-applies `profileID` so the newly-installed mods' state
    /// ends up matching the profile. For the "Install missing (N)" action
    /// offered after `applyProfile` reports mods the profile wants that
    /// aren't installed yet.
    @discardableResult
    func installMissingAndReapply(
        fullNames: [String],
        profileID: UUID,
        gameDir: URL,
        index: [ThunderstorePackage]
    ) async throws -> ProfileStore.ApplyResult {
        for fullName in fullNames {
            guard let package = index.first(where: { $0.fullName == fullName }) else { continue }
            try await modManager.install(package: package, index: index, gameDir: gameDir)
        }
        return try await applyProfile(id: profileID, gameDir: gameDir)
    }

    /// Updates the active profile's mod list to match the manifest — call
    /// after a manual install/uninstall/toggle from the Installed/Browse
    /// tabs (see `ProfileStore.syncActiveProfile`), in addition to the
    /// existing `refreshManifest()` those actions already do.
    func syncActiveProfileWithManifest() async {
        await profileStore.syncActiveProfile()
        await refreshProfiles()
    }

    private static func checkRosetta() async -> Bool {
        guard let result = try? await ShellRunner.run("/usr/bin/arch", ["-x86_64", "/usr/bin/true"]) else {
            return false
        }
        return result.status == 0
    }

    /// Surfaces `message` to the user via the shared alert modifier
    /// (`View.bifrostErrorAlert`). Any view holding an `AppState` can call
    /// this instead of rolling its own alert state.
    func reportError(_ title: String, _ message: String) {
        lastError = BifrostError(title: title, message: message)
    }
}

/// A user-facing error surfaced through `View.bifrostErrorAlert`.
struct BifrostError: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}
