using System.Diagnostics;

namespace Bifrost.Core.Services;

/// <summary>
/// Hands a play request off to Steam. Ported from the macOS reference
/// implementation's <c>Launcher.swift</c>, simplified for the Windows
/// delta: there's no launch-wrapper script or Steam launch-options
/// splicing to route through — Windows Valheim loads winhttp.dll (the
/// doorstop shim) straight out of the game directory, so the modded/vanilla
/// switch is simply the <c>doorstop_config.ini</c> [General] enabled key
/// (see <see cref="DoorstopConfig"/>), flipped before Steam is asked to
/// launch the game. Windows' own <c>steam://</c> URL-protocol registration
/// will start Steam on its own if it isn't running, but that always shows
/// Steam's window — <see cref="EnsureSteamRunningAsync"/> starts
/// <c>steam.exe</c> itself first (optionally with <c>-silent</c>) so a
/// silent-start preference is actually honored, mirroring the macOS app's
/// own <c>ensureSteamRunning</c> stage.
/// </summary>
public static class Launcher
{
    public static Uri LaunchUri => new($"steam://rungameid/{GameLocator.ValheimAppId}");

    public sealed record PlanStep(string Description);

    /// <summary>A stage <see cref="PlayAsync"/> has reached, reported through its <c>onPhase</c> callback.</summary>
    public enum LaunchPhase
    {
        /// <summary>"Back up saves before modded launch" is on and the newest automatic backup is stale (or missing); backing up before Steam is even touched.</summary>
        BackingUpSaves,
        /// <summary>Steam wasn't running; <c>steam.exe</c> (optionally <c>-silent</c>) was just started.</summary>
        StartingSteam,
        /// <summary>Steam's process is up; waiting for it to finish its own startup.</summary>
        WaitingForSteam,
        /// <summary>The doorstop toggle is set and the steam:// rungameid URL has been opened.</summary>
        Launching,
    }

    /// <summary>
    /// Describes exactly what <see cref="PlayAsync"/> would do, without doing
    /// it — used by <c>--check</c> so verification never triggers a real
    /// launch or opens a steam:// URL.
    /// </summary>
    public static List<PlanStep> Plan(bool modded, string gameDir, bool startSteamSilently = true, bool backupSavesBeforeModdedLaunch = true)
    {
        var doorstopPath = Path.Combine(gameDir, "doorstop_config.ini");
        var steps = new List<PlanStep>();
        if (modded && backupSavesBeforeModdedLaunch)
        {
            steps.Add(new PlanStep("If the newest automatic backup is more than 30 minutes old (or there isn't one), back up worlds_local/characters_local first (SaveBackup.BackupNow(\"pre-launch\"))"));
        }
        steps.Add(new PlanStep(startSteamSilently
            ? "Ensure Steam is running (start steam.exe -silent if needed, so its window stays hidden) and wait for it to finish starting up"
            : "Ensure Steam is running (start steam.exe if needed) and wait for it to finish starting up"));
        steps.Add(new PlanStep($"Set [General] enabled = {(modded ? "true" : "false")} in {doorstopPath}"));
        steps.Add(new PlanStep($"Open {LaunchUri} via ShellExecute"));
        return steps;
    }

    /// <summary>
    /// Runs the full staged launch: an optional pre-launch save backup, then
    /// ensures Steam is running (<see cref="EnsureSteamRunningAsync"/>), sets
    /// the doorstop toggle, and opens Steam's rungameid URL via
    /// ShellExecute.
    /// </summary>
    public static async Task PlayAsync(
        bool modded,
        string gameDir,
        bool startSteamSilently = true,
        bool backupSavesBeforeModdedLaunch = true,
        Action<LaunchPhase>? onPhase = null)
    {
        if (modded && backupSavesBeforeModdedLaunch)
        {
            await BackUpSavesBeforeModdedLaunchIfNeededAsync(onPhase);
        }

        await EnsureSteamRunningAsync(startSteamSilently, onPhase);

        SetModdedEnabled(modded, gameDir);

        onPhase?.Invoke(LaunchPhase.Launching);
        var psi = new ProcessStartInfo
        {
            FileName = LaunchUri.ToString(),
            UseShellExecute = true,
        };
        Process.Start(psi);
    }

    /// <summary>
    /// Synchronous convenience for callers that don't need the staged
    /// backup/silent-Steam behavior (e.g. a quick vanilla launch from a
    /// context with no event loop to await on) — sets the doorstop toggle
    /// and opens the rungameid URL exactly like the original Windows port
    /// did, with no Steam-readiness wait.
    /// </summary>
    public static void Play(bool modded, string gameDir)
    {
        SetModdedEnabled(modded, gameDir);

        var psi = new ProcessStartInfo
        {
            FileName = LaunchUri.ToString(),
            UseShellExecute = true,
        };
        Process.Start(psi);
    }

    // MARK: - Ensure Steam running (silent start)

