using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Bifrost.Core.Models;

namespace Bifrost.Core.Services;

/// <summary>
/// Headless verification path for development: <c>Bifrost --check</c> runs
/// against temp fixtures (and, where safe, real Thunderstore downloads) and
/// prints PASS/FAIL per section, mirroring the macOS reference
/// implementation's <c>DebugCheck.swift</c>. Every section here is written
/// to be safe to run on this Mac dev machine: it never touches the real
/// %AppData%\Bifrost, and only ever reads (never writes) the real macOS
/// manifest.json used for the cross-platform shape check.
/// </summary>
public static class SelfTest
{
    private static bool _anyFailure;

    public static async Task<bool> RunAllAsync(TextWriter output)
    {
        _anyFailure = false;

        Section(output, "Setup status");
        await CheckSetupStatusAsync(output);

        Section(output, "VDF / ACF parsing");
        CheckVdfParsing(output);

        Section(output, "Doorstop ini toggle");
        CheckDoorstopToggle(output);

        Section(output, "Thunderstore index fetch + 304 revalidation");
        List<ThunderstorePackage>? index = await CheckThunderstoreIndexAsync(output);

        Section(output, "BepInEx installer (real download, fake game dir)");
        await CheckBepInExInstallerAsync(output);

        Section(output, "Mod manager end-to-end (real downloads, fake game dir)");
        if (index is not null)
        {
            await CheckModManagerAsync(output, index);
        }
        else
        {
            output.WriteLine("SKIPPED: no Thunderstore index available");
        }

        Section(output, "Profile reconcile");
        CheckProfiles(output);

        Section(output, "Manifest JSON shape compatibility (real macOS manifest.json, read-only)");
        CheckManifestShapeCompatibility(output);

        Section(output, "Config editor (BepInExConfig parser/writer, keyed apply, association, README)");
        await CheckConfigEditorAsync(output);

        Section(output, "Install from file (zip/dll heuristics, manifest.json identity, collision/replace, local excluded from updates)");
        await CheckInstallFromFileAsync(output);

        Section(output, "Save backups (fixtures, retention pruning, restore + pre-restore safety zip, running-game refusal)");
        CheckSaveBackups(output);

        Section(output, "Game update detection (appmanifest_892970.acf buildid, first/unchanged/updated, persistence)");
        CheckGameUpdateWatcher(output);

        Section(output, "Update All aggregation (sequential, failure-tolerant, summary)");
        await CheckUpdateAllRunnerAsync(output);

        Section(output, "Thunderstore index auto-refresh staleness");
        CheckIndexAutoRefresher(output);

        Section(output, "Launcher plan + silent Steam (argument/executable resolution)");
        CheckLauncherSilentSteam(output);

        Section(output, "App settings store (defaults, persistence, missing/corrupt file)");
        CheckAppSettingsStore(output);

        Section(output, "Nexus Mods: nxm:// link parsing");
        CheckNxmLinkParsing(output);

        Section(output, "Nexus Mods: credential store round trip");
        CheckWindowsCredentialsRoundTrip(output);

        Section(output, "Nexus Mods: nxm:// protocol registration (Windows registry)");
        CheckNxmProtocolRegistration(output);

        Section(output, "Single-instance mutex + named-pipe forwarding");
        await CheckSingleInstanceAsync(output);

        Section(output, "Multiplayer safety: mod classifier");
        CheckModClassifier(output);

        Section(output, "Multiplayer safety: guided Join-a-Server planner");
        CheckServerJoinPlanner(output);

        Section(output, "Profile sharing: native format + r2modman interop");
        await CheckProfileShareAsync(output);

        Section(output, "Fun round: Saga stats");
        CheckSagaStats(output);

        Section(output, "Fun round: Flavor quips + Runestone tips");
        CheckFlavorAndRunestoneTips(output);

        Section(output, "Fun round: Surprise Me filter");
        CheckSurpriseMe(output);

        output.WriteLine();
        output.WriteLine(_anyFailure ? "== One or more checks FAILED ==" : "== All checks PASSED ==");
        return !_anyFailure;
    }

    private static void Section(TextWriter output, string name)
    {
        output.WriteLine();
        output.WriteLine($"== {name} ==");
    }

    private static void Report(TextWriter output, string name, bool pass, string? detail = null)
    {
        _anyFailure |= !pass;
        var status = pass ? "PASS" : "FAIL";
        output.WriteLine(detail is null ? $"[{status}] {name}" : $"[{status}] {name} — {detail}");
    }

    // MARK: - Setup status

    private static async Task CheckSetupStatusAsync(TextWriter output)
    {
        var locator = new GameLocator();
        output.WriteLine($"steam root: {locator.SteamRoot}");
        var located = locator.Locate();
        if (located is { } game)
        {
            output.WriteLine($"game found: true -> {game.Directory} (valid={game.IsValid})");
        }
        else
        {
            output.WriteLine("game found: false");
        }

        var bepinexInstalled = located is not null && GameLocator.BepInExInstalled(located.Directory);
        output.WriteLine($"bepinex installed: {bepinexInstalled}");

        var moddedState = located is not null ? Launcher.CurrentModdedEnabled(located.Directory) : null;
        output.WriteLine($"doorstop enabled (modded): {moddedState?.ToString() ?? "unknown"}");

        var steamRunning = GameLocator.SteamIsRunning();
        output.WriteLine($"steam running: {steamRunning}");

        await Task.CompletedTask;
    }

    // MARK: - VDF / ACF parsing

    private const string LibraryFoldersNestedFixture = """
        "libraryfolders"
        {
        	"0"
        	{
        		"path"		"C:\\Program Files (x86)\\Steam"
        		"label"		""
        		"contentid"		"1234567890"
        		"apps"
        		{
        			"892970"		"12659212800"
        		}
        	}
        	"1"
        	{
        		"path"		"D:\\SteamLibrary"
        		"label"		""
        		"contentid"		"9876543210"
        		"apps"
        		{
        		}
        	}
        }
        """;

    private const string LibraryFoldersFlatFixture = """
        "LibraryFolders"
        {
        	"TimeNextStatsReport"		"0"
        	"ContentStatsID"		"0"
        	"1"		"D:\\SteamLibrary"
        	"2"		"E:\\Games\\Steam"
        }
        """;

    private const string AppManifestFixture = """
        "AppState"
        {
        	"appid"		"892970"
        	"universe"		"1"
        	"name"		"Valheim"
        	"StateFlags"		"4"
        	"installdir"		"Valheim"
        	"LastUpdated"		"1700000000"
        	"SizeOnDisk"		"2000000000"
        	"buildid"		"12345678"
        }
        """;

    private static void CheckVdfParsing(TextWriter output)
    {
        var nestedPaths = VdfParser.ParseLibraryFolderPaths(LibraryFoldersNestedFixture);
        Report(output, "nested libraryfolders.vdf -> 2 paths",
            nestedPaths.Count == 2 && nestedPaths[0] == @"C:\Program Files (x86)\Steam" && nestedPaths[1] == @"D:\SteamLibrary",
            string.Join(", ", nestedPaths));

        var flatPaths = VdfParser.ParseLibraryFolderPaths(LibraryFoldersFlatFixture);
        Report(output, "flat (legacy) libraryfolders.vdf -> 2 paths",
            flatPaths.Count == 2 && flatPaths[0] == @"D:\SteamLibrary" && flatPaths[1] == @"E:\Games\Steam",
            string.Join(", ", flatPaths));

        var installDir = VdfParser.GetValue("installdir", AppManifestFixture);
        Report(output, "appmanifest_892970.acf installdir -> \"Valheim\"", installDir == "Valheim", installDir);

        // Integration: GameLocator against a fake Steam root built from
        // these same fixtures, with a dummy valheim.exe dropped in.
        var fakeSteamRoot = Path.Combine(Path.GetTempPath(), $"BifrostCheck-steamroot-{Guid.NewGuid()}");
        try
        {
            var steamappsDir = Path.Combine(fakeSteamRoot, "steamapps");
            Directory.CreateDirectory(steamappsDir);
            File.WriteAllText(Path.Combine(steamappsDir, "libraryfolders.vdf"), LibraryFoldersFlatFixture);
            File.WriteAllText(Path.Combine(steamappsDir, $"appmanifest_{GameLocator.ValheimAppId}.acf"), AppManifestFixture);

            var gameDir = Path.Combine(steamappsDir, "common", "Valheim");
            Directory.CreateDirectory(gameDir);
            File.WriteAllText(Path.Combine(gameDir, "valheim.exe"), "dummy");

            var locator = new GameLocator(fakeSteamRoot);
            var located = locator.Locate();
            Report(output, "GameLocator.Locate() against fixture root", located is { IsValid: true } && located.Directory == gameDir,
                located?.Directory);
        }
        finally
        {
            TryDelete(fakeSteamRoot);
        }
    }

    // MARK: - Doorstop ini toggle

    private static void CheckDoorstopToggle(TextWriter output)
    {
        // A real doorstop_config.ini's [General] section (verbatim, as
        // shipped inside denikson-BepInExPack_Valheim).
        const string fixture = """
            # General options for Unity Doorstop
            [General]

            # Enable Doorstop?
            enabled = true

            # Path to the assembly to load and execute
            target_assembly=BepInEx\core\BepInEx.Preloader.dll

            # If true, Unity's output log is redirected to <current folder>\output_log.txt
            redirect_output_log = false

            [UnityMono]

            debug_enabled = false
            """;

        Report(output, "GetEnabled(fixture) == true", DoorstopConfig.GetEnabled(fixture) == true);

        var toFalse = DoorstopConfig.SetEnabled(fixture, false);
        var falseLineCount = CountChangedLines(fixture, toFalse.Text);
        Report(output, "toggle true -> false: exactly 1 line changed, other bytes preserved",
            toFalse.Changed && falseLineCount == 1 && DoorstopConfig.GetEnabled(toFalse.Text) == false,
            $"changed={toFalse.Changed} changedLines={falseLineCount}");

        var backToTrue = DoorstopConfig.SetEnabled(toFalse.Text, true);
        Report(output, "toggle false -> true round-trips byte-identical to the original",
            backToTrue.Changed && backToTrue.Text == fixture);

        var noOp = DoorstopConfig.SetEnabled(fixture, true);
        Report(output, "setting to the value already present is a byte-identical no-op",
            !noOp.Changed && noOp.Text == fixture);
    }

    private static int CountChangedLines(string a, string b)
    {
        var linesA = a.Split('\n');
        var linesB = b.Split('\n');
        var max = Math.Max(linesA.Length, linesB.Length);
        var changed = 0;
        for (var i = 0; i < max; i++)
        {
            var lineA = i < linesA.Length ? linesA[i] : null;
            var lineB = i < linesB.Length ? linesB[i] : null;
            if (lineA != lineB)
            {
                changed++;
            }
        }
        return changed;
    }

    // MARK: - Thunderstore index

    private static async Task<List<ThunderstorePackage>?> CheckThunderstoreIndexAsync(TextWriter output)
    {
        var tempDir = Path.Combine(Path.GetTempPath(), $"BifrostCheck-thunderstore-{Guid.NewGuid()}");
        Directory.CreateDirectory(tempDir);
        try
        {
            var client = new ThunderstoreClient(cacheFilePath: Path.Combine(tempDir, "package-index.json"), validatorsFilePath: Path.Combine(tempDir, "package-index.validators.json"));

            var sw1 = System.Diagnostics.Stopwatch.StartNew();
            var packages = await client.FetchIndexAsync(force: true);
            sw1.Stop();
            output.WriteLine($"fetch #1 (force, fresh): {packages.Count} packages in {sw1.Elapsed.TotalSeconds:F2}s");
            Report(output, "fetch #1 returned a non-trivial package list", packages.Count > 100);

            var cacheExists = File.Exists(Path.Combine(tempDir, "package-index.json"));
            var validatorsExists = File.Exists(Path.Combine(tempDir, "package-index.validators.json"));
            Report(output, "cache + validators files created", cacheExists && validatorsExists);

            var sw2 = System.Diagnostics.Stopwatch.StartNew();
            var packages2 = await client.FetchIndexAsync(force: false);
            sw2.Stop();
            output.WriteLine($"fetch #2 (conditional, expect 304/cache): {packages2.Count} packages in {sw2.Elapsed.TotalSeconds:F2}s");
            Report(output, "fetch #2 (conditional) is much faster than the forced fetch and returns the same count",
                packages2.Count == packages.Count && sw2.Elapsed < sw1.Elapsed);

            return packages;
        }
        catch (Exception ex)
        {
            Report(output, "Thunderstore index fetch", false, ex.Message);
            return null;
        }
        finally
        {
            TryDelete(tempDir);
        }
    }

