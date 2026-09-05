using Bifrost.Core.Models;

namespace Bifrost.Core.Services;

/// <summary>
/// A mod's risk category for joining an unfamiliar multiplayer server —
/// purely advisory. Nothing here ever disables a mod on its own; it only
/// informs the guided "Join a Server" flow (<see cref="ServerJoinPlanner"/>)
/// and the Installed tab's per-row badge. Ported from the macOS reference
/// implementation's <c>ModClassifier.swift</c>.
/// </summary>
public enum ModClass
{
    /// <summary>Purely visual/QoL — affects nothing the server or other players can observe. Safe to leave enabled joining any server, running the mod or not.</summary>
    ClientOnly,

    /// <summary>
    /// Adds craftable/lootable items. BepInEx just stops loading the item's
    /// prefab when disabled — it doesn't delete anything from a save — but
    /// an item already in an inventory can end up hidden or unusable, so the
    /// safer default is to leave these enabled rather than disable them.
    /// </summary>
    AddsItems,

    /// <summary>Changes world generation, biomes, or other persistent world state. Mismatched between client and the server being joined can desync or corrupt shared world data.</summary>
    WorldAltering,

    /// <summary>A framework/library whose whole purpose is enforcing client/server version parity (Jotunn-style) — it needs to match whatever the server runs, but is never something to blanket-disable for joining one.</summary>
    ServerSynced,

    /// <summary>No curated entry, no informative Thunderstore category, and no heuristic keyword hit — Bifrost has no signal either way.</summary>
    Unknown,
}

public static class ModClassExtensions
{
    public static string DisplayName(this ModClass modClass) => modClass switch
    {
        ModClass.ClientOnly => "Client-only",
        ModClass.AddsItems => "Adds items",
        ModClass.WorldAltering => "World-altering",
        ModClass.ServerSynced => "Server-synced",
        ModClass.Unknown => "Unknown",
        _ => throw new ArgumentOutOfRangeException(nameof(modClass)),
    };

    /// <summary>A single emoji standing in for a tinted capsule color in contexts (plain-text <c>--check</c> output) that can't render actual color.</summary>
    public static string Glyph(this ModClass modClass) => modClass switch
    {
        ModClass.ClientOnly => "🟢",
        ModClass.AddsItems => "🟠",
        ModClass.WorldAltering => "🔴",
        ModClass.ServerSynced => "🔵",
        ModClass.Unknown => "⚪",
        _ => throw new ArgumentOutOfRangeException(nameof(modClass)),
    };

    /// <summary>One-line explanation shown in the Installed tab badge's tooltip.</summary>
    public static string Explanation(this ModClass modClass) => modClass switch
    {
        ModClass.ClientOnly => "Purely client-side — safe to keep enabled on any server.",
        ModClass.AddsItems => "Adds items to your inventory — disabling it after joining a server that doesn't run it may hide or strand those items.",
        ModClass.WorldAltering => "Changes world generation or persistent world state — risky if the server you're joining doesn't run it too.",
        ModClass.ServerSynced => "Enforces version parity with the server (Jotunn-style) — must match whatever the server runs.",
        ModClass.Unknown => "Bifrost has no information about this mod's multiplayer impact.",
        _ => throw new ArgumentOutOfRangeException(nameof(modClass)),
    };
}

/// <summary>One classification result: the class plus a short machine-readable trail of why — surfaced in the Installed tab badge's tooltip and the guided join-flow's plan, and printed by <c>--check</c>.</summary>
public sealed record ModClassification(ModClass ModClass, string Basis);

/// <summary>
/// Classifies installed mods for the guided "Join a Server" flow and the
/// Installed tab's badges.
///
/// Resolution order (first match wins):
///  1. <see cref="CuratedOverrides"/> — a small built-in table for mods whose
///     actual multiplayer behavior this developer knows for a fact, since
///     Thunderstore's own category tags are author-supplied and often
///     missing or misleading (a pure FPS-counter overlay, for instance,
///     commonly carries no "Client-side" tag at all).
///  2. Thunderstore category tags from the cached index, when the mod's
///     <see cref="ThunderstorePackage"/> is known (null for a source ==
///     "local"/"nexus" mod, or one dropped from the index between installs).
///  3. Keyword heuristics against the package's name/description (falling
///     back to the mod's own full name when no package is known at all).
///  4. <see cref="ModClass.Unknown"/>.
/// </summary>
public static class ModClassifier
{
    /// <summary>Built-in "we know exactly what this is" table, keyed by Thunderstore full name ("Author-Name"). Takes priority over anything derived from the index.</summary>
    public static readonly IReadOnlyDictionary<string, ModClass> CuratedOverrides = new Dictionary<string, ModClass>
    {
        ["Azumatt-FirstPersonMode"] = ModClass.ClientOnly,
        ["K_xD-ValheimFPSOptimizer"] = ModClass.ClientOnly,
        ["LEGIOmods-AutoLodBias"] = ModClass.ClientOnly,
        ["PUP82-PUP_FPS"] = ModClass.ClientOnly,
        ["ColdSpirit-ValheimGammaMod"] = ModClass.ClientOnly,
        ["shudnal-GammaOfNightLights"] = ModClass.ClientOnly,
        ["BetterSounds-BetterSounds"] = ModClass.ClientOnly,
        ["AAAValheimExperience-ImmersiveParryAudio"] = ModClass.ClientOnly,
        // Willybach's HD/texture packs — purely visual asset replacements.
        ["Willybach-Willybachs_HD_Seasonality"] = ModClass.ClientOnly,
        ["blacks7ar-GunzNBullets"] = ModClass.AddsItems,
        // Graphics-preset overhaul — purely visual.
        ["CarlosMods-CLGMMOGraphics"] = ModClass.ClientOnly,
        ["RandyKnapp-EquipmentAndQuickSlots"] = ModClass.AddsItems,
        ["Soloredis-RtDBiomes"] = ModClass.WorldAltering,
        ["Soloredis-RtDOcean"] = ModClass.WorldAltering,
        ["ValheimModding-Jotunn"] = ModClass.ServerSynced,
    };

