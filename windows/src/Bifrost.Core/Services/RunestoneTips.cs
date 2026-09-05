namespace Bifrost.Core.Services;

/// <summary>
/// Data for the Home tab's runestone tip card — a mix of practical Bifrost
/// tips and Valheim lore lines, picked at random. Ported from the macOS
/// reference implementation's <c>RunestoneTips.swift</c> — same 25 entries,
/// same order (tips first, then lore).
/// </summary>
public static class RunestoneTips
{
    public sealed record Tip(string Text, bool IsLore);

    public static readonly IReadOnlyList<Tip> All = new List<Tip>
    {
        // Useful tips
        new("Drag any mod zip onto this window to install it.", false),
        new("Shift+H toggles first person — check keybind chips on Installed rows.", false),
        new("Backups live in Settings → Backups.", false),
        new("The dice button in Browse rolls a random well-rated mod worth trying.", false),
        new("Profiles let you swap your whole modlist before joining a friend's server.", false),
        new("\"Join a Server…\" builds a safe modlist automatically before you connect.", false),
        new("An nxm:// link from Nexus Mods installs straight into Bifrost — no manual download.", false),
        new("Disabling a mod keeps its files on disk — no need to reinstall it later.", false),
        new("The Installed tab's colored badges show how risky a mod is on someone else's server.", false),
        new("Bifrost always launches through Steam, never directly — so your playtime still counts.", false),
        new("A stale automatic backup gets refreshed for you right before every modded launch.", false),
        new("You can restore an older backup from Settings without touching your current save.", false),
        new("Update checks skip mods installed from a local zip — there's no index entry to compare.", false),
        new("The refresh icon on Home re-runs every setup check without restarting the app.", false),
        new("A mod with a config file gets an in-app editor — no digging through BepInEx/config by hand.", false),
        // Lore
        new("Hugin appears to guide the fallen — some say he also debugs mod conflicts, for a price.", true),
        new("A karve is small enough for a river, brave enough for the sea.", true),
        new("Greydwarves fear fire, sunlight, and moderately competent base defenses.", true),
        new("The Elder does not care about your ping.", true),
        new("A well-fed Viking hits harder — bring more than one food to the fight.", true),
        new("Portals cannot carry ore, but they carry grudges just fine.", true),
        new("Odin walks Midgard in disguise, usually asking oddly specific questions.", true),
        new("Mistlands fog hides cliffs, ticks, and your own poor life choices equally well.", true),
        new("A lox never forgets who fed it, and never forgets who didn't.", true),
        new("Valheim's stars are the same every night — the deaths rarely are.", true),
    };

    /// <summary>A fresh random index into <see cref="All"/> — unseeded, so it differs run to run (matches macOS's per-launch <c>Int.random(in:)</c> pick).</summary>
    public static int RandomIndex() => Random.Shared.Next(All.Count);

    /// <summary>
    /// A random index guaranteed to differ from <paramref name="current"/>
    /// (as long as <see cref="All"/> has more than one entry) — the "show
    /// another tip" button's behavior, so it always visibly changes the tip.
    /// </summary>
    public static int NextIndex(int current)
    {
        if (All.Count <= 1)
        {
            return current;
        }
        int next;
        do
        {
            next = Random.Shared.Next(All.Count);
        } while (next == current);
        return next;
    }
}
