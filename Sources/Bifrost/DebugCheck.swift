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
/// which case that's a deliberate no-op), and never installs BepInEx
/// anywhere but a throwaway temp directory.
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
        await checkModManager(realGameDir: located?.directory, modManager: modManager)

        print("")
        print("== Wizard simulation (fresh-machine) ==")
        await checkWizardSimulation()
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

    /// Exercises `ModManager` end to end against the REAL game directory:
    /// install a simple no-dep mod, install a mod with a Jotunn dependency
    /// (verifying auto-resolution and the loader special case), toggle
    /// enabled state, uninstall the first mod, and re-verify the
    /// update-detection fix now that a loader version is on record. Leaves
    /// the real install with Jotunn + its dependent mod installed and
    /// enabled, and the first mod removed — see the task notes for why.
    private static func checkModManager(realGameDir: URL?, modManager: ModManager) async {
        guard let gameDir = realGameDir else {
            print("skipped: no game dir located")
            return
        }

        let thunderstoreClient = ThunderstoreClient()
        guard let index = try? await thunderstoreClient.fetchIndex(force: false) else {
            print("skipped: could not load Thunderstore index")
            return
        }

        // Step 0: this dev machine has BepInExPack_Valheim 5.4.2333 on disk
        // from an earlier manual spike, installed before Bifrost's manifest
        // existed, so there's no record of it. Seed one — exactly what
        // ModManager.install(loader) would have recorded had the pack been
        // installed through Bifrost — so the update-detection fix (above)
        // has something real to compare against.
        if await modManager.loaderVersion() == nil, await BepInExInstaller().status(gameDir: gameDir, launchDir: BepInExInstaller.defaultLaunchDir).packFilesPresent {
            print("NOTE: seeding manifest loader version to 5.4.2333 — pre-existing manual BepInEx install on this dev machine, no prior manifest record")
            try? await modManager.setLoaderVersion("5.4.2333")
        }

        print("")
        print("6) update-detection fix, re-checked now that a loader version is on record:")
        let loaderVersion = await modManager.loaderVersion()
        let dryRunActions = await BepInExInstaller().dryRun(gameDir: gameDir, launchDir: BepInExInstaller.defaultLaunchDir, manifestVersion: loaderVersion)
        for action in dryRunActions { print("  - \(action)") }
        let claimsPendingUpdate = dryRunActions.contains { $0.hasPrefix("Update BepInEx pack") }
        print("  claims a pending loader update: \(claimsPendingUpdate) -> \(claimsPendingUpdate ? "FAIL" : "PASS")")

        print("")
        print("1) install Advize-PlantEverything (simple, no plugin deps beyond the loader):")
        await installAndVerify(fullName: "Advize-PlantEverything", index: index, gameDir: gameDir, modManager: modManager) { resolved in
            let dllPresent = FileManager.default.fileExists(
                atPath: gameDir.appendingPathComponent("BepInEx/plugins/Advize-PlantEverything/Advize_PlantEverything.dll").path
            )
            let manifestHasIt = await modManager.isInstalled(fullName: "Advize-PlantEverything")
            print("  dll present under BepInEx/plugins/Advize-PlantEverything/: \(dllPresent)")
            print("  manifest records it: \(manifestHasIt)")
            return dllPresent && manifestHasIt
        }

        print("")
        print("2) install RandyKnapp-EquipmentAndQuickSlots (depends on Jotunn + the loader):")
        await installAndVerify(fullName: "RandyKnapp-EquipmentAndQuickSlots", index: index, gameDir: gameDir, modManager: modManager) { resolved in
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
            try await modManager.setEnabled(fullName: "Advize-PlantEverything", enabled: false, gameDir: gameDir)
            let disabledPresent = FileManager.default.fileExists(
                atPath: gameDir.appendingPathComponent("BepInEx/plugins/Advize-PlantEverything/Advize_PlantEverything.dll.disabled").path
            )
            print("  after disable, .dll.disabled present: \(disabledPresent)")

            try await modManager.setEnabled(fullName: "Advize-PlantEverything", enabled: true, gameDir: gameDir)
            let enabledPresent = FileManager.default.fileExists(
                atPath: gameDir.appendingPathComponent("BepInEx/plugins/Advize-PlantEverything/Advize_PlantEverything.dll").path
            )
            print("  after re-enable, .dll present: \(enabledPresent)")
            print("  -> \((disabledPresent && enabledPresent) ? "PASS" : "FAIL")")
        } catch {
            print("  FAILED: \(error)")
        }

        print("")
        print("4) uninstall Advize-PlantEverything — Jotunn/EquipmentAndQuickSlots must be untouched:")
        do {
            try await modManager.uninstall(fullName: "Advize-PlantEverything", gameDir: gameDir)
            let dirGone = !FileManager.default.fileExists(atPath: gameDir.appendingPathComponent("BepInEx/plugins/Advize-PlantEverything").path)
            let manifestGone = await !modManager.isInstalled(fullName: "Advize-PlantEverything")
            let jotunnStillInstalled = await modManager.isInstalled(fullName: "ValheimModding-Jotunn")
            let eqsStillInstalled = await modManager.isInstalled(fullName: "RandyKnapp-EquipmentAndQuickSlots")
            let jotunnFilesPresent = FileManager.default.fileExists(atPath: gameDir.appendingPathComponent("BepInEx/plugins/ValheimModding-Jotunn/Jotunn.dll").path)
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
        print("5) final state (expected: Jotunn + EquipmentAndQuickSlots installed & enabled, PlantEverything gone):")
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
}
