using Bifrost.Core.Models;
using Bifrost.Core.Services;

namespace Bifrost.Services;

/// <summary>
/// One shared set of service instances for the whole app session — the
/// Windows counterpart of the macOS reference implementation's
/// <c>AppState</c> (minus the SwiftUI observable bits, which live on the
/// individual view models instead). Every tab view model is handed the same
/// instances so they all read/write the same manifest.json/profiles.json.
/// </summary>
public sealed class AppServices
{
    public GameLocator GameLocator { get; } = new();
    public ModManager ModManager { get; } = new();
    public ProfileStore ProfileStore { get; }
    public ThunderstoreClient ThunderstoreClient { get; } = new();
    public BepInExInstaller BepInExInstaller { get; } = new();
    public SaveBackup SaveBackup { get; } = new();
    public AppSettingsStore SettingsStore { get; } = new();

    /// <summary>
    /// The current preference toggles, loaded once at startup and kept in
    /// sync by whoever mutates a toggle (see <c>SettingsViewModel</c>) —
    /// read by <c>HomeViewModel</c>'s play commands and the tray icon
    /// without each of them re-reading settings.json on every launch.
    /// </summary>
    public AppSettings Settings { get; private set; }

    /// <summary>
    /// Raised whenever <see cref="SaveSettings"/> persists a change — lets
    /// the tray icon (built once in <c>App.axaml.cs</c>, outside any view
    /// model's lifetime) react to the "Show tray icon" toggle live rather
    /// than only on next launch.
    /// </summary>
    public event Action? SettingsChanged;

    public AppServices()
    {
        ProfileStore = new ProfileStore(ModManager);
        Settings = SettingsStore.Load();
    }

    /// <summary>Persists <paramref name="settings"/> and updates <see cref="Settings"/> so every other consumer sees the change immediately.</summary>
    public void SaveSettings(AppSettings settings)
    {
        SettingsStore.Save(settings);
        Settings = settings;
        SettingsChanged?.Invoke();
    }

    /// <summary>
    /// The located game directory, re-resolved on every call (cheap:
    /// filesystem-only) rather than cached, since the user can install the
    /// game or add a Steam library while Bifrost is running.
    /// </summary>
    public string? LocateGameDir()
    {
        var located = GameLocator.Locate();
        return located is { IsValid: true } ? located.Directory : null;
    }
}
