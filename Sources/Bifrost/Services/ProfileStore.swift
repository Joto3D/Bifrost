import Foundation

/// Owns `profiles.json` — CRUD over named `Profile`s, and `apply`, which
/// reconciles a profile's desired mod membership against what's actually
/// installed (`InstalledManifest`, via `ModManager`).
///
/// Profiles express *intent*; the manifest remains the source of truth for
/// what's actually installed. `apply` never installs or uninstalls
/// anything itself — it only enables/disables mods that are already
/// installed, and reports back (as `ApplyResult`/`ApplyPreview`) any
/// profile mods that aren't installed yet, for the caller to offer
/// installing (see `ModManager.resolve`/`install`) before re-applying.
actor ProfileStore {
    enum ProfileStoreError: Error, CustomStringConvertible {
        case notFound(id: UUID)
        case cannotDeleteActive

        var description: String {
            switch self {
            case .notFound(let id):
                return "No profile with id \(id)"
            case .cannotDeleteActive:
                return "Can't delete the active profile — switch to another profile first"
            }
        }
    }

    /// What `apply` actually did: mods it left needing an install, because
    /// the profile wants them but they aren't in the manifest yet.
    struct ApplyResult: Sendable, Equatable {
        let missing: [String]
    }

    /// What `apply` *would* do, computed without changing anything — for a
    /// caller to decide whether to confirm with the user first.
    struct ApplyPreview: Sendable, Equatable {
        /// Installed mods that are currently enabled but aren't enabled in
        /// the target profile (either absent from it, or present but
        /// disabled) — these would get disabled.
        let toDisable: [String]
        /// Profile mods that aren't installed yet.
        let missing: [String]

        var isNoOp: Bool { toDisable.isEmpty && missing.isEmpty }
    }

    let profilesURL: URL
    private let modManager: ModManager

    /// - Parameters:
    ///   - profilesURL: Defaults to the real Bifrost support directory;
    ///     tests should override this with a temp file, same pattern as
    ///     `ModManager.manifestURL`.
    ///   - modManager: The manifest `apply`/migration reconcile against.
    ///     Shared with the caller's own `ModManager` instance so both read
    ///     the same manifest — pass a fixture instance in tests.
    init(profilesURL: URL = ProfileStore.defaultProfilesURL, modManager: ModManager) {
        self.profilesURL = profilesURL
        self.modManager = modManager
    }

    static var defaultProfilesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Bifrost/profiles.json")
    }

    // MARK: - I/O

    /// Loads `profiles.json` from disk, or `.empty` if it doesn't exist yet
    /// or fails to parse. Callers that need first-run migration should call
    /// `loadOrMigrate()` instead.
    func load() -> ProfilesFile {
        guard let data = try? Data(contentsOf: profilesURL),
              let file = try? JSONDecoder().decode(ProfilesFile.self, from: data) else {
            return .empty
        }
        return file
    }

    private func save(_ file: ProfilesFile) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: profilesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: profilesURL, options: .atomic)
    }

    /// Loads `profiles.json`, auto-migrating on first run: if the file
    /// doesn't exist yet, creates a "Default" profile capturing the
    /// manifest's current mod membership and enabled state, marks it
    /// active, and persists that as the new `profiles.json`.
    @discardableResult
    func loadOrMigrate() async -> ProfilesFile {
        guard !FileManager.default.fileExists(atPath: profilesURL.path) else {
            return load()
        }
        let manifest = await modManager.loadManifest()
        let defaultProfile = Profile(
            id: UUID(),
            name: "Default",
            mods: manifest.mods.map { Profile.ProfileMod(fullName: $0.fullName, enabled: $0.enabled) }
        )
        let file = ProfilesFile(activeProfileID: defaultProfile.id, profiles: [defaultProfile])
        try? save(file)
        return file
    }

    // MARK: - CRUD

    /// Creates a new profile named `name`. When `fromCurrent` is true, it
    /// starts out matching every currently-installed mod's membership and
    /// enabled state (a snapshot, not a live link); otherwise it starts
    /// empty.
    @discardableResult
    func create(name: String, fromCurrent: Bool) async -> Profile {
        var file = await loadOrMigrate()
        let mods: [Profile.ProfileMod]
        if fromCurrent {
            let manifest = await modManager.loadManifest()
            mods = manifest.mods.map { Profile.ProfileMod(fullName: $0.fullName, enabled: $0.enabled) }
        } else {
            mods = []
        }
        let profile = Profile(id: UUID(), name: name, mods: mods)
        file.profiles.append(profile)
        try? save(file)
        return profile
    }

    /// Creates a copy of `id` named `newName`, with the same mod list.
    @discardableResult
    func duplicate(id: UUID, newName: String) async throws -> Profile {
        var file = await loadOrMigrate()
        guard let source = file.profiles.first(where: { $0.id == id }) else {
            throw ProfileStoreError.notFound(id: id)
        }
        let copy = Profile(id: UUID(), name: newName, mods: source.mods)
        file.profiles.append(copy)
        try save(file)
        return copy
    }

    func rename(id: UUID, to newName: String) async throws {
        var file = await loadOrMigrate()
        guard let index = file.profiles.firstIndex(where: { $0.id == id }) else {
            throw ProfileStoreError.notFound(id: id)
        }
        file.profiles[index].name = newName
        try save(file)
    }

    /// Deletes profile `id`. Refuses to delete the active profile — switch
    /// (`apply`) to a different one first.
    func delete(id: UUID) async throws {
        var file = await loadOrMigrate()
        guard file.profiles.contains(where: { $0.id == id }) else {
            throw ProfileStoreError.notFound(id: id)
        }
        guard file.activeProfileID != id else {
            throw ProfileStoreError.cannotDeleteActive
        }
        file.profiles.removeAll { $0.id == id }
        try save(file)
    }

    // MARK: - Apply / reconcile

    /// Computes what `apply(profileID:gameDir:)` would do to the real
    /// install right now, without changing anything — a caller (the UI)
    /// uses this to decide whether the switch needs confirming.
    func previewApply(profileID: UUID) async throws -> ApplyPreview {
        let file = await loadOrMigrate()
        guard let profile = file.profiles.first(where: { $0.id == profileID }) else {
            throw ProfileStoreError.notFound(id: profileID)
        }
        let manifest = await modManager.loadManifest()
        return Self.computePreview(profile: profile, manifest: manifest)
    }

    /// Reconciles the installed mods against `profileID`'s desired
    /// membership:
    ///  1. installed mod listed in the profile → `setEnabled` to the
    ///     profile's flag;
    ///  2. installed mod not listed in the profile → disabled (never
    ///     uninstalled — profiles only ever enable/disable, they don't
    ///     touch what's on disk beyond the `.dll`/`.dll.disabled` rename
    ///     `setEnabled` already does);
    ///  3. profile mod not installed → collected into `ApplyResult.missing`
    ///     for the caller to offer installing.
    /// On success, marks `profileID` as the active profile.
    @discardableResult
    func apply(profileID: UUID, gameDir: URL) async throws -> ApplyResult {
        let file = await loadOrMigrate()
        guard let profile = file.profiles.first(where: { $0.id == profileID }) else {
            throw ProfileStoreError.notFound(id: profileID)
        }
        let manifest = await modManager.loadManifest()
        let installedFullNames = Set(manifest.mods.map { $0.fullName })
        let profileByFullName = Dictionary(uniqueKeysWithValues: profile.mods.map { ($0.fullName, $0) })

        var missing: [String] = []
        for profileMod in profile.mods {
            guard installedFullNames.contains(profileMod.fullName) else {
                missing.append(profileMod.fullName)
                continue
            }
            try await modManager.setEnabled(fullName: profileMod.fullName, enabled: profileMod.enabled, gameDir: gameDir)
        }
        for installedMod in manifest.mods where profileByFullName[installedMod.fullName] == nil {
            try await modManager.setEnabled(fullName: installedMod.fullName, enabled: false, gameDir: gameDir)
        }

        var updated = file
        updated.activeProfileID = profileID
        try save(updated)

        return ApplyResult(missing: missing)
    }

    /// Updates the active profile's mod list to exactly match what's
    /// currently in the manifest (membership and enabled state). Call this
    /// after any manual install/uninstall/toggle from the Installed/Browse
    /// tabs so the active profile follows the user's manual edits instead
    /// of silently diverging from them. No-op if no profile is active.
    func syncActiveProfile() async {
        var file = await loadOrMigrate()
        guard let activeID = file.activeProfileID,
              let index = file.profiles.firstIndex(where: { $0.id == activeID }) else {
            return
        }
        let manifest = await modManager.loadManifest()
        file.profiles[index].mods = manifest.mods.map { Profile.ProfileMod(fullName: $0.fullName, enabled: $0.enabled) }
        try? save(file)
    }

    private static func computePreview(profile: Profile, manifest: InstalledManifest) -> ApplyPreview {
        let profileByFullName = Dictionary(uniqueKeysWithValues: profile.mods.map { ($0.fullName, $0) })

        let toDisable = manifest.mods
            .filter { $0.enabled && (profileByFullName[$0.fullName]?.enabled ?? false) == false }
            .map { $0.fullName }

        let installedFullNames = Set(manifest.mods.map { $0.fullName })
        let missing = profile.mods.map { $0.fullName }.filter { !installedFullNames.contains($0) }

        return ApplyPreview(toDisable: toDisable, missing: missing)
    }
}
