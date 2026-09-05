namespace Bifrost.Core.Services;

/// <summary>
/// Central place for every path Bifrost reads or writes outside the game
/// directory itself. Everything here is overridable — by an environment
/// variable for the Steam root, and by constructor parameters on the
/// services that consume these paths — so <c>--check</c> can run safely on
/// a non-Windows dev machine against fixtures instead of the real
/// locations.
/// </summary>
public static class BifrostPaths
{
    /// <summary>
    /// Overrides Steam's install root. Set by <c>--check</c>'s fixtures (and
    /// usable by anyone testing off a real Windows box) instead of touching
    /// the registry or the real Program Files layout.
    /// </summary>
    public const string SteamRootEnvVar = "BIFROST_STEAM_ROOT";

    /// <summary>
    /// Bifrost's own app-data directory: <c>%AppData%\Bifrost</c> on
    /// Windows (<see cref="Environment.SpecialFolder.ApplicationData"/>).
    /// Holds manifest.json, profiles.json, package-index.json and its
    /// validator sidecar.
    /// </summary>
    public static string AppDataDir
    {
        get
        {
            var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            return Path.Combine(appData, "Bifrost");
        }
    }

    public static string ManifestPath => Path.Combine(AppDataDir, "manifest.json");
    public static string ProfilesPath => Path.Combine(AppDataDir, "profiles.json");
    public static string PackageIndexCachePath => Path.Combine(AppDataDir, "package-index.json");
    public static string PackageIndexValidatorsPath => Path.Combine(AppDataDir, "package-index.validators.json");

    /// <summary>
    /// Resolves Steam's install root: <see cref="SteamRootEnvVar"/> first
    /// (for tests/overrides), then the registry
    /// (HKCU\SOFTWARE\Valve\Steam@InstallPath, Windows only), then the two
    /// well-known Program Files locations.
    /// </summary>
    public static string ResolveSteamRoot()
    {
        var overridden = Environment.GetEnvironmentVariable(SteamRootEnvVar);
        if (!string.IsNullOrWhiteSpace(overridden))
        {
            return overridden;
        }

        if (OperatingSystem.IsWindows())
        {
            var fromRegistry = ReadSteamInstallPathFromRegistry();
            if (!string.IsNullOrWhiteSpace(fromRegistry))
            {
                return fromRegistry;
            }
        }

        string[] fallbacks =
        {
            @"C:\Program Files (x86)\Steam",
            @"C:\Program Files\Steam",
        };

        foreach (var fallback in fallbacks)
        {
            if (Directory.Exists(fallback))
            {
                return fallback;
            }
        }

        return fallbacks[0];
    }

    private static string? ReadSteamInstallPathFromRegistry()
    {
        if (!OperatingSystem.IsWindows())
        {
            return null;
        }

        try
        {
            return WindowsRegistry.ReadSteamInstallPath();
        }
        catch
        {
            return null;
        }
    }
}
