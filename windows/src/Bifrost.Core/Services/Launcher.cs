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
/// launch the game.
/// </summary>
public static class Launcher
{
    public static Uri LaunchUri => new($"steam://rungameid/{GameLocator.ValheimAppId}");

    public sealed record PlanStep(string Description);

    /// <summary>
    /// Describes exactly what <see cref="Play"/> would do, without doing it
    /// — used by <c>--check</c> so verification never triggers a real
    /// launch or opens a steam:// URL.
    /// </summary>
    public static List<PlanStep> Plan(bool modded, string gameDir)
    {
        var doorstopPath = Path.Combine(gameDir, "doorstop_config.ini");
        return new List<PlanStep>
        {
            new($"Set [General] enabled = {(modded ? "true" : "false")} in {doorstopPath}"),
            new($"Open {LaunchUri} via ShellExecute"),
        };
    }

    /// <summary>
    /// Sets the doorstop toggle for <paramref name="modded"/> and opens
    /// Steam's rungameid URL via ShellExecute (the Windows/.NET equivalent
    /// of macOS's <c>NSWorkspace.open</c> — handled entirely by the OS's own
    /// URL-protocol registration, so Steam does not need to already be
    /// running).
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
