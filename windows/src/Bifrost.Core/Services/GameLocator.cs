namespace Bifrost.Core.Services;

/// <summary>
/// Locates the Valheim install through Steam's own bookkeeping — the
/// registry-resolved (or overridden) Steam root, its
/// <c>steamapps/libraryfolders.vdf</c>, and the app manifest for 892970.
/// Ported from the macOS reference implementation's <c>GameLocator.swift</c>.
///
/// Every path this walks is overridable (constructor parameter or the
/// <c>BIFROST_STEAM_ROOT</c> environment variable — see
/// <see cref="BifrostPaths.ResolveSteamRoot"/>), so <c>--check</c> can drive
/// this entirely against fixtures on a non-Windows dev machine.
/// </summary>
public sealed class GameLocator
{
    public const string ValheimAppId = "892970";

    public sealed record LocatedGame(string Directory, bool HasExecutable)
    {
        public bool IsValid => HasExecutable;
    }

    private readonly string _steamRoot;

    public GameLocator(string? steamRoot = null)
    {
        _steamRoot = steamRoot ?? BifrostPaths.ResolveSteamRoot();
    }

    public string SteamRoot => _steamRoot;

    /// <summary>
    /// Every configured Steam library path, including the Steam root itself
    /// (always an implicit library).
    /// </summary>
    public List<string> SteamLibraryPaths()
    {
        var paths = new List<string> { _steamRoot };

        var libraryFoldersPath = Path.Combine(_steamRoot, "steamapps", "libraryfolders.vdf");
        if (!File.Exists(libraryFoldersPath))
        {
            return paths;
        }

        var contents = TryReadAllText(libraryFoldersPath);
        if (contents is null)
        {
            return paths;
        }

        foreach (var path in VdfParser.ParseLibraryFolderPaths(contents))
        {
            if (!paths.Contains(path))
            {
                paths.Add(path);
            }
        }
        return paths;
    }

    /// <summary>
    /// Finds the Valheim install directory by walking every configured
    /// library and looking for an app manifest for 892970.
    /// </summary>
    public LocatedGame? Locate()
    {
        foreach (var library in SteamLibraryPaths())
        {
            var steamappsDir = Path.Combine(library, "steamapps");
            var manifestPath = Path.Combine(steamappsDir, $"appmanifest_{ValheimAppId}.acf");
            var manifestContents = TryReadAllText(manifestPath);
            if (manifestContents is null)
            {
                continue;
            }

            var installDir = VdfParser.GetValue("installdir", manifestContents) ?? "Valheim";
            var gameDir = Path.Combine(steamappsDir, "common", installDir);

            var exePath = Path.Combine(gameDir, "valheim.exe");
            var hasExecutable = File.Exists(exePath);
            return new LocatedGame(gameDir, hasExecutable);
        }
        return null;
    }

    /// <summary>
    /// A BepInEx install is considered present when the loader's core
    /// directory, its Windows doorstop shim (winhttp.dll), and the doorstop
    /// config all sit alongside the game.
    /// </summary>
    public static bool BepInExInstalled(string gameDir)
    {
        string[] markers =
        {
            Path.Combine(gameDir, "BepInEx", "core"),
            Path.Combine(gameDir, "winhttp.dll"),
            Path.Combine(gameDir, "doorstop_config.ini"),
        };
        return markers.All(m => Directory.Exists(m) || File.Exists(m));
    }

    /// <summary>Whether any Steam process is currently running.</summary>
    public static bool SteamIsRunning()
    {
        try
        {
            return System.Diagnostics.Process.GetProcessesByName("steam").Length > 0;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>
    /// Whether Valheim itself is currently running — the config editor
    /// polls this to show a "changes apply next launch" notice, since the
    /// game only reads <c>.cfg</c> files at startup. Mirrors the macOS
    /// reference implementation's <c>pgrep -x Valheim</c> check.
    /// </summary>
    public static bool ValheimIsRunning()
    {
        try
        {
            return System.Diagnostics.Process.GetProcessesByName("valheim").Length > 0;
        }
        catch
        {
            return false;
        }
    }

    private static string? TryReadAllText(string path)
    {
        try
        {
            return File.Exists(path) ? File.ReadAllText(path) : null;
        }
        catch
        {
            return null;
        }
    }
}
