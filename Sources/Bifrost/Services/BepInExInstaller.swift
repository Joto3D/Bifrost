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

    /// Presence of each piece BepInEx needs, plus what version (if any) is
    /// currently on disk.
    struct InstallStatus: Sendable, Equatable {
        var bepInExCorePresent: Bool
        var doorstopLibsPresent: Bool
        var doorstopConfigPresent: Bool
        var startScriptPresent: Bool
        var installedVersion: String?
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
    let launchDir: URL

    /// - Parameters:
    ///   - session: Defaults to `.shared`. Overridable for tests.
    ///   - launchDir: Where the launch wrapper + mode file are installed.
    ///     Defaults to the real Bifrost support directory; tests should
    ///     override this with a temp directory so they never touch a real
    ///     launch setup.
    init(session: URLSession = .shared, launchDir: URL = BepInExInstaller.defaultLaunchDir) {
        self.session = session
        self.launchDir = launchDir
    }

    static var defaultLaunchDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Bifrost/launch")
    }

    var wrapperScriptURL: URL { launchDir.appendingPathComponent("run_modded.sh") }
    var modeFileURL: URL { launchDir.appendingPathComponent("mode") }

    // MARK: - Status

    /// Reads what's on disk right now. Filesystem-only, no network.
    func status(gameDir: URL) -> InstallStatus {
        let fm = FileManager.default
        let versionFile = gameDir.appendingPathComponent(".doorstop_version")
        let installedVersion = (try? String(contentsOf: versionFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return InstallStatus(
            bepInExCorePresent: fm.fileExists(atPath: gameDir.appendingPathComponent("BepInEx/core").path),
            doorstopLibsPresent: fm.fileExists(atPath: gameDir.appendingPathComponent("doorstop_libs").path),
            doorstopConfigPresent: fm.fileExists(atPath: gameDir.appendingPathComponent("doorstop_config.ini").path),
            startScriptPresent: fm.fileExists(atPath: gameDir.appendingPathComponent("start_game_bepinex.sh").path),
            installedVersion: (installedVersion?.isEmpty == false) ? installedVersion : nil,
            wrapperInstalled: fm.fileExists(atPath: wrapperScriptURL.path)
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
    func dryRun(gameDir: URL) async -> [String] {
        var actions: [String] = []
        let local = status(gameDir: gameDir)
        let latest = try? await fetchLatestVersionInfo()

        if local.packFilesPresent {
            if let latest, let installed = local.installedVersion, installed != latest.versionNumber {
                actions.append("Update BepInEx pack: \(installed) -> \(latest.versionNumber) (plugins/config left untouched)")
            } else {
                let versionSuffix = local.installedVersion.map { " (version \($0))" } ?? ""
                actions.append("BepInEx pack already installed\(versionSuffix) — nothing to do")
            }
        } else {
            let versionDescription = latest?.versionNumber ?? "latest"
            actions.append("Download BepInExPack_Valheim \(versionDescription) from Thunderstore")
            actions.append("Extract and copy pack files into \(gameDir.path)")
            actions.append("Strip quarantine attribute and chmod +x start_game_bepinex.sh")
        }

        if local.wrapperInstalled {
            actions.append("Launch wrapper already installed at \(wrapperScriptURL.path) — nothing to do")
        } else {
            actions.append("Install launch wrapper to \(wrapperScriptURL.path) (mode=modded)")
        }

        return actions
    }

    // MARK: - Install

    /// Installs (or updates) the BepInEx pack into `gameDir`, and installs
    /// Bifrost's launch wrapper into `launchDir`. Idempotent: skips the pack
    /// download/copy entirely when the pack files are present and already
    /// match the latest published version, and never overwrites an existing
    /// `mode` file (so a user's vanilla/modded choice survives a reinstall).
    /// A reinstall/upgrade never touches `BepInEx/plugins` or
    /// `BepInEx/config`.
    func install(gameDir: URL, onProgress: @Sendable (Progress) -> Void = { _ in }) async throws -> InstallOutcome {
        onProgress(.fetchingVersionInfo)
        let latest = try await fetchLatestVersionInfo()
        let local = status(gameDir: gameDir)

        let packUpToDate = local.packFilesPresent && local.installedVersion == latest.versionNumber
        if packUpToDate {
            onProgress(.packAlreadyUpToDate(versionNumber: latest.versionNumber))
        } else {
            try await installPackFiles(gameDir: gameDir, version: latest, onProgress: onProgress)
        }

        onProgress(.installingWrapper)
        let modeFileCreated = try installWrapper(gameDir: gameDir)

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
    private func installWrapper(gameDir: URL) throws -> Bool {
        let fm = FileManager.default
        try fm.createDirectory(at: launchDir, withIntermediateDirectories: true)

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
