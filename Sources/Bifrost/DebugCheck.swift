import Foundation

/// Headless verification path for development: `swift run Bifrost --check`
/// runs the setup-status checks and exercises the Thunderstore client, then
/// prints the results and exits — no window, no Xcode/XCTest required.
enum DebugCheck {
    /// If `--check` was passed on the command line, runs diagnostics and
    /// exits the process. Returns normally (a no-op) otherwise, so callers
    /// can call this unconditionally at the very top of `App.init()`.
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--check") else { return }

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await run()
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }

    private static func run() async {
        print("== Bifrost setup status ==")

        let located = GameLocator.locate()
        switch located {
        case .some(let game):
            print("game found: true -> \(game.directory.path) (valid=\(game.isValid))")
        case .none:
            print("game found: false")
        }

        let bepinexInstalled = located.map { GameLocator.bepinexInstalled(at: $0.directory) } ?? false
        print("bepinex installed: \(bepinexInstalled)")

        let rosettaResult = try? await ShellRunner.run("/usr/bin/arch", ["-x86_64", "/usr/bin/true"])
        let rosettaOK = rosettaResult?.status == 0
        print("rosetta ok: \(rosettaOK)")

        let steamConfigured = GameLocator.steamConfiguredForModdedLaunch()
        print("steam configured: \(steamConfigured)")

        let status = SetupStatus(
            gameFound: (located?.isValid == true) ? located?.directory : nil,
            bepinexInstalled: bepinexInstalled,
            rosettaOK: rosettaOK,
            steamConfigured: steamConfigured
        )
        print("ready to play: \(status.readyToPlay)")

        print("")
        print("== Thunderstore index ==")
        let client = ThunderstoreClient()
        let supportDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Bifrost")
        let cacheURL = supportDir.appendingPathComponent("package-index.json")
        let etagURL = supportDir.appendingPathComponent("package-index.etag")

        do {
            let start = Date()
            let packages = try await client.fetchIndex(force: true)
            let elapsed = Date().timeIntervalSince(start)
            print("fetch #1 (force, fresh): \(packages.count) packages in \(String(format: "%.2f", elapsed))s")

            let cacheExists = FileManager.default.fileExists(atPath: cacheURL.path)
            let etagExists = FileManager.default.fileExists(atPath: etagURL.path)
            print("cache file created: \(cacheExists) -> \(cacheURL.path)")
            print("etag file created: \(etagExists) -> \(etagURL.path)")

            let start2 = Date()
            let packages2 = try await client.fetchIndex(force: false)
            let elapsed2 = Date().timeIntervalSince(start2)
            print("fetch #2 (conditional, expect 304/cache): \(packages2.count) packages in \(String(format: "%.2f", elapsed2))s")
        } catch {
            print("thunderstore fetch failed: \(error)")
        }
    }
}
