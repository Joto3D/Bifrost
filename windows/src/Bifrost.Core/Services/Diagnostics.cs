namespace Bifrost.Core.Services;

/// <summary>
/// Classifies the state of a modded launch by reading BepInEx's
/// <c>LogOutput.log</c>. Ported from the macOS reference implementation's
/// <c>Diagnostics.swift</c> — the log format and its "Chainloader
/// started"/"Loading [" markers are identical on Windows.
/// </summary>
public static class Diagnostics
{
    public abstract record LaunchDiagnosis
    {
        /// <summary>
        /// BepInEx's chainloader finished starting and reported how many
        /// plugins it loaded.
        /// </summary>
        public sealed record ModsLoaded(int PluginCount) : LaunchDiagnosis;

        /// <summary>The chainloader announced itself, but no plugin-count line has shown up yet.</summary>
        public sealed record ChainloaderStarted : LaunchDiagnosis;

        /// <summary>No log appeared within the watch window.</summary>
        public sealed record NoLogFile(string Hint) : LaunchDiagnosis;

        /// <summary>Not a modded launch — no BepInEx log is expected.</summary>
        public sealed record VanillaMode : LaunchDiagnosis;

        public string Summary => this switch
        {
            ModsLoaded m => m.PluginCount == 0
                ? "BepInEx started — 0 plugins loaded"
                : $"BepInEx started — {m.PluginCount} plugin{(m.PluginCount == 1 ? "" : "s")} loaded",
            ChainloaderStarted => "BepInEx chainloader started…",
            NoLogFile n => n.Hint,
            VanillaMode => "Launched in vanilla mode",
            _ => throw new InvalidOperationException(),
        };
    }

    /// <summary>
    /// Watches <c>&lt;gameDir&gt;/BepInEx/LogOutput.log</c> for up to
    /// <paramref name="timeoutSeconds"/> seconds after a launch, returning
    /// as soon as it can be classified.
    /// </summary>
    public static async Task<LaunchDiagnosis> WatchAsync(string gameDir, bool modded, double timeoutSeconds = 90)
    {
        if (!modded)
        {
            return new LaunchDiagnosis.VanillaMode();
        }

        var logPath = Path.Combine(gameDir, "BepInEx", "LogOutput.log");
        var deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);

        while (DateTime.UtcNow < deadline)
        {
            if (TryReadLog(logPath, out var contents))
            {
                var diagnosis = Classify(contents!);
                if (diagnosis is not null)
                {
                    return diagnosis;
                }
            }
            await Task.Delay(TimeSpan.FromSeconds(1));
        }

        var hint = $"No BepInEx log appeared within {(int)timeoutSeconds}s — check that Steam's launch options actually invoke Bifrost's wrapper, and that BepInEx installed correctly.";
        return new LaunchDiagnosis.NoLogFile(hint);
    }

    private static bool TryReadLog(string logPath, out string? contents)
    {
        try
        {
            if (!File.Exists(logPath))
            {
                contents = null;
                return false;
            }
            using var stream = new FileStream(logPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var reader = new StreamReader(stream);
            contents = reader.ReadToEnd();
            return true;
        }
        catch
        {
            contents = null;
            return false;
        }
    }

    /// <summary>
    /// Classifies already-read log contents, without any polling. Null
    /// means the log exists but hasn't reached a recognizable state yet.
    /// </summary>
    public static LaunchDiagnosis? Classify(string logContents)
    {
        var count = PluginCount(logContents);
        if (count is not null)
        {
            return new LaunchDiagnosis.ModsLoaded(count.Value);
        }
        if (logContents.Contains("Chainloader started", StringComparison.Ordinal))
        {
            return new LaunchDiagnosis.ChainloaderStarted();
        }
        return null;
    }

    private static int? PluginCount(string logContents)
    {
        var declared = DeclaredPluginCount(logContents);
        if (declared is not null)
        {
            return declared;
        }
        if (!logContents.Contains("Chainloader started", StringComparison.Ordinal))
        {
            return null;
        }
        var loadingLines = logContents.Split('\n').Count(l => l.Contains("Loading [", StringComparison.Ordinal));
        return loadingLines == 0 ? null : loadingLines;
    }

    private static int? DeclaredPluginCount(string logContents)
    {
        foreach (var line in logContents.Split('\n'))
        {
            var index = line.IndexOf("plugins to load", StringComparison.Ordinal);
            if (index < 0)
            {
                continue;
            }
            var prefix = line[..index].Trim();
            var tokens = prefix.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (tokens.Length > 0 && int.TryParse(tokens[^1], out var number))
            {
                return number;
            }
        }
        return null;
    }
}
