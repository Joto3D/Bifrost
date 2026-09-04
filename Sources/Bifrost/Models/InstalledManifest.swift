import Foundation

/// Bifrost's own record of what it has installed into the game directory —
/// the source of truth `ModManager` reads and writes for every
/// install/uninstall/update/enable operation, and for update-availability
/// checks. This is deliberately independent of anything actually on disk:
/// disk state can be probed (`GameLocator.bepinexInstalled`,
/// `BepInExInstaller.status`), but *version* information only exists here,
/// because Thunderstore payloads carry no reliable version marker of their
/// own once extracted.
///
/// Persisted as JSON at `~/Library/Application Support/Bifrost/manifest.json`.
struct InstalledManifest: Codable, Sendable, Equatable {
    /// The installed BepInEx loader pack (`denikson-BepInExPack_Valheim`),
    /// if Bifrost has installed or recorded one. `nil` means either no pack
    /// is installed, or one is installed but predates Bifrost's manifest
    /// (see `BepInExInstaller.dryRun`'s `manifestVersion` handling).
    var loader: Loader?

    /// Every mod Bifrost has installed, keyed by full name ("Author-Name").
    var mods: [InstalledMod]

    static let empty = InstalledManifest(loader: nil, mods: [])

    struct Loader: Codable, Sendable, Equatable {
        var version: String
    }

    struct InstalledMod: Codable, Sendable, Equatable, Identifiable, Hashable {
        /// Thunderstore's "Author-Name" full name — stable, and unique
        /// per mod regardless of version.
        var fullName: String
        var version: String
        var enabled: Bool
        /// Every file this mod's install wrote, as paths relative to the
        /// game directory (e.g. "BepInEx/plugins/Author-Name/Foo.dll").
        /// These always reflect the *current* on-disk names — `setEnabled`
        /// rewrites the `.dll`/`.dll.disabled` entries in place when
        /// toggling, so `uninstall` can always delete exactly what's
        /// really there.
        var files: [String]

        var id: String { fullName }
    }
}
