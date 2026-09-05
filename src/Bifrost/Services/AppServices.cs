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

    public AppServices()
    {
        ProfileStore = new ProfileStore(ModManager);
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
