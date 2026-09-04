import Foundation
import AppKit

/// Hands a play request off to Steam and watches Steam's own console log to
/// confirm the launch actually went through — `open steam://rungameid` is
/// silently dropped if Steam is still starting up, and can stall on
/// dialogs Steam shows the user (another device playing the same game, a
/// cloud-save conflict, ...). `play(modded:onPhase:)` stages the hand-off
/// into three steps (`ensureSteamRunning`, `requestLaunch`, `confirmLaunch`)
/// and reports progress through `onPhase` as it goes, mirroring
/// `BepInExInstaller.install`'s `onProgress` callback.
///
/// Also opens the plugins folder and BepInEx log from the Home tab.
enum Launcher {
    /// One step of what `play(modded:)` would do. Used to describe the
    /// launch without triggering it (see `plan(modded:)`).
    struct PlanStep: Sendable, Equatable {
        let description: String
    }

    /// A stage `play(modded:onPhase:)` has reached. `onPhase` may be called
    /// several times as the launch progresses; the phase returned by
    /// `play` itself is always the last one reported.
    enum LaunchPhase: Sendable, Equatable {
        /// Steam wasn't running; `open -a Steam` (or its silent variant,
        /// see `silent`) was just issued.
        case startingSteam(silent: Bool)
        /// Steam's process is up; waiting for it to finish its own startup
        /// before handing it a launch request.
        case waitingForSteam
        /// The mode file is written and the `steam://rungameid` URL has
        /// been opened; watching Steam's console log for confirmation.
        case launching
        /// Steam is showing a dialog that needs a response (e.g. another
        /// device is playing the same game) and hasn't resolved it within
        /// the attention window. `hint` is a human-readable explanation of
        /// `task`, Steam's own name for the dialog.
        case steamNeedsAttention(task: String, hint: String)
        /// Steam confirmed the launch — via a "Completed" GameAction, the
        /// launch wrapper's log gaining a new entry, or the game process
        /// itself appearing.
        case launched
        /// Steam's process never came up (or never finished starting)
        /// within the timeout.
        case steamFailedToStart
        /// Steam came up, but nothing confirmed the launch within the
        /// watch window even after one retry of the URL.
        case launchNotConfirmed(hint: String)
    }

    static var modeFileURL: URL {
        BepInExInstaller.defaultLaunchDir.appendingPathComponent("mode")
    }

    static var launchURL: URL {
        URL(string: "steam://rungameid/\(GameLocator.valheimAppID)")!
    }

    static var wrapperLogURL: URL {
        BepInExInstaller.defaultLaunchDir.appendingPathComponent("wrapper.log")
    }

    /// Describes exactly what `play(modded:)` would do, without doing it —
    /// used by `--check` so verification never triggers a real launch or
    /// opens a `steam://` URL.
    static func plan(modded: Bool) -> [PlanStep] {
        let steamStepDescription = startSteamSilentlyPreference()
            ? "Ensure Steam is running (open -a Steam --args -silent if needed, so its window stays hidden) and wait for it to finish starting up"
            : "Ensure Steam is running (open -a Steam if needed) and wait for it to finish starting up"
        return [
            PlanStep(description: steamStepDescription),
            PlanStep(description: "Write \"\(modded ? "modded" : "vanilla")\" to \(modeFileURL.path)"),
            PlanStep(description: "Open \(launchURL.absoluteString) via NSWorkspace"),
            PlanStep(description: "Watch \(SteamLogWatcher.defaultLogURL.path) for GameAction progress on AppID \(GameLocator.valheimAppID) — retry the URL once if nothing appears, and flag any Steam dialog that needs a response"),
        ]
    }