    /// <summary>
    /// If Steam is already running, returns immediately without starting or
    /// waiting on anything. Otherwise locates <c>steam.exe</c> via the same
    /// Steam root <see cref="GameLocator"/> resolves (registry
    /// <c>InstallPath</c> first, falling back to the well-known Program
    /// Files locations) and starts it — with <c>-silent</c> when
    /// <paramref name="silent"/> is true, so its window never appears — then
    /// polls for up to <paramref name="timeout"/> for the process to come
    /// up. Returns whether Steam ended up running either way; never throws.
    /// </summary>
    public static async Task<bool> EnsureSteamRunningAsync(bool silent, Action<LaunchPhase>? onPhase = null, TimeSpan? timeout = null, string? steamRoot = null)
    {
        if (GameLocator.SteamIsRunning())
        {
            return true;
        }

        onPhase?.Invoke(LaunchPhase.StartingSteam);
        var steamExePath = FindSteamExecutable(steamRoot);
        if (steamExePath is not null)
        {
            try
            {
                var psi = new ProcessStartInfo { FileName = steamExePath, UseShellExecute = true };
                if (silent)
                {
                    psi.Arguments = SteamSilentArgument;
                }
                Process.Start(psi);
            }
            catch
            {
                // Fall through — the steam:// URI that PlayAsync opens next
                // will still try to start Steam on its own (just not
                // silently) via Windows' URL-protocol registration.
            }
        }

        onPhase?.Invoke(LaunchPhase.WaitingForSteam);
        var deadline = DateTime.UtcNow + (timeout ?? TimeSpan.FromSeconds(90));
        while (DateTime.UtcNow < deadline)
        {
            if (GameLocator.SteamIsRunning())
            {
                return true;
            }
            await Task.Delay(1000);
        }
        return GameLocator.SteamIsRunning();
    }

    /// <summary>The command-line argument that starts Steam minimized without opening its window.</summary>
    public const string SteamSilentArgument = "-silent";

    /// <summary>
    /// Locates <c>steam.exe</c> under <paramref name="steamRoot"/> (defaults
    /// to <see cref="BifrostPaths.ResolveSteamRoot"/> — the same
    /// registry-or-well-known-path resolution <see cref="GameLocator"/>
    /// uses), or null if it isn't there.
    /// </summary>
    public static string? FindSteamExecutable(string? steamRoot = null)
    {
        var root = steamRoot ?? BifrostPaths.ResolveSteamRoot();
        var exePath = Path.Combine(root, "steam.exe");
        return File.Exists(exePath) ? exePath : null;
    }

    // MARK: - Save backups

    /// <summary>
    /// Cheap insurance against a bad mod corrupting a save with no safety
    /// net: before a modded launch, takes a fresh "pre-launch" backup if the
    /// newest *automatic* backup (manual ones don't count toward this) is
    /// more than 30 minutes old, or there isn't one yet. Never throws — a
    /// launch should never be blocked by a failed backup.
    /// </summary>
    private static async Task BackUpSavesBeforeModdedLaunchIfNeededAsync(Action<LaunchPhase>? onPhase)
    {
        var staleness = TimeSpan.FromMinutes(30);
        var backup = new SaveBackup();
        var newestAutomatic = backup.List().FirstOrDefault(b => b.Reason != SaveBackup.ManualReason);
        if (newestAutomatic is not null && DateTime.Now - newestAutomatic.Date < staleness)
        {
            return;
        }

        onPhase?.Invoke(LaunchPhase.BackingUpSaves);
        await Task.Run(() =>
        {
            try { backup.BackupNow("pre-launch"); } catch { /* never block a launch on a failed backup */ }
        });
    }

    /// <summary>
    /// Flips the doorstop_config.ini toggle without launching anything —
    /// the primitive <see cref="Play"/> builds on, exposed separately so the
    /// UI can reflect the current toggle state without triggering Steam.
    /// </summary>
    public static void SetModdedEnabled(bool modded, string gameDir)
    {
        var doorstopPath = Path.Combine(gameDir, "doorstop_config.ini");
        var text = File.ReadAllText(doorstopPath);
        var result = DoorstopConfig.SetEnabled(text, modded);
        if (result.Changed)
        {
            File.WriteAllText(doorstopPath, result.Text);
        }
    }

    /// <summary>Current doorstop toggle state, or null if it can't be read.</summary>
    public static bool? CurrentModdedEnabled(string gameDir)
    {
        var doorstopPath = Path.Combine(gameDir, "doorstop_config.ini");
        if (!File.Exists(doorstopPath))
        {
            return null;
        }
        try
        {
            return DoorstopConfig.GetEnabled(File.ReadAllText(doorstopPath));
        }
        catch
        {
            return null;
        }
    }

    /// <summary>Reveals BepInEx/plugins in Explorer.</summary>
    public static void OpenPluginsFolder(string gameDir) => OpenFolder(Path.Combine(gameDir, "BepInEx", "plugins"));

    /// <summary>Opens BepInEx/LogOutput.log in its default viewer.</summary>
    public static void OpenBepInExLog(string gameDir) => OpenFile(Path.Combine(gameDir, "BepInEx", "LogOutput.log"));

    /// <summary>Opens Bifrost's own app-data folder in Explorer.</summary>
    public static void OpenAppDataFolder() => OpenFolder(BifrostPaths.AppDataDir);

    /// <summary>Opens Bifrost's save-backups folder in Explorer.</summary>
    public static void OpenBackupsFolder() => OpenFolder(BifrostPaths.SaveBackupsDir);

    /// <summary>Opens <paramref name="url"/> in the system's default browser — used by Settings' "Get your API key" link (Nexus Mods).</summary>
    public static void OpenUrl(string url) => Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true });

    private static void OpenFolder(string path)
    {
        if (!Directory.Exists(path))
        {
            return;
        }
        Process.Start(new ProcessStartInfo { FileName = path, UseShellExecute = true });
    }

    private static void OpenFile(string path)
    {
        if (!File.Exists(path))
        {
            return;
        }
        Process.Start(new ProcessStartInfo { FileName = path, UseShellExecute = true });
    }
}