    // MARK: - BepInEx installer

    private static async Task CheckBepInExInstallerAsync(TextWriter output)
    {
        var fakeGameDir = Path.Combine(Path.GetTempPath(), $"BifrostCheck-fakegame-{Guid.NewGuid()}");
        try
        {
            var installer = new BepInExInstaller();
            var outcome = await installer.InstallAsync(fakeGameDir, manifestVersion: null, onProgress: p => output.WriteLine($"  progress: {p.Stage} {p.VersionNumber}"));
            output.WriteLine($"installed version {outcome.VersionNumber} (packWasUpToDate={outcome.PackWasUpToDate})");

            var winhttpPresent = File.Exists(Path.Combine(fakeGameDir, "winhttp.dll"));
            var bepinexCorePresent = Directory.Exists(Path.Combine(fakeGameDir, "BepInEx", "core"));
            var doorstopConfigPresent = File.Exists(Path.Combine(fakeGameDir, "doorstop_config.ini"));
            var doorstopVersionPresent = File.Exists(Path.Combine(fakeGameDir, ".doorstop_version"));
            Report(output, "BepInEx/core, winhttp.dll, doorstop_config.ini, .doorstop_version all present",
                winhttpPresent && bepinexCorePresent && doorstopConfigPresent && doorstopVersionPresent);

            var doorstopLibsAbsent = !Directory.Exists(Path.Combine(fakeGameDir, "doorstop_libs"));
            var startScriptAbsent = !File.Exists(Path.Combine(fakeGameDir, "start_game_bepinex.sh"));
            var serverScriptAbsent = !File.Exists(Path.Combine(fakeGameDir, "start_server_bepinex.sh"));
            Report(output, "unix-only payload (doorstop_libs/, start_*.sh) excluded from a Windows install",
                doorstopLibsAbsent && startScriptAbsent && serverScriptAbsent);

            Report(output, "GameLocator.BepInExInstalled(fakeGameDir)", GameLocator.BepInExInstalled(fakeGameDir));

            // Idempotency: re-running install with the version we just
            // recorded should report packWasUpToDate and skip the download.
            var second = await installer.InstallAsync(fakeGameDir, manifestVersion: outcome.VersionNumber);
            Report(output, "reinstalling with a matching manifestVersion reports packWasUpToDate", second.PackWasUpToDate);

            var dryRun = await installer.DryRunAsync(fakeGameDir, outcome.VersionNumber);
            output.WriteLine("dry-run actions:");
            foreach (var action in dryRun)
            {
                output.WriteLine($"  - {action}");
            }
        }
        catch (Exception ex)
        {
            Report(output, "BepInEx installer", false, ex.Message);
        }
        finally
        {
            TryDelete(fakeGameDir);
        }
    }

    // MARK: - Mod manager

    private static async Task CheckModManagerAsync(TextWriter output, List<ThunderstorePackage> index)
    {
        var fakeGameDir = Path.Combine(Path.GetTempPath(), $"BifrostCheck-modmanager-game-{Guid.NewGuid()}");
        var fakeManifestPath = Path.Combine(Path.GetTempPath(), $"BifrostCheck-modmanager-manifest-{Guid.NewGuid()}.json");
        try
        {
            var modManager = new ModManager(manifestPath: fakeManifestPath);

            output.WriteLine("1) install Advize-PlantEverything (simple, no plugin deps beyond the loader):");
            var plantEverything = index.FirstOrDefault(p => p.FullName == "Advize-PlantEverything");
            if (plantEverything is null)
            {
                output.WriteLine("  SKIPPED: not found in index");
            }
            else
            {
                var resolved = await modManager.ResolveAsync(plantEverything, index);
                await modManager.InstallResolvedAsync(resolved, fakeGameDir, p => output.WriteLine($"  progress: {p.Stage} {p.FullName}"));
                var dllPresent = File.Exists(Path.Combine(fakeGameDir, "BepInEx", "plugins", "Advize-PlantEverything", "Advize_PlantEverything.dll"));
                var manifestHasIt = modManager.IsInstalled("Advize-PlantEverything");
                Report(output, "Advize-PlantEverything installed (dll on disk + manifest record)", dllPresent && manifestHasIt);
            }

            output.WriteLine();
            output.WriteLine("2) install RandyKnapp-EquipmentAndQuickSlots (depends on Jotunn + the loader):");
            var eqs = index.FirstOrDefault(p => p.FullName == "RandyKnapp-EquipmentAndQuickSlots");
            if (eqs is null)
            {
                output.WriteLine("  SKIPPED: not found in index");
            }
            else
            {
                var resolved = await modManager.ResolveAsync(eqs, index);
                var loaderCount = resolved.Count(r => r is ModManager.ResolvedInstall.Loader);
                await modManager.InstallResolvedAsync(resolved, fakeGameDir, p => output.WriteLine($"  progress: {p.Stage} {p.FullName}"));
                var jotunnInstalled = modManager.IsInstalled("ValheimModding-Jotunn");
                var eqsInstalled = modManager.IsInstalled("RandyKnapp-EquipmentAndQuickSlots");
                var loaderVersionAfter = modManager.LoaderVersion();
                var winhttpPresent = File.Exists(Path.Combine(fakeGameDir, "winhttp.dll"));
                Report(output, "loader appears at most once, Jotunn auto-resolved, EQS installed, loader recorded + files present",
                    loaderCount <= 1 && jotunnInstalled && eqsInstalled && loaderVersionAfter is not null && winhttpPresent);
            }

            output.WriteLine();
            output.WriteLine("3) setEnabled(false) then setEnabled(true) on Advize-PlantEverything:");
            if (modManager.IsInstalled("Advize-PlantEverything"))
            {
                modManager.SetEnabled("Advize-PlantEverything", false, fakeGameDir);
                var disabledPresent = File.Exists(Path.Combine(fakeGameDir, "BepInEx", "plugins", "Advize-PlantEverything", "Advize_PlantEverything.dll.disabled"));
                modManager.SetEnabled("Advize-PlantEverything", true, fakeGameDir);
                var enabledPresent = File.Exists(Path.Combine(fakeGameDir, "BepInEx", "plugins", "Advize-PlantEverything", "Advize_PlantEverything.dll"));
                Report(output, "enable/disable renames .dll <-> .dll.disabled", disabledPresent && enabledPresent);
            }
            else
            {
                output.WriteLine("  SKIPPED: PlantEverything not installed");
            }

            output.WriteLine();
            output.WriteLine("4) update-detection: force-downgrade the recorded version, expect an update to show up:");
            if (modManager.IsInstalled("Advize-PlantEverything"))
            {
                var manifest = modManager.LoadManifest();
                var mod = manifest.Mods.First(m => m.FullName == "Advize-PlantEverything");
                var realVersion = mod.Version;
                mod.Version = "0.0.1";
                File.WriteAllText(fakeManifestPath, JsonSerializer.Serialize(manifest, BifrostJson.Options));

                var updates = await modManager.UpdatesAvailableAsync(index);
                var flagged = updates.FirstOrDefault(u => u.FullName == "Advize-PlantEverything");
                Report(output, "downgraded mod is flagged as updatable", flagged is not null && flagged.LatestVersion == realVersion);

                await modManager.UpdateAsync("Advize-PlantEverything", index, fakeGameDir);
                var updatedVersion = modManager.InstalledMod("Advize-PlantEverything")?.Version;
                Report(output, "update() restores the latest version", updatedVersion == realVersion);
            }
            else
            {
                output.WriteLine("  SKIPPED: PlantEverything not installed");
            }

            output.WriteLine();
            output.WriteLine("5) uninstall Advize-PlantEverything — Jotunn/EquipmentAndQuickSlots must be untouched:");
            if (modManager.IsInstalled("Advize-PlantEverything"))
            {
                modManager.Uninstall("Advize-PlantEverything", fakeGameDir);
                var dirGone = !Directory.Exists(Path.Combine(fakeGameDir, "BepInEx", "plugins", "Advize-PlantEverything"));
                var manifestGone = !modManager.IsInstalled("Advize-PlantEverything");
                var jotunnStillInstalled = modManager.IsInstalled("ValheimModding-Jotunn");
                var jotunnFilesPresent = File.Exists(Path.Combine(fakeGameDir, "BepInEx", "plugins", "ValheimModding-Jotunn", "Jotunn.dll"));
                Report(output, "PlantEverything fully removed; Jotunn untouched",
                    dirGone && manifestGone && jotunnStillInstalled && jotunnFilesPresent);
            }
            else
            {
                output.WriteLine("  SKIPPED: PlantEverything not installed");
            }
        }
        catch (Exception ex)
        {
            Report(output, "Mod manager end-to-end", false, ex.Message);
        }
        finally
        {
            TryDelete(fakeGameDir);
            TryDeleteFile(fakeManifestPath);
        }
    }

    // MARK: - Profiles