    /// Runs the full staged launch: ensures Steam is running and ready
    /// (`ensureSteamRunning`), writes the mode file and opens Steam's
    /// rungameid URL (`requestLaunch`), then watches Steam's console log to
    /// confirm the launch actually proceeded (`confirmLaunch`). Reports
    /// each phase reached via `onPhase`, and returns the final one.
    ///
    /// Throws only for a filesystem failure writing the mode file — every
    /// other outcome (Steam not starting, a blocking dialog, no
    /// confirmation) is reported as a `LaunchPhase`, not an error, since
    /// those are expected shapes a launch can take rather than exceptional
    /// failures.
    static func play(modded: Bool, onPhase: @Sendable (LaunchPhase) -> Void = { _ in }) async throws -> LaunchPhase {
        guard await ensureSteamRunning(onPhase: onPhase) else {
            onPhase(.steamFailedToStart)
            return .steamFailedToStart
        }

        try writeModeFile(modded: modded)
        await openLaunchURL()

        let phase = await confirmLaunch(onPhase: onPhase)
        onPhase(phase)
        return phase
    }

    // MARK: - Stage 1: ensureSteamRunning

    /// If Steam is already running, returns `true` immediately without
    /// opening or announcing anything — the common case once a player has
    /// Steam open already. Otherwise opens Steam and waits for it to come
    /// up, reporting `.startingSteam` then `.waitingForSteam`. "Ready"
    /// means a "System startup time" line has appeared in the console log
    /// since we opened Steam; if none shows up, falls back to "process
    /// alive for `grace` seconds". Returns `false` if Steam never comes up
    /// within `timeout`.
    static func ensureSteamRunning(onPhase: @Sendable (LaunchPhase) -> Void, timeout: TimeInterval = 90, grace: TimeInterval = 20) async -> Bool {
        if await steamIsRunning() {
            return true
        }

        let silent = startSteamSilentlyPreference()
        onPhase(.startingSteam(silent: silent))
        let startOffset = SteamLogWatcher.currentOffset()
        _ = try? await ShellRunner.run("/usr/bin/open", openSteamArguments(silentPreference: silent))

        let deadline = Date().addingTimeInterval(timeout)
        var processAliveSince: Date?
        var announcedWaiting = false

        while Date() < deadline {
            if await steamIsRunning() {
                if processAliveSince == nil {
                    processAliveSince = Date()
                }
                if !announcedWaiting {
                    onPhase(.waitingForSteam)
                    announcedWaiting = true
                }

                let (lines, _) = SteamLogWatcher.readAppended(since: startOffset)
                if SteamLaunchLogParser.containsStartupCompletion(lines) {
                    return true
                }
                if let processAliveSince, Date().timeIntervalSince(processAliveSince) >= grace {
                    return true
                }
            }
            try? await Task.sleep(nanoseconds: pollInterval)
        }
        return false
    }

    // MARK: - Stage 2: requestLaunch (writeModeFile + openLaunchURL below)

