import Foundation

/// Detects when Valheim's Steam build changes between checks, so a mod that
/// broke against a new build isn't silently trusted just because it was
/// working yesterday — and so a Steam "verify integrity of game files" pass
/// (which can strip BepInEx's own files right back out) gets flagged instead
/// of just quietly failing to launch modded.
///
/// Reads `buildid`/`SizeOnDisk` straight out of Steam's own
/// `appmanifest_892970.acf`, using the same tiny VDF reader
/// `GameLocator`/`SteamConfigurator` already rely on (`VDF.value`) rather
/// than inventing a second parser — the manifest is a flat `"AppState" { ... }`
/// block, so a single-segment path is all `VDF.value` needs.
enum GameUpdateWatcher {
    /// The bits of `appmanifest_892970.acf` this watcher cares about.
    struct ManifestInfo: Sendable, Equatable {
        let buildID: String
        let sizeOnDisk: String?
    }

    /// The outcome of comparing the manifest's current `buildid` against
    /// whatever was persisted from the last check.
    enum CheckResult: Sendable, Equatable {
        /// No prior buildid was on record (first check ever, or a fresh
        /// `UserDefaults` domain) — the current one is now recorded, but
        /// there's nothing to warn about yet.
        case firstSeen(buildID: String)
        /// Same buildid as last time — nothing changed.
        case unchanged(buildID: String)
        /// The buildid changed since the last time this was checked.
        case updated(previousBuildID: String, currentBuildID: String)
        /// The game couldn't be located, or its `.acf` couldn't be read/
        /// parsed — nothing to compare.
        case unavailable

        /// The banner text for `.updated`; `nil` for every other case (there's
        /// nothing to warn about).
        var message: String? {
            guard case .updated(let previous, let current) = self else { return nil }
            return "Valheim updated (build \(previous) \u{2192} \(current)) — mods may be broken until updated; BepInEx may need reinstalling if Steam verified files."
        }
    }

    /// `UserDefaults` key the last-seen buildid is persisted under.
    static let lastSeenBuildIDDefaultsKey = "GameUpdateWatcher.lastSeenBuildID"

    /// Reads `buildid`/`SizeOnDisk` from `<steamlib>/steamapps/appmanifest_892970.acf`
    /// for the Steam library `gameDir` lives under. `gameDir` is shaped like
    /// `<library>/steamapps/common/<installdir>` (see `GameLocator.locate`),
    /// so the manifest sits two directories up from it. Read-only — never
    /// writes anything.
    static func readManifestInfo(gameDir: URL) -> ManifestInfo? {
        let steamappsDir = gameDir.deletingLastPathComponent().deletingLastPathComponent()
        let manifestURL = steamappsDir.appendingPathComponent("appmanifest_\(GameLocator.valheimAppID).acf")
        guard let text = try? String(contentsOf: manifestURL, encoding: .utf8) else { return nil }
        guard let buildID = VDF.value(forKey: "buildid", atPath: ["AppState"], in: text) else { return nil }
        let sizeOnDisk = VDF.value(forKey: "SizeOnDisk", atPath: ["AppState"], in: text)
        return ManifestInfo(buildID: buildID, sizeOnDisk: sizeOnDisk)
    }

    /// Reads the current buildid (via `readManifestInfo`) and compares it
    /// against whatever `defaults` has recorded under
    /// `lastSeenBuildIDDefaultsKey`, always persisting the current value back
    /// afterward (so the next call compares against *this* one). `defaults`
    /// defaults to `.standard` but is injectable so this stays testable
    /// without touching the real app's persisted state (see `DebugCheck`).
    ///
    /// Callers that want this to run at most once per app launch (to avoid
    /// two near-simultaneous checks racing each other — the second would
    /// always see the first one's just-persisted value and report
    /// `.unchanged`, clobbering a real `.updated` result) should guard the
    /// call themselves; see `AppState.refresh`.
    static func check(gameDir: URL?, defaults: UserDefaults = .standard) -> CheckResult {
        guard let gameDir, let info = readManifestInfo(gameDir: gameDir) else {
            return .unavailable
        }

        let previous = defaults.string(forKey: lastSeenBuildIDDefaultsKey)
        defaults.set(info.buildID, forKey: lastSeenBuildIDDefaultsKey)

        guard let previous else {
            return .firstSeen(buildID: info.buildID)
        }
        guard previous != info.buildID else {
            return .unchanged(buildID: info.buildID)
        }
        return .updated(previousBuildID: previous, currentBuildID: info.buildID)
    }
}
