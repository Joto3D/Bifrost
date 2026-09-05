import Foundation

/// A mod's risk category for joining an unfamiliar multiplayer server —
/// purely advisory. Nothing in this file ever disables a mod on its own;
/// it only informs the guided "Join a Server" flow (`ServerJoinPlanner`)
/// and the Installed tab's per-row badge (`InstalledModsView`).
enum ModClass: String, Sendable, Equatable, CaseIterable {
    /// Purely visual/QoL — affects nothing the server or other players can
    /// observe. Safe to leave enabled joining any server, running the mod
    /// or not.
    case clientOnly
    /// Adds craftable/lootable items. BepInEx just stops loading the
    /// item's prefab when disabled — it doesn't delete anything from a
    /// save — but an item already in an inventory can end up hidden or
    /// unusable, so the safer default is to leave these enabled rather
    /// than disable them.
    case addsItems
    /// Changes world generation, biomes, or other persistent world state.
    /// Mismatched between client and the server being joined can desync
    /// or corrupt shared world data.
    case worldAltering
    /// A framework/library whose whole purpose is enforcing client/server
    /// version parity (Jotunn-style) — it needs to match whatever the
    /// server runs, but is never something to blanket-disable for
    /// joining one.
    case serverSynced
    /// No curated entry, no informative Thunderstore category, and no
    /// heuristic keyword hit — Bifrost has no signal either way.
    case unknown

    var displayName: String {
        switch self {
        case .clientOnly: return "Client-only"
        case .addsItems: return "Adds items"
        case .worldAltering: return "World-altering"
        case .serverSynced: return "Server-synced"
        case .unknown: return "Unknown"
        }
    }

    /// A single emoji standing in for a tinted capsule color in contexts
    /// (plain-text `--check` output) that can't render actual color.
    var glyph: String {
        switch self {
        case .clientOnly: return "🟢"
        case .addsItems: return "🟠"
        case .worldAltering: return "🔴"
        case .serverSynced: return "🔵"
        case .unknown: return "⚪"
        }
    }

    /// One-line explanation shown in the Installed tab badge's tooltip.
    var explanation: String {
        switch self {
        case .clientOnly:
            return "Purely client-side — safe to keep enabled on any server."
        case .addsItems:
            return "Adds items to your inventory — disabling it after joining a server that doesn't run it may hide or strand those items."
        case .worldAltering:
            return "Changes world generation or persistent world state — risky if the server you're joining doesn't run it too."
        case .serverSynced:
            return "Enforces version parity with the server (Jotunn-style) — must match whatever the server runs."
        case .unknown:
            return "Bifrost has no information about this mod's multiplayer impact."
        }
    }
}

/// One classification result: the class plus a short machine-readable
/// trail of *why* — surfaced in the Installed tab badge's tooltip and the
/// guided join-flow's plan, and printed by `--check`.
struct ModClassification: Sendable, Equatable {
    let modClass: ModClass
    /// e.g. `"curated"`, `"category: Client-side"`,
    /// `"heuristic: contains \"fps\""`, or `"no signal"`.
    let basis: String
}

