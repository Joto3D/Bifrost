import Foundation

/// Headless verification path for development: `swift run Bifrost --check`
/// runs the setup-status checks and exercises the Thunderstore client,
/// BepInEx installer, VDF splicer, Steam configurator, launcher, and
/// diagnostics classifier, then prints the results and exits — no window,
/// no Xcode/XCTest required.
///
/// Every section here is written to be safe to run against this
/// developer's real machine: it never launches Valheim, never opens a
/// `steam://` URL, never quits or reconfigures the real running Steam
/// unless its launch options are already exactly what Bifrost wants (in
/// which case that's a deliberate no-op), never installs BepInEx anywhere
/// but a throwaway temp directory, and never installs, uninstalls, toggles,
/// or otherwise mutates mods in the real game directory or real manifest —
/// the mod-manager and profiles sections exercise `ModManager`/`ProfileStore`
/// entirely against temp fixtures, touching the real install (if any) only
/// through read-only dry-run calls.
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
        await checkThunderstoreIndex()

        let modManager = ModManager()

        print("")
        print("== BepInEx installer ==")
        await checkInstaller(realGameDir: located?.directory, modManager: modManager)

        print("")
        print("== VDF splice ==")
        await checkVDFSplice()

        print("")
        print("== Steam configurator ==")
        await checkSteamConfigurator()

        print("")
        print("== Launcher (dry) ==")
        checkLauncherPlan()

        print("")
        print("== Launch readiness ==")
        await checkLaunchReadiness()

        print("")
        print("== Diagnostics classification ==")
        checkDiagnostics(gameDir: located?.directory)

        print("")
        print("== Mod manager ==")
        await checkModManager(realGameDir: located?.directory, realModManager: modManager)

        print("")
        print("== Wizard simulation (fresh-machine) ==")
        await checkWizardSimulation()

        print("")
        print("== Profiles ==")
        await checkProfiles()

        print("")
        print("== Config editor ==")
        await checkConfigEditor(realGameDir: located?.directory)

        print("")
        print("== Save backups ==")
        await checkSaveBackups()
    }

    // MARK: - Safety guard

    /// Traps loudly if `url` is not rooted under the system temp directory.
    /// Every fake-dir test section below must call this on each throwaway
    /// path it constructs before handing it to a service that writes files —
    /// this is exactly the guard that would have caught the bug where a
    /// wrapper script got written into the *real* Bifrost launch directory
    /// while templated with a throwaway `gameDir` (see `BepInExInstaller`'s
    /// init doc for the fix that also makes this structurally harder to
    /// repeat).
    private static func assertUnderTempDir(_ url: URL, label: String) {
        let tempPath = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let urlPath = url.resolvingSymlinksInPath().path
        guard urlPath.hasPrefix(tempPath) else {
            fatalError("SAFETY: \(label) (\(url.path)) is not under the temp directory (\(FileManager.default.temporaryDirectory.path)) — refusing to let a --check test section write here")
        }
    }

    // MARK: - Thunderstore

    private static func checkThunderstoreIndex() async {
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

    // MARK: - BepInEx installer

    private static func checkInstaller(realGameDir: URL?, modManager: ModManager) async {
        guard let realGameDir else {
            print("skipped: no game dir located")
            return
        }

        let realInstaller = BepInExInstaller()
        // Manifest-driven version, per the update-detection fix — not
        // `.doorstop_version` (see BepInExInstaller.dryRun). Likely nil at
        // this point on a fresh checkout; the "Mod manager" section below
        // seeds it for this dev machine's pre-existing manual install and
        // re-proves the dry-run there.
        let manifestVersion = await modManager.loaderVersion()
        // Read-only (dryRun never writes), so the real launch dir here is
        // safe — it's only used to describe what a real install would do.
        let dryRunActions = await realInstaller.dryRun(gameDir: realGameDir, launchDir: BepInExInstaller.defaultLaunchDir, manifestVersion: manifestVersion)
        print("dry-run against real game dir (\(realGameDir.path)), manifest loader version = \(manifestVersion ?? "nil"):")
        for action in dryRunActions {
            print("  - \(action)")
        }

        let fm = FileManager.default
        let fakeGameDir = fm.temporaryDirectory.appendingPathComponent("BifrostCheck-fakegame-\(UUID().uuidString)")
        let fakeLaunchDir = fm.temporaryDirectory.appendingPathComponent("BifrostCheck-fakelaunch-\(UUID().uuidString)")
        defer {
            try? fm.removeItem(at: fakeGameDir)
            try? fm.removeItem(at: fakeLaunchDir)
        }

        print("")
        print("full install into a throwaway fake game dir: \(fakeGameDir.path)")
        print("  (wrapper pointed at a throwaway launch dir: \(fakeLaunchDir.path), not the real one)")
        assertUnderTempDir(fakeGameDir, label: "fakeGameDir")
        assertUnderTempDir(fakeLaunchDir, label: "fakeLaunchDir")
        let fakeInstaller = BepInExInstaller()
        do {
            let outcome = try await fakeInstaller.install(gameDir: fakeGameDir, launchDir: fakeLaunchDir) { progress in
                print("  progress: \(progress)")
            }
            print("  installed version \(outcome.versionNumber) (packWasUpToDate=\(outcome.packWasUpToDate), modeFileCreated=\(outcome.modeFileCreated))")

            let markers = ["BepInEx", "doorstop_libs", "doorstop_config.ini", "start_game_bepinex.sh"]
            var allPresent = true
            for marker in markers {
                let present = fm.fileExists(atPath: fakeGameDir.appendingPathComponent(marker).path)
                allPresent = allPresent && present
                print("  \(marker) present: \(present)")
            }
            let wrapperPresent = fm.fileExists(atPath: fakeLaunchDir.appendingPathComponent("run_modded.sh").path)
            let modePresent = fm.fileExists(atPath: fakeLaunchDir.appendingPathComponent("mode").path)
            print("  wrapper installed: \(wrapperPresent), mode file: \(modePresent)")
            print("  GameLocator.bepinexInstalled(at: fakeGameDir): \(GameLocator.bepinexInstalled(at: fakeGameDir))")
            print("  fake-dir install -> \((allPresent && wrapperPresent && modePresent) ? "PASS" : "FAIL")")
        } catch {
            print("  fake-dir install failed: \(error)")
        }
    }

    // MARK: - VDF splice

    private static func checkVDFSplice() async {
        guard let realConfigURL = SteamConfigurator.realLocalConfigURL(),
              let originalText = try? String(contentsOf: realConfigURL, encoding: .utf8) else {
            print("skipped: could not read real localconfig.vdf")
            return
        }
        print("real localconfig.vdf: \(realConfigURL.path)")

        let path = SteamConfigurator.appPath
        guard let currentValue = VDF.value(forKey: "LaunchOptions", atPath: path, in: originalText) else {
            print("could not locate LaunchOptions in real config — aborting VDF checks")
            return
        }
        print("real LaunchOptions value: \(currentValue)")

        let originalCopyURL = writeTempVDF(originalText, name: "original")
        defer { try? FileManager.default.removeItem(at: originalCopyURL) }

        // (a) key already holds the target value -> no-op, byte-identical.
        await runVDFScenario(
            name: "(a) value already correct (no-op)",
            base: originalText,
            baseURL: originalCopyURL,
            path: path,
            targetValue: currentValue,
            expectHunks: 0
        )

        // (b) key exists with a different value -> exactly one changed line.
        await runVDFScenario(
            name: "(b) value differs (1 changed line)",
            base: originalText,
            baseURL: originalCopyURL,
            path: path,
            targetValue: currentValue + " # bifrost-check",
            expectHunks: 1
        )

        // (c) key absent -> inserted after the block's `{` (1 added line).
        do {
            let withoutKey = try VDF.removingKey("LaunchOptions", atPath: path, in: originalText)
            let withoutKeyURL = writeTempVDF(withoutKey, name: "without-key")
            defer { try? FileManager.default.removeItem(at: withoutKeyURL) }
            await runVDFScenario(
                name: "(c) key absent (1 inserted line)",
                base: withoutKey,
                baseURL: withoutKeyURL,
                path: path,
                targetValue: currentValue,
                expectHunks: 1
            )
        } catch {
            print("(c) key absent: FAILED building fixture: \(error)")
        }
    }

    private static func runVDFScenario(name: String, base: String, baseURL: URL, path: [String], targetValue: String, expectHunks: Int) async {
        do {
            let result = try VDF.settingKey("LaunchOptions", to: targetValue, atPath: path, in: base)
            let splicedURL = writeTempVDF(result.text, name: "spliced")
            defer { try? FileManager.default.removeItem(at: splicedURL) }

            let hunks = await diffHunkCount(baseURL, splicedURL)
            let reread = VDF.value(forKey: "LaunchOptions", atPath: path, in: result.text)
            let rereadOK = reread == targetValue
            let hunksOK = hunks == expectHunks
            let pass = hunksOK && rereadOK

            print("\(name): changed=\(result.changed) diff-hunks=\(hunks.map(String.init) ?? "?") (expect \(expectHunks)) reread-ok=\(rereadOK) -> \(pass ? "PASS" : "FAIL")")
        } catch {
            print("\(name): FAILED with error \(error)")
        }
    }

    private static func writeTempVDF(_ text: String, name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BifrostCheck-\(name)-\(UUID().uuidString).vdf")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Runs `diff` between two files and counts hunks (change/insert/delete
    /// locations) — one hunk per contiguous changed region, which is what
    /// "exactly 1 changed/added line" means here.
    private static func diffHunkCount(_ a: URL, _ b: URL) async -> Int? {
        guard let result = try? await ShellRunner.run("/usr/bin/diff", [a.path, b.path]) else { return nil }
        guard result.status == 0 || result.status == 1 else { return nil } // 0 = identical, 1 = differences found
        let hunkHeaders = result.stdout
            .components(separatedBy: "\n")
            .filter { line in !line.isEmpty && !line.hasPrefix("< ") && !line.hasPrefix("> ") && line != "---" }
        return hunkHeaders.count
    }

    // MARK: - Steam configurator

    private static func checkSteamConfigurator() async {
        let configurator = SteamConfigurator()
        do {
            let current = try await configurator.currentLaunchOptions()
            let desired = await configurator.desiredLaunchOptions
            print("current LaunchOptions: \(current ?? "<none>")")
            print("desired LaunchOptions: \(desired)")

            guard current == desired else {
                print("SAFETY: current != desired — skipping configure() entirely so Steam is never quit by --check")
                return
            }

            let outcome = try await configurator.configure()
            switch outcome {
            case .alreadyConfigured:
                print("configure() -> alreadyConfigured (Steam untouched) -> PASS")
            case .configured(let backupURL):
                print("configure() unexpectedly returned .configured (backup at \(backupURL.path)) — should not happen when current == desired")
            }
        } catch {
            print("steam configurator check failed: \(error)")
        }
    }

    // MARK: - Launcher (dry)

    private static func checkLauncherPlan() {
        for modded in [true, false] {
            print("plan(modded: \(modded)):")
            for step in Launcher.plan(modded: modded) {
                print("  - \(step.description)")
            }
        }
    }

    // MARK: - Launch readiness

    /// Drives `SteamLaunchLogParser`'s pure classification against four
    /// fixture scenarios — two lifted verbatim from the task's real console
    /// log excerpts (dropped, completed-despite-an-earlier-long-block), one
    /// built from this machine's own real `console_log.txt` (interstitial
    /// auto-continue), and one trimmed to isolate the still-unanswered
    /// moment of a blocking dialog (KickingOtherSession). Then, only when
    /// it's safe to do so, live-checks that `ensureSteamRunning` is a fast,
    /// silent no-op when Steam is already running.
    private static func checkLaunchReadiness() async {
        let appID = GameLocator.valheimAppID

        func runScenario(_ name: String, lines: [String], now: Date, expect: SteamLaunchLogParser.Outcome) {
            let outcome = SteamLaunchLogParser.classifyLaunch(lines: lines, appID: appID, now: now)
            let pass = outcome == expect
            print("\(name): -> \(outcome) (expect \(expect)) -> \(pass ? "PASS" : "FAIL")")
        }

        // Scenario 1: dropped — the URL was opened but Steam never logged a
        // single GameAction line for it.
        let dropped = [
            "[2026-09-04 16:41:39] ExecuteSteamURL: \"steam://rungameid/892970\"",
        ]
        runScenario("dropped launch (no GameAction lines at all)", lines: dropped, now: fixtureDate("2026-09-04 16:42:00"), expect: .dropped)

        // Scenario 2: blocked — real excerpt, trimmed to the moment the
        // KickingOtherSession dialog is still unanswered (its resolution,
        // 44 minutes later in the full log, hasn't happened yet from this
        // snapshot's point of view).
        let blocked = [
            "[2026-09-04 16:41:39] ExecuteSteamURL: \"steam://rungameid/892970\"",
            "[2026-09-04 16:41:39] GameAction [AppID 892970, ActionID 1] : LaunchApp changed task to SynchronizingCloud with \"\"",
            "[2026-09-04 16:41:40] GameAction [AppID 892970, ActionID 1] : LaunchApp waiting for user response to KickingOtherSession \"HELLDIVERS™ 2\"",
        ]
        runScenario("blocked launch (KickingOtherSession, unanswered)", lines: blocked, now: fixtureDate("2026-09-04 16:41:50"), expect: .blocked(task: "KickingOtherSession"))

        // Scenario 3: interstitial auto-continue — real lines from this
        // machine's own console_log.txt (denikson launch on 2026-09-04).
        // ShowInterstitials asks the same "waiting for user response"
        // question as a genuine block, but answers itself in the same
        // second — must NOT classify as blocked even though `now` here is
        // long past the attention threshold.
        let interstitial = [
            "[2026-09-04 17:30:52] GameAction [AppID 892970, ActionID 1] : LaunchApp changed task to ShowInterstitials with \"\"",
            "[2026-09-04 17:30:52] GameAction [AppID 892970, ActionID 1] : LaunchApp waiting for user response to ShowInterstitials \"\"",
            "[2026-09-04 17:30:52] GameAction [AppID 892970, ActionID 1] : LaunchApp continues with user response \"ShowInterstitials\"",
            "[2026-09-04 17:30:52] GameAction [AppID 892970, ActionID 1] : LaunchApp changed task to SynchronizingControllerConfig with \"\"",
        ]
        runScenario("interstitial auto-continue (not a block)", lines: interstitial, now: fixtureDate("2026-09-04 17:31:30"), expect: .inProgress)

        // Scenario 4: completed — the full real excerpt, including the
        // 44-minute-later resolution. Proves `.completed` wins over the
        // earlier unresolved KickingOtherSession wait rather than getting
        // stuck reporting blocked forever.
        let completed = [
            "[2026-09-04 16:41:39] ExecuteSteamURL: \"steam://rungameid/892970\"",
            "[2026-09-04 16:41:39] GameAction [AppID 892970, ActionID 1] : LaunchApp changed task to SynchronizingCloud with \"\"",
            "[2026-09-04 16:41:40] GameAction [AppID 892970, ActionID 1] : LaunchApp waiting for user response to KickingOtherSession \"HELLDIVERS™ 2\"",
            "[2026-09-04 17:25:35] GameAction [AppID 892970, ActionID 2] : LaunchApp changed task to CreatingProcess with \"\"",
            "[2026-09-04 17:25:36] GameAction [AppID 892970, ActionID 2] : LaunchApp changed task to Completed with \"\"",
        ]
        runScenario("completed launch (resolves despite the earlier long block)", lines: completed, now: fixtureDate("2026-09-04 17:25:40"), expect: .completed)

        let startupLine = ["[2026-09-04 17:30:49] System startup time: 3.27 seconds"]
        let readinessDetected = SteamLaunchLogParser.containsStartupCompletion(startupLine)
        let readinessAbsent = !SteamLaunchLogParser.containsStartupCompletion(dropped)
        print("startup-completion detection: present -> \(readinessDetected), absent in unrelated lines -> \(readinessAbsent) -> \((readinessDetected && readinessAbsent) ? "PASS" : "FAIL")")

        // Pure command-construction check: proves the "Start Steam
        // silently" preference plumbs through to the right `open`
        // arguments in both states, without spawning any process.
        let silentArgs = Launcher.openSteamArguments(silentPreference: true)
        let plainArgs = Launcher.openSteamArguments(silentPreference: false)
        let silentArgsOK = silentArgs == ["-a", "Steam", "--args", "-silent"]
        let plainArgsOK = plainArgs == ["-a", "Steam"]
        print("openSteamArguments(silentPreference: true) -> \(silentArgs) -> \(silentArgsOK ? "PASS" : "FAIL")")
        print("openSteamArguments(silentPreference: false) -> \(plainArgs) -> \(plainArgsOK ? "PASS" : "FAIL")")

        print("")
        let valheimRunning = (try? await ShellRunner.run("/usr/bin/pgrep", ["-x", "Valheim"]))?.status == 0
        let steamRunning = (try? await ShellRunner.run("/usr/bin/pgrep", ["-x", "steam_osx"]))?.status == 0
        print("Valheim running: \(valheimRunning), Steam running: \(steamRunning)")

        guard !valheimRunning, steamRunning else {
            print("skipped live ensureSteamRunning no-op test — requires Steam already running and Valheim not running (safe default otherwise)")
            return
        }

        print("live no-op test: Steam is already running -> ensureSteamRunning should return true immediately without opening or announcing anything")
        // `onPhase` is `@Sendable` (it may be invoked from a polling loop
        // that isn't this function's own isolation domain), but
        // `ensureSteamRunning` only ever calls it sequentially within its
        // own single await chain — never concurrently — so a plain
        // captured var is safe here despite the compiler's conservative
        // default; `nonisolated(unsafe)` documents that instead of routing
        // through an actor for what's just a debug-print sanity check.
        nonisolated(unsafe) var phasesSeen: [Launcher.LaunchPhase] = []
        let start = Date()
        let ready = await Launcher.ensureSteamRunning { phase in phasesSeen.append(phase) }
        let elapsed = Date().timeIntervalSince(start)
        let fast = elapsed < 2.0
        let silent = phasesSeen.isEmpty
        print("  ready=\(ready) elapsed=\(String(format: "%.2f", elapsed))s phases-emitted=\(phasesSeen) -> \((ready && fast && silent) ? "PASS" : "FAIL")")
    }

    private static func fixtureDate(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: string) ?? Date()
    }

    // MARK: - Diagnostics

    private static func checkDiagnostics(gameDir: URL?) {
        guard let gameDir else {
            print("skipped: no game dir located")
            return
        }
        let logURL = gameDir.appendingPathComponent("BepInEx/LogOutput.log")
        guard let contents = try? String(contentsOf: logURL, encoding: .utf8) else {
            print("no LogOutput.log found at \(logURL.path)")
            return
        }
        let diagnosis = Diagnostics.classify(logContents: contents)
        print("classify(real LogOutput.log) -> \(String(describing: diagnosis))")
        print("summary: \(diagnosis?.summary ?? "<nil>")")
    }

    // MARK: - Mod manager

    /// Exercises `ModManager` end to end against a throwaway TEMP fixture
    /// (fake game dir + fake manifest + fake launch dir, all under the
    /// system temp directory and guarded by `assertUnderTempDir`): install a
    /// simple no-dep mod, install a mod with a Jotunn dependency (verifying
    /// auto-resolution and the loader special case), toggle enabled state,
    /// uninstall the first mod. The REAL game dir is only ever read from —
    /// a dry-run of the update-detection fix, no installs/uninstalls/writes.
    ///
    /// This used to run every step directly against the REAL Steam install
    /// (a `--check` on this dev machine had, at one point, silently
    /// reinstalled mods that had been deliberately removed through the
    /// app). Nothing here touches the real install any more.
    private static func checkModManager(realGameDir: URL?, realModManager: ModManager) async {
        print("(read-only) update-detection dry-run against the REAL game dir:")
        if let realGameDir {
            let loaderVersion = await realModManager.loaderVersion()
            let dryRunActions = await BepInExInstaller().dryRun(gameDir: realGameDir, launchDir: BepInExInstaller.defaultLaunchDir, manifestVersion: loaderVersion)
            for action in dryRunActions { print("  - \(action)") }
            let claimsPendingUpdate = dryRunActions.contains { $0.hasPrefix("Update BepInEx pack") }
            print("  claims a pending loader update: \(claimsPendingUpdate)")
        } else {
            print("  skipped: no real game dir located")
        }

        let thunderstoreClient = ThunderstoreClient()
        guard let index = try? await thunderstoreClient.fetchIndex(force: false) else {
            print("skipped: could not load Thunderstore index")
            return
        }

        let fm = FileManager.default
        let fakeGameDir = fm.temporaryDirectory.appendingPathComponent("BifrostCheck-modmanager-game-\(UUID().uuidString)")
        let fakeManifestURL = fm.temporaryDirectory.appendingPathComponent("BifrostCheck-modmanager-manifest-\(UUID().uuidString).json")
        let fakeLaunchDir = fm.temporaryDirectory.appendingPathComponent("BifrostCheck-modmanager-launch-\(UUID().uuidString)")
        assertUnderTempDir(fakeGameDir, label: "mod manager fakeGameDir")
        assertUnderTempDir(fakeManifestURL, label: "mod manager fakeManifestURL")
        assertUnderTempDir(fakeLaunchDir, label: "mod manager fakeLaunchDir")
        defer {
            try? fm.removeItem(at: fakeGameDir)
            try? fm.removeItem(at: fakeManifestURL)
            try? fm.removeItem(at: fakeLaunchDir)
        }
        let modManager = ModManager(manifestURL: fakeManifestURL, launchDir: fakeLaunchDir)

        print("")
        print("fixture: fake game dir \(fakeGameDir.path)")
        print("fixture: fake manifest \(fakeManifestURL.path)")

        print("")
        print("1) install Advize-PlantEverything (simple, no plugin deps beyond the loader):")
        await installAndVerify(fullName: "Advize-PlantEverything", index: index, gameDir: fakeGameDir, modManager: modManager) { resolved in
            let dllPresent = FileManager.default.fileExists(
                atPath: fakeGameDir.appendingPathComponent("BepInEx/plugins/Advize-PlantEverything/Advize_PlantEverything.dll").path
            )
            let manifestHasIt = await modManager.isInstalled(fullName: "Advize-PlantEverything")
            print("  dll present under BepInEx/plugins/Advize-PlantEverything/: \(dllPresent)")
            print("  manifest records it: \(manifestHasIt)")
            return dllPresent && manifestHasIt
        }

        print("")
        print("2) install RandyKnapp-EquipmentAndQuickSlots (depends on Jotunn + the loader):")
        await installAndVerify(fullName: "RandyKnapp-EquipmentAndQuickSlots", index: index, gameDir: fakeGameDir, modManager: modManager) { resolved in
            let loaderCount = resolved.filter { if case .loader = $0 { return true }; return false }.count
            let jotunnInstalled = await modManager.isInstalled(fullName: "ValheimModding-Jotunn")
            let eqsInstalled = await modManager.isInstalled(fullName: "RandyKnapp-EquipmentAndQuickSlots")
            let loaderVersionAfter = await modManager.loaderVersion()
            print("  loader appears \(loaderCount) time(s) in the resolved plan (special-cased, never duplicated)")
            print("  Jotunn auto-resolved & installed: \(jotunnInstalled)")
            print("  EquipmentAndQuickSlots installed: \(eqsInstalled)")
            print("  loader version recorded: \(loaderVersionAfter ?? "nil")")
            return loaderCount <= 1 && jotunnInstalled && eqsInstalled && loaderVersionAfter != nil
        }

        print("")
        print("3) setEnabled(false) then setEnabled(true) on Advize-PlantEverything:")
        do {
            try await modManager.setEnabled(fullName: "Advize-PlantEverything", enabled: false, gameDir: fakeGameDir)
            let disabledPresent = FileManager.default.fileExists(
                atPath: fakeGameDir.appendingPathComponent("BepInEx/plugins/Advize-PlantEverything/Advize_PlantEverything.dll.disabled").path
            )
            print("  after disable, .dll.disabled present: \(disabledPresent)")

            try await modManager.setEnabled(fullName: "Advize-PlantEverything", enabled: true, gameDir: fakeGameDir)
            let enabledPresent = FileManager.default.fileExists(
                atPath: fakeGameDir.appendingPathComponent("BepInEx/plugins/Advize-PlantEverything/Advize_PlantEverything.dll").path
            )
            print("  after re-enable, .dll present: \(enabledPresent)")
            print("  -> \((disabledPresent && enabledPresent) ? "PASS" : "FAIL")")
        } catch {
            print("  FAILED: \(error)")
        }

        print("")
        print("4) uninstall Advize-PlantEverything — Jotunn/EquipmentAndQuickSlots must be untouched:")
        do {
            try await modManager.uninstall(fullName: "Advize-PlantEverything", gameDir: fakeGameDir)
            let dirGone = !FileManager.default.fileExists(atPath: fakeGameDir.appendingPathComponent("BepInEx/plugins/Advize-PlantEverything").path)
            let manifestGone = await !modManager.isInstalled(fullName: "Advize-PlantEverything")
            let jotunnStillInstalled = await modManager.isInstalled(fullName: "ValheimModding-Jotunn")
            let eqsStillInstalled = await modManager.isInstalled(fullName: "RandyKnapp-EquipmentAndQuickSlots")
            let jotunnFilesPresent = FileManager.default.fileExists(atPath: fakeGameDir.appendingPathComponent("BepInEx/plugins/ValheimModding-Jotunn/Jotunn.dll").path)
            print("  BepInEx/plugins/Advize-PlantEverything/ removed: \(dirGone)")
            print("  manifest entry removed: \(manifestGone)")
            print("  Jotunn untouched (manifest / disk): \(jotunnStillInstalled) / \(jotunnFilesPresent)")
            print("  EquipmentAndQuickSlots untouched (manifest): \(eqsStillInstalled)")
            let pass = dirGone && manifestGone && jotunnStillInstalled && jotunnFilesPresent && eqsStillInstalled
            print("  -> \(pass ? "PASS" : "FAIL")")
        } catch {
            print("  FAILED: \(error)")
        }

        print("")
        print("5) final fixture state (expected: Jotunn + EquipmentAndQuickSlots installed & enabled, PlantEverything gone):")
        let finalManifest = await modManager.loadManifest()
        print("  loader: \(finalManifest.loader?.version ?? "nil")")
        for mod in finalManifest.mods.sorted(by: { $0.fullName < $1.fullName }) {
            print("  \(mod.fullName) v\(mod.version) enabled=\(mod.enabled) files=\(mod.files.count)")
        }
    }

    // MARK: - Wizard simulation

    /// Drives `SetupWizardView`'s underlying step logic — not the UI —
    /// against a throwaway fake environment simulating a fresh machine: an
    /// empty fake game dir, a temp Bifrost launch dir, and a copy of the
    /// real `localconfig.vdf` with its `LaunchOptions` line stripped so the
    /// Steam-config step starts out genuinely "needed". Each step is run in
    /// wizard order and asserted to transition from needed to done, all
    /// against paths verified (`assertUnderTempDir`) to be under the temp
    /// directory — never the real game dir, real Bifrost launch dir, or
    /// real `localconfig.vdf`.
    ///
    /// Deliberately does **not** call `SteamConfigurator.configure()`:
    /// that method unconditionally quits the *real, currently running*
    /// Steam process whenever the value it reads differs from the desired
    /// one, regardless of which `localconfig.vdf` path it was pointed at —
    /// there's no way to fake that part safely. So the "Configure Steam"
    /// step here exercises `VDF.settingKey` directly — the same splice
    /// primitive `configure()` delegates to — which faithfully proves the
    /// step's file-editing logic without ever touching the real Steam
    /// process. The wizard's real "Configure Steam" step (reachable only by
    /// a human clicking through consent text in the UI) still calls the
    /// real `configure()`.
    private static func checkWizardSimulation() async {
        guard let realConfigURL = SteamConfigurator.realLocalConfigURL(),
              let originalText = try? String(contentsOf: realConfigURL, encoding: .utf8) else {
            print("skipped: could not read real localconfig.vdf to build a fixture")
            return
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("BifrostCheck-wizard-\(UUID().uuidString)")
        let fakeGameDir = root.appendingPathComponent("game")
        let fakeLaunchDir = root.appendingPathComponent("bifrost-launch")
        let fakeConfigDir = root.appendingPathComponent("userdata/00000001/config")
        let fakeConfigURL = fakeConfigDir.appendingPathComponent("localconfig.vdf")

        assertUnderTempDir(fakeGameDir, label: "wizard fakeGameDir")
        assertUnderTempDir(fakeLaunchDir, label: "wizard fakeLaunchDir")
        assertUnderTempDir(fakeConfigURL, label: "wizard fakeConfigURL")

        defer { try? fm.removeItem(at: root) }

        do {
            try fm.createDirectory(at: fakeGameDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: fakeConfigDir, withIntermediateDirectories: true)
            let withoutLaunchOptions = try VDF.removingKey("LaunchOptions", atPath: SteamConfigurator.appPath, in: originalText)
            try withoutLaunchOptions.write(to: fakeConfigURL, atomically: true, encoding: .utf8)
        } catch {
            print("skipped: could not build fixture: \(error)")
            return
        }

        print("fixture: empty fake game dir \(fakeGameDir.path)")
        print("fixture: fake localconfig.vdf (LaunchOptions stripped) \(fakeConfigURL.path)")

        print("")
        print("step 1) Detect game — needed: bepinexInstalled(emptyFakeGameDir) = \(GameLocator.bepinexInstalled(at: fakeGameDir)) (expect false)")

        print("")
        print("step 2) Install BepInEx — needed -> done:")
        let installer = BepInExInstaller()
        var bepinexStepPassed = false
        do {
            let neededBefore = !GameLocator.bepinexInstalled(at: fakeGameDir)
            let outcome = try await installer.install(gameDir: fakeGameDir, launchDir: fakeLaunchDir) { progress in
                print("  progress: \(progress)")
            }
            let doneAfter = GameLocator.bepinexInstalled(at: fakeGameDir)
            let wrapperWritten = fm.fileExists(atPath: BepInExInstaller.wrapperScriptURL(launchDir: fakeLaunchDir).path)
            bepinexStepPassed = neededBefore && doneAfter && wrapperWritten
            print("  needed-before=\(neededBefore) done-after=\(doneAfter) wrapper-written=\(wrapperWritten) version=\(outcome.versionNumber)")
            print("  -> \(bepinexStepPassed ? "PASS" : "FAIL")")
        } catch {
            print("  FAILED: \(error)")
        }

        print("")
        print("step 3) Configure Steam (VDF splice only — real Steam process untouched) — needed -> done:")
        var vdfStepPassed = false
        do {
            let currentText = try String(contentsOf: fakeConfigURL, encoding: .utf8)
            let beforeValue = VDF.value(forKey: "LaunchOptions", atPath: SteamConfigurator.appPath, in: currentText)
            let desired = "\"\(BepInExInstaller.wrapperScriptURL(launchDir: fakeLaunchDir).path)\" %command%"
            let neededBefore = (beforeValue == nil)

            let spliced = try VDF.settingKey("LaunchOptions", to: desired, atPath: SteamConfigurator.appPath, in: currentText)
            try spliced.text.write(to: fakeConfigURL, atomically: true, encoding: .utf8)

            let afterText = try String(contentsOf: fakeConfigURL, encoding: .utf8)
            let afterValue = VDF.value(forKey: "LaunchOptions", atPath: SteamConfigurator.appPath, in: afterText)
            let doneAfter = afterValue == desired

            vdfStepPassed = neededBefore && doneAfter
            print("  needed-before=\(neededBefore) (was \(beforeValue ?? "<none>")) done-after=\(doneAfter) (now \(afterValue ?? "<none>"))")
            print("  -> \(vdfStepPassed ? "PASS" : "FAIL")")
        } catch {
            print("  FAILED: \(error)")
        }

        print("")
        print("step 4) Done — overall wizard simulation: \((bepinexStepPassed && vdfStepPassed) ? "PASS" : "FAIL")")
    }

    // MARK: - Profiles

    /// Exercises `ProfileStore` end to end against a throwaway TEMP fixture
    /// (fake game dir with dummy `.dll` files + temp manifest + temp
    /// profiles.json, all under the system temp directory and guarded by
    /// `assertUnderTempDir`) — never the real manifest or profiles.json:
    /// first-run migration, full CRUD, `apply`'s three reconcile cases
    /// (enable, disable-not-in-profile, missing), manual-edit sync, and the
    /// delete-active guard.
    private static func checkProfiles() async {
        let fm = FileManager.default
        let fakeGameDir = fm.temporaryDirectory.appendingPathComponent("BifrostCheck-profiles-game-\(UUID().uuidString)")
        let fakeManifestURL = fm.temporaryDirectory.appendingPathComponent("BifrostCheck-profiles-manifest-\(UUID().uuidString).json")
        let fakeLaunchDir = fm.temporaryDirectory.appendingPathComponent("BifrostCheck-profiles-launch-\(UUID().uuidString)")
        let fakeProfilesURL = fm.temporaryDirectory.appendingPathComponent("BifrostCheck-profiles-\(UUID().uuidString).json")
        let fakeProfilesURL2 = fm.temporaryDirectory.appendingPathComponent("BifrostCheck-profiles2-\(UUID().uuidString).json")
        assertUnderTempDir(fakeGameDir, label: "profiles fakeGameDir")
        assertUnderTempDir(fakeManifestURL, label: "profiles fakeManifestURL")
        assertUnderTempDir(fakeLaunchDir, label: "profiles fakeLaunchDir")
        assertUnderTempDir(fakeProfilesURL, label: "profiles fakeProfilesURL")
        assertUnderTempDir(fakeProfilesURL2, label: "profiles fakeProfilesURL2")
        defer {
            try? fm.removeItem(at: fakeGameDir)
            try? fm.removeItem(at: fakeManifestURL)
            try? fm.removeItem(at: fakeLaunchDir)
            try? fm.removeItem(at: fakeProfilesURL)
            try? fm.removeItem(at: fakeProfilesURL2)
        }

        // Fixture manifest: three installed mods (A, B enabled; C
        // disabled), each with a real dummy .dll file on disk so
        // `setEnabled`'s file-rename logic has something to move.
        let fixtureManifest = InstalledManifest(
            loader: .init(version: "5.4.2333"),
            mods: [
                .init(fullName: "Fixture-ModA", version: "1.0.0", enabled: true, files: ["BepInEx/plugins/Fixture-ModA/ModA.dll"]),
                .init(fullName: "Fixture-ModB", version: "1.0.0", enabled: true, files: ["BepInEx/plugins/Fixture-ModB/ModB.dll"]),
                .init(fullName: "Fixture-ModC", version: "1.0.0", enabled: false, files: ["BepInEx/plugins/Fixture-ModC/ModC.dll.disabled"]),
            ]
        )
        do {
            for mod in fixtureManifest.mods {
                for relativePath in mod.files {
                    let url = fakeGameDir.appendingPathComponent(relativePath)
                    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data("dummy".utf8).write(to: url)
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try fm.createDirectory(at: fakeManifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(fixtureManifest).write(to: fakeManifestURL)
        } catch {
            print("skipped: could not build fixture: \(error)")
            return
        }

        let fixtureModManager = ModManager(manifestURL: fakeManifestURL, launchDir: fakeLaunchDir)
        let store = ProfileStore(profilesURL: fakeProfilesURL, modManager: fixtureModManager)

        print("fixture: fake game dir \(fakeGameDir.path)")
        print("fixture: fake manifest \(fakeManifestURL.path)")
        print("fixture: fake profiles.json \(fakeProfilesURL.path)")

        print("")
        print("1) first-run migration creates \"Default\" from current manifest state:")
        let migrated = await store.loadOrMigrate()
        let defaultProfile = migrated.profiles.first
        let migrationOK = migrated.profiles.count == 1
            && defaultProfile?.name == "Default"
            && migrated.activeProfileID == defaultProfile?.id
            && defaultProfile?.mods.sorted(by: { $0.fullName < $1.fullName }) == [
                .init(fullName: "Fixture-ModA", enabled: true),
                .init(fullName: "Fixture-ModB", enabled: true),
                .init(fullName: "Fixture-ModC", enabled: false),
            ]
        print("  profiles=\(migrated.profiles.count) name=\(defaultProfile?.name ?? "nil") active=\(migrated.activeProfileID == defaultProfile?.id) mods=\(defaultProfile?.mods.count ?? -1)")
        print("  -> \(migrationOK ? "PASS" : "FAIL")")
        guard let defaultProfile else {
            print("ABORT: no default profile to continue from")
            return
        }

        print("")
        print("2) create empty + create-from-current:")
        let emptyProfile = await store.create(name: "Empty", fromCurrent: false)
        let fromCurrentProfile = await store.create(name: "FromCurrent", fromCurrent: true)
        let createOK = emptyProfile.mods.isEmpty && fromCurrentProfile.mods.count == 3
        print("  Empty.mods=\(emptyProfile.mods.count) FromCurrent.mods=\(fromCurrentProfile.mods.count)")
        print("  -> \(createOK ? "PASS" : "FAIL")")

        print("")
        print("3) duplicate + rename:")
        var duplicateOK = false
        var renameOK = false
        do {
            let duplicated = try await store.duplicate(id: defaultProfile.id, newName: "Default Copy")
            duplicateOK = duplicated.id != defaultProfile.id && duplicated.mods == defaultProfile.mods
            print("  duplicated \"Default Copy\": mods match Default=\(duplicated.mods == defaultProfile.mods), distinct id=\(duplicated.id != defaultProfile.id)")

            try await store.rename(id: emptyProfile.id, to: "Renamed")
            let afterRename = await store.load()
            renameOK = afterRename.profiles.first { $0.id == emptyProfile.id }?.name == "Renamed"
            print("  renamed Empty -> Renamed: \(renameOK)")
        } catch {
            print("  FAILED: \(error)")
        }
        print("  -> \((duplicateOK && renameOK) ? "PASS" : "FAIL")")

        print("")
        print("4) delete-active guard + delete a non-active profile:")
        var deleteGuardOK = false
        do {
            try await store.delete(id: defaultProfile.id)
            print("  delete(active Default) unexpectedly succeeded")
        } catch ProfileStore.ProfileStoreError.cannotDeleteActive {
            deleteGuardOK = true
            print("  delete(active Default) correctly refused")
        } catch {
            print("  delete(active Default) failed with unexpected error: \(error)")
        }
        var deleteNonActiveOK = false
        do {
            try await store.delete(id: emptyProfile.id) // now named "Renamed", not active
            let afterDelete = await store.load()
            deleteNonActiveOK = !afterDelete.profiles.contains { $0.id == emptyProfile.id }
            print("  delete(non-active Renamed) removed it: \(deleteNonActiveOK)")
        } catch {
            print("  delete(non-active Renamed) FAILED: \(error)")
        }
        print("  -> \((deleteGuardOK && deleteNonActiveOK) ? "PASS" : "FAIL")")

        print("")
        print("5) apply — all three reconcile cases (enable / disable-not-in-profile / missing):")
        // Hand-authored profile (bypassing create/duplicate, which can only
        // ever copy current state or start empty): wants ModA (already
        // enabled, stays), ModC (installed but disabled, gets enabled), and
        // ModD (not installed at all, -> missing). ModB is deliberately
        // left out, so it should get disabled.
        let targetProfile = Profile(
            id: UUID(),
            name: "Target",
            mods: [
                .init(fullName: "Fixture-ModA", enabled: true),
                .init(fullName: "Fixture-ModC", enabled: true),
                .init(fullName: "Fixture-ModD", enabled: true),
            ]
        )
        var applyOK = false
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(ProfilesFile(activeProfileID: nil, profiles: [targetProfile])).write(to: fakeProfilesURL2)
            let store2 = ProfileStore(profilesURL: fakeProfilesURL2, modManager: fixtureModManager)

            let result = try await store2.apply(profileID: targetProfile.id, gameDir: fakeGameDir)
            let missingOK = result.missing == ["Fixture-ModD"]

            let manifestAfter = await fixtureModManager.loadManifest()
            let modA = manifestAfter.mods.first { $0.fullName == "Fixture-ModA" }
            let modB = manifestAfter.mods.first { $0.fullName == "Fixture-ModB" }
            let modC = manifestAfter.mods.first { $0.fullName == "Fixture-ModC" }
            let stateOK = modA?.enabled == true && modB?.enabled == false && modC?.enabled == true

            let aDllPresent = fm.fileExists(atPath: fakeGameDir.appendingPathComponent("BepInEx/plugins/Fixture-ModA/ModA.dll").path)
            let bDisabledPresent = fm.fileExists(atPath: fakeGameDir.appendingPathComponent("BepInEx/plugins/Fixture-ModB/ModB.dll.disabled").path)
            let cDllPresent = fm.fileExists(atPath: fakeGameDir.appendingPathComponent("BepInEx/plugins/Fixture-ModC/ModC.dll").path)
            let filesOK = aDllPresent && bDisabledPresent && cDllPresent

            let afterApply = await store2.load()
            let activeOK = afterApply.activeProfileID == targetProfile.id

            applyOK = missingOK && stateOK && filesOK && activeOK
            print("  missing=\(result.missing) (expect [\"Fixture-ModD\"]) -> \(missingOK)")
            print("  enabled after: ModA=\(modA?.enabled.description ?? "nil") ModB=\(modB?.enabled.description ?? "nil") ModC=\(modC?.enabled.description ?? "nil") -> \(stateOK)")
            print("  files after: ModA.dll=\(aDllPresent) ModB.dll.disabled=\(bDisabledPresent) ModC.dll=\(cDllPresent) -> \(filesOK)")
            print("  activeProfileID == Target: \(activeOK)")

            print("")
            print("6) manual-edit sync — active profile follows a direct setEnabled() outside of apply():")
            try await fixtureModManager.setEnabled(fullName: "Fixture-ModA", enabled: false, gameDir: fakeGameDir)
            await store2.syncActiveProfile()
            let afterSync = await store2.load()
            let syncedTarget = afterSync.profiles.first { $0.id == targetProfile.id }
            let syncedMods = Set(syncedTarget?.mods ?? [])
            let expectedSyncedMods: Set<Profile.ProfileMod> = [
                .init(fullName: "Fixture-ModA", enabled: false),
                .init(fullName: "Fixture-ModB", enabled: false),
                .init(fullName: "Fixture-ModC", enabled: true),
            ]
            let syncOK = syncedMods == expectedSyncedMods
            print("  synced mods: \(syncedTarget?.mods.sorted(by: { $0.fullName < $1.fullName }) ?? [])")
            print("  (ModD dropped since it's still not installed, ModA now disabled to match the manual edit)")
            print("  -> \(syncOK ? "PASS" : "FAIL")")

            print("")
            print("(step 5 verdict) -> \(applyOK ? "PASS" : "FAIL")")
        } catch {
            print("  FAILED: \(error)")
        }
    }

    /// Resolves and installs `fullName` against the real game dir, prints
    /// the resolved plan, then runs `verify` (which may itself await
    /// further ModManager calls) and prints PASS/FAIL.
    private static func installAndVerify(
        fullName: String,
        index: [ThunderstorePackage],
        gameDir: URL,
        modManager: ModManager,
        verify: @escaping ([ModManager.ResolvedInstall]) async -> Bool
    ) async {
        guard let package = index.first(where: { $0.fullName == fullName }) else {
            print("  SKIPPED: \(fullName) not found in the Thunderstore index")
            return
        }
        do {
            let resolved = try await modManager.resolve(package: package, index: index)
            print("  resolve() -> \(resolved.map(describeResolved).joined(separator: ", "))")
            try await modManager.install(resolved: resolved, gameDir: gameDir) { progress in
                print("  progress: \(progress)")
            }
            let pass = await verify(resolved)
            print("  -> \(pass ? "PASS" : "FAIL")")
        } catch {
            print("  FAILED: \(error)")
        }
    }

    private static func describeResolved(_ item: ModManager.ResolvedInstall) -> String {
        switch item {
        case .loader:
            return "denikson-BepInExPack_Valheim (loader)"
        case .mod(let fullName, _, let version):
            return "\(fullName)@\(version.versionNumber)"
        }
    }

    // MARK: - Config editor

    /// Exercises `BepInExConfig` against a throwaway TEMP copy (guarded by
    /// `assertUnderTempDir`) of the REAL `Azumatt.FirstPersonMode.cfg` —
    /// read-only against the real file, every parse/save/diff round-trip
    /// happens only against the temp copy: structure, the known
    /// `KeyboardShortcut` entry, description/default population,
    /// byte-identical no-op round-trip, a single-line surgical change,
    /// reset-to-default, the filename/mod association heuristic, and (best
    /// effort, skips gracefully offline) a live README fetch.
    private static func checkConfigEditor(realGameDir: URL?) async {
        guard let realGameDir else {
            print("skipped: no game dir located")
            return
        }
        let realConfigURL = realGameDir.appendingPathComponent("BepInEx/config/Azumatt.FirstPersonMode.cfg")
        guard let originalText = try? String(contentsOf: realConfigURL, encoding: .utf8) else {
            print("skipped: could not read real Azumatt.FirstPersonMode.cfg at \(realConfigURL.path)")
            return
        }
        print("real config (read-only): \(realConfigURL.path)")

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("BifrostCheck-configeditor-\(UUID().uuidString)")
        let tempConfigURL = tempDir.appendingPathComponent("Azumatt.FirstPersonMode.cfg")
        assertUnderTempDir(tempConfigURL, label: "config editor tempConfigURL")
        defer { try? fm.removeItem(at: tempDir) }

        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try originalText.write(to: tempConfigURL, atomically: true, encoding: .utf8)
        } catch {
            print("FAILED to set up fixture: \(error)")
            return
        }
        print("temp fixture copy: \(tempConfigURL.path)")

        print("")
        print("1) parse structure:")
        let parsed = BepInExConfig.parse(originalText)
        let sectionCountOK = parsed.sections.count >= 3
        print("  sections: \(parsed.sections.count) (expect >= 3) -> \(sectionCountOK ? "PASS" : "FAIL")")

        let shortcutEntry = parsed.allEntries.first { $0.key == "Toggle First Person Shortcut" }
        let shortcutOK = shortcutEntry?.settingType == "KeyboardShortcut" && shortcutEntry?.rawValue == "H + LeftShift"
        print("  \"Toggle First Person Shortcut\": type=\(shortcutEntry?.settingType ?? "nil") value=\(shortcutEntry?.rawValue ?? "nil") (expect KeyboardShortcut / \"H + LeftShift\") -> \(shortcutOK ? "PASS" : "FAIL")")

        let entriesWithDescriptions = parsed.allEntries.filter { $0.description?.isEmpty == false }.count
        let entriesWithDefaults = parsed.allEntries.filter { $0.defaultValue?.isEmpty == false }.count
        let descriptionsOK = entriesWithDescriptions == parsed.allEntries.count
        let defaultsOK = entriesWithDefaults == parsed.allEntries.count
        print("  entries: \(parsed.allEntries.count), with descriptions: \(entriesWithDescriptions), with defaults: \(entriesWithDefaults) -> \((descriptionsOK && defaultsOK) ? "PASS" : "FAIL")")

        print("")
        print("2) round-trip (parse + save with zero changes must be byte-identical):")
        let roundTripped = BepInExConfig.applying([:], to: originalText)
        let roundTripOK = roundTripped == originalText
        print("  byte-identical: \(roundTripOK) -> \(roundTripOK ? "PASS" : "FAIL")")

        print("")
        print("3) change one value + save -> diff shows exactly 1 changed line:")
        guard let fovEntry = parsed.allEntries.first(where: { $0.key == "Default FOV" }) else {
            print("  SKIPPED: could not find \"Default FOV\" entry")
            return
        }
        let changedText = BepInExConfig.applying([fovEntry.lineIndex: "75"], to: originalText)
        let changedURL = tempDir.appendingPathComponent("changed.cfg")
        try? changedText.write(to: changedURL, atomically: true, encoding: .utf8)
        let hunks = await diffHunkCount(tempConfigURL, changedURL)
        let reparsed = BepInExConfig.parse(changedText)
        let rereadValue = reparsed.allEntries.first { $0.key == "Default FOV" }?.rawValue
        let untouchedElsewhere = reparsed.allEntries.filter { $0.key != "Default FOV" } == parsed.allEntries.filter { $0.key != "Default FOV" }
        let changeOK = hunks == 1 && rereadValue == "75" && untouchedElsewhere
        print("  diff-hunks=\(hunks.map(String.init) ?? "?") (expect 1) reread=\(rereadValue ?? "nil") (expect 75) other-entries-untouched=\(untouchedElsewhere) -> \(changeOK ? "PASS" : "FAIL")")

        print("")
        print("4) reset-to-default logic (embedded fixture, not the real file — this machine's real Default FOV may well differ from its default already):")
        // Deliberately not asserted against `fovEntry`/`originalText` above:
        // those come from the REAL Azumatt.FirstPersonMode.cfg, whose
        // current value is whatever this developer has it set to right now
        // (e.g. changed from the shipped default of 65 to 100) — a
        // perfectly normal thing for a real config to be, but it made this
        // step fail on any machine where the value had ever been touched.
        // The reset-to-default *logic* being tested here is
        // `ConfigEditorView`'s "Reset to Default" button, which just writes
        // the entry's own `defaultValue` back via `BepInExConfig.applying`
        // — that's exercised below against a small embedded fixture string
        // instead, so this section's PASS/FAIL no longer depends on what
        // this machine's real file happens to contain.
        let fixtureConfigText = """
        [General]

        ## The field of view to use while first person mode is active.
        # Setting type: Single
        # Default value: 65
        Default FOV = 100
        """
        let fixtureParsed = BepInExConfig.parse(fixtureConfigText)
        guard let fixtureFovEntry = fixtureParsed.allEntries.first(where: { $0.key == "Default FOV" }) else {
            print("  FAILED: could not parse \"Default FOV\" out of the embedded fixture")
            return
        }
        let fixtureStartsChanged = fixtureFovEntry.defaultValue == "65"
            && fixtureFovEntry.rawValue == "100"
            && fixtureFovEntry.rawValue != fixtureFovEntry.defaultValue
        let afterResetText = BepInExConfig.applying([fixtureFovEntry.lineIndex: fixtureFovEntry.defaultValue!], to: fixtureConfigText)
        let afterResetValue = BepInExConfig.parse(afterResetText).allEntries.first { $0.key == "Default FOV" }?.rawValue
        let resetOK = fixtureStartsChanged && afterResetValue == fixtureFovEntry.defaultValue
        print("  fixture starts changed from default: default=\(fixtureFovEntry.defaultValue ?? "nil") current=\(fixtureFovEntry.rawValue) -> \(fixtureStartsChanged)")
        print("  after applying Reset to Default: current=\(afterResetValue ?? "nil") (expect \(fixtureFovEntry.defaultValue ?? "nil")) -> \(resetOK ? "PASS" : "FAIL")")

        print("")
        print("5) association heuristic:")
        let candidates = [(fullName: "Azumatt-FirstPersonMode", name: "First Person Mode")]
        let matched = BepInExConfig.associate(cfgFileName: "Azumatt.FirstPersonMode.cfg", candidates: candidates)
        let unmatched = BepInExConfig.associate(cfgFileName: "BepInEx.cfg", candidates: candidates)
        let associationOK = matched == "Azumatt-FirstPersonMode" && unmatched == nil
        print("  \"Azumatt.FirstPersonMode.cfg\" -> \(matched ?? "nil") (expect Azumatt-FirstPersonMode)")
        print("  \"BepInEx.cfg\" -> \(unmatched.map { "\"\($0)\"" } ?? "nil") (expect nil)")
        print("  -> \(associationOK ? "PASS" : "FAIL")")

        print("")
        print("6) discoverConfigs against the real config dir (read-only):")
        let realConfigDir = realGameDir.appendingPathComponent("BepInEx/config")
        let discovered = BepInExConfig.discoverConfigs(in: realConfigDir, candidates: candidates)
        let discoveredOK = discovered.contains { $0.fileName == "Azumatt.FirstPersonMode.cfg" && $0.associatedFullName == "Azumatt-FirstPersonMode" }
            && discovered.contains { $0.fileName == "BepInEx.cfg" && $0.associatedFullName == nil }
        for config in discovered {
            print("  \(config.fileName) -> \(config.associatedFullName ?? "(unmatched)")")
        }
        print("  -> \(discoveredOK ? "PASS" : "FAIL")")

        print("")
        print("7) README fetch (best effort, skips gracefully offline):")
        await checkReadmeFetch()

        print("")
        print("8) keyed application — conflict-safe save onto an externally-rewritten copy:")
        checkKeyedApplication()

        print("")
        print("9) multi-file round-trip sweep (every real .cfg, temp copies only):")
        await checkConfigRoundTripSweep(realConfigDir: realConfigDir)

        print("")
        print("10) CRLF tolerance (none of this machine's real cfgs use it, so an embedded fixture):")
        checkCRLFTolerance()
    }

    /// None of this developer's real `.cfg` files use CRLF line endings
    /// (checked: all are bare `\n`), but nothing guarantees every mod
    /// author's config template stays that way, and `parse` splits on
    /// `"\n"` alone — which used to leave a dangling `"\r"` on every line
    /// that `.whitespaces` trimming (as opposed to `.whitespacesAndNewlines`)
    /// didn't strip, corrupting section names, keys, and values alike.
    /// Embedded fixture, since a real CRLF file isn't available to test
    /// against.
    private static func checkCRLFTolerance() {
        let crlfText = "[General]\r\n\r\n## A CRLF-terminated description.\r\n# Setting type: Boolean\r\n# Default value: false\r\nEnabled = true\r\n"
        let parsed = BepInExConfig.parse(crlfText)
        let entry = parsed.allEntries.first { $0.key == "Enabled" }
        let sectionOK = parsed.sections.first?.name == "General"
        let keyOK = entry?.key == "Enabled"
        let valueOK = entry?.rawValue == "true"
        let boolValueOK = entry?.boolValue == true
        let descriptionOK = entry?.description == "A CRLF-terminated description."
        let pass = sectionOK && keyOK && valueOK && boolValueOK && descriptionOK
        print("  section name (no stray \\r): \"\(parsed.sections.first?.name ?? "nil")\" (expect \"General\") -> \(sectionOK)")
        print("  key (no stray \\r): \"\(entry?.key ?? "nil")\" (expect \"Enabled\") -> \(keyOK)")
        print("  value (no stray \\r): \"\(entry?.rawValue ?? "nil")\" (expect \"true\") -> \(valueOK)")
        print("  boolValue resolves despite CRLF: \(entry?.boolValue.map(String.init) ?? "nil") (expect true) -> \(boolValueOK)")
        print("  description (no stray \\r): \"\(entry?.description ?? "nil")\" -> \(descriptionOK)")
        print("  -> \(pass ? "PASS" : "FAIL")")
    }

    /// Exercises `BepInExConfig.applying(values:to:)` — the fix for the
    /// stale-write race where a mod rewrites its `.cfg` on game exit
    /// between when `ConfigEditorView` read the file and when the user
    /// hits Save. Simulates that exact sequence with embedded fixtures
    /// (no real files touched): the editor opens `originalText`, the user
    /// edits one setting, then — before they save — an external rewrite
    /// (a) changes an unrelated setting's value, (b) inserts a brand-new
    /// section+setting that didn't exist when the editor opened (so line
    /// indices no longer line up at all), and (c) removes a setting the
    /// user never touched but a stale second edit still references.
    /// Asserts: the user's edit lands, the external changes both survive
    /// untouched, and the edit targeting the now-vanished setting is
    /// reported as skipped rather than silently dropped or crashing.
    private static func checkKeyedApplication() {
        let originalText = """
        [General]

        ## The field of view to use while first person mode is active.
        # Setting type: Single
        # Default value: 65
        Default FOV = 65

        [Other]

        ## Whether the feature is enabled.
        # Setting type: Boolean
        # Default value: false
        Enabled = false

        ## A setting that will vanish in the external rewrite below.
        # Setting type: Boolean
        # Default value: false
        Temporary = false
        """

        // What the game/mod wrote to disk after the editor opened but
        // before the user saved: "Enabled" flipped to true (external
        // change to a setting the user didn't touch), a brand-new
        // "New Toggle" setting inserted above it (shifts every following
        // line index), and "Temporary" removed entirely.
        let externallyRewrittenText = """
        [General]

        ## The field of view to use while first person mode is active.
        # Setting type: Single
        # Default value: 65
        Default FOV = 65

        [Other]

        ## Whether the feature is enabled.
        # Setting type: Boolean
        # Default value: false
        Enabled = true

        ## Newly added by the mod itself on this run.
        # Setting type: Boolean
        # Default value: false
        New Toggle = true
        """

        let parsedOriginal = BepInExConfig.parse(originalText)
        guard let fovEntry = parsedOriginal.allEntries.first(where: { $0.key == "Default FOV" }) else {
            print("  FAILED: could not find \"Default FOV\" in the fixture")
            return
        }

        // The user's pending edits, computed against the ORIGINAL
        // (now-stale) snapshot — exactly what `ConfigEditorView.save()`
        // has in `editedValues` at save time: one edit to a setting that
        // still exists ("Default FOV"), one to a setting that no longer
        // does ("Temporary").
        let userEdits = [
            BepInExConfig.KeyedChange(section: fovEntry.section, key: fovEntry.key, value: "90"),
            BepInExConfig.KeyedChange(section: "Other", key: "Temporary", value: "true"),
        ]

        let result = BepInExConfig.applying(values: userEdits, to: externallyRewrittenText)

        let userEditLanded = result.text.contains("Default FOV = 90")
        let externalValueChangeSurvived = result.text.contains("Enabled = true")
        let externalInsertionSurvived = result.text.contains("New Toggle = true")
        let vanishedKeyNotWritten = !result.text.contains("Temporary")
        let skippedReportedCorrectly = result.skipped == [
            BepInExConfig.KeyedChange(section: "Other", key: "Temporary", value: "true"),
        ]
        // Nothing else in the externally-rewritten text should have moved
        // — same byte-for-byte-preservation guarantee as the line-indexed
        // `applying(_:to:)`, just re-targeted.
        let reparsed = BepInExConfig.parse(result.text)
        let otherEntriesUntouched = reparsed.allEntries.filter { $0.key != "Default FOV" }
            == BepInExConfig.parse(externallyRewrittenText).allEntries.filter { $0.key != "Default FOV" }

        let pass = userEditLanded && externalValueChangeSurvived && externalInsertionSurvived
            && vanishedKeyNotWritten && skippedReportedCorrectly && otherEntriesUntouched

        print("  user edit (Default FOV -> 90) landed onto the rewritten copy: \(userEditLanded)")
        print("  external value change (Enabled -> true) survived: \(externalValueChangeSurvived)")
        print("  external insertion (New Toggle, shifts line indices) survived: \(externalInsertionSurvived)")
        print("  vanished-key edit (Temporary) not written: \(vanishedKeyNotWritten)")
        print("  skipped = \(result.skipped.map { "\($0.section)/\($0.key)" }) (expect [\"Other/Temporary\"]) -> \(skippedReportedCorrectly)")
        print("  every other entry preserved byte-for-byte: \(otherEntriesUntouched)")
        print("  -> \(pass ? "PASS" : "FAIL")")
    }

    /// Round-trip-tests `BepInExConfig.parse`/`applying` against a TEMP
    /// copy (guarded by `assertUnderTempDir`) of every `.cfg` file
    /// currently in the real config dir — not just one fixture file. For
    /// each: parses it, counts entries, cross-checks that count against an
    /// independent `grep`-based baseline (`^[^#\[].* = `: any non-comment,
    /// non-section-header line containing " = " — i.e. every `Key = value`
    /// line BepInEx's own format can produce, including empty-value
    /// entries), and verifies a zero-change round trip is byte-identical.
    /// A mismatched entry count means the parser silently dropped (or
    /// double-counted) something real-world — exactly the "a setting was
    /// missing" failure mode this whole fix exists for.
    private static func checkConfigRoundTripSweep(realConfigDir: URL) async {
        guard let cfgFiles = try? FileManager.default.contentsOfDirectory(at: realConfigDir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension.lowercased() == "cfg" })
            .sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
        else {
            print("  skipped: could not list \(realConfigDir.path)")
            return
        }
        guard !cfgFiles.isEmpty else {
            print("  skipped: no .cfg files found in \(realConfigDir.path)")
            return
        }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("BifrostCheck-configsweep-\(UUID().uuidString)")
        assertUnderTempDir(tempDir, label: "config round-trip sweep tempDir")
        defer { try? fm.removeItem(at: tempDir) }
        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            print("  FAILED to create temp sweep dir: \(error)")
            return
        }

        var allPassed = true
        for realURL in cfgFiles {
            let fileName = realURL.lastPathComponent
            guard let originalText = try? String(contentsOf: realURL, encoding: .utf8) else {
                print("  \(fileName): FAILED to read")
                allPassed = false
                continue
            }

            let tempURL = tempDir.appendingPathComponent(fileName)
            assertUnderTempDir(tempURL, label: "config round-trip sweep tempURL")
            do {
                try originalText.write(to: tempURL, atomically: true, encoding: .utf8)
            } catch {
                print("  \(fileName): FAILED to copy to temp: \(error)")
                allPassed = false
                continue
            }

            let parsed = BepInExConfig.parse(originalText)
            let entryCount = parsed.allEntries.count

            let baselineResult = try? await ShellRunner.run("/usr/bin/grep", ["-cE", "^[^#\\[].* = ", tempURL.path])
            // grep exits 1 (not an error here) when it finds zero matches;
            // only treat a missing result entirely as "couldn't compute".
            let baselineCount = baselineResult.flatMap { Int($0.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) }

            let roundTripped = BepInExConfig.applying([:], to: originalText)
            let roundTripOK = roundTripped == originalText

            let countOK = baselineCount.map { $0 == entryCount } ?? false
            let filePass = countOK && roundTripOK
            allPassed = allPassed && filePass

            print("  \(fileName): parsed=\(entryCount) baseline=\(baselineCount.map(String.init) ?? "?") round-trip-identical=\(roundTripOK) -> \(filePass ? "PASS" : "FAIL")")
        }
        print("  -> \(allPassed ? "PASS" : "FAIL") (\(cfgFiles.count) file(s))")
    }

    /// Fetches the loader pack's current version from Thunderstore's
    /// package metadata endpoint, then its README from the experimental
    /// `{owner}/{name}/{version}/readme/` endpoint — a `{"markdown":
    /// "..."}` JSON body (verified against the live API). Never hits a
    /// hardcoded version, so this keeps working as the pack updates.
    private static func checkReadmeFetch() async {
        struct PackageMeta: Decodable {
            struct Latest: Decodable {
                let versionNumber: String
                enum CodingKeys: String, CodingKey { case versionNumber = "version_number" }
            }
            let latest: Latest
        }
        struct ReadmeResponse: Decodable { let markdown: String }

        guard let metadataURL = URL(string: "https://thunderstore.io/api/experimental/package/denikson/BepInExPack_Valheim/") else {
            print("  FAILED: bad metadata URL")
            return
        }
        do {
            let (metaData, metaResponse) = try await URLSession.shared.data(from: metadataURL)
            guard let metaHTTP = metaResponse as? HTTPURLResponse, (200..<300).contains(metaHTTP.statusCode) else {
                print("  skipped: could not fetch package metadata (offline or API unavailable)")
                return
            }
            let meta = try JSONDecoder().decode(PackageMeta.self, from: metaData)

            guard let readmeURL = URL(string: "https://thunderstore.io/api/experimental/package/denikson/BepInExPack_Valheim/\(meta.latest.versionNumber)/readme/") else {
                print("  FAILED: bad readme URL")
                return
            }
            let (data, response) = try await URLSession.shared.data(from: readmeURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                print("  skipped: non-2xx readme response")
                return
            }
            let decoded = try JSONDecoder().decode(ReadmeResponse.self, from: data)
            let nonEmpty = !decoded.markdown.isEmpty
            print("  denikson-BepInExPack_Valheim@\(meta.latest.versionNumber) markdown length: \(decoded.markdown.count) -> \(nonEmpty ? "PASS" : "FAIL")")
        } catch {
            print("  skipped: \(error) (likely offline)")
        }
    }

    // MARK: - Save backups

    /// Exercises `SaveBackup` end to end against throwaway TEMP fixtures
    /// (a fake save dir with dummy `.db`/`.fwl`/`.fch` files, a fake
    /// backups dir, and a second fake dir to restore into — all guarded by
    /// `assertUnderTempDir`): archive contents, pruning down to
    /// `autoRetentionCount` while manual backups survive, a restore that
    /// reproduces files byte-identically and takes its own pre-restore
    /// safety backup, and the running-game refusal exercised both ways via
    /// the injectable `isGameRunning` closure. Finishes with a read-only
    /// line against the REAL save dir (existence + file counts only, never
    /// written to).
    private static func checkSaveBackups() async {
        let fm = FileManager.default
        let fixtureSaveDir = fm.temporaryDirectory.appendingPathComponent("BifrostCheck-savebackup-savedir-\(UUID().uuidString)")
        let fixtureBackupsDir = fm.temporaryDirectory.appendingPathComponent("BifrostCheck-savebackup-backupsdir-\(UUID().uuidString)")
        let restoreTargetDir = fm.temporaryDirectory.appendingPathComponent("BifrostCheck-savebackup-restoretarget-\(UUID().uuidString)")
        assertUnderTempDir(fixtureSaveDir, label: "save backup fixtureSaveDir")
        assertUnderTempDir(fixtureBackupsDir, label: "save backup fixtureBackupsDir")
        assertUnderTempDir(restoreTargetDir, label: "save backup restoreTargetDir")
        defer {
            try? fm.removeItem(at: fixtureSaveDir)
            try? fm.removeItem(at: fixtureBackupsDir)
            try? fm.removeItem(at: restoreTargetDir)
        }

        let worldDB = fixtureSaveDir.appendingPathComponent("worlds_local/World1.db")
        let worldFWL = fixtureSaveDir.appendingPathComponent("worlds_local/World1.fwl")
        let characterFCH = fixtureSaveDir.appendingPathComponent("characters_local/Hero1.fch")
        do {
            for url in [worldDB, worldFWL, characterFCH] {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            try Data("world1-db-content".utf8).write(to: worldDB)
            try Data("world1-fwl-content".utf8).write(to: worldFWL)
            try Data("hero1-fch-content".utf8).write(to: characterFCH)
        } catch {
            print("skipped: could not build fixture save dir: \(error)")
            return
        }
        print("fixture: fake save dir \(fixtureSaveDir.path) (worlds_local: 2 files, characters_local: 1 file)")
        print("fixture: fake backups dir \(fixtureBackupsDir.path)")

        let backup = SaveBackup(saveDir: fixtureSaveDir, backupsDir: fixtureBackupsDir)

        print("")
        print("1) backupNow(reason: \"manual\") — creates a zip with the expected entries:")
        var manualBackup: SaveBackup.Backup?
        do {
            let outcome = try await backup.backupNow(reason: SaveBackup.manualReason)
            guard case .created(let summary) = outcome else {
                print("  FAILED: expected .created, got \(outcome)")
                return
            }
            let fileCountOK = summary.fileCount == 3
            let sizeOK = summary.byteSize > 0
            print("  fileCount=\(summary.fileCount) (expect 3) byteSize=\(summary.byteSize) -> fileCount-ok=\(fileCountOK) size-ok=\(sizeOK)")

            let listResult = try? await ShellRunner.run("/usr/bin/unzip", ["-Z1", summary.url.path])
            let entries = Set((listResult?.stdout ?? "").split(separator: "\n").map(String.init))
            let expectedEntries = ["worlds_local/World1.db", "worlds_local/World1.fwl", "characters_local/Hero1.fch"]
            let entriesOK = expectedEntries.allSatisfy(entries.contains)
            print("  zip entries: \(entries.sorted()) -> contains-expected=\(entriesOK)")

            manualBackup = await backup.list().first { $0.reason == SaveBackup.manualReason }
            print("  -> \((fileCountOK && sizeOK && entriesOK && manualBackup != nil) ? "PASS" : "FAIL")")
        } catch {
            print("  FAILED: \(error)")
        }
        guard let manualBackup else {
            print("ABORT: no manual backup to continue from")
            return
        }

        print("")
        print("2) pruning — 17 automatic backups collapse to \(SaveBackup.autoRetentionCount), manual survives:")
        for i in 0..<17 {
            _ = try? await backup.backupNow(reason: "auto-\(i)")
        }
        let afterPruning = await backup.list()
        let automaticCount = afterPruning.filter { $0.reason != SaveBackup.manualReason }.count
        let manualCount = afterPruning.filter { $0.reason == SaveBackup.manualReason }.count
        let physicalCount = (try? fm.contentsOfDirectory(atPath: fixtureBackupsDir.path).count) ?? -1
        let pruningOK = automaticCount == SaveBackup.autoRetentionCount && manualCount == 1 && physicalCount == afterPruning.count
        print("  automatic=\(automaticCount) (expect \(SaveBackup.autoRetentionCount)) manual=\(manualCount) (expect 1) files-on-disk=\(physicalCount) listed=\(afterPruning.count)")
        print("  -> \(pruningOK ? "PASS" : "FAIL")")

        print("")
        print("3) restore into a second temp dir — byte-identical files + a pre-restore safety zip:")
        let oldWorld = restoreTargetDir.appendingPathComponent("worlds_local/OldWorld.db")
        let oldCharacter = restoreTargetDir.appendingPathComponent("characters_local/OldHero.fch")
        var restoreOK = false
        do {
            for url in [oldWorld, oldCharacter] {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            try Data("old-world-content".utf8).write(to: oldWorld)
            try Data("old-hero-content".utf8).write(to: oldCharacter)

            let preRestoreCountBefore = await backup.list().filter { $0.reason == "pre-restore" }.count

            let summary = try await backup.restore(backup: manualBackup, into: restoreTargetDir, isGameRunning: { false })

            let restoredWorldDBOK = await filesIdentical(worldDB, restoreTargetDir.appendingPathComponent("worlds_local/World1.db"))
            let restoredWorldFWLOK = await filesIdentical(worldFWL, restoreTargetDir.appendingPathComponent("worlds_local/World1.fwl"))
            let restoredCharacterOK = await filesIdentical(characterFCH, restoreTargetDir.appendingPathComponent("characters_local/Hero1.fch"))
            let oldFilesUntouched = fm.fileExists(atPath: oldWorld.path) && fm.fileExists(atPath: oldCharacter.path)

            let preRestoreCountAfter = await backup.list().filter { $0.reason == "pre-restore" }.count
            let safetyBackupCreated = preRestoreCountAfter == preRestoreCountBefore + 1

            // worlds_local now has World1.db + World1.fwl + OldWorld.db = 3;
            // characters_local now has Hero1.fch + OldHero.fch = 2.
            let fileCountOK = summary.fileCount == 5

            restoreOK = restoredWorldDBOK && restoredWorldFWLOK && restoredCharacterOK && oldFilesUntouched && safetyBackupCreated && fileCountOK
            print("  World1.db byte-identical: \(restoredWorldDBOK), World1.fwl byte-identical: \(restoredWorldFWLOK), Hero1.fch byte-identical: \(restoredCharacterOK)")
            print("  pre-existing files in target dir left in place (merge, not wipe): \(oldFilesUntouched)")
            print("  pre-restore safety zip created: \(safetyBackupCreated) (count \(preRestoreCountBefore) -> \(preRestoreCountAfter))")
            print("  restore() reported fileCount=\(summary.fileCount) (expect 5, the merged total)")
            print("  -> \(restoreOK ? "PASS" : "FAIL")")
        } catch {
            print("  FAILED: \(error)")
        }

        print("")
        print("4) running-game refusal — both paths of the injectable closure:")
        var refusalOK = false
        do {
            _ = try await backup.restore(backup: manualBackup, into: restoreTargetDir, isGameRunning: { true })
            print("  restore() with isGameRunning:{true} unexpectedly succeeded")
        } catch SaveBackup.SaveBackupError.gameRunning {
            refusalOK = true
            print("  restore() with isGameRunning:{true} correctly refused with .gameRunning")
        } catch {
            print("  restore() with isGameRunning:{true} failed with unexpected error: \(error)")
        }
        let allowedPathAlreadyProven = restoreOK
        print("  isGameRunning:{false} path already exercised and verified in step 3 above: \(allowedPathAlreadyProven)")
        print("  -> \((refusalOK && allowedPathAlreadyProven) ? "PASS" : "FAIL")")

        print("")
        print("5) (read-only) real Valheim save dir:")
        let realSaveDir = SaveBackup.defaultSaveDir
        let realDirExists = fm.fileExists(atPath: realSaveDir.path)
        print("  \(realSaveDir.path) exists: \(realDirExists)")
        if realDirExists {
            for subdir in SaveBackup.savedSubdirectories {
                let subdirURL = realSaveDir.appendingPathComponent(subdir)
                guard fm.fileExists(atPath: subdirURL.path) else { continue }
                let count = (try? fm.contentsOfDirectory(atPath: subdirURL.path).count) ?? 0
                print("  \(subdir): \(count) entrie(s)")
            }
        }
    }

    /// Byte-for-byte comparison of two files via `diff`, used to verify a
    /// restored file exactly reproduces the original it was backed up
    /// from.
    private static func filesIdentical(_ a: URL, _ b: URL) async -> Bool {
        (try? await ShellRunner.run("/usr/bin/diff", [a.path, b.path]))?.status == 0
    }
}