    /// <summary>Classifies <paramref name="fullName"/>, consulting <paramref name="package"/> (that full name's entry in the cached Thunderstore index, when known) for its categories and description.</summary>
    public static ModClassification Classify(string fullName, ThunderstorePackage? package)
    {
        if (CuratedOverrides.TryGetValue(fullName, out var curated))
        {
            return new ModClassification(curated, "curated");
        }

        if (package?.Categories is { } categories)
        {
            var byCategory = ClassifyByCategory(categories);
            if (byCategory is not null)
            {
                return new ModClassification(byCategory.Value.ModClass, $"category: {byCategory.Value.Category}");
            }
        }

        var haystack = string.Join(" ", new[] { package?.Name, package?.LatestVersion?.Description, fullName }.Where(s => !string.IsNullOrEmpty(s)));
        var byHeuristic = ClassifyByHeuristic(haystack);
        if (byHeuristic is not null)
        {
            return new ModClassification(byHeuristic.Value.ModClass, $"heuristic: contains \"{byHeuristic.Value.Keyword}\"");
        }

        return new ModClassification(ModClass.Unknown, "no signal");
    }

    /// <summary>Convenience for a manifest entry against an already-fetched index.</summary>
    public static ModClassification Classify(InstalledManifest.InstalledMod mod, IReadOnlyList<ThunderstorePackage> index) =>
        Classify(mod.FullName, index.FirstOrDefault(p => p.FullName == mod.FullName));

    /// <summary>
    /// "World Generation" wins over a bare "Client-side"/"Server-side" tag
    /// since it's the single most specific and highest-risk signal
    /// Thunderstore's categories carry on their own; "Client-side" (a mod
    /// explicitly marked safe client-only) wins over a bare "Server-side"
    /// tag, which by itself just means "this needs installing on servers
    /// too" — Jotunn-style version-enforcement territory rather than
    /// anything actively risky.
    /// </summary>
    private static (ModClass ModClass, string Category)? ClassifyByCategory(IReadOnlyList<string> categories)
    {
        if (categories.Contains("World Generation"))
        {
            return (ModClass.WorldAltering, "World Generation");
        }
        if (categories.Contains("Client-side"))
        {
            return (ModClass.ClientOnly, "Client-side");
        }
        if (categories.Contains("Server-side"))
        {
            return (ModClass.ServerSynced, "Server-side");
        }
        return null;
    }

    private static readonly string[] ClientOnlyKeywords = { "texture", "sound", "fps", "camera", "ui" };
    private static readonly string[] WorldAlteringKeywords = { "biome", "world gen", "worldgen", "location" };
    private static readonly string[] AddsItemsKeywords = { "weapon", "item", "armor" };

    /// <summary>Checked in clientOnly -> worldAltering -> addsItems order — matches the priority the feature spec lists the keyword groups in.</summary>
    private static (ModClass ModClass, string Keyword)? ClassifyByHeuristic(string haystack)
    {
        var lowered = haystack.ToLowerInvariant();
        foreach (var keyword in ClientOnlyKeywords)
        {
            if (lowered.Contains(keyword))
            {
                return (ModClass.ClientOnly, keyword);
            }
        }
        foreach (var keyword in WorldAlteringKeywords)
        {
            if (lowered.Contains(keyword))
            {
                return (ModClass.WorldAltering, keyword);
            }
        }
        foreach (var keyword in AddsItemsKeywords)
        {
            if (lowered.Contains(keyword))
            {
                return (ModClass.AddsItems, keyword);
            }
        }
        return null;
    }
}
