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
        /// Thunderstore's "Author-Name" full name for a Thunderstore
        /// install, or Bifrost's own derived identity ("Local-<name>" or
        /// "<author>-<name>" parsed from a bundled manifest.json) for a
        /// `source == "local"` install — stable either way, and unique per
        /// mod regardless of version.
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
        /// Where this mod came from: `"thunderstore"` for anything
        /// resolved/installed against the Thunderstore index (Browse tab,
        /// dependency resolution, updates), `"local"` for a mod installed
        /// from a file on disk (see `ModManager.installFromFile`) — local
        /// mods are excluded from update checks since there's no index
        /// entry to compare against — or `"nexus"` for a mod installed via
        /// the `nxm://` "Mod Manager Download" flow (see
        /// `ModManager.installFromNexus`), whose update checks go against
        /// Nexus's own API instead using `nexusModId` below.
        var source: String

        /// The Nexus mod id this entry was installed from, when `source ==
        /// "nexus"`. `nil` for every other source, and also `nil` for an
        /// older nexus-sourced manifest entry written before this field
        /// existed — `updatesAvailable` treats that the same as "can't
        /// check" and skips it silently rather than erroring.
        var nexusModId: Int?
        /// The specific Nexus file id this entry's download came from
        /// (a mod can have multiple files/versions) — recorded alongside
        /// `nexusModId` for the same `source == "nexus"` entries.
        var nexusFileId: Int?

        var id: String { fullName }

        init(fullName: String, version: String, enabled: Bool, files: [String], source: String = "thunderstore", nexusModId: Int? = nil, nexusFileId: Int? = nil) {
            self.fullName = fullName
            self.version = version
            self.enabled = enabled
            self.files = files
            self.source = source
            self.nexusModId = nexusModId
            self.nexusFileId = nexusFileId
        }

        enum CodingKeys: String, CodingKey {
            case fullName, version, enabled, files, source, nexusModId, nexusFileId
        }

        /// Custom rather than synthesized so a manifest written before
        /// `source`/`nexusModId`/`nexusFileId` existed decodes with every
        /// mod defaulting to `"thunderstore"` and `nil` respectively,
        /// instead of failing to load entirely.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fullName = try container.decode(String.self, forKey: .fullName)
            version = try container.decode(String.self, forKey: .version)
            enabled = try container.decode(Bool.self, forKey: .enabled)
            files = try container.decode([String].self, forKey: .files)
            source = try container.decodeIfPresent(String.self, forKey: .source) ?? "thunderstore"
            nexusModId = try container.decodeIfPresent(Int.self, forKey: .nexusModId)
            nexusFileId = try container.decodeIfPresent(Int.self, forKey: .nexusFileId)
        }
    }
}