    private static void CheckProfiles(TextWriter output)
    {
        var fakeGameDir = Path.Combine(Path.GetTempPath(), $"BifrostCheck-profiles-game-{Guid.NewGuid()}");
        var fakeManifestPath = Path.Combine(Path.GetTempPath(), $"BifrostCheck-profiles-manifest-{Guid.NewGuid()}.json");
        var fakeProfilesPath = Path.Combine(Path.GetTempPath(), $"BifrostCheck-profiles-{Guid.NewGuid()}.json");
        try
        {
            var fixtureManifest = new InstalledManifest
            {
                Loader = new InstalledManifest.LoaderInfo { Version = "5.4.2333" },
                Mods =
                {
                    new InstalledManifest.InstalledMod { FullName = "Fixture-ModA", Version = "1.0.0", Enabled = true, Files = { "BepInEx/plugins/Fixture-ModA/ModA.dll" } },
                    new InstalledManifest.InstalledMod { FullName = "Fixture-ModB", Version = "1.0.0", Enabled = true, Files = { "BepInEx/plugins/Fixture-ModB/ModB.dll" } },
                    new InstalledManifest.InstalledMod { FullName = "Fixture-ModC", Version = "1.0.0", Enabled = false, Files = { "BepInEx/plugins/Fixture-ModC/ModC.dll.disabled" } },
                },
            };
            foreach (var mod in fixtureManifest.Mods)
            {
                foreach (var relativePath in mod.Files)
                {
                    var path = Path.Combine(fakeGameDir, relativePath.Replace('/', Path.DirectorySeparatorChar));
                    Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                    File.WriteAllText(path, "dummy");
                }
            }
            Directory.CreateDirectory(Path.GetDirectoryName(fakeManifestPath)!);
            File.WriteAllText(fakeManifestPath, JsonSerializer.Serialize(fixtureManifest, BifrostJson.Options));

            var modManager = new ModManager(manifestPath: fakeManifestPath);
            var store = new ProfileStore(modManager, fakeProfilesPath);

            var migrated = store.LoadOrMigrate();
            var defaultProfile = migrated.Profiles.FirstOrDefault();
            var migrationOk = migrated.Profiles.Count == 1 && defaultProfile is not null && defaultProfile.Name == "Default" && migrated.ActiveProfileId == defaultProfile.Id && defaultProfile.Mods.Count == 3;
            Report(output, "first-run migration creates \"Default\" from current manifest state", migrationOk);
            if (defaultProfile is null)
            {
                return;
            }

            var targetProfile = new Profile
            {
                Id = Guid.NewGuid(),
                Name = "Target",
                Mods =
                {
                    new Profile.ProfileMod { FullName = "Fixture-ModA", Enabled = true },
                    new Profile.ProfileMod { FullName = "Fixture-ModC", Enabled = true },
                    new Profile.ProfileMod { FullName = "Fixture-ModD", Enabled = true },
                },
            };
            var file = new ProfilesFile { ActiveProfileId = null, Profiles = { targetProfile } };
            File.WriteAllText(fakeProfilesPath, JsonSerializer.Serialize(file, BifrostJson.Options));
            var store2 = new ProfileStore(modManager, fakeProfilesPath);

            var result = store2.Apply(targetProfile.Id, fakeGameDir);
            var missingOk = result.Missing.SequenceEqual(new[] { "Fixture-ModD" });

            var manifestAfter = modManager.LoadManifest();
            var modA = manifestAfter.Mods.First(m => m.FullName == "Fixture-ModA");
            var modB = manifestAfter.Mods.First(m => m.FullName == "Fixture-ModB");
            var modC = manifestAfter.Mods.First(m => m.FullName == "Fixture-ModC");
            var stateOk = modA.Enabled && !modB.Enabled && modC.Enabled;

            var aDllPresent = File.Exists(Path.Combine(fakeGameDir, "BepInEx", "plugins", "Fixture-ModA", "ModA.dll"));
            var bDisabledPresent = File.Exists(Path.Combine(fakeGameDir, "BepInEx", "plugins", "Fixture-ModB", "ModB.dll.disabled"));
            var cDllPresent = File.Exists(Path.Combine(fakeGameDir, "BepInEx", "plugins", "Fixture-ModC", "ModC.dll"));
            var filesOk = aDllPresent && bDisabledPresent && cDllPresent;

            var activeOk = store2.Load().ActiveProfileId == targetProfile.Id;

            Report(output, "apply(): enable / disable-not-in-profile / missing all reconcile correctly",
                missingOk && stateOk && filesOk && activeOk,
                $"missing={string.Join(",", result.Missing)} A={modA.Enabled} B={modB.Enabled} C={modC.Enabled}");

            modManager.SetEnabled("Fixture-ModA", false, fakeGameDir);
            store2.SyncActiveProfile();
            var syncedTarget = store2.Load().Profiles.First(p => p.Id == targetProfile.Id);
            var syncedMods = new HashSet<Profile.ProfileMod>(syncedTarget.Mods);
            var expected = new HashSet<Profile.ProfileMod>
            {
                new() { FullName = "Fixture-ModA", Enabled = false },
                new() { FullName = "Fixture-ModB", Enabled = false },
                new() { FullName = "Fixture-ModC", Enabled = true },
            };
            Report(output, "manual-edit sync: active profile follows a direct SetEnabled() outside apply()", syncedMods.SetEquals(expected));

            var deleteGuardOk = false;
            try { store2.Delete(targetProfile.Id); }
            catch (ProfileStore.ProfileStoreException) { deleteGuardOk = true; }
            Report(output, "delete(active profile) is refused", deleteGuardOk);
        }
        catch (Exception ex)
        {
            Report(output, "Profile reconcile", false, ex.Message);
        }
        finally
        {
            TryDelete(fakeGameDir);
            TryDeleteFile(fakeManifestPath);
            TryDeleteFile(fakeProfilesPath);
        }
    }

    // MARK: - Manifest JSON shape compatibility

    private static void CheckManifestShapeCompatibility(TextWriter output)
    {
        var realMacManifestPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "Library", "Application Support", "Bifrost", "manifest.json");

        if (!File.Exists(realMacManifestPath))
        {
            output.WriteLine($"SKIPPED: no real macOS manifest.json found at {realMacManifestPath}");
            return;
        }

