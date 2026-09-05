import Foundation

/// A named, desired set of mods layered over Bifrost's single shared install
/// pool — every profile draws from the same `BepInEx/plugins` on disk and
/// the same `InstalledManifest`, they never get their own copy (this is the
/// same approach r2modman uses when it "shares" its mod cache across
/// profiles). A profile only records *membership and enabled state*; the
/// mod's actual installed version is still tracked solely by
/// `InstalledManifest`, and version pinning per profile is out of scope.
/// Per-profile `BepInEx/config` overrides are likewise out of scope for now.
///
/// Persisted as JSON at `~/Library/Application Support/Bifrost/profiles.json`
/// (see `ProfilesFile`), owned and mutated by `ProfileStore`.
struct Profile: Codable, Sendable, Equatable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var mods: [ProfileMod]

    /// Marks this profile as a temporary "join a server" profile created
    /// by the guided flow (`ServerJoinPlanner`/`ServerJoinSheetView`) —
    /// drives the "Back to my profile" hint on Home. `Bool?` rather than
    /// `Bool` so a `profiles.json` written before this field existed still
    /// decodes (Swift's synthesized `Decodable` treats a missing key for
    /// an `Optional` property as `nil`, rather than throwing) — `nil` and
    /// `false` are equivalent everywhere this is read (see
    /// `isGuestProfile`).
    var isServerGuest: Bool? = nil

    var isGuestProfile: Bool { isServerGuest == true }

    /// One mod's desired membership in a profile. Matched against
    /// `InstalledManifest.InstalledMod` by `fullName`.
    struct ProfileMod: Codable, Sendable, Equatable, Hashable {
        var fullName: String
        var enabled: Bool
    }
}

/// The full shape of `profiles.json`.
struct ProfilesFile: Codable, Sendable, Equatable {
    var activeProfileID: UUID?
    var profiles: [Profile]

    static let empty = ProfilesFile(activeProfileID: nil, profiles: [])
}
