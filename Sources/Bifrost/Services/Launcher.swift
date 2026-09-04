import Foundation
import AppKit

/// Hands a play request off to Steam: writes Bifrost's `mode` file — which
/// the launch wrapper reads to decide modded vs. vanilla — then asks Steam
/// to launch Valheim via `steam://rungameid`. Also opens the plugins folder
/// and BepInEx log from the Home tab.
enum Launcher {
    /// One step of what `play(modded:)` would do. Used to describe the
    /// launch without triggering it (see `plan(modded:)`).
    struct PlanStep: Sendable, Equatable {
        let description: String
    }

    static var modeFileURL: URL {
        BepInExInstaller.defaultLaunchDir.appendingPathComponent("mode")
    }

    static var launchURL: URL {
        URL(string: "steam://rungameid/\(GameLocator.valheimAppID)")!
    }

    /// Describes exactly what `play(modded:)` would do, without doing it —
    /// used by `--check` so verification never triggers a real launch or
    /// opens a `steam://` URL.
    static func plan(modded: Bool) -> [PlanStep] {
        [
            PlanStep(description: "Write \"\(modded ? "modded" : "vanilla")\" to \(modeFileURL.path)"),
            PlanStep(description: "Open \(launchURL.absoluteString) via NSWorkspace"),
        ]
    }

    /// Writes the mode file, then opens Steam's rungameid URL for Valheim.
    @MainActor
    static func play(modded: Bool) throws {
        let mode = modded ? "modded" : "vanilla"
        try FileManager.default.createDirectory(at: modeFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try mode.write(to: modeFileURL, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(launchURL)
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
}
