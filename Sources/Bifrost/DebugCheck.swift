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
        print("4) reset-to-default logic (\"Default FOV\" untouched in the original fixture, so current == default):")
        let resetOK = fovEntry.defaultValue == "65" && fovEntry.rawValue == fovEntry.defaultValue
        print("  default=\(fovEntry.defaultValue ?? "nil") current=\(fovEntry.rawValue) -> \(resetOK ? "PASS" : "FAIL")")

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
}