/// Classifies installed mods for the guided "Join a Server" flow and the
/// Installed tab's badges.
///
/// Resolution order (first match wins):
///  1. `curatedOverrides` — a small built-in table for mods whose actual
///     multiplayer behavior this developer knows for a fact, since
///     Thunderstore's own category tags are author-supplied and often
///     missing or misleading (a pure FPS-counter overlay, for instance,
///     commonly carries no "Client-side" tag at all).
///  2. Thunderstore category tags from the cached index, when the mod's
///     `ThunderstorePackage` is known (nil for a `source ==
///     "local"`/`"nexus"` mod, or one dropped from the index between
///     installs).
///  3. Keyword heuristics against the package's name/description (falling
///     back to the mod's own full name when no package is known at all).
///  4. `.unknown`.
enum ModClassifier {
    /// Built-in "we know exactly what this is" table, keyed by
    /// Thunderstore full name ("Author-Name"). Takes priority over
    /// anything derived from the index.
    static let curatedOverrides: [String: ModClass] = [
        "Azumatt-FirstPersonMode": .clientOnly,
        "K_xD-ValheimFPSOptimizer": .clientOnly,
        "LEGIOmods-AutoLodBias": .clientOnly,
        "PUP82-PUP_FPS": .clientOnly,
        "ColdSpirit-ValheimGammaMod": .clientOnly,
        "shudnal-GammaOfNightLights": .clientOnly,
        "BetterSounds-BetterSounds": .clientOnly,
        "AAAValheimExperience-ImmersiveParryAudio": .clientOnly,
        // Willybach's HD/texture packs — purely visual asset replacements.
        "Willybach-Willybachs_HD_Seasonality": .clientOnly,
        "blacks7ar-GunzNBullets": .addsItems,
        "RandyKnapp-EquipmentAndQuickSlots": .addsItems,
        "Soloredis-RtDBiomes": .worldAltering,
        "Soloredis-RtDOcean": .worldAltering,
        "ValheimModding-Jotunn": .serverSynced,
    ]

    /// Classifies `fullName`, consulting `package` (that full name's entry
    /// in the cached Thunderstore index, when known) for its categories
    /// and description.
    static func classify(fullName: String, package: ThunderstorePackage?) -> ModClassification {
        if let curated = curatedOverrides[fullName] {
            return ModClassification(modClass: curated, basis: "curated")
        }

        if let categories = package?.categories,
           let (byCategory, matchedCategory) = classifyByCategory(categories) {
            return ModClassification(modClass: byCategory, basis: "category: \(matchedCategory)")
        }

        let haystack = [package?.name, package?.latestVersion?.description, fullName]
            .compactMap { $0 }
            .joined(separator: " ")
        if let (byHeuristic, keyword) = classifyByHeuristic(haystack) {
            return ModClassification(modClass: byHeuristic, basis: "heuristic: contains \"\(keyword)\"")
        }

        return ModClassification(modClass: .unknown, basis: "no signal")
    }

    /// Convenience for a manifest entry against an already-fetched index.
    static func classify(mod: InstalledManifest.InstalledMod, index: [ThunderstorePackage]) -> ModClassification {
        classify(fullName: mod.fullName, package: index.first { $0.fullName == mod.fullName })
    }

    /// "World Generation" wins over a bare "Client-side"/"Server-side" tag
    /// since it's the single most specific and highest-risk signal
    /// Thunderstore's categories carry on their own; "Client-side" (a mod
    /// explicitly marked safe client-only) wins over a bare "Server-side"
    /// tag, which by itself just means "this needs installing on servers
    /// too" — Jotunn-style version-enforcement territory rather than
    /// anything actively risky.
    private static func classifyByCategory(_ categories: [String]) -> (ModClass, String)? {
        if categories.contains("World Generation") { return (.worldAltering, "World Generation") }
        if categories.contains("Client-side") { return (.clientOnly, "Client-side") }
        if categories.contains("Server-side") { return (.serverSynced, "Server-side") }
        return nil
    }

    private static let clientOnlyKeywords = ["texture", "sound", "fps", "camera", "ui"]
    private static let worldAlteringKeywords = ["biome", "world gen", "worldgen", "location"]
    private static let addsItemsKeywords = ["weapon", "item", "armor"]

    /// Checked in clientOnly -> worldAltering -> addsItems order — matches
    /// the priority the feature spec lists the keyword groups in.
    private static func classifyByHeuristic(_ haystack: String) -> (ModClass, String)? {
        let lowered = haystack.lowercased()
        for keyword in clientOnlyKeywords where lowered.contains(keyword) {
            return (.clientOnly, keyword)
        }
        for keyword in worldAlteringKeywords where lowered.contains(keyword) {
            return (.worldAltering, keyword)
        }
        for keyword in addsItemsKeywords where lowered.contains(keyword) {
            return (.addsItems, keyword)
        }
        return nil
    }
}
