import Foundation

/// Classifies the state of a modded launch by watching BepInEx's
/// `LogOutput.log`, so the UI can show something more useful than "it's
/// launching" while Steam hands off to the wrapper and Rosetta spins up.
enum Diagnostics {
    enum LaunchDiagnosis: Sendable, Equatable {
        /// BepInEx's chainloader finished starting and reported how many
        /// plugins it loaded (from the "N plugins to load" summary line).
        case modsLoaded(pluginCount: Int)
        /// The chainloader announced itself, but no plugin-count line has
        /// shown up yet.
        case chainloaderStarted
        /// No log appeared within the watch window. `hint` explains the
        /// likely cause (Rosetta missing, wrapper not actually invoked).
        case noLogFile(hint: String)
        /// Not a modded launch — no BepInEx log is expected.
        case vanillaMode

        var summary: String {
            switch self {
            case .modsLoaded(let count):
                return count == 0
                    ? "BepInEx started — 0 plugins loaded"
                    : "BepInEx started — \(count) plugin\(count == 1 ? "" : "s") loaded"
            case .chainloaderStarted:
                return "BepInEx chainloader started…"
            case .noLogFile(let hint):
                return hint
            case .vanillaMode:
                return "Launched in vanilla mode"
            }
        }
    }

    /// How often to re-check the log file while watching.
    private static let pollInterval: UInt64 = 1_000_000_000

    /// Watches `<gameDir>/BepInEx/LogOutput.log` for up to `timeout`
    /// seconds after a launch, returning as soon as it can be classified.
    /// Runs off the main actor.
    static func watch(gameDir: URL, modded: Bool, timeout: TimeInterval = 90) async -> LaunchDiagnosis {
        guard modded else { return .vanillaMode }

        let logURL = gameDir.appendingPathComponent("BepInEx/LogOutput.log")
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let contents = try? String(contentsOf: logURL, encoding: .utf8), let diagnosis = classify(logContents: contents) {
                return diagnosis
            }
            try? await Task.sleep(nanoseconds: pollInterval)
        }

        let hint = "No BepInEx log appeared within \(Int(timeout))s — check that Rosetta 2 is installed "
            + "(\"arch -x86_64 /usr/bin/true\" should succeed) and that Steam's launch options actually "
            + "invoke Bifrost's wrapper script."
        return .noLogFile(hint: hint)
    }

    /// Classifies already-read log contents, without any polling. `nil`
    /// means the log exists but hasn't reached a recognizable state yet
    /// (used internally by `watch`; exposed for direct testing against a
    /// known-good log).
    static func classify(logContents: String) -> LaunchDiagnosis? {
        if let count = pluginCount(in: logContents) {
            return .modsLoaded(pluginCount: count)
        }
        if logContents.contains("Chainloader started") {
            return .chainloaderStarted
        }
        return nil
    }

    /// The plugin count BepInEx reports in its "N plugins to load" summary
    /// line, logged right after the chainloader starts. Falls back to
    /// counting "Loading [" lines if that summary is missing but individual
    /// plugin loads are present.
    private static func pluginCount(in logContents: String) -> Int? {
        if let declared = declaredPluginCount(in: logContents) {
            return declared
        }
        guard logContents.contains("Chainloader started") else { return nil }
        let loadingLines = logContents
            .components(separatedBy: "\n")
            .filter { $0.contains("Loading [") }
        return loadingLines.isEmpty ? nil : loadingLines.count
    }

    private static func declaredPluginCount(in logContents: String) -> Int? {
        for line in logContents.components(separatedBy: "\n") {
            guard let range = line.range(of: "plugins to load") else { continue }
            let prefix = line[line.startIndex..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            guard let numberToken = prefix.split(separator: " ").last, let number = Int(numberToken) else { continue }
            return number
        }
        return nil
    }
}
