import Foundation
import Observation

/// App-wide observable state, injected into the view hierarchy via
/// `.environment`. Owns the setup-status checks that gate modded launches.
@MainActor
@Observable
final class AppState {
    private(set) var status: SetupStatus = .unknown
    private(set) var isRefreshing = false

    /// Re-runs every setup check. Filesystem checks are cheap and run
    /// inline; the Rosetta probe shells out, so it's the only truly async
    /// step.
    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let located = GameLocator.locate()
        let gameFound = (located?.isValid == true) ? located?.directory : nil

        let bepinexInstalled: Bool
        if let gameDir = located?.directory {
            bepinexInstalled = GameLocator.bepinexInstalled(at: gameDir)
        } else {
            bepinexInstalled = false
        }

        let rosettaOK = await Self.checkRosetta()
        let steamConfigured = GameLocator.steamConfiguredForModdedLaunch()

        status = SetupStatus(
            gameFound: gameFound,
            bepinexInstalled: bepinexInstalled,
            rosettaOK: rosettaOK,
            steamConfigured: steamConfigured
        )
    }

    private static func checkRosetta() async -> Bool {
        guard let result = try? await ShellRunner.run("/usr/bin/arch", ["-x86_64", "/usr/bin/true"]) else {
            return false
        }
        return result.status == 0
    }
}
