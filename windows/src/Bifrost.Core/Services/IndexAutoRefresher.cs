namespace Bifrost.Core.Services;

/// <summary>
/// On app open, if the cached Thunderstore package index is missing or older
/// than a day, kicks off a quiet background refresh via
/// <see cref="ThunderstoreClient"/>'s existing force-fetch path — no modal,
/// no blocking of startup. Ported from the macOS reference implementation's
/// <c>IndexAutoRefresher.swift</c>.
///
/// Reads the cache file's own last-write time directly, rather than adding a
/// new accessor to <see cref="ThunderstoreClient"/> — the cache path is a
/// fixed, already-relied-upon convention (see <see cref="BifrostPaths.PackageIndexCachePath"/>).
/// </summary>
public static class IndexAutoRefresher
{
    public static readonly TimeSpan StaleAfter = TimeSpan.FromHours(24);

    /// <summary>True when the cache file is missing entirely, or its last-write time is more than <see cref="StaleAfter"/> before <paramref name="now"/> (UTC).</summary>
    public static bool IsStale(string? cacheFilePath = null, DateTime? now = null)
    {
        cacheFilePath ??= BifrostPaths.PackageIndexCachePath;
        if (!File.Exists(cacheFilePath))
        {
            return true;
        }
        var modified = File.GetLastWriteTimeUtc(cacheFilePath);
        return (now ?? DateTime.UtcNow) - modified > StaleAfter;
    }

    /// <summary>
    /// If the cache is stale, kicks off a background force-refresh and
    /// returns a short human-readable status note once it finishes
    /// (successfully or not); returns null without doing anything if the
    /// cache is already fresh.
    /// </summary>
    public static async Task<string?> RefreshIfStaleAsync(ThunderstoreClient client, string? cacheFilePath = null)
    {
        if (!IsStale(cacheFilePath))
        {
            return null;
        }
        try
        {
            var packages = await client.FetchIndexAsync(force: true);
            return $"Thunderstore index refreshed in the background ({packages.Count} packages)";
        }
        catch (Exception ex)
        {
            return $"Background index refresh failed: {ex.Message}";
        }
    }
}
