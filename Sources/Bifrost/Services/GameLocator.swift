import Foundation

/// Locates the Valheim install through Steam's own bookkeeping. We
/// deliberately never guess at well-known install paths (there's a stray
/// `~/Applications/Valheim.app` on this machine that must never be used) —
/// the only trustworthy source of truth is Steam's library folder list and
/// app manifest.
enum GameLocator {
    static let valheimAppID = "892970"

    struct LocatedGame: Sendable, Equatable {
        let directory: URL
        let hasExecutable: Bool

        var isValid: Bool { hasExecutable }
    }

    enum LocatorError: Error {
        case steamNotFound
        case libraryFoldersNotFound
        case appNotOwned
    }

    static var steamRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam")
    }

    /// Finds the Valheim install directory by walking Steam's configured
    /// library folders and looking for an app manifest for 892970.
    static func locate() -> LocatedGame? {
        let libraries = steamLibraryPaths()
        for library in libraries {
            let steamappsDir = library.appendingPathComponent("steamapps")
            let manifestURL = steamappsDir.appendingPathComponent("appmanifest_\(valheimAppID).acf")
            guard let manifestContents = try? String(contentsOf: manifestURL, encoding: .utf8) else {
                continue
            }

            let installDir = vdfValue(for: "installdir", in: manifestContents) ?? "Valheim"
            let gameDir = steamappsDir
                .appendingPathComponent("common")
                .appendingPathComponent(installDir)

            let appBundle = gameDir.appendingPathComponent("valheim.app")
            let hasExecutable = FileManager.default.fileExists(atPath: appBundle.path)
            return LocatedGame(directory: gameDir, hasExecutable: hasExecutable)
        }
        return nil
    }

    /// Reads `libraryfolders.vdf` and returns every configured library path,
    /// including the Steam root itself (which is always an implicit
    /// library). Tolerates both the older flat format
    /// (`"1" "/some/path"`) and the newer nested-object format
    /// (`"1" { "path" "/some/path" ... }`).
    static func steamLibraryPaths() -> [URL] {
        let root = steamRoot
        var paths: [URL] = [root]

        let libraryFoldersURL = root
            .appendingPathComponent("steamapps")
            .appendingPathComponent("libraryfolders.vdf")

        guard let contents = try? String(contentsOf: libraryFoldersURL, encoding: .utf8) else {
            return paths
        }

        for line in contents.components(separatedBy: .newlines) {
            guard let path = vdfLineValue(for: "path", in: line) else { continue }
            let url = URL(fileURLWithPath: path)
            if !paths.contains(url) {
                paths.append(url)
            }
        }

        return paths
    }

    /// Extracts the value for `"key"    "value"` from a single VDF line.
    private static func vdfLineValue(for key: String, in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\"\(key)\"") else { return nil }

        // Strip the key, then pull the next quoted token.
        let afterKey = trimmed.dropFirst(key.count + 2)
        return firstQuotedToken(in: String(afterKey))
    }

    /// Extracts the value for `"key"    "value"` anywhere in a multi-line
    /// VDF blob (used for flat manifest files like appmanifest_*.acf).
    private static func vdfValue(for key: String, in contents: String) -> String? {
        for line in contents.components(separatedBy: .newlines) {
            if let value = vdfLineValue(for: key, in: line) {
                return value
            }
        }
        return nil
    }

    private static func firstQuotedToken(in text: String) -> String? {
        guard let firstQuote = text.firstIndex(of: "\"") else { return nil }
        let afterFirst = text.index(after: firstQuote)
        guard let secondQuote = text[afterFirst...].firstIndex(of: "\"") else { return nil }
        return String(text[afterFirst..<secondQuote])
    }

    // MARK: - BepInEx

    /// A BepInEx install is considered present when the loader's directory
    /// tree and doorstop shim are all sitting alongside the game.
    static func bepinexInstalled(at gameDir: URL) -> Bool {
        let fm = FileManager.default
        let markers = [
            "BepInEx",
            "doorstop_libs",
            "doorstop_config.ini",
            "start_game_bepinex.sh",
        ]
        return markers.allSatisfy { fm.fileExists(atPath: gameDir.appendingPathComponent($0).path) }
    }

    // MARK: - Steam launch options

    /// Checks whether any Steam user profile has launch options for
    /// Valheim (892970) that route through Bifrost's `run_modded.sh`
    /// wrapper. This is a targeted scan, not a full VDF parse: it finds the
    /// `"892970" { ... }` block nested under `"apps"` and looks for a
    /// `LaunchOptions` value mentioning our wrapper script.
    static func steamConfiguredForModdedLaunch() -> Bool {
        let userdataRoot = steamRoot.appendingPathComponent("userdata")
        guard let profiles = try? FileManager.default.contentsOfDirectory(
            at: userdataRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        // Prefer the most recently modified profile, but fall back to
        // checking all of them if that one doesn't have it configured.
        let sortedProfiles = profiles.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return lhsDate > rhsDate
        }

        for profile in sortedProfiles {
            let configURL = profile.appendingPathComponent("config/localconfig.vdf")
            guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else { continue }
            if launchOptionsReferenceRunModded(in: contents) {
                return true
            }
        }
        return false
    }

    /// Scans for the `"892970" { ... "LaunchOptions" "..." ... }` block
    /// under `"apps"` and checks that its LaunchOptions value mentions
    /// run_modded.sh. Line-based and deliberately tolerant of the rest of
    /// the file's structure.
    private static func launchOptionsReferenceRunModded(in contents: String) -> Bool {
        let lines = contents.components(separatedBy: .newlines)
        guard let appIDLineIndex = lines.firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed == "\"\(valheimAppID)\""
        }) else {
            return false
        }

        // Scan forward from the app id line for a LaunchOptions entry,
        // stopping once we've closed that app's brace block.
        var depth = 0
        var sawOpenBrace = false
        for line in lines[appIDLineIndex...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "{" {
                depth += 1
                sawOpenBrace = true
                continue
            }
            if trimmed == "}" {
                depth -= 1
                if sawOpenBrace && depth <= 0 { break }
                continue
            }
            if trimmed.hasPrefix("\"LaunchOptions\"") {
                return trimmed.contains("run_modded.sh")
            }
        }
        return false
    }
}
