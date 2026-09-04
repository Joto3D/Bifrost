import Foundation

/// Ensures the current Steam user's launch options for Valheim (892970)
/// route through Bifrost's launch wrapper, by splicing a single
/// `LaunchOptions` value into `localconfig.vdf`. Every other byte of that
/// file is left untouched — see `VDF`.
///
/// If the value is already exactly right, `configure()` is a complete
/// no-op: Steam is never quit. That's the expected common case once a user
/// has set this up once.
actor SteamConfigurator {
    enum ConfiguratorError: Error, CustomStringConvertible {
        case noUserdataProfile
        case cannotReadConfig(URL)
        case blockNotFound
        case validationFailed
        case steamDidNotQuit

        var description: String {
            switch self {
            case .noUserdataProfile:
                return "No Steam userdata profile found"
            case .cannotReadConfig(let url):
                return "Could not read \(url.path)"
            case .blockNotFound:
                return "Could not find the Valheim (892970) block in localconfig.vdf"
            case .validationFailed:
                return "Re-parsing localconfig.vdf after the splice didn't return the expected value"
            case .steamDidNotQuit:
                return "Steam did not quit in time"
            }
        }
    }

    enum ConfigureOutcome: Sendable, Equatable {
        case alreadyConfigured
        case configured(backupURL: URL)
    }

    /// The key path to Valheim's per-app block in `localconfig.vdf`.
    /// Intermediate keys are matched case-insensitively by `VDF`, since
    /// Steam has been observed writing some of these lowercase.
    static let appPath = ["UserLocalConfigStore", "Software", "Valve", "Steam", "apps", GameLocator.valheimAppID]

    private let wrapperScriptURL: URL
    private let userdataRootOverride: URL?

    /// - Parameters:
    ///   - wrapperScriptURL: Path to the installed launch wrapper. Defaults
    ///     to where `BepInExInstaller` installs it.
    ///   - userdataRootOverride: For tests only — points profile lookup at
    ///     a directory other than the real `Steam/userdata`, so verification
    ///     can run against a copy of a real config without touching it.
    init(
        wrapperScriptURL: URL = BepInExInstaller.wrapperScriptURL(launchDir: BepInExInstaller.defaultLaunchDir),
        userdataRootOverride: URL? = nil
    ) {
        self.wrapperScriptURL = wrapperScriptURL
        self.userdataRootOverride = userdataRootOverride
    }

    /// The exact value Bifrost wants `LaunchOptions` to hold.
    var desiredLaunchOptions: String {
        "\"\(wrapperScriptURL.path)\" %command%"
    }

    private var userdataRoot: URL {
        userdataRootOverride ?? GameLocator.steamRoot.appendingPathComponent("userdata")
    }

    /// The userdata profile directory most recently modified, under
    /// `userdataRoot` — the active/most-recently-used Steam login on this
    /// machine (or whichever profile a test's `userdataRootOverride`
    /// points at).
    static func mostRecentUserdataProfile(under userdataRoot: URL) -> URL? {
        guard let profiles = try? FileManager.default.contentsOfDirectory(
            at: userdataRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return profiles.max { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return lhsDate < rhsDate
        }
    }

    /// The real, on-disk `localconfig.vdf` for the most-recently-used
    /// Steam profile — exposed (read-only) so `--check` can verify `VDF`'s
    /// splice logic against copies of it without going through an actor
    /// instance.
    static func realLocalConfigURL() -> URL? {
        mostRecentUserdataProfile(under: GameLocator.steamRoot.appendingPathComponent("userdata"))
            .map { $0.appendingPathComponent("config/localconfig.vdf") }
    }

    private func configURL() throws -> URL {
        guard let profile = Self.mostRecentUserdataProfile(under: userdataRoot) else {
            throw ConfiguratorError.noUserdataProfile
        }
        return profile.appendingPathComponent("config/localconfig.vdf")
    }

    /// The current `LaunchOptions` value for Valheim in the
    /// most-recently-used Steam profile, if set.
    func currentLaunchOptions() throws -> String? {
        let url = try configURL()
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            throw ConfiguratorError.cannotReadConfig(url)
        }
        return VDF.value(forKey: "LaunchOptions", atPath: Self.appPath, in: contents)
    }

    /// Whether Valheim's launch options already route through Bifrost's
    /// wrapper.
    func isConfigured() throws -> Bool {
        (try currentLaunchOptions())?.contains("run_modded.sh") ?? false
    }

    /// Ensures `LaunchOptions` routes through Bifrost's wrapper.
    ///
    /// If it already does — byte-for-byte the value Bifrost wants — this
    /// returns `.alreadyConfigured` immediately and Steam is never touched.
    /// Otherwise: quits Steam, backs up `localconfig.vdf`, splices in the
    /// new value, re-parses the result to validate it landed correctly, and
    /// relaunches Steam.
    func configure() async throws -> ConfigureOutcome {
        let url = try configURL()
        guard let original = try? String(contentsOf: url, encoding: .utf8) else {
            throw ConfiguratorError.cannotReadConfig(url)
        }

        let current = VDF.value(forKey: "LaunchOptions", atPath: Self.appPath, in: original)
        if current == desiredLaunchOptions {
            return .alreadyConfigured
        }

        try await quitSteam()

        let backupURL = url.appendingPathExtension("bifrost-backup-\(Self.backupTimestamp())")
        try FileManager.default.copyItem(at: url, to: backupURL)

        let spliced = try VDF.settingKey("LaunchOptions", to: desiredLaunchOptions, atPath: Self.appPath, in: original)
        try spliced.text.write(to: url, atomically: true, encoding: .utf8)

        guard
            let revalidated = try? String(contentsOf: url, encoding: .utf8),
            VDF.value(forKey: "LaunchOptions", atPath: Self.appPath, in: revalidated) == desiredLaunchOptions
        else {
            throw ConfiguratorError.validationFailed
        }

        _ = try? await ShellRunner.run("/usr/bin/open", ["-a", "Steam"])

        return .configured(backupURL: backupURL)
    }

    /// Asks Steam to quit via AppleScript, then polls for the process to
    /// actually exit before falling back to SIGTERM.
    private func quitSteam() async throws {
        _ = try? await ShellRunner.run("/usr/bin/osascript", ["-e", "quit app \"Steam\""])

        let pollDeadline = Date().addingTimeInterval(30)
        while Date() < pollDeadline {
            if !(await steamIsRunning()) { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        _ = try? await ShellRunner.run("/usr/bin/pkill", ["-TERM", "-x", "steam_osx"])
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        if await steamIsRunning() {
            throw ConfiguratorError.steamDidNotQuit
        }
    }

    private func steamIsRunning() async -> Bool {
        let result = try? await ShellRunner.run("/usr/bin/pgrep", ["-x", "steam_osx"])
        return result?.status == 0
    }

    private static func backupTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone.current
        return formatter.string(from: Date())
    }
}
