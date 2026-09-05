namespace Bifrost.Core.Models;

/// <summary>
/// Bifrost's persisted user preferences — the Windows counterpart of the
/// macOS reference implementation's small handful of <c>UserDefaults</c>-backed
/// <c>@AppStorage</c> toggles (<c>Launcher.startSteamSilentlyDefaultsKey</c>,
/// <c>Launcher.backupSavesBeforeModdedLaunchDefaultsKey</c>,
/// <c>MenuBarPreference.showIconDefaultsKey</c>). Windows has no equivalent
/// of a simple per-app defaults database, so these are persisted as JSON at
/// <c>%AppData%\Bifrost\settings.json</c> (see <see cref="Services.AppSettingsStore"/>)
/// instead — same shape, same defaults (every toggle defaults to on, matching
/// the macOS app), just a different storage mechanism.
/// </summary>
public sealed class AppSettings
{
    /// <summary>
    /// When Bifrost needs to start Steam itself (it isn't already running),
    /// start it minimized (<c>steam.exe -silent</c>) rather than letting its
    /// window pop up. Defaults to on.
    /// </summary>
    public bool StartSteamSilently { get; set; } = true;

    /// <summary>
    /// Before a modded launch, back up worlds_local/characters_local if the
    /// newest automatic backup is more than 30 minutes old (or there isn't
    /// one yet). Defaults to on.
    /// </summary>
    public bool BackupSavesBeforeModdedLaunch { get; set; } = true;

    /// <summary>Show a Bifrost tray icon for quick Play/profile actions without opening the main window. Defaults to on.</summary>
    public bool ShowTrayIcon { get; set; } = true;
}
