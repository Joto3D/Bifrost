import Foundation

/// Installs and updates the BepInEx mod loader pack (denikson's
/// `BepInExPack_Valheim` from Thunderstore) next to Valheim, and installs
/// Bifrost's launch wrapper alongside it.
///
/// Reinstalling to pick up a newer pack version never touches
/// `BepInEx/plugins` or `BepInEx/config` — those hold user-installed mods
/// and settings and must survive an upgrade untouched.
actor BepInExInstaller {
    enum InstallerError: Error, CustomStringConvertible {
        case badPackageResponse
        case badDownloadResponse(status: Int)
        case extractionFailed(status: Int32)
        case payloadNotFound

        var description: String {
            switch self {
            case .badPackageResponse:
                return "Could not read the BepInExPack_Valheim package listing from Thunderstore"
            case .badDownloadResponse(let status):
                return "Download failed with HTTP status \(status)"
            case .extractionFailed(let status):
                return "ditto extraction failed (exit \(status))"
            case .payloadNotFound:
                return "Extracted archive did not contain a BepInExPack_Valheim folder"
            }
        }
    }

    /// Presence of each piece BepInEx needs. Deliberately carries no
    /// version — `.doorstop_version` (still copied as part of the pack
    /// payload) is UnityDoorstop's own version, not the BepInExPack_Valheim
    /// version, so it's useless for update detection. The pack version
    /// Bifrost actually installed is tracked separately, in its own
    /// manifest (see `ModManager`), and passed into `dryRun`/`install` as
    /// `manifestVersion`.
    struct InstallStatus: Sendable, Equatable {
        var bepInExCorePresent: Bool
        var doorstopLibsPresent: Bool
        var doorstopConfigPresent: Bool
        var startScriptPresent: Bool
        var wrapperInstalled: Bool

        var packFilesPresent: Bool {
            bepInExCorePresent && doorstopLibsPresent && doorstopConfigPresent && startScriptPresent
        }
    }

    /// Latest available pack version, as reported by Thunderstore.
    struct VersionInfo: Sendable, Equatable {
        let versionNumber: String
        let downloadURL: URL
    }

    /// One step of progress reported during `install(gameDir:)`.
    enum Progress: Sendable, Equatable {
        case fetchingVersionInfo
        case packAlreadyUpToDate(versionNumber: String)
        case downloading(versionNumber: String)
        case extracting
        case copyingFiles
        case strippingQuarantine
        case installingWrapper
        case done(versionNumber: String)
    }

    /// What `install(gameDir:)` actually did.
    struct InstallOutcome: Sendable, Equatable {
        let versionNumber: String
        let packWasUpToDate: Bool
        let modeFileCreated: Bool
    }

    private static let packageIndexURL = URL(string: "https://thunderstore.io/api/experimental/package/denikson/BepInExPack_Valheim/")!
    private static let payloadFolderName = "BepInExPack_Valheim"

    /// Payload items copied from inside the pack's `BepInExPack_Valheim/`
    /// folder to sit next to `valheim.app`. `winhttp.dll`,
    /// `changelog.txt`, and `start_server_bepinex.sh` are part of the
    /// upstream pack but irrelevant on macOS and deliberately skipped.
    private static let payloadItems = [
        "BepInEx",
        "doorstop_libs",
        "doorstop_config.ini",
        "start_game_bepinex.sh",
        ".doorstop_version",
    ]

    private let session: URLSession

    /// - Parameter session: Defaults to `.shared`. Overridable for tests.
    ///
    /// Deliberately holds no `launchDir` state: every operation that
    /// touches the launch wrapper/mode file takes `launchDir` as an
    /// explicit parameter (see `status`, `dryRun`, `install` below) rather
    /// than fixing it at construction time. This is a deliberate safety
    /// property — a prior bug wrote the launch wrapper into the *real*
    /// Bifrost launch directory (`defaultLaunchDir`) while templating it
    /// with a throwaway test `gameDir`, because an installer instance
    /// constructed with the (real) default `launchDir` was reused against a
    /// fake `gameDir`. Forcing `launchDir` to be named at every call site
    /// makes that pairing visible and grep-able instead of silently
    /// defaulted.
    init(session: URLSession = .shared) {
        self.session = session
    }

    static var defaultLaunchDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Bifrost/launch")
    }

    static func wrapperScriptURL(launchDir: URL) -> URL { launchDir.appendingPathComponent("run_modded.sh") }
    static func modeFileURL(launchDir: URL) -> URL { launchDir.appendingPathComponent("mode") }

    // MARK: - Status

    /// Reads what's on disk right now. Filesystem-only, no network.
    func status(gameDir: URL, launchDir: URL) -> InstallStatus {
        let fm = FileManager.default
        return InstallStatus(
            bepInExCorePresent: fm.fileExists(atPath: gameDir.appendingPathComponent("BepInEx/core").path),
            doorstopLibsPresent: fm.fileExists(atPath: gameDir.appendingPathComponent("doorstop_libs").path),
            doorstopConfigPresent: fm.fileExists(atPath: gameDir.appendingPathComponent("doorstop_config.ini").path),
            startScriptPresent: fm.fileExists(atPath: gameDir.appendingPathComponent("start_game_bepinex.sh").path),
            wrapperInstalled: fm.fileExists(atPath: Self.wrapperScriptURL(launchDir: launchDir).path)
        )
    }

    /// Fetches the latest published pack version from Thunderstore's
    /// experimental package API.
    func fetchLatestVersionInfo() async throws -> VersionInfo {
        let (data, response) = try await session.data(from: Self.packageIndexURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw InstallerError.badPackageResponse
        }
        let decoded = try JSONDecoder().decode(PackageResponse.self, from: data)
        return VersionInfo(versionNumber: decoded.latest.versionNumber, downloadURL: decoded.latest.downloadURL)
    }

    /// Describes, without changing anything, what `install(gameDir:)` would
    /// do right now. Fetches the latest version info (best-effort — a
    /// network failure just means version comparisons are skipped, not that
    /// this throws).
    ///
    /// - Parameter manifestVersion: The pack version Bifrost's own manifest
    ///   has recorded for this install (`ModManager`'s `loader.version`),
    ///   if any. When the pack's files are present but this is `nil` — a
    ///   pre-Bifrost manual install, or any other install Bifrost never
    ///   recorded — this reports the pack as installed with an unknown
    ///   version and offers a non-forced reinstall/update, rather than
    ///   claiming an update is actually pending (there's no reliable way to
    ///   tell from disk alone).
    func dryRun(gameDir: URL, launchDir: URL, manifestVersion: String? = nil) async -> [String] {
        var actions: [String] = []
        let local = status(gameDir: gameDir, launchDir: launchDir)
        let latest = try? await fetchLatestVersionInfo()

        if local.packFilesPresent {
            if let manifestVersion {
                if let latest, manifestVersion != latest.versionNumber {
                    actions.append("Update BepInEx pack: \(manifestVersion) -> \(latest.versionNumber) (plugins/config left untouched)")
                } else {
                    actions.append("BepInEx pack already installed (version \(manifestVersion)) — nothing to do")
                }
            } else {
                actions.append("BepInEx pack files present but not recorded in Bifrost's manifest — version unknown; Reinstall/Update available (not forced, plugins/config left untouched)")
            }
        } else {
            let versionDescription = latest?.versionNumber ?? "latest"
            actions.append("Download BepInExPack_Valheim \(versionDescription) from Thunderstore")
            actions.append("Extract and copy pack files into \(gameDir.path)")
            actions.append("Strip quarantine attribute and chmod +x start_game_bepinex.sh")
        }

        if local.wrapperInstalled {
            actions.append("Launch wrapper already installed at \(Self.wrapperScriptURL(launchDir: launchDir).path) — nothing to do")
        } else {
            actions.append("Install launch wrapper to \(Self.wrapperScriptURL(launchDir: launchDir).path) (mode=modded)")
        }

        return actions
    }

    // MARK: - Install

    /// Installs (or updates) the BepInEx pack into `gameDir`, and installs
    /// Bifrost's launch wrapper into `launchDir`. Idempotent: skips the pack
    /// download/copy entirely when the pack files are present and
    /// `manifestVersion` (see `dryRun`) already matches the latest
    /// published version, and never overwrites an existing `mode` file (so
    /// a user's vanilla/modded choice survives a reinstall). A
    /// reinstall/upgrade never touches `BepInEx/plugins` or
    /// `BepInEx/config`. Callers (namely `ModManager`) are responsible for
    /// recording the returned version back into the manifest.
    func install(gameDir: URL, launchDir: URL, manifestVersion: String? = nil, onProgress: @Sendable (Progress) -> Void = { _ in }) async throws -> InstallOutcome {
        onProgress(.fetchingVersionInfo)
        let latest = try await fetchLatestVersionInfo()
        let local = status(gameDir: gameDir, launchDir: launchDir)

        let packUpToDate = local.packFilesPresent && manifestVersion == latest.versionNumber
        if packUpToDate {
            onProgress(.packAlreadyUpToDate(versionNumber: latest.versionNumber))
        } else {
            try await installPackFiles(gameDir: gameDir, version: latest, onProgress: onProgress)
        }

        onProgress(.installingWrapper)
        let modeFileCreated = try installWrapper(gameDir: gameDir, launchDir: launchDir)

        onProgress(.done(versionNumber: latest.versionNumber))
        return InstallOutcome(versionNumber: latest.versionNumber, packWasUpToDate: packUpToDate, modeFileCreated: modeFileCreated)
    }

    private func installPackFiles(gameDir: URL, version: VersionInfo, onProgress: @Sendable (Progress) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: gameDir, withIntermediateDirectories: true)

        let workDir = fm.temporaryDirectory.appendingPathComponent("Bifrost-BepInExInstall-\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        onProgress(.downloading(versionNumber: version.versionNumber))
        let (downloadedURL, response) = try await session.download(from: version.downloadURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw InstallerError.badDownloadResponse(status: status)
        }
        let zipURL = workDir.appendingPathComponent("BepInExPack_Valheim.zip")
        try fm.moveItem(at: downloadedURL, to: zipURL)

        onProgress(.extracting)
        let extractDir = workDir.appendingPathComponent("extracted")
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let dittoResult = try await ShellRunner.run("/usr/bin/ditto", ["-xk", zipURL.path, extractDir.path])
        guard dittoResult.status == 0 else {
            throw InstallerError.extractionFailed(status: dittoResult.status)
        }

        let payloadDir = extractDir.appendingPathComponent(Self.payloadFolderName)
        guard fm.fileExists(atPath: payloadDir.path) else {
            throw InstallerError.payloadNotFound
        }

        onProgress(.copyingFiles)
        try copyPayload(from: payloadDir, to: gameDir)

        onProgress(.strippingQuarantine)
        for item in Self.payloadItems {
            let itemPath = gameDir.appendingPathComponent(item).path
            guard fm.fileExists(atPath: itemPath) else { continue }
            _ = try? await ShellRunner.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", itemPath])
        }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gameDir.appendingPathComponent("start_game_bepinex.sh").path)
    }

    /// Copies each payload item into `gameDir`. `BepInEx` is merged rather
    /// than replaced wholesale, so existing `plugins/` and `config/`
    /// contents are never touched.
    private func copyPayload(from payloadDir: URL, to gameDir: URL) throws {
        let fm = FileManager.default
        for item in Self.payloadItems {
            let src = payloadDir.appendingPathComponent(item)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = gameDir.appendingPathComponent(item)

            if item == "BepInEx" {
                try mergeBepInExDirectory(from: src, to: dst)
            } else {
                if fm.fileExists(atPath: dst.path) {
                    try fm.removeItem(at: dst)
                }
                try fm.copyItem(at: src, to: dst)
            }
        }
    }

    private func mergeBepInExDirectory(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        let preservedNames: Set<String> = ["plugins", "config"]

        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        for entry in try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) {
            let name = entry.lastPathComponent
            let target = dst.appendingPathComponent(name)

            if preservedNames.contains(name), fm.fileExists(atPath: target.path) {
                continue // never touch existing plugins/config — user data.
            }
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.copyItem(at: entry, to: target)
        }
    }

    /// Installs the launch wrapper script (rewritten unconditionally — it's
    /// static content with no user state) and creates the `mode` file only
    /// if one doesn't already exist, so a user's vanilla/modded choice
    /// survives a reinstall. Returns whether the mode file was created.
    private func installWrapper(gameDir: URL, launchDir: URL) throws -> Bool {
        let fm = FileManager.default
        try fm.createDirectory(at: launchDir, withIntermediateDirectories: true)

        let wrapperScriptURL = Self.wrapperScriptURL(launchDir: launchDir)
        let modeFileURL = Self.modeFileURL(launchDir: launchDir)

        try Self.wrapperScript(gameDir: gameDir).write(to: wrapperScriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapperScriptURL.path)

        guard !fm.fileExists(atPath: modeFileURL.path) else { return false }
        try "modded".write(to: modeFileURL, atomically: true, encoding: .utf8)
        return true
    }

    /// The launch wrapper's exact, verified-working content — only
    /// `GAME_DIR` is templated, from the game directory `GameLocator`
    /// resolved.
    private static func wrapperScript(gameDir: URL) -> String {
        """
        #!/bin/sh
        # Bifrost launch wrapper for Valheim (appid 892970).
        # Steam launch options invoke this as:  "<this script>" %command%
        # Mode file next to this script selects modded (BepInEx via Rosetta) or vanilla.

        BIFROST_DIR="$(cd "$(dirname "$0")" && pwd)"
        MODE_FILE="$BIFROST_DIR/mode"
        GAME_DIR="\(gameDir.path)"
        LOG="$BIFROST_DIR/wrapper.log"

        MODE="modded"
        [ -f "$MODE_FILE" ] && MODE="$(cat "$MODE_FILE")"

        echo "$(date '+%F %T') mode=$MODE args=$*" >> "$LOG"

        if [ "$MODE" != "modded" ] || [ ! -x "$GAME_DIR/start_game_bepinex.sh" ]; then
            # Steam passes the .app bundle path as %command% on macOS; a bundle
            # directory cannot be exec'd, so resolve its inner executable first.
            TARGET="$1"
            case "$TARGET" in
                *.app)
                    INNER="$(defaults read "$TARGET/Contents/Info" CFBundleExecutable 2>/dev/null)"
                    if [ -n "$INNER" ] && [ -x "$TARGET/Contents/MacOS/$INNER" ]; then
                        shift
                        exec "$TARGET/Contents/MacOS/$INNER" "$@"
                    fi
                ;;
            esac
            exec "$@"
        fi

        cd "$GAME_DIR" || exec "$@"
        # Run the BepInEx bootstrap under an x86_64 shell so the game execs its
        # x86_64 slice (doorstop's dylib is Intel-only and needs Rosetta).
        exec arch -x86_64 /bin/sh "$GAME_DIR/start_game_bepinex.sh" "$@"

        """
    }

    // MARK: - Thunderstore experimental package API

    private struct PackageResponse: Decodable {
        let latest: Latest

        struct Latest: Decodable {
            let versionNumber: String
            let downloadURL: URL

            enum CodingKeys: String, CodingKey {
                case versionNumber = "version_number"
                case downloadURL = "download_url"
            }
        }
    }
}
