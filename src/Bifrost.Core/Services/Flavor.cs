namespace Bifrost.Core.Services;

/// <summary>
/// Purely decorative launch quips shown alongside (never replacing) the real
/// launch status line while a launch is in progress. Ported from the macOS
/// reference implementation's <c>Flavor.swift</c> — same 25 quips.
/// </summary>
public static class Flavor
{
    public static readonly IReadOnlyList<string> Quips = new List<string>
    {
        "Sharpening the axe…",
        "Rowing the karve ashore…",
        "Bribing Hugin with breadcrumbs…",
        "Waking the Greydwarfs gently…",
        "Polishing Mjölnir replicas…",
        "Counting runestones twice…",
        "Braiding the beard for battle…",
        "Asking Odin for a tailwind…",
        "Feeding the boar a snack…",
        "Tuning the longship's oars…",
        "Checking the mead reserves…",
        "Whittling a spare arrow…",
        "Reinforcing the palisade…",
        "Consulting the sacrificial stones…",
        "Untangling the fishing net…",
        "Warming up the campfire…",
        "Negotiating with a troll…",
        "Stitching the linen cape…",
        "Rolling the dice with Yggdrasil…",
        "Greasing the portal runes…",
        "Herding stray lox…",
        "Sweeping the longhouse floor…",
        "Waxing the shield rim…",
        "Listening for Freyr's blessing…",
        "Loading the ballista, gently…",
    };

    /// <summary>
    /// Deterministic per-launch, not per-render: the caller generates one
    /// <paramref name="seed"/> when a launch starts (e.g. a Unix timestamp)
    /// and reuses it across every phase-transition status update during that
    /// same launch, so the caption doesn't flicker between quips as phases
    /// change — a brand-new launch gets a fresh seed and likely a fresh
    /// quip.
    /// </summary>
    public static string Quip(int seed)
    {
        if (Quips.Count == 0)
        {
            return "";
        }
        var random = new Random(seed);
        return Quips[random.Next(Quips.Count)];
    }
}
