using Bifrost.Core.Models;

namespace Bifrost.Core.Services;

/// <summary>
/// Builds the Home tab's "Saga" stats card: playtime (from Steam's
/// <c>localconfig.vdf</c>), world/character counts (from the Valheim save
/// directory), installed mods by risk class (via <see cref="ModClassifier"/>),
/// and backup count/size (via <see cref="SaveBackup"/>) — rendered as a
/// short list of viking-flavored one-liners. Ported from the macOS reference
/// implementation's <c>SagaStats.swift</c>.
/// </summary>
public static class SagaStats
{
    public sealed record ClassCount(ModClass ModClass, int Count);

    public sealed record SaveEntry(string Name, long ByteSize);

    public sealed class Snapshot
    {
        /// <summary>Null if localconfig.vdf is unreadable or has no Playtime key yet.</summary>
        public int? PlaytimeMinutes { get; init; }
        public int ModCount { get; init; }
        /// <summary>Only classes with count &gt; 0, in <see cref="ModClass"/> declaration order.</summary>
        public List<ClassCount> ClassBreakdown { get; init; } = new();
        public int BackupCount { get; init; }
        public long BackupTotalBytes { get; init; }
        public List<SaveEntry> Worlds { get; init; } = new();
        public List<SaveEntry> Characters { get; init; } = new();

        public static Snapshot Empty => new();
    }

    private static readonly string[] PlaytimePath = { "UserLocalConfigStore", "Software", "Valve", "Steam", "apps", GameLocator.ValheimAppId };

    /// <summary>
    /// Reads Valheim's Playtime (in minutes) out of a
    /// <c>localconfig.vdf</c>'s text, or null if unreadable/missing. See
    /// <see cref="VdfParser.FindNestedValue"/>.
    /// </summary>
    public static int? PlaytimeMinutes(string? localConfigText)
    {
        if (string.IsNullOrEmpty(localConfigText))
        {
            return null;
        }
        var value = VdfParser.FindNestedValue("Playtime", PlaytimePath, localConfigText);
        return value is not null && int.TryParse(value, out var minutes) ? minutes : null;
    }

    /// <summary>
    /// The most recently modified <c>userdata/&lt;profile&gt;/config/localconfig.vdf</c>
    /// under <paramref name="steamRoot"/> — mirrors picking "whichever
    /// numeric userdata profile has the most recent modification date",
    /// same convention the macOS app uses to pick a userdata profile without
    /// needing the user's actual SteamID. Null if no such file exists
    /// anywhere under <c>userdata</c>.
    /// </summary>
    public static string? FindMostRecentLocalConfig(string steamRoot)
    {
        var userdataDir = Path.Combine(steamRoot, "userdata");
        if (!Directory.Exists(userdataDir))
        {
            return null;
        }

        string? best = null;
        var bestTime = DateTime.MinValue;
        foreach (var profileDir in Directory.EnumerateDirectories(userdataDir))
        {
            var path = Path.Combine(profileDir, "config", "localconfig.vdf");
            if (!File.Exists(path))
            {
                continue;
            }
            var modified = File.GetLastWriteTimeUtc(path);
            if (best is null || modified > bestTime)
            {
                best = path;
                bestTime = modified;
            }
        }
        return best;
    }

    /// <summary>Tallies every installed mod's <see cref="ModClassifier"/> classification, keeping only non-empty classes in enum declaration order.</summary>
    public static List<ClassCount> ClassBreakdown(InstalledManifest manifest, IReadOnlyList<ThunderstorePackage> index)
    {
        var counts = new Dictionary<ModClass, int>();
        foreach (var mod in manifest.Mods)
        {
            var classification = ModClassifier.Classify(mod, index);
            counts[classification.ModClass] = counts.GetValueOrDefault(classification.ModClass) + 1;
        }

        var result = new List<ClassCount>();
        foreach (ModClass modClass in Enum.GetValues<ModClass>())
        {
            if (counts.TryGetValue(modClass, out var count) && count > 0)
            {
                result.Add(new ClassCount(modClass, count));
            }
        }
        return result;
    }

    /// <summary>Resolves <c>saveDir/worlds_local</c> (falling back to legacy <c>worlds</c>), groups <c>.fwl</c>/<c>.db</c> files by stem, sums each stem's file sizes.</summary>
    public static List<SaveEntry> WorldEntries(string saveDir) =>
        GroupedEntries(saveDir, "worlds_local", "worlds", new[] { ".fwl", ".db" });

