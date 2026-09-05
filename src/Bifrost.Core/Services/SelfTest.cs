using System.Text.Json;
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

                var updates = modManager.UpdatesAvailable(index);
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
