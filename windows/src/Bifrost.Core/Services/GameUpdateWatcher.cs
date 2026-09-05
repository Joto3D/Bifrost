namespace Bifrost.Core.Services;

/// <summary>
/// Detects when Valheim's Steam build changes between checks, so a mod that
/// broke against a new build isn't silently trusted just because it was
/// working yesterday — and so a Steam "verify integrity of game files" pass
/// (which can strip BepInEx's own files right back out) gets flagged instead
/// of just quietly failing to launch modded. Ported from the macOS reference
/// implementation's <c>GameUpdateWatcher.swift</c>.
///
/// Reads <c>buildid</c>/<c>SizeOnDisk</c> straight out of Steam's own
/// <c>appmanifest_892970.acf</c>, using the same tiny VDF reader
/// <see cref="GameLocator"/> already relies on. The last-seen buildid is
/// persisted to a small text file (see <see cref="BifrostPaths.GameUpdateLastSeenPath"/>)
/// rather than the macOS app's <c>UserDefaults</c> — same role, injectable
/// path for tests either way.
/// </summary>
public static class GameUpdateWatcher
{
    /// <summary>The bits of appmanifest_892970.acf this watcher cares about.</summary>
    public sealed record ManifestInfo(string BuildId, string? SizeOnDisk);

    public enum ResultKind { FirstSeen, Unchanged, Updated, Unavailable }

    /// <summary>The outcome of comparing the manifest's current buildid against whatever was persisted from the last check.</summary>
    public sealed record CheckResult(ResultKind Kind, string? PreviousBuildId = null, string? CurrentBuildId = null)
    {
        /// <summary>The banner text for <see cref="ResultKind.Updated"/>; null for every other case.</summary>
        public string? Message => Kind == ResultKind.Updated
            ? $"Valheim updated (build {PreviousBuildId} → {CurrentBuildId}) — mods may be broken until updated; BepInEx may need reinstalling if Steam verified files."
            : null;
    }

    /// <summary>
    /// Reads buildid/SizeOnDisk from &lt;steamlib&gt;/steamapps/appmanifest_892970.acf
    /// for the Steam library gameDir lives under. gameDir is shaped like
    /// &lt;library&gt;/steamapps/common/&lt;installdir&gt; (see
    /// <see cref="GameLocator.Locate"/>), so the manifest sits two
    /// directories up from it. Read-only — never writes anything.
    /// </summary>
    public static ManifestInfo? ReadManifestInfo(string gameDir)
    {
        var commonDir = Directory.GetParent(gameDir);
        var steamappsDir = commonDir?.Parent?.FullName;
        if (steamappsDir is null)
        {
            return null;
        }

        var manifestPath = Path.Combine(steamappsDir, $"appmanifest_{GameLocator.ValheimAppId}.acf");
        if (!File.Exists(manifestPath))
        {
            return null;
        }

        string text;
        try { text = File.ReadAllText(manifestPath); } catch { return null; }

        var buildId = VdfParser.GetValue("buildid", text);
        if (buildId is null)
        {
            return null;
        }
        var sizeOnDisk = VdfParser.GetValue("SizeOnDisk", text);
        return new ManifestInfo(buildId, sizeOnDisk);
    }

    /// <summary>
    /// Reads the current buildid (via <see cref="ReadManifestInfo"/>) and
    /// compares it against whatever was previously persisted at
    /// <paramref name="lastSeenPath"/>, always persisting the current value
    /// back afterward. <paramref name="lastSeenPath"/> defaults to the real
    /// persisted location but is injectable so this stays testable without
    /// touching it.
    /// </summary>
    public static CheckResult Check(string? gameDir, string? lastSeenPath = null)
    {
        lastSeenPath ??= BifrostPaths.GameUpdateLastSeenPath;

        if (gameDir is null)
        {
            return new CheckResult(ResultKind.Unavailable);
        }
        var info = ReadManifestInfo(gameDir);
        if (info is null)
        {
            return new CheckResult(ResultKind.Unavailable);
        }

        string? previous = null;
        try
        {
            if (File.Exists(lastSeenPath))
            {
                previous = File.ReadAllText(lastSeenPath).Trim();
            }
        }
        catch { /* treat unreadable as "no prior record" */ }

        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(lastSeenPath)!);
            File.WriteAllText(lastSeenPath, info.BuildId);
        }
        catch { /* best effort — persistence failing shouldn't crash the check */ }

        if (string.IsNullOrEmpty(previous))
        {
            return new CheckResult(ResultKind.FirstSeen, CurrentBuildId: info.BuildId);
        }
        if (previous == info.BuildId)
        {
            return new CheckResult(ResultKind.Unchanged, CurrentBuildId: info.BuildId);
        }
        return new CheckResult(ResultKind.Updated, previous, info.BuildId);
    }
}