    /// <summary>Resolves <c>saveDir/characters_local</c> (falling back to legacy <c>characters</c>), one entry per <c>.fch</c> file's stem.</summary>
    public static List<SaveEntry> CharacterEntries(string saveDir) =>
        GroupedEntries(saveDir, "characters_local", "characters", new[] { ".fch" });

    private static List<SaveEntry> GroupedEntries(string saveDir, string preferredSubdir, string legacySubdir, string[] extensions)
    {
        var dir = Directory.Exists(Path.Combine(saveDir, preferredSubdir))
            ? Path.Combine(saveDir, preferredSubdir)
            : Path.Combine(saveDir, legacySubdir);
        if (!Directory.Exists(dir))
        {
            return new List<SaveEntry>();
        }

        var sizesByStem = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
        try
        {
            foreach (var file in Directory.EnumerateFiles(dir))
            {
                var ext = Path.GetExtension(file);
                if (!extensions.Any(e => string.Equals(e, ext, StringComparison.OrdinalIgnoreCase)))
                {
                    continue;
                }
                var stem = Path.GetFileNameWithoutExtension(file);
                long size;
                try { size = new FileInfo(file).Length; } catch { size = 0; }
                sizesByStem[stem] = sizesByStem.GetValueOrDefault(stem) + size;
            }
        }
        catch
        {
            return new List<SaveEntry>();
        }

        return sizesByStem
            .OrderBy(kv => kv.Key, StringComparer.OrdinalIgnoreCase)
            .Select(kv => new SaveEntry(kv.Key, kv.Value))
            .ToList();
    }

    /// <summary>Builds a full snapshot from already-loaded state — no I/O of its own beyond the small helpers above, so callers gather manifest/index/backups/localConfigText themselves first.</summary>
    public static Snapshot BuildSnapshot(InstalledManifest manifest, IReadOnlyList<ThunderstorePackage> index, IReadOnlyList<SaveBackup.Backup> backups, string saveDir, string? localConfigText) => new()
    {
        PlaytimeMinutes = PlaytimeMinutes(localConfigText),
        ModCount = manifest.Mods.Count,
        ClassBreakdown = ClassBreakdown(manifest, index),
        BackupCount = backups.Count,
        BackupTotalBytes = backups.Sum(b => b.ByteSize),
        Worlds = WorldEntries(saveDir),
        Characters = CharacterEntries(saveDir),
    };

    /// <summary>
    /// A prioritized, variable-length list of viking-flavored one-liners —
    /// each only appended if its data is present/non-zero. Always returns at
    /// least 1 line (a fallback when everything's empty), at most 5.
    /// </summary>
    public static List<string> FlavorLines(Snapshot snapshot)
    {
        var lines = new List<string>();

        if (snapshot.PlaytimeMinutes is { } minutes)
        {
            var hours = minutes / 60;
            lines.Add($"⚔️ {hours} hour{(hours == 1 ? "" : "s")} carved into the saga so far");
        }
        if (snapshot.Worlds.Count > 0)
        {
            lines.Add($"🌍 {snapshot.Worlds.Count} world{(snapshot.Worlds.Count == 1 ? "" : "s")} under your protection");
        }
        if (snapshot.Characters.Count > 0)
        {
            lines.Add($"🛡️ {snapshot.Characters.Count} hero{(snapshot.Characters.Count == 1 ? "" : "es")} answering the call");
        }
        if (snapshot.ModCount > 0)
        {
            lines.Add($"🔨 {snapshot.ModCount} mod{(snapshot.ModCount == 1 ? "" : "s")} reinforcing the longship");
        }
        if (snapshot.BackupCount > 0)
        {
            lines.Add($"💾 {snapshot.BackupCount} backup{(snapshot.BackupCount == 1 ? "" : "s")} guarding {FormatBytes(snapshot.BackupTotalBytes)} of saga");
        }

        if (lines.Count == 0)
        {
            lines.Add("🪓 No saga recorded yet — sharpen your axe and begin");
        }
        return lines;
    }

    /// <summary>Decimal (1000-based) human-readable byte formatting, matching macOS's <c>ByteCountFormatter(.file)</c> convention (Finder-style "1.2 GB") rather than a binary 1024-based one.</summary>
    public static string FormatBytes(long bytes)
    {
        string[] units = { "bytes", "KB", "MB", "GB", "TB" };
        double value = bytes;
        var unitIndex = 0;
        while (value >= 1000 && unitIndex < units.Length - 1)
        {
            value /= 1000;
            unitIndex++;
        }
        return unitIndex == 0
            ? $"{bytes} bytes"
            : $"{value.ToString("0.#", System.Globalization.CultureInfo.InvariantCulture)} {units[unitIndex]}";
    }
}
