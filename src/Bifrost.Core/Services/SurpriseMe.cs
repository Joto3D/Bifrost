using Bifrost.Core.Models;

namespace Bifrost.Core.Services;

/// <summary>
/// Picks a random well-rated, not-yet-installed mod for Browse's "Surprise
/// Me" dice button. Ported from the macOS reference implementation's
/// <c>SurpriseMe.swift</c>.
/// </summary>
public static class SurpriseMe
{
    public const int MinimumRating = 20;

    /// <summary>
    /// Packages worth surprising someone with: rated at least
    /// <see cref="MinimumRating"/>, not deprecated, not the BepInEx loader
    /// pack itself, and not already installed. Defensive even though
    /// <see cref="ThunderstoreClient.FetchIndexAsync"/> already excludes
    /// deprecated packages and the loader pack from what it returns — this
    /// re-checks anyway so the function is correct against any raw index,
    /// including test fixtures.
    /// </summary>
    public static List<ThunderstorePackage> Eligible(IReadOnlyList<ThunderstorePackage> index, InstalledManifest manifest)
    {
        var installedFullNames = new HashSet<string>(manifest.Mods.Select(m => m.FullName));
        return index.Where(p =>
            p.RatingScore >= MinimumRating
            && !p.IsDeprecated
            && p.FullName != ModManager.LoaderFullName
            && !installedFullNames.Contains(p.FullName)
        ).ToList();
    }

    /// <summary>
    /// Unseeded system RNG, deliberately — every press of the dice should
    /// feel like a fresh roll, not a reproducible one (unlike
    /// <see cref="Flavor.Quip"/>). Null if nothing qualifies.
    /// </summary>
    public static ThunderstorePackage? Pick(IReadOnlyList<ThunderstorePackage> index, InstalledManifest manifest)
    {
        var eligible = Eligible(index, manifest);
        return eligible.Count == 0 ? null : eligible[Random.Shared.Next(eligible.Count)];
    }
}