        output.WriteLine($"real manifest (read-only): {realMacManifestPath}");
        try
        {
            var json = File.ReadAllText(realMacManifestPath);
            var manifest = JsonSerializer.Deserialize<InstalledManifest>(json, BifrostJson.Options);

            var loaderOk = manifest?.Loader is { Version.Length: > 0 };
            var modsOk = manifest is not null && manifest.Mods.Count > 0
                && manifest.Mods.All(m => m.FullName.Length > 0 && m.Version.Length > 0 && m.Files.Count > 0);

            Report(output, "real manifest.json deserializes into Bifrost.Core.Models.InstalledManifest with the expected shape",
                loaderOk && modsOk,
                $"loader.version={manifest?.Loader?.Version} mods={manifest?.Mods.Count}");
        }
        catch (Exception ex)
        {
            Report(output, "manifest shape compatibility", false, ex.Message);
        }
    }

    // MARK: - Config editor

    private const string RealValheimConfigDirEnvVar = "BIFROST_CHECK_REAL_VALHEIM_CONFIG_DIR";

    /// <summary>
    /// Where this Mac dev machine's own real Valheim install keeps its
    /// BepInEx <c>.cfg</c> files — used only to pull realistic, real-world
    /// fixtures for the parser round-trip sweep below. Read-only: every
    /// file under here is copied to a temp directory before anything
    /// touches it, and the originals are never written to. Not the Windows
    /// game directory <see cref="GameLocator"/> resolves — this machine has
    /// no Windows Steam install to locate; overridable via
    /// <see cref="RealValheimConfigDirEnvVar"/> for anyone running this
    /// suite against a different real Valheim install.
    /// </summary>
    private static string RealValheimConfigDir =>
        Environment.GetEnvironmentVariable(RealValheimConfigDirEnvVar)
        ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "Library", "Application Support", "Steam", "steamapps", "common", "Valheim", "BepInEx", "config");

    /// <summary>
    /// Exercises <see cref="BepInExConfig"/> — the parser/writer that backs
    /// the config editor UI — against embedded fixtures and, read-only
    /// (copied to temp first, originals never touched), every real
    /// <c>.cfg</c> file under <see cref="RealValheimConfigDir"/>. Mirrors
    /// the macOS reference implementation's <c>DebugCheck.checkConfigEditor</c>
    /// section, including its later hardening-pass additions (keyed apply,
    /// CRLF tolerance).
    /// </summary>
    private static async Task CheckConfigEditorAsync(TextWriter output)
    {
        CheckConfigRoundTripSweep(output);
        CheckCrlfRoundTrip(output);
        CheckSingleChangeDiff(output);
        CheckKeyedApplication(output);
        CheckResetToDefault(output);
        CheckAssociationHeuristic(output);
        await CheckReadmeFetchAsync(output);
    }

    /// <summary>
    /// For every real <c>.cfg</c> under <see cref="RealValheimConfigDir"/>
    /// (temp copy only): parses it, cross-checks the entry count against an
    /// independent regex baseline (<c>^[^#\[].* = </c> — any non-comment,
    /// non-section-header line containing " = ", i.e. every <c>Key = value</c>
    /// line BepInEx's own format can produce), and verifies a zero-change
    /// round trip is byte-identical. A mismatched count means the parser
    /// silently dropped (or double-counted) something real-world.
    /// </summary>
    private static void CheckConfigRoundTripSweep(TextWriter output)
    {
        var realConfigDir = RealValheimConfigDir;
        List<string> cfgFiles;
        try
        {
            cfgFiles = Directory.Exists(realConfigDir)
                ? Directory.EnumerateFiles(realConfigDir, "*.cfg").OrderBy(f => f, StringComparer.OrdinalIgnoreCase).ToList()
                : new List<string>();
        }
        catch
        {
            cfgFiles = new List<string>();
        }

        if (cfgFiles.Count == 0)
        {
            output.WriteLine($"SKIPPED: no real .cfg files found at {realConfigDir}");
            return;
        }

        var tempDir = Path.Combine(Path.GetTempPath(), $"BifrostCheck-configsweep-{Guid.NewGuid()}");
        Directory.CreateDirectory(tempDir);
        try
        {
            var allPassed = true;
            foreach (var realPath in cfgFiles)
            {
                var fileName = Path.GetFileName(realPath);
                string originalText;
                try
                {
                    originalText = File.ReadAllText(realPath);
                }
                catch (Exception ex)
                {
                    output.WriteLine($"  {fileName}: FAILED to read real file: {ex.Message}");
                    allPassed = false;
                    continue;
                }

                // Read-only against the real file — write a temp copy and
                // never touch the original again.
                File.WriteAllText(Path.Combine(tempDir, fileName), originalText);

                var parsed = BepInExConfig.Parse(originalText);
                var entryCount = parsed.AllEntries.Count();
                // Line-by-line (like `grep`, which never sees other lines'
                // bytes while matching one) rather than one Regex.Matches
                // pass over the whole multiline text: a negated character
                // class like [^#\[] matches ANY character not in that set —
                // including '\n' — so applying it across the whole text
                // with RegexOptions.Multiline lets a match that starts on
                // an empty line "swallow" that line's newline and continue
                // matching into the next line's content, silently
                // inflating the count whenever a blank line precedes a
                // comment that happens to contain " = " (e.g. a
                // description line like "Higher number = more to the
                // right"). Matching one line at a time sidesteps that
                // entirely, since there's no adjacent line for the pattern
                // to bleed into.
                var baselineCount = originalText.Split('\n').Count(line => Regex.IsMatch(line, @"^[^#\[].* = "));

                var roundTripped = BepInExConfig.Applying(new Dictionary<int, string>(), originalText);
                var roundTripOk = roundTripped == originalText;
                var countOk = baselineCount == entryCount;
                var filePass = countOk && roundTripOk;
                allPassed &= filePass;

                output.WriteLine($"  {fileName}: parsed={entryCount} baseline={baselineCount} round-trip-identical={roundTripOk} -> {(filePass ? "PASS" : "FAIL")}");
            }
            Report(output, $"real .cfg round-trip sweep ({cfgFiles.Count} file(s), read-only source, temp copies only)", allPassed);
        }
        finally
        {
            TryDelete(tempDir);
        }
    }

    /// <summary>
    /// None of this developer's real <c>.cfg</c> files use CRLF line
    /// endings, but Windows' own are routinely CRLF, and <c>Parse</c>
    /// splits on <c>'\n'</c> alone — which would leave a dangling
    /// <c>'\r'</c> on every line if trimming didn't strip it, corrupting
    /// section names, keys, and values alike (exactly the bug the macOS
    /// port's own hardening pass had to fix). Embedded fixture, since a
    /// real CRLF file isn't available on this machine to test against.
    /// </summary>
    private static void CheckCrlfRoundTrip(TextWriter output)
    {
        const string crlfText = "[General]\r\n\r\n## A CRLF-terminated description.\r\n# Setting type: Boolean\r\n# Default value: false\r\nEnabled = true\r\n";
        var parsed = BepInExConfig.Parse(crlfText);
        var entry = parsed.AllEntries.FirstOrDefault(e => e.Key == "Enabled");

        var sectionOk = parsed.Sections.FirstOrDefault()?.Name == "General";
        var keyOk = entry?.Key == "Enabled";
        var valueOk = entry?.RawValue == "true";
        var boolValueOk = entry?.BoolValue == true;
        var descriptionOk = entry?.Description == "A CRLF-terminated description.";
        Report(output, "CRLF fixture: section/key/value/boolValue/description survive a CRLF split with no stray \\r",
            sectionOk && keyOk && valueOk && boolValueOk && descriptionOk,
            $"section={parsed.Sections.FirstOrDefault()?.Name} key={entry?.Key} value={entry?.RawValue} boolValue={entry?.BoolValue} description={entry?.Description}");

        var noOpRoundTrip = BepInExConfig.Applying(new Dictionary<int, string>(), crlfText);
        Report(output, "CRLF fixture: byte-identical no-op round trip (line endings preserved)", noOpRoundTrip == crlfText);
    }

    /// <summary>Changing one entry's value and reapplying must produce exactly one changed line, leave every other entry untouched, and reread back correctly.</summary>
    private static void CheckSingleChangeDiff(TextWriter output)
    {
        const string originalText = "[General]\n\n## The field of view to use.\n# Setting type: Single\n# Default value: 65\nDefault FOV = 65\n\nUnrelated = untouched\n";
        var parsed = BepInExConfig.Parse(originalText);
        var fovEntry = parsed.AllEntries.FirstOrDefault(e => e.Key == "Default FOV");
        if (fovEntry is null)
        {
            Report(output, "single-change diff fixture parses \"Default FOV\"", false);
            return;
        }

        var changedText = BepInExConfig.Applying(new Dictionary<int, string> { [fovEntry.LineIndex] = "75" }, originalText);
        var changedLines = CountChangedLines(originalText, changedText);
        var reparsed = BepInExConfig.Parse(changedText);
        var rereadValue = reparsed.AllEntries.FirstOrDefault(e => e.Key == "Default FOV")?.RawValue;
        var otherEntriesUntouched = reparsed.AllEntries.Where(e => e.Key != "Default FOV")
            .SequenceEqual(parsed.AllEntries.Where(e => e.Key != "Default FOV"));

        Report(output, "change one value: exactly 1 changed line, reread matches, everything else untouched",
            changedLines == 1 && rereadValue == "75" && otherEntriesUntouched,
            $"changedLines={changedLines} reread={rereadValue}");
    }

    /// <summary>
    /// Exercises <c>BepInExConfig.Applying(IReadOnlyList&lt;KeyedChange&gt;, string)</c>
    /// — the fix for the stale-write race where a mod rewrites its
    /// <c>.cfg</c> on game exit between when the editor read the file and
    /// when the user hits Save. Simulates that exact sequence: the editor
    /// opens <c>originalText</c>, the user edits one setting, then — before
    /// they save — an external rewrite (a) changes an unrelated setting's
    /// value, (b) inserts a brand-new setting that didn't exist when the
    /// editor opened (so line indices no longer line up at all), and (c)
    /// removes a setting the user never touched but a stale second edit
    /// still references. Asserts: the user's edit lands, both external
    /// changes survive untouched, and the edit targeting the now-vanished
    /// setting is reported as skipped rather than silently dropped or
    /// crashing.
    /// </summary>
    private static void CheckKeyedApplication(TextWriter output)
    {
        const string originalText = """
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
            """;

        const string externallyRewrittenText = """
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
            """;

        var parsedOriginal = BepInExConfig.Parse(originalText);
        var fovEntry = parsedOriginal.AllEntries.FirstOrDefault(e => e.Key == "Default FOV");
        if (fovEntry is null)
        {
            Report(output, "keyed-apply fixture parses \"Default FOV\"", false);
            return;
        }

        var userEdits = new List<BepInExConfig.KeyedChange>
        {
            new(fovEntry.Section, fovEntry.Key, "90"),
            new("Other", "Temporary", "true"),
        };

        var result = BepInExConfig.Applying(userEdits, externallyRewrittenText);

        var userEditLanded = result.Text.Contains("Default FOV = 90");
        var externalValueChangeSurvived = result.Text.Contains("Enabled = true");
        var externalInsertionSurvived = result.Text.Contains("New Toggle = true");
        var vanishedKeyNotWritten = !result.Text.Contains("Temporary");
        var skippedReportedCorrectly = result.Skipped.SequenceEqual(new[] { new BepInExConfig.KeyedChange("Other", "Temporary", "true") });
        var reparsed = BepInExConfig.Parse(result.Text);
        var otherEntriesUntouched = reparsed.AllEntries.Where(e => e.Key != "Default FOV")
            .SequenceEqual(BepInExConfig.Parse(externallyRewrittenText).AllEntries.Where(e => e.Key != "Default FOV"));

        Report(output, "keyed apply onto an externally-rewritten copy: user edit lands, external changes survive, vanished key skipped and reported",
            userEditLanded && externalValueChangeSurvived && externalInsertionSurvived && vanishedKeyNotWritten && skippedReportedCorrectly && otherEntriesUntouched,
            $"landed={userEditLanded} externalValue={externalValueChangeSurvived} externalInsert={externalInsertionSurvived} vanishedSkipped={vanishedKeyNotWritten} skipped=[{string.Join(",", result.Skipped.Select(s => $"{s.Section}/{s.Key}"))}] otherUntouched={otherEntriesUntouched}");
    }

    /// <summary>
    /// The config editor's "Reset to Default" button just writes an
    /// entry's own <c>DefaultValue</c> back via <c>BepInExConfig.Applying</c>
    /// — exercised here against a small embedded fixture (not this
    /// machine's real file, whose current value is whatever this developer
    /// has it set to right now).
    /// </summary>
    private static void CheckResetToDefault(TextWriter output)
    {
        const string fixtureConfigText = """
            [General]

            ## The field of view to use while first person mode is active.
            # Setting type: Single
            # Default value: 65
            Default FOV = 100
            """;

        var parsed = BepInExConfig.Parse(fixtureConfigText);
        var fovEntry = parsed.AllEntries.FirstOrDefault(e => e.Key == "Default FOV");
        if (fovEntry is null)
        {
            Report(output, "reset-to-default fixture parses \"Default FOV\"", false);
            return;
        }

        var startsChanged = fovEntry.DefaultValue == "65" && fovEntry.RawValue == "100" && fovEntry.RawValue != fovEntry.DefaultValue;
        var afterResetText = BepInExConfig.Applying(new Dictionary<int, string> { [fovEntry.LineIndex] = fovEntry.DefaultValue! }, fixtureConfigText);
        var afterResetValue = BepInExConfig.Parse(afterResetText).AllEntries.FirstOrDefault(e => e.Key == "Default FOV")?.RawValue;

        Report(output, "reset-to-default: writing the entry's own DefaultValue back restores it",
            startsChanged && afterResetValue == fovEntry.DefaultValue,
            $"default={fovEntry.DefaultValue} before={fovEntry.RawValue} after={afterResetValue}");
    }

    /// <summary>Filename/mod association heuristic, plus discovery against the real config dir (read-only).</summary>
    private static void CheckAssociationHeuristic(TextWriter output)
    {
        var candidates = new List<(string FullName, string Name)> { ("Azumatt-FirstPersonMode", "First Person Mode") };
        var matched = BepInExConfig.Associate("Azumatt.FirstPersonMode.cfg", candidates);
        var unmatched = BepInExConfig.Associate("BepInEx.cfg", candidates);
        Report(output, "association heuristic: filename matches FullName/Name, unrelated filename doesn't",
            matched == "Azumatt-FirstPersonMode" && unmatched is null,
            $"\"Azumatt.FirstPersonMode.cfg\" -> {matched ?? "null"}, \"BepInEx.cfg\" -> {unmatched ?? "null"}");

        var realConfigDir = RealValheimConfigDir;
        if (!Directory.Exists(realConfigDir))
        {
            output.WriteLine($"SKIPPED discoverConfigs (read-only) — no real config dir at {realConfigDir}");
            return;
        }
        var discovered = BepInExConfig.DiscoverConfigs(realConfigDir, candidates);
        var discoveredOk = discovered.Any(c => c.FileName == "Azumatt.FirstPersonMode.cfg" && c.AssociatedFullName == "Azumatt-FirstPersonMode")
            && discovered.Any(c => c.FileName == "BepInEx.cfg" && c.AssociatedFullName is null);
        Report(output, "discoverConfigs against the real config dir (read-only) associates the known file and leaves BepInEx.cfg unmatched", discoveredOk,
            string.Join(", ", discovered.Select(c => $"{c.FileName}->{c.AssociatedFullName ?? "(unmatched)"}")));
    }

    /// <summary>
    /// Fetches the loader pack's current version from Thunderstore's
    /// package metadata endpoint, then its README from the experimental
    /// <c>{owner}/{name}/{version}/readme/</c> endpoint — never a
    /// hardcoded version, so this keeps working as the pack updates. Best
    /// effort: skips gracefully rather than failing when offline.
    /// </summary>
    private static async Task CheckReadmeFetchAsync(TextWriter output)
    {
        try
        {
            const string metadataUrl = "https://thunderstore.io/api/experimental/package/denikson/BepInExPack_Valheim/";
            using var http = new HttpClient();
            var metaResponse = await http.GetAsync(metadataUrl);
            if (!metaResponse.IsSuccessStatusCode)
            {
                output.WriteLine("SKIPPED: could not fetch package metadata (offline or API unavailable)");
                return;
            }
            var metaJson = await metaResponse.Content.ReadAsStringAsync();
            using var metaDoc = JsonDocument.Parse(metaJson);
            var versionNumber = metaDoc.RootElement.GetProperty("latest").GetProperty("version_number").GetString();
            if (string.IsNullOrEmpty(versionNumber))
            {
                output.WriteLine("SKIPPED: could not read latest version number from package metadata");
                return;
            }

            var client = new ThunderstoreClient();
            var markdown = await client.FetchReadmeAsync("denikson", "BepInExPack_Valheim", versionNumber);
            Report(output, $"live README fetch: denikson-BepInExPack_Valheim@{versionNumber} returns non-empty markdown", markdown.Length > 0, $"length={markdown.Length}");
        }
        catch (Exception ex)
        {
            output.WriteLine($"SKIPPED: {ex.Message} (likely offline)");
        }
    }

    // MARK: - Install from file

    /// <summary>
    /// Exercises <see cref="ModManager.InstallFromFileAsync"/> against
    /// in-memory-built fixture archives (never a real download): a
    /// Thunderstore-shaped zip carrying its own manifest.json (identity
    /// derived from it), a flat zip with a bare .dll at its root (identity
    /// derived from the file name), a bare standalone .dll, name-collision
    /// refusal vs. replaceExisting, and that a "local" source is excluded
    /// from <see cref="ModManager.UpdatesAvailableAsync"/>.
    /// </summary>
    private static async Task CheckInstallFromFileAsync(TextWriter output)
    {
        var fakeGameDir = Path.Combine(Path.GetTempPath(), $"BifrostCheck-installfromfile-game-{Guid.NewGuid()}");
        var fakeManifestPath = Path.Combine(Path.GetTempPath(), $"BifrostCheck-installfromfile-manifest-{Guid.NewGuid()}.json");
        var fixturesDir = Path.Combine(Path.GetTempPath(), $"BifrostCheck-installfromfile-fixtures-{Guid.NewGuid()}");
        try
        {
            Directory.CreateDirectory(fixturesDir);
            var modManager = new ModManager(manifestPath: fakeManifestPath);

            output.WriteLine("1) zip with a bundled manifest.json (author+name+version) -> identity derived from it:");
            var manifestZipPath = Path.Combine(fixturesDir, "FancyMod.zip");
            BuildZipFixture(manifestZipPath, new Dictionary<string, string>
            {
                ["manifest.json"] = """{"name":"Fancy Mod","version_number":"2.1.0","author":"Some Author"}""",
                ["icon.png"] = "not-a-real-png",
                ["FancyMod.dll"] = "dummy-dll-bytes",
            });
            var installedFullName = await modManager.InstallFromFileAsync(manifestZipPath, fakeGameDir);
            var expectedFullName = "Some-Author-Fancy-Mod";
            var dllPresent = File.Exists(Path.Combine(fakeGameDir, "BepInEx", "plugins", expectedFullName, "FancyMod.dll"));
            var recorded = modManager.InstalledMod(expectedFullName);
            Report(output, "manifest.json identity (\"Some-Author-Fancy-Mod\" @ 2.1.0), dll copied, source=local",
                installedFullName == expectedFullName && dllPresent && recorded is { Version: "2.1.0", Source: "local" },
                $"installed={installedFullName} version={recorded?.Version} source={recorded?.Source}");

            output.WriteLine();
            output.WriteLine("2) flat zip with no manifest.json -> identity derived from the file name:");
            var flatZipPath = Path.Combine(fixturesDir, "PlainZipMod.zip");
            BuildZipFixture(flatZipPath, new Dictionary<string, string> { ["PlainZipMod.dll"] = "dummy" });
            var flatInstalled = await modManager.InstallFromFileAsync(flatZipPath, fakeGameDir);
            var flatDllPresent = File.Exists(Path.Combine(fakeGameDir, "BepInEx", "plugins", "Local-PlainZipMod", "PlainZipMod.dll"));
            Report(output, "no-manifest zip -> \"Local-PlainZipMod\", version 0.0.0-local",
                flatInstalled == "Local-PlainZipMod" && flatDllPresent && modManager.InstalledMod("Local-PlainZipMod")?.Version == "0.0.0-local");

            output.WriteLine();
            output.WriteLine("3) bare standalone .dll -> identity derived from the file's own name:");
            var bareDllPath = Path.Combine(fixturesDir, "StandaloneThing.dll");
            File.WriteAllText(bareDllPath, "dummy-dll-bytes");
            var dllInstalled = await modManager.InstallFromFileAsync(bareDllPath, fakeGameDir);
            var bareDllPresent = File.Exists(Path.Combine(fakeGameDir, "BepInEx", "plugins", "Local-StandaloneThing", "StandaloneThing.dll"));
            Report(output, "bare .dll -> \"Local-StandaloneThing\", copied as-is", dllInstalled == "Local-StandaloneThing" && bareDllPresent);

            output.WriteLine();
            output.WriteLine("4) re-installing the same manifest zip without replaceExisting -> NameCollisionException; with replaceExisting -> succeeds:");
            var collisionThrown = false;
            try { await modManager.InstallFromFileAsync(manifestZipPath, fakeGameDir); }
            catch (ModManager.NameCollisionException ex) { collisionThrown = ex.FullName == expectedFullName; }
            var replaced = await modManager.InstallFromFileAsync(manifestZipPath, fakeGameDir, replaceExisting: true);
            Report(output, "collision refused by default, succeeds with replaceExisting: true",
                collisionThrown && replaced == expectedFullName);

            output.WriteLine();
            output.WriteLine("5) local-sourced mods are excluded from UpdatesAvailable even if the index happens to carry a matching FullName:");
            var fakePackage = new ThunderstorePackage
            {
                Name = "Fancy Mod",
                FullName = expectedFullName,
                Owner = "Some Author",
                Versions = new List<ThunderstorePackage.Version>
                {
                    new() { VersionNumber = "9.9.9", DownloadUrl = "https://example.invalid/x.zip", Dependencies = new List<string>() },
                },
            };
            var updates = await modManager.UpdatesAvailableAsync(new List<ThunderstorePackage> { fakePackage });
            Report(output, "local mod never flagged as updatable even though the index has a newer \"latest\" for the same FullName",
                updates.All(u => u.FullName != expectedFullName));

            output.WriteLine();
            output.WriteLine("6) unsupported file extension is rejected:");
            var unsupportedPath = Path.Combine(fixturesDir, "notes.txt");
            File.WriteAllText(unsupportedPath, "hi");
            var rejectedUnsupported = false;
            try { await modManager.InstallFromFileAsync(unsupportedPath, fakeGameDir); }
            catch (ModManager.ModManagerException) { rejectedUnsupported = true; }
            Report(output, "a .txt file is rejected as unsupported", rejectedUnsupported);
        }
        catch (Exception ex)
        {
            Report(output, "Install from file", false, ex.Message);
        }
        finally
        {
            TryDelete(fakeGameDir);
            TryDelete(fixturesDir);
            TryDeleteFile(fakeManifestPath);
        }
    }

    private static void BuildZipFixture(string zipPath, Dictionary<string, string> entries)
    {
        using var stream = new FileStream(zipPath, FileMode.Create);
        using var archive = new System.IO.Compression.ZipArchive(stream, System.IO.Compression.ZipArchiveMode.Create);
        foreach (var (name, content) in entries)
        {
            var entry = archive.CreateEntry(name);
            using var writer = new StreamWriter(entry.Open());
            writer.Write(content);
        }
    }

    // MARK: - Save backups

    /// <summary>
    /// Exercises <see cref="SaveBackup"/> end to end against throwaway TEMP
    /// fixtures: archive contents, pruning down to
    /// <see cref="SaveBackup.AutoRetentionCount"/> while manual backups
    /// survive, a restore that reproduces files byte-identically (merging
    /// rather than wiping the target) plus its own pre-restore safety zip,
    /// and the running-game refusal via the injectable <c>isGameRunning</c>
    /// closure.
    /// </summary>
    private static void CheckSaveBackups(TextWriter output)
    {
        var fixtureSaveDir = Path.Combine(Path.GetTempPath(), $"BifrostCheck-savebackup-savedir-{Guid.NewGuid()}");
        var fixtureBackupsDir = Path.Combine(Path.GetTempPath(), $"BifrostCheck-savebackup-backupsdir-{Guid.NewGuid()}");
        var restoreTargetDir = Path.Combine(Path.GetTempPath(), $"BifrostCheck-savebackup-restoretarget-{Guid.NewGuid()}");
        try
        {
            var worldDb = Path.Combine(fixtureSaveDir, "worlds_local", "World1.db");
            var worldFwl = Path.Combine(fixtureSaveDir, "worlds_local", "World1.fwl");
            var characterFch = Path.Combine(fixtureSaveDir, "characters_local", "Hero1.fch");
            foreach (var path in new[] { worldDb, worldFwl, characterFch })
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            }
            File.WriteAllText(worldDb, "world1-db-content");
            File.WriteAllText(worldFwl, "world1-fwl-content");
            File.WriteAllText(characterFch, "hero1-fch-content");

            var backup = new SaveBackup(fixtureSaveDir, fixtureBackupsDir);

            output.WriteLine("1) BackupNow(\"manual\") — creates a zip with the expected entries:");
            SaveBackup.Backup? manualBackup = null;
            {
                var outcome = backup.BackupNow(SaveBackup.ManualReason);
                if (outcome is not SaveBackup.BackupOutcome.Created created)
                {
                    Report(output, "BackupNow(\"manual\") returns .Created", false, outcome.GetType().Name);
                }
                else
                {
                    var fileCountOk = created.Summary.FileCount == 3;
                    var sizeOk = created.Summary.ByteSize > 0;
                    using var archive = System.IO.Compression.ZipFile.OpenRead(created.Summary.Path);
                    var entries = archive.Entries.Select(e => e.FullName.Replace('\\', '/')).ToHashSet();
                    var expectedEntries = new[] { "worlds_local/World1.db", "worlds_local/World1.fwl", "characters_local/Hero1.fch" };
                    var entriesOk = expectedEntries.All(entries.Contains);
                    manualBackup = backup.List().FirstOrDefault(b => b.Reason == SaveBackup.ManualReason);
                    Report(output, "manual backup: 3 files, non-zero size, expected zip entries present",
                        fileCountOk && sizeOk && entriesOk && manualBackup is not null,
                        $"fileCount={created.Summary.FileCount} byteSize={created.Summary.ByteSize} entries=[{string.Join(",", entries.OrderBy(e => e))}]");
                }
            }
            if (manualBackup is null)
            {
                output.WriteLine("ABORT: no manual backup to continue from");
                return;
            }

            output.WriteLine();
            output.WriteLine($"2) pruning — 17 automatic backups collapse to {SaveBackup.AutoRetentionCount}, manual survives:");
            for (var i = 0; i < 17; i++)
            {
                backup.BackupNow($"auto-{i}");
            }
            var afterPruning = backup.List();
            var automaticCount = afterPruning.Count(b => b.Reason != SaveBackup.ManualReason);
            var manualCount = afterPruning.Count(b => b.Reason == SaveBackup.ManualReason);
            var physicalCount = Directory.EnumerateFiles(fixtureBackupsDir).Count();
            var pruningOk = automaticCount == SaveBackup.AutoRetentionCount && manualCount == 1 && physicalCount == afterPruning.Count;
            Report(output, $"automatic={automaticCount} (expect {SaveBackup.AutoRetentionCount}), manual={manualCount} (expect 1), files-on-disk={physicalCount}", pruningOk);

            output.WriteLine();
            output.WriteLine("3) restore into a second temp dir — byte-identical files, merges rather than wipes, + a pre-restore safety zip:");
            var oldWorld = Path.Combine(restoreTargetDir, "worlds_local", "OldWorld.db");
            var oldCharacter = Path.Combine(restoreTargetDir, "characters_local", "OldHero.fch");
            var restoreOk = false;
            try
            {
                foreach (var path in new[] { oldWorld, oldCharacter })
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                }
                File.WriteAllText(oldWorld, "old-world-content");
                File.WriteAllText(oldCharacter, "old-hero-content");

                var preRestoreCountBefore = backup.List().Count(b => b.Reason == "pre-restore");
                var summary = backup.Restore(manualBackup, restoreTargetDir, isGameRunning: () => false);

                var restoredWorldDbOk = File.ReadAllText(Path.Combine(restoreTargetDir, "worlds_local", "World1.db")) == "world1-db-content";
                var restoredWorldFwlOk = File.ReadAllText(Path.Combine(restoreTargetDir, "worlds_local", "World1.fwl")) == "world1-fwl-content";
                var restoredCharacterOk = File.ReadAllText(Path.Combine(restoreTargetDir, "characters_local", "Hero1.fch")) == "hero1-fch-content";
                var oldFilesUntouched = File.Exists(oldWorld) && File.Exists(oldCharacter);
                var preRestoreCountAfter = backup.List().Count(b => b.Reason == "pre-restore");
                var safetyBackupCreated = preRestoreCountAfter == preRestoreCountBefore + 1;
                var fileCountOk = summary.FileCount == 5; // World1.db + World1.fwl + OldWorld.db + Hero1.fch + OldHero.fch

                restoreOk = restoredWorldDbOk && restoredWorldFwlOk && restoredCharacterOk && oldFilesUntouched && safetyBackupCreated && fileCountOk;
                output.WriteLine($"  byte-identical: db={restoredWorldDbOk} fwl={restoredWorldFwlOk} fch={restoredCharacterOk}; old files untouched (merge): {oldFilesUntouched}");
                output.WriteLine($"  pre-restore safety zip created: {safetyBackupCreated} (count {preRestoreCountBefore} -> {preRestoreCountAfter}); reported fileCount={summary.FileCount} (expect 5)");
                Report(output, "restore merges byte-identical files and takes a pre-restore safety backup", restoreOk);
            }
            catch (Exception ex)
            {
                Report(output, "restore()", false, ex.Message);
            }

            output.WriteLine();
            output.WriteLine("4) running-game refusal:");
            var refusalOk = false;
            try
            {
                backup.Restore(manualBackup, restoreTargetDir, isGameRunning: () => true);
            }
            catch (SaveBackup.GameRunningException)
            {
                refusalOk = true;
            }
            catch (Exception ex)
            {
                output.WriteLine($"  unexpected exception: {ex.Message}");
            }
            Report(output, "restore() with isGameRunning:true is refused with GameRunningException", refusalOk);

            output.WriteLine();
            output.WriteLine("5) filename <-> (date, reason) round trip:");
            var parsed = SaveBackup.ParseFilename(Path.GetFileName(manualBackup.Path));
            Report(output, "ParseFilename round-trips the manual backup's own filename",
                parsed is { Reason: SaveBackup.ManualReason });

            output.WriteLine();
            output.WriteLine("6) (read-only) real Valheim save dir (never written to by this check):");
            output.WriteLine($"  {BifrostPaths.ValheimSaveDir} exists={Directory.Exists(BifrostPaths.ValheimSaveDir)}");
        }
        catch (Exception ex)
        {
            Report(output, "Save backups", false, ex.Message);
        }
        finally
        {
            TryDelete(fixtureSaveDir);
            TryDelete(fixtureBackupsDir);
            TryDelete(restoreTargetDir);
        }
    }

    // MARK: - Game update detection

    /// <summary>
    /// Exercises <see cref="GameUpdateWatcher.Check"/> against a throwaway
    /// TEMP fixture (a fake &lt;root&gt;/steamapps/common/FakeGame game dir
    /// alongside a fake appmanifest_892970.acf) and an injectable
    /// last-seen-buildid file path (never the real persisted one): first-seen,
    /// unchanged, changed (message correct), and a same-run re-check proving
    /// persistence.
    /// </summary>
    private static void CheckGameUpdateWatcher(TextWriter output)
    {
        var root = Path.Combine(Path.GetTempPath(), $"BifrostCheck-gameupdate-{Guid.NewGuid()}");
        var gameDir = Path.Combine(root, "steamapps", "common", "FakeGame");
        var steamappsDir = Path.Combine(root, "steamapps");
        var manifestPath = Path.Combine(steamappsDir, $"appmanifest_{GameLocator.ValheimAppId}.acf");
        var lastSeenPath = Path.Combine(Path.GetTempPath(), $"BifrostCheck-gameupdate-lastseen-{Guid.NewGuid()}.txt");
        try
        {
            void WriteManifest(string buildId)
            {
                Directory.CreateDirectory(steamappsDir);
                Directory.CreateDirectory(gameDir);
                File.WriteAllText(manifestPath, $"\"AppState\"\n{{\n\t\"appid\"\t\t\"892970\"\n\t\"buildid\"\t\t\"{buildId}\"\n\t\"SizeOnDisk\"\t\t\"12345678\"\n}}\n");
            }

            output.WriteLine("1) firstSeen / unchanged / updated, persisted to a throwaway file:");
            WriteManifest("100");

            var first = GameUpdateWatcher.Check(gameDir, lastSeenPath);
            var firstOk = first is { Kind: GameUpdateWatcher.ResultKind.FirstSeen, CurrentBuildId: "100" };
            Report(output, "first check (no prior record) -> FirstSeen(100)", firstOk);

            var second = GameUpdateWatcher.Check(gameDir, lastSeenPath);
            var secondOk = second is { Kind: GameUpdateWatcher.ResultKind.Unchanged, CurrentBuildId: "100" };
            Report(output, "second check (same buildid) -> Unchanged(100)", secondOk);

            WriteManifest("200");
            var third = GameUpdateWatcher.Check(gameDir, lastSeenPath);
            var thirdOk = third is { Kind: GameUpdateWatcher.ResultKind.Updated, PreviousBuildId: "100", CurrentBuildId: "200" };
            Report(output, "third check (buildid changed) -> Updated(100 -> 200)", thirdOk, third.Message);

            output.WriteLine();
            output.WriteLine("2) persistence round-trip — a later check sees 200 as the baseline, not FirstSeen again:");
            var fourth = GameUpdateWatcher.Check(gameDir, lastSeenPath);
            var fourthOk = fourth is { Kind: GameUpdateWatcher.ResultKind.Unchanged, CurrentBuildId: "200" };
            Report(output, "fourth check -> Unchanged(200)", fourthOk);

            output.WriteLine();
            output.WriteLine("3) missing game dir / missing manifest -> Unavailable:");
            var unavailableNullDir = GameUpdateWatcher.Check(null, lastSeenPath);
            var unavailableNoManifest = GameUpdateWatcher.Check(Path.Combine(Path.GetTempPath(), "nonexistent-" + Guid.NewGuid()), lastSeenPath);
            Report(output, "null gameDir and a gameDir with no manifest both report Unavailable",
                unavailableNullDir.Kind == GameUpdateWatcher.ResultKind.Unavailable && unavailableNoManifest.Kind == GameUpdateWatcher.ResultKind.Unavailable);
        }
        catch (Exception ex)
        {
            Report(output, "Game update detection", false, ex.Message);
        }
        finally
        {
            TryDelete(root);
            TryDeleteFile(lastSeenPath);
        }
    }

    // MARK: - Update All

    /// <summary>
    /// Exercises <see cref="UpdateAllRunner.RunAsync"/> aggregation: three
    /// mods, the middle one's updater throws — the other two must still run
    /// and the summary must report 2 succeeded / 1 failed with the right
    /// failure message, never abort the batch.
    /// </summary>
    private static async Task CheckUpdateAllRunnerAsync(TextWriter output)
    {
        var progressSeen = new List<string>();
        var summary = await UpdateAllRunner.RunAsync(
            new List<string> { "Fixture-ModA", "Fixture-ModB", "Fixture-ModC" },
            updater: fullName =>
            {
                if (fullName == "Fixture-ModB")
                {
                    throw new InvalidOperationException("simulated failure");
                }
                return Task.CompletedTask;
            },
            onProgress: fullName => progressSeen.Add(fullName));

        var progressOk = progressSeen.SequenceEqual(new[] { "Fixture-ModA", "Fixture-ModB", "Fixture-ModC" });
        var countsOk = summary.SucceededCount == 2 && summary.FailedCount == 1;
        var failureOk = summary.Failures is [("Fixture-ModB", "simulated failure")];
        Report(output, "all 3 mods attempted in order (one failure doesn't abort the batch), 2 succeeded / 1 failed with the right message",
            progressOk && countsOk && failureOk,
            $"progress=[{string.Join(",", progressSeen)}] succeeded={summary.SucceededCount} failed={summary.FailedCount} failures=[{string.Join(",", summary.Failures.Select(f => $"{f.FullName}:{f.Message}"))}]");
    }

    // MARK: - Index auto-refresh

    private static void CheckIndexAutoRefresher(TextWriter output)
    {
        var fixturePath = Path.Combine(Path.GetTempPath(), $"BifrostCheck-indexautorefresh-{Guid.NewGuid()}.json");
        try
        {
            var missingIsStale = IndexAutoRefresher.IsStale(fixturePath);
            Report(output, "a missing cache file is always stale", missingIsStale);

            File.WriteAllText(fixturePath, "{}");
            var freshNotStale = !IndexAutoRefresher.IsStale(fixturePath, now: DateTime.UtcNow);
            Report(output, "a just-written cache file is not stale", freshNotStale);

            var staleWhenOld = IndexAutoRefresher.IsStale(fixturePath, now: DateTime.UtcNow + IndexAutoRefresher.StaleAfter + TimeSpan.FromMinutes(1));
            Report(output, "a cache file older than StaleAfter (simulated via `now`) is stale", staleWhenOld);
        }
        finally
        {
            TryDeleteFile(fixturePath);
        }
    }

    // MARK: - Launcher / silent Steam

    private static void CheckLauncherSilentSteam(TextWriter output)
    {
        for (var modded = true; ; modded = false)
        {
            output.WriteLine($"Plan(modded: {modded}):");
            foreach (var step in Launcher.Plan(modded, @"C:\Games\Valheim"))
            {
                output.WriteLine($"  - {step.Description}");
            }
            if (!modded)
            {
                break;
            }
        }

        Report(output, "Plan(modded: true) mentions the pre-launch backup and the silent-Steam step by default",
            Launcher.Plan(true, @"C:\Games\Valheim").Any(s => s.Description.Contains("back up", StringComparison.OrdinalIgnoreCase))
            && Launcher.Plan(true, @"C:\Games\Valheim").Any(s => s.Description.Contains("-silent", StringComparison.Ordinal)));

        Report(output, "Plan(..., backupSavesBeforeModdedLaunch: false) omits the backup step",
            !Launcher.Plan(true, @"C:\Games\Valheim", backupSavesBeforeModdedLaunch: false).Any(s => s.Description.Contains("back up", StringComparison.OrdinalIgnoreCase)));

        Report(output, "Plan(..., startSteamSilently: false) omits the -silent mention",
            !Launcher.Plan(true, @"C:\Games\Valheim", startSteamSilently: false).Any(s => s.Description.Contains("-silent", StringComparison.Ordinal)));

        // Pure argument/path-construction checks — never spawns steam.exe.
        Report(output, "SteamSilentArgument is \"-silent\"", Launcher.SteamSilentArgument == "-silent");

        var fakeSteamRoot = Path.Combine(Path.GetTempPath(), $"BifrostCheck-steamexe-{Guid.NewGuid()}");
        try
        {
            Directory.CreateDirectory(fakeSteamRoot);
            var missing = Launcher.FindSteamExecutable(fakeSteamRoot);
            Report(output, "FindSteamExecutable returns null when steam.exe isn't present", missing is null);

            File.WriteAllText(Path.Combine(fakeSteamRoot, "steam.exe"), "dummy");
            var found = Launcher.FindSteamExecutable(fakeSteamRoot);
            Report(output, "FindSteamExecutable finds steam.exe under the given root", found == Path.Combine(fakeSteamRoot, "steam.exe"));
        }
        finally
        {
            TryDelete(fakeSteamRoot);
        }

        output.WriteLine();
        output.WriteLine("SKIPPED: live EnsureSteamRunningAsync (actually starting steam.exe) — Windows-only mechanism, needs a real Windows box to verify.");
    }

    // MARK: - App settings store

    private static void CheckAppSettingsStore(TextWriter output)
    {
        var fixturePath = Path.Combine(Path.GetTempPath(), $"BifrostCheck-settings-{Guid.NewGuid()}.json");
        try
        {
            var store = new AppSettingsStore(fixturePath);
            var defaults = store.Load();
            Report(output, "missing settings.json loads defaults (every toggle on)",
                defaults is { StartSteamSilently: true, BackupSavesBeforeModdedLaunch: true, ShowTrayIcon: true });

            defaults.StartSteamSilently = false;
            defaults.ShowTrayIcon = false;
            store.Save(defaults);
            var reloaded = new AppSettingsStore(fixturePath).Load();
            Report(output, "round trip preserves changed values", reloaded is { StartSteamSilently: false, BackupSavesBeforeModdedLaunch: true, ShowTrayIcon: false });

            File.WriteAllText(fixturePath, "{ not valid json");
            var corrupt = new AppSettingsStore(fixturePath).Load();
            Report(output, "corrupt settings.json falls back to defaults rather than throwing",
                corrupt is { StartSteamSilently: true, BackupSavesBeforeModdedLaunch: true, ShowTrayIcon: true });
        }
        finally
        {
            TryDeleteFile(fixturePath);
        }
    }

    // MARK: - Nexus Mods: nxm:// link parsing

    private static void CheckNxmLinkParsing(TextWriter output)
    {
        var valid = NxmLink.Parse("nxm://valheim/mods/123/files/456?key=abc&expires=999");
        Report(output, "valid nxm link parses gameDomain/modId/fileId/key/expires",
            valid.GameDomain == "valheim" && valid.ModId == 123 && valid.FileId == 456 && valid.Key == "abc" && valid.Expires == "999");

        var premiumStyle = NxmLink.Parse("nxm://valheim/mods/1/files/2");
        Report(output, "a premium-account link (no key/expires) parses with both null", premiumStyle.Key is null && premiumStyle.Expires is null);

        var wrongGameThrew = false;
        try { NxmLink.Parse("nxm://skyrim/mods/1/files/2"); }
        catch (NxmLink.ParseException.WrongGame ex) { wrongGameThrew = ex.Game == "skyrim"; }
        Report(output, "a link for another game throws WrongGame(\"skyrim\")", wrongGameThrew);

        var wrongSchemeThrew = false;
        try { NxmLink.Parse("https://example.com/mods/1/files/2"); }
        catch (NxmLink.ParseException.Malformed) { wrongSchemeThrew = true; }
        Report(output, "a non-nxm scheme throws Malformed", wrongSchemeThrew);

        var nonNumericIdThrew = false;
        try { NxmLink.Parse("nxm://valheim/mods/abc/files/2"); }
        catch (NxmLink.ParseException.Malformed) { nonNumericIdThrew = true; }
        Report(output, "a non-numeric mod id throws Malformed", nonNumericIdThrew);
    }

    // MARK: - Nexus Mods: credential store

    private static void CheckWindowsCredentialsRoundTrip(TextWriter output)
    {
        const string testTarget = "Bifrost-NexusAPIKey-check";
        try
        {
            WindowsCredentials.Delete(testTarget); // clean slate, in case a previous run left something
            var missing = WindowsCredentials.Read(testTarget);
            Report(output, "reading a target that was never saved returns null", missing is null);

            WindowsCredentials.Save("test-key-12345", testTarget);
            var read = WindowsCredentials.Read(testTarget);
            Report(output, "save then read round-trips the value", read == "test-key-12345");

            WindowsCredentials.Save("replacement-key", testTarget);
            var replaced = WindowsCredentials.Read(testTarget);
            Report(output, "saving again upserts rather than erroring", replaced == "replacement-key");

            var deleted = WindowsCredentials.Delete(testTarget);
            var afterDelete = WindowsCredentials.Read(testTarget);
            Report(output, "delete removes it, and reading afterward returns null", deleted && afterDelete is null);
            Report(output, "deleting an already-absent target still reports success", WindowsCredentials.Delete(testTarget));

            output.WriteLine(OperatingSystem.IsWindows()
                ? "  (ran against the real Windows Credential Manager)"
                : "  (ran against the dev-only plaintext fallback store — this Mac has no Credential Manager; never used on a real Windows install)");
        }
        finally
        {
            WindowsCredentials.Delete(testTarget);
        }
    }

    // MARK: - Nexus Mods: nxm:// protocol registration

    private static void CheckNxmProtocolRegistration(TextWriter output)
    {
        if (!OperatingSystem.IsWindows())
        {
            output.WriteLine("SKIPPED: nxm:// registry protocol registration (HKCU\\Software\\Classes\\nxm) is Windows-only — needs a real Windows box to verify.");
            return;
        }

        // Real registry writes, but under a fake exe path this developer's
        // real Nexus links will never point at.
        const string fakeExePath = @"C:\Fake\BifrostCheck\Bifrost.exe";
        try
        {
            NxmProtocolRegistrar.Register(fakeExePath);
            Report(output, "Register() then IsRegisteredTo(same path) reports true", NxmProtocolRegistrar.IsRegisteredTo(fakeExePath));
            Report(output, "IsRegisteredTo(a different path) reports false", !NxmProtocolRegistrar.IsRegisteredTo(@"C:\Different\Bifrost.exe"));
        }
        finally
        {
            NxmProtocolRegistrar.Unregister();
        }
        Report(output, "Unregister() then IsRegisteredTo() reports false", !NxmProtocolRegistrar.IsRegisteredTo(fakeExePath));
    }

    // MARK: - Single-instance mutex + named-pipe forwarding

    /// <summary>
    /// Exercises <see cref="SingleInstance"/> for real: both the named
    /// mutex and named pipe it uses are supported cross-platform by .NET
    /// (Unix included), so unlike the registry-based protocol registration
    /// above, this isn't Windows-only and runs for real on this Mac —
    /// using throwaway mutex/pipe names so it never collides with a real
    /// running Bifrost instance.
    /// </summary>
    private static async Task CheckSingleInstanceAsync(TextWriter output)
    {
        var suffix = Guid.NewGuid().ToString("N")[..8];
        var mutexName = $"BifrostCheck-SingleInstance-{suffix}";
        // Kept short — see the length caveat on SingleInstance's pipeName parameter.
        var pipeName = $"BCk-{suffix}";

        using var primary = new SingleInstance(mutexName, pipeName);
        var becamePrimary = primary.AcquirePrimary();
        Report(output, "the first instance acquires primary", becamePrimary);

        using var secondary = new SingleInstance(mutexName, pipeName);
        var secondaryBecamePrimary = secondary.AcquirePrimary();
        Report(output, "a second instance (same mutex name) is refused primary", !secondaryBecamePrimary);

        string? received = null;
        var tcs = new TaskCompletionSource();
        primary.StartListening(message =>
        {
            received = message;
            tcs.TrySetResult();
        });
        await Task.Delay(150); // let the named-pipe server start accepting connections

        var forwarded = SingleInstance.TryForward("nxm://valheim/mods/1/files/2", pipeName, timeoutMs: 2000);
        var delivered = await Task.WhenAny(tcs.Task, Task.Delay(3000)) == tcs.Task;

        Report(output, "a forwarded nxm:// message reaches the primary's listener",
            forwarded && delivered && received == "nxm://valheim/mods/1/files/2",
            $"forwarded={forwarded} delivered={delivered} received={received}");
    }

    // MARK: - Multiplayer safety: mod classifier

    private static void CheckModClassifier(TextWriter output)
    {
        var curated = ModClassifier.Classify("ValheimModding-Jotunn", package: null);
        Report(output, "curated override wins regardless of package data: ValheimModding-Jotunn -> ServerSynced",
            curated.ModClass == ModClass.ServerSynced && curated.Basis == "curated");

        var byCategory = ModClassifier.Classify("Some-UncuratedMod", new ThunderstorePackage { FullName = "Some-UncuratedMod", Categories = new List<string> { "World Generation" } });
        Report(output, "category signal: \"World Generation\" -> WorldAltering",
            byCategory.ModClass == ModClass.WorldAltering && byCategory.Basis.StartsWith("category:", StringComparison.Ordinal));

        var byHeuristic = ModClassifier.Classify("Some-TextureThing", package: null);
        Report(output, "heuristic signal: full name contains \"texture\" -> ClientOnly",
            byHeuristic.ModClass == ModClass.ClientOnly && byHeuristic.Basis.Contains("texture", StringComparison.Ordinal));

        var unknown = ModClassifier.Classify("Nobody-Knows-This-One", package: null);
        Report(output, "no curated/category/heuristic signal -> Unknown, basis \"no signal\"",
            unknown.ModClass == ModClass.Unknown && unknown.Basis == "no signal");

        // Informational: classify whatever's in this machine's real
        // manifest.json (read-only) so a developer can eyeball the
        // classifier against real installed mods, same spirit as the
        // manifest-shape-compatibility check above.
        var realManifest = new ModManager(manifestPath: BifrostPaths.ManifestPath).LoadManifest();
        if (realManifest.Mods.Count == 0)
        {
            output.WriteLine("  (no real manifest.json on this machine — nothing to list)");
        }
        else
        {
            output.WriteLine($"  classifying {realManifest.Mods.Count} real installed mod(s) (informational only):");
            foreach (var mod in realManifest.Mods)
            {
                var classification = ModClassifier.Classify(mod.FullName, package: null);
                output.WriteLine($"    {classification.ModClass.Glyph()} {mod.FullName}: {classification.ModClass} ({classification.Basis})");
            }
        }
    }

    // MARK: - Multiplayer safety: guided Join-a-Server planner

    private static void CheckServerJoinPlanner(TextWriter output)
    {
        var fakeSaveDir = Path.Combine(Path.GetTempPath(), $"BifrostCheck-serverjoin-savedir-{Guid.NewGuid()}");
        var fakeBackupsDir = Path.Combine(Path.GetTempPath(), $"BifrostCheck-serverjoin-backupsdir-{Guid.NewGuid()}");
        var fakeGameDir = Path.Combine(Path.GetTempPath(), $"BifrostCheck-serverjoin-game-{Guid.NewGuid()}");
        var fakeManifestPath = Path.Combine(Path.GetTempPath(), $"BifrostCheck-serverjoin-manifest-{Guid.NewGuid()}.json");
        var fakeProfilesPath = Path.Combine(Path.GetTempPath(), $"BifrostCheck-serverjoin-profiles-{Guid.NewGuid()}.json");
        try
        {
            var fixtureManifest = new InstalledManifest
            {
                Mods =
                {
                    new InstalledManifest.InstalledMod { FullName = "Azumatt-FirstPersonMode", Version = "1.0.0", Enabled = true, Files = { "BepInEx/plugins/Azumatt-FirstPersonMode/A.dll" } },
                    new InstalledManifest.InstalledMod { FullName = "RandyKnapp-EquipmentAndQuickSlots", Version = "1.0.0", Enabled = true, Files = { "BepInEx/plugins/RandyKnapp-EquipmentAndQuickSlots/B.dll" } },
                    new InstalledManifest.InstalledMod { FullName = "Soloredis-RtDBiomes", Version = "1.0.0", Enabled = true, Files = { "BepInEx/plugins/Soloredis-RtDBiomes/C.dll" } },
                    new InstalledManifest.InstalledMod { FullName = "Mystery-UnknownMod", Version = "1.0.0", Enabled = true, Files = { "BepInEx/plugins/Mystery-UnknownMod/D.dll" } },
                },
            };
            foreach (var mod in fixtureManifest.Mods)
            {
                foreach (var relativePath in mod.Files)
                {
                    var path = Path.Combine(fakeGameDir, relativePath.Replace('/', Path.DirectorySeparatorChar));
                    Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                    File.WriteAllText(path, "dummy");
                }
            }
            Directory.CreateDirectory(Path.GetDirectoryName(fakeManifestPath)!);
            File.WriteAllText(fakeManifestPath, JsonSerializer.Serialize(fixtureManifest, BifrostJson.Options));

            var modManager = new ModManager(manifestPath: fakeManifestPath);
            var plan = ServerJoinPlanner.BuildPlan(fixtureManifest, new List<ThunderstorePackage>());

            var groupingOk = plan.KeepEnabled.Any(i => i.FullName == "Azumatt-FirstPersonMode" && i.Enabled)
                && plan.AddsItemsWarning.Any(i => i.FullName == "RandyKnapp-EquipmentAndQuickSlots" && i.Enabled)
                && plan.Disable.Any(i => i.FullName == "Soloredis-RtDBiomes" && !i.Enabled)
                && plan.Disable.Any(i => i.FullName == "Mystery-UnknownMod" && !i.Enabled);
            Report(output, "BuildPlan groups by class with the documented per-group defaults (keep/warn-but-keep/disable)", groupingOk);

            var overridden = ServerJoinPlanner.BuildPlan(fixtureManifest, new List<ThunderstorePackage>(),
                new Dictionary<string, bool> { ["Soloredis-RtDBiomes"] = true, ["RandyKnapp-EquipmentAndQuickSlots"] = false });
            var overrideOk = overridden.Disable.First(i => i.FullName == "Soloredis-RtDBiomes").Enabled
                && !overridden.AddsItemsWarning.First(i => i.FullName == "RandyKnapp-EquipmentAndQuickSlots").Enabled;
            Report(output, "per-mod overrides flip a group's default", overrideOk);

            var worldFile = Path.Combine(fakeSaveDir, "worlds_local", "TestWorld.db");
            Directory.CreateDirectory(Path.GetDirectoryName(worldFile)!);
            File.WriteAllText(worldFile, "world-data");
            var saveBackup = new SaveBackup(fakeSaveDir, fakeBackupsDir);
            var profileStore = new ProfileStore(modManager, fakeProfilesPath);
            var targetProfile = profileStore.Create("Server Guest Fixture", new List<Profile.ProfileMod>());

            var outcome = ServerJoinPlanner.Apply(plan, targetProfile.Id, fakeGameDir, profileStore, saveBackup);

            var backupCreated = outcome.BackupOutcome is SaveBackup.BackupOutcome.Created;
            var savedProfile = profileStore.Load().Profiles.First(p => p.Id == targetProfile.Id);
            var isGuestOk = savedProfile.IsServerGuest == true;
            var modsWrittenOk = savedProfile.Mods.Count == fixtureManifest.Mods.Count;

            var manifestAfter = modManager.LoadManifest();
            var clientOnlyEnabled = manifestAfter.Mods.First(m => m.FullName == "Azumatt-FirstPersonMode").Enabled;
            var worldAlteringDisabled = !manifestAfter.Mods.First(m => m.FullName == "Soloredis-RtDBiomes").Enabled;

            Report(output, "Apply(): takes a pre-server backup first, marks the profile a guest with the plan's mods, and reconciles the real install",
                backupCreated && isGuestOk && modsWrittenOk && clientOnlyEnabled && worldAlteringDisabled,
                $"backup={outcome.BackupOutcome.GetType().Name} isGuest={savedProfile.IsServerGuest} mods={savedProfile.Mods.Count} clientOnlyEnabled={clientOnlyEnabled} worldAlteringDisabled={worldAlteringDisabled}");
        }
        finally
        {
            TryDelete(fakeSaveDir);
            TryDelete(fakeBackupsDir);
            TryDelete(fakeGameDir);
            TryDeleteFile(fakeManifestPath);
            TryDeleteFile(fakeProfilesPath);
        }
    }

    // MARK: - Profile sharing

    private static async Task CheckProfileShareAsync(TextWriter output)
    {
        var manifest = new InstalledManifest
        {
            Mods =
            {
                new InstalledManifest.InstalledMod { FullName = "Fixture-ModA", Version = "1.0.0", Enabled = true, Source = "thunderstore", Files = { "BepInEx/plugins/Fixture-ModA/A.dll" } },
                new InstalledManifest.InstalledMod { FullName = "Fixture-LocalOnly", Version = "0.0.0-local", Enabled = true, Source = "local", Files = { "BepInEx/plugins/Fixture-LocalOnly/L.dll" } },
                new InstalledManifest.InstalledMod { FullName = "Fixture-NexusMod", Version = "2.0.0", Enabled = false, Source = "nexus", NexusModId = 42, Files = { "BepInEx/plugins/Fixture-NexusMod/N.dll" } },
            },
        };
        var profile = new Profile
        {
            Id = Guid.NewGuid(),
            Name = "Fixture Profile",
            Mods =
            {
                new Profile.ProfileMod { FullName = "Fixture-ModA", Enabled = true },
                new Profile.ProfileMod { FullName = "Fixture-LocalOnly", Enabled = true },
                new Profile.ProfileMod { FullName = "Fixture-NexusMod", Enabled = false },
            },
        };

        var outcome = ProfileShare.Export(profile, manifest);
        Report(output, "export skips source==\"local\" mods and reports them separately", outcome.SkippedLocalMods.SequenceEqual(new[] { "Fixture-LocalOnly" }));
        Report(output, "export keeps thunderstore + nexus mods, marking the nexus source/id",
            outcome.Json.Mods.Count == 2
            && outcome.Json.Mods.Any(m => m.FullName == "Fixture-ModA" && m.Source is null)
            && outcome.Json.Mods.Any(m => m.FullName == "Fixture-NexusMod" && m.Source == "nexus" && m.NexusModId == 42));

        var fakeIndex = new List<ThunderstorePackage>
        {
            new()
            {
                FullName = "Fixture-ModA", Name = "Mod A", Owner = "Fixture",
                Versions = new List<ThunderstorePackage.Version> { new() { VersionNumber = "1.5.0", DownloadUrl = "https://example.invalid/a.zip" } },
            },
        };
        var recipientManifest = InstalledManifest.Empty;
        var plan = ProfileShare.Plan(outcome.EncodedString, fakeIndex, recipientManifest);
        var resolvableOk = plan.Resolvable.Any(m => m.FullName == "Fixture-ModA" && m.RequestedVersion == "1.0.0" && m.ResolvedVersion == "1.5.0" && m.WasSubstituted);
        var nexusUnresolvableOk = plan.Unresolvable.Any(m => m.FullName == "Fixture-NexusMod" && m.Reason is ProfileShare.ImportPlan.UnresolvableReason.NexusOnly { ModId: 42 });
        Report(output, "native round trip: the exported code re-plans with a substituted version and a Nexus-marked unresolvable entry",
            resolvableOk && nexusUnresolvableOk,
            $"resolvable=[{string.Join(",", plan.Resolvable.Select(m => m.FullName))}] unresolvable=[{string.Join(",", plan.Unresolvable.Select(m => m.FullName))}]");

        var fileFixturePath = Path.Combine(Path.GetTempPath(), $"BifrostCheck-profileshare-{Guid.NewGuid()}.bifrostprofile");
        try
        {
            var skipped = ProfileShare.ExportFile(profile, manifest, fileFixturePath);
            var planFromFile = ProfileShare.PlanFromFile(fileFixturePath, fakeIndex, recipientManifest);
            Report(output, ".bifrostprofile file round trip resolves the same as the base64 code",
                skipped.SequenceEqual(new[] { "Fixture-LocalOnly" })
                && planFromFile.Resolvable.Count == plan.Resolvable.Count
                && planFromFile.Unresolvable.Count == plan.Unresolvable.Count);
        }
        finally
        {
            TryDeleteFile(fileFixturePath);
        }

        var futureFormatJson = JsonSerializer.Serialize(new { bifrost = 99, name = "x", mods = Array.Empty<object>() });
        var unsupportedVersionThrew = false;
        try { ProfileShare.Plan(Convert.ToBase64String(Encoding.UTF8.GetBytes(futureFormatJson)), fakeIndex, recipientManifest); }
        catch (ProfileShare.ProfileShareException.UnsupportedVersion) { unsupportedVersionThrew = true; }
        Report(output, "a share from a newer format version throws UnsupportedVersion rather than misreading it", unsupportedVersionThrew);

        Report(output, "LooksLikeR2ModManCode: a bare UUID is true, a Bifrost base64 code is false",
            ProfileShare.LooksLikeR2ModManCode(Guid.NewGuid().ToString()) && !ProfileShare.LooksLikeR2ModManCode(outcome.EncodedString));

        try
        {
            var r2Manifest = new InstalledManifest
            {
                Mods = { new InstalledManifest.InstalledMod { FullName = "Fixture-ModA", Version = "1.0.0", Enabled = true, Source = "thunderstore", Files = { "BepInEx/plugins/Fixture-ModA/A.dll" } } },
            };
            var r2Profile = new Profile { Id = Guid.NewGuid(), Name = "R2 Fixture", Mods = { new Profile.ProfileMod { FullName = "Fixture-ModA", Enabled = true } } };

            var code = await ProfileShare.ExportR2CodeAsync(r2Profile, r2Manifest);
            Report(output, "LIVE r2modman export: uploaded to Thunderstore's legacyprofile/create/ and returned a bare-UUID code", Guid.TryParse(code, out _), code);

            var r2Plan = await ProfileShare.ImportR2CodeAsync(code, fakeIndex, recipientManifest);
            Report(output, "LIVE r2modman round trip: re-fetching the code resolves \"Fixture-ModA\" again",
                r2Plan.Resolvable.Any(m => m.FullName == "Fixture-ModA") || r2Plan.AlreadyInstalled.Any(m => m.FullName == "Fixture-ModA"),
                $"importedName={r2Plan.ImportedName}");
        }
        catch (Exception ex)
        {
            output.WriteLine($"SKIPPED live r2modman round trip: {ex.Message} (likely offline)");
        }
    }

    // MARK: - Fun round: Saga stats

    private static void CheckSagaStats(TextWriter output)
    {
        var fakeSaveDir = Path.Combine(Path.GetTempPath(), $"BifrostCheck-sagastats-savedir-{Guid.NewGuid()}");
        try
        {
            const string localConfigFixture = """
                "UserLocalConfigStore"
                {
                	"Software"
                	{
                		"Valve"
                		{
                			"Steam"
                			{
                				"apps"
                				{
                					"892970"
                					{
                						"Playtime"		"125"
                					}
                				}
                			}
                		}
                	}
                }
                """;
            var playtime = SagaStats.PlaytimeMinutes(localConfigFixture);
            Report(output, "PlaytimeMinutes reads the nested apps/892970/Playtime value", playtime == 125);
            Report(output, "PlaytimeMinutes(null) is null", SagaStats.PlaytimeMinutes(null) is null);

            var worldDb = Path.Combine(fakeSaveDir, "worlds_local", "MyWorld.db");
            var worldFwl = Path.Combine(fakeSaveDir, "worlds_local", "MyWorld.fwl");
            var characterFch = Path.Combine(fakeSaveDir, "characters_local", "Hero.fch");
            foreach (var path in new[] { worldDb, worldFwl, characterFch })
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            }
            File.WriteAllText(worldDb, "12345");
            File.WriteAllText(worldFwl, "12");
            File.WriteAllText(characterFch, "123");

            var worlds = SagaStats.WorldEntries(fakeSaveDir);
            var characters = SagaStats.CharacterEntries(fakeSaveDir);
            Report(output, "worlds_local groups .db+.fwl by stem into one SaveEntry with summed size",
                worlds.Count == 1 && worlds[0].Name == "MyWorld" && worlds[0].ByteSize == 5 + 2);
            Report(output, "characters_local: one .fch file -> one SaveEntry", characters.Count == 1 && characters[0].Name == "Hero" && characters[0].ByteSize == 3);

            var fixtureManifest = new InstalledManifest
            {
                Mods =
                {
                    new InstalledManifest.InstalledMod { FullName = "Azumatt-FirstPersonMode", Version = "1.0.0", Enabled = true },
                    new InstalledManifest.InstalledMod { FullName = "ValheimModding-Jotunn", Version = "1.0.0", Enabled = true },
                },
            };
            var breakdown = SagaStats.ClassBreakdown(fixtureManifest, new List<ThunderstorePackage>());
            Report(output, "ClassBreakdown tallies curated classes in ModClass declaration order, skipping empty classes",
                breakdown.Select(c => c.ModClass).SequenceEqual(new[] { ModClass.ClientOnly, ModClass.ServerSynced }) && breakdown.All(c => c.Count == 1));

            var backups = new List<SaveBackup.Backup> { new("/fake/backup.zip", DateTime.UtcNow, "manual", 2_500_000) };
            var snapshot = SagaStats.BuildSnapshot(fixtureManifest, new List<ThunderstorePackage>(), backups, fakeSaveDir, localConfigFixture);
            var lines = SagaStats.FlavorLines(snapshot);
            Report(output, "FlavorLines: playtime/worlds/characters/mods/backups lines all present with correct counts",
                lines.Any(l => l.Contains("2 hour", StringComparison.Ordinal)) // 125 min -> 2 hours
                && lines.Any(l => l.Contains("1 world", StringComparison.Ordinal))
                && lines.Any(l => l.Contains("1 hero", StringComparison.Ordinal))
                && lines.Any(l => l.Contains("2 mods", StringComparison.Ordinal))
                && lines.Any(l => l.Contains("1 backup", StringComparison.Ordinal)),
                string.Join(" | ", lines));

            var emptyLines = SagaStats.FlavorLines(SagaStats.Snapshot.Empty);
            Report(output, "an entirely empty snapshot falls back to exactly one line", emptyLines.Count == 1 && emptyLines[0].Contains("No saga recorded", StringComparison.Ordinal));
        }
        finally
        {
            TryDelete(fakeSaveDir);
        }
    }

    // MARK: - Fun round: Flavor quips + Runestone tips

    private static void CheckFlavorAndRunestoneTips(TextWriter output)
    {
        Report(output, "Flavor.Quips: 25 unique entries", Flavor.Quips.Count == 25 && Flavor.Quips.Distinct().Count() == 25);

        var quipA = Flavor.Quip(42);
        var quipB = Flavor.Quip(42);
        Report(output, "Flavor.Quip(seed) is deterministic for the same seed and always picks from Quips", quipA == quipB && Flavor.Quips.Contains(quipA));

        Report(output, "RunestoneTips.All: 25 unique entries, 15 tips followed by 10 lore lines",
            RunestoneTips.All.Count == 25
            && RunestoneTips.All.Select(t => t.Text).Distinct().Count() == 25
            && RunestoneTips.All.Take(15).All(t => !t.IsLore)
            && RunestoneTips.All.Skip(15).All(t => t.IsLore));

        var next = RunestoneTips.NextIndex(0);
        Report(output, "RunestoneTips.NextIndex always differs from the current index", next != 0);
    }

    // MARK: - Fun round: Surprise Me

    private static void CheckSurpriseMe(TextWriter output)
    {
        var installedManifest = new InstalledManifest { Mods = { new InstalledManifest.InstalledMod { FullName = "Already-Installed", Version = "1.0.0", Enabled = true } } };
        var index = new List<ThunderstorePackage>
        {
            new() { FullName = "Good-HighRating", RatingScore = 50, IsDeprecated = false },
            new() { FullName = "Bad-LowRating", RatingScore = 19, IsDeprecated = false },
            new() { FullName = "Bad-Deprecated", RatingScore = 100, IsDeprecated = true },
            new() { FullName = "Already-Installed", RatingScore = 100, IsDeprecated = false },
            new() { FullName = ModManager.LoaderFullName, RatingScore = 100, IsDeprecated = false },
            new() { FullName = "Boundary-ExactlyMinimum", RatingScore = SurpriseMe.MinimumRating, IsDeprecated = false },
        };

        var eligible = SurpriseMe.Eligible(index, installedManifest);
        Report(output, "Eligible excludes low rating, deprecated, the loader pack, and already-installed; keeps the exact-minimum-rating boundary",
            eligible.Select(p => p.FullName).OrderBy(n => n, StringComparer.Ordinal).SequenceEqual(new[] { "Boundary-ExactlyMinimum", "Good-HighRating" }));

        var pick = SurpriseMe.Pick(index, installedManifest);
        Report(output, "Pick returns one of the eligible packages", pick is not null && eligible.Contains(pick));

        var emptyPick = SurpriseMe.Pick(new List<ThunderstorePackage>(), installedManifest);
        Report(output, "Pick against an empty index returns null rather than throwing", emptyPick is null);
    }

    // MARK: - Helpers

    private static void TryDelete(string dir)
    {
        try { if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true); } catch { /* best effort */ }
    }

    private static void TryDeleteFile(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { /* best effort */ }
    }
}