    private static func writeModeFile(modded: Bool) throws {
        let mode = modded ? "modded" : "vanilla"
        try FileManager.default.createDirectory(at: modeFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try mode.write(to: modeFileURL, atomically: true, encoding: .utf8)
    }

    @MainActor
    private static func openLaunchURL() {
        NSWorkspace.shared.open(launchURL)
    }

    // MARK: - Stage 3: confirmLaunch

    /// Watches Steam's console log (plus the wrapper log and the process
    /// table as side channels) for up to `timeout` seconds to confirm the
    /// launch requested by `requestLaunch` actually proceeded. Retries the
    /// URL open once if no `GameAction` line for Valheim has appeared at
    /// all by `noSignalGrace` seconds in (the dropped-launch case).
    private static func confirmLaunch(
        onPhase: @Sendable (LaunchPhase) -> Void,
        timeout: TimeInterval = 25,
        noSignalGrace: TimeInterval = 10,
        attentionThreshold: TimeInterval = 5
    ) async -> LaunchPhase {
        onPhase(.launching)

        let appID = GameLocator.valheimAppID
        let wrapperLogStartSize = fileSize(at: wrapperLogURL)
        var logOffset = SteamLogWatcher.currentOffset()
        var accumulatedLines: [String] = []
        var retriedDrop = false
        let started = Date()
        let deadline = started.addingTimeInterval(timeout)

        while Date() < deadline {
            let (newLines, newOffset) = SteamLogWatcher.readAppended(since: logOffset)
            logOffset = newOffset
            accumulatedLines.append(contentsOf: newLines)

            if await launchConfirmedBySideChannel(wrapperLogStartSize: wrapperLogStartSize) {
                return .launched
            }

            switch SteamLaunchLogParser.classifyLaunch(lines: accumulatedLines, appID: appID, now: Date(), attentionThreshold: attentionThreshold) {
            case .completed:
                return .launched
            case .blocked(let task):
                return .steamNeedsAttention(task: task, hint: attentionHint(for: task))
            case .dropped:
                if !retriedDrop, Date().timeIntervalSince(started) >= noSignalGrace {
                    retriedDrop = true
                    await openLaunchURL()
                }
            case .inProgress:
                break
            }

            try? await Task.sleep(nanoseconds: pollInterval)
        }

        let hint = "Steam didn't confirm the launch within \(Int(timeout))s — it may still be starting. Check Steam directly, or try again."
        return .launchNotConfirmed(hint: hint)
    }

    /// True once the wrapper log has grown past its size when the launch
    /// was requested, or Valheim's process shows up — either means the
    /// launch made it through even if the console log's own GameAction
    /// lines were slow or missed.
    private static func launchConfirmedBySideChannel(wrapperLogStartSize: Int) async -> Bool {
        if fileSize(at: wrapperLogURL) > wrapperLogStartSize {
            return true
        }
        if let result = try? await ShellRunner.run("/usr/bin/pgrep", ["-x", "Valheim"]), result.status == 0 {
            return true
        }
        return false
    }

    /// A human-readable explanation of a Steam dialog task name, for
    /// `.steamNeedsAttention`'s hint. Falls back to a generic explanation
    /// for tasks not specifically called out.
    private static func attentionHint(for task: String) -> String {
        switch task {
        case "KickingOtherSession":
            return "Steam is showing a dialog that needs your answer — likely asking to close this game running on another device."
        case "CloudSyncConflict":
            return "Steam is showing a cloud-save conflict dialog — pick which save to keep."
        default:
            return "Steam is showing a dialog (\(task)) that needs your answer before Valheim can launch."
        }
    }

    // MARK: - Shared helpers

    /// UserDefaults key backing "Start Steam silently in the background" in
    /// Settings (see `SettingsView`). Defaults to on — most players never
    /// need to see Steam's own window just to launch a game through it.
    static let startSteamSilentlyDefaultsKey = "startSteamSilently"

    /// Current value of the "Start Steam silently" preference, defaulting
    /// to `true` when the user has never touched the setting.
    private static func startSteamSilentlyPreference() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: startSteamSilentlyDefaultsKey) != nil else { return true }
        return defaults.bool(forKey: startSteamSilentlyDefaultsKey)
    }

    /// Arguments to `/usr/bin/open` for starting Steam, honoring the
    /// silent-start preference. Pure — takes the preference value directly
    /// rather than reading `UserDefaults` itself — so `--check` can assert
    /// the silent flag plumbs through to the right arguments without
    /// spawning any process.
    static func openSteamArguments(silentPreference: Bool) -> [String] {
        silentPreference ? ["-a", "Steam", "--args", "-silent"] : ["-a", "Steam"]
    }

    /// How often stages 1 and 3 poll while waiting.
    private static let pollInterval: UInt64 = 1_000_000_000

    private static func steamIsRunning() async -> Bool {
        guard let result = try? await ShellRunner.run("/usr/bin/pgrep", ["-x", "steam_osx"]) else { return false }
        return result.status == 0
    }

    private static func fileSize(at url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        return (attributes[.size] as? Int) ?? 0
    }

    /// Reveals `BepInEx/plugins` in Finder.
    @MainActor
    static func openPluginsFolder(gameDir: URL) {
        NSWorkspace.shared.open(gameDir.appendingPathComponent("BepInEx/plugins"))
    }

    /// Opens `BepInEx/LogOutput.log` in its default viewer.
    @MainActor
    static func openBepInExLog(gameDir: URL) {
        NSWorkspace.shared.open(gameDir.appendingPathComponent("BepInEx/LogOutput.log"))
    }

    /// Opens the launch wrapper's own log (`wrapper.log`, appended to by
    /// `run_modded.sh` on every launch — records the mode it saw and the
    /// arguments Steam passed it) in its default viewer.
    @MainActor
    static func openWrapperLog() {
        NSWorkspace.shared.open(wrapperLogURL)
    }
}
