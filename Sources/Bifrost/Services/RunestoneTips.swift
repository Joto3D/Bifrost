import Foundation

/// The "Runestone" tip line's data: a rotating mix of genuinely useful
/// Bifrost tips and short Valheim lore-ish lines, shown on Home
/// (`RunestoneTipCard`). Purely presentational data — nothing here reads or
/// mutates any app state.
enum RunestoneTips {
    struct Tip: Sendable, Equatable {
        let text: String
        /// `false` for a practical Bifrost tip, `true` for a lore-flavored
        /// line — drives the small "Tip"/"Lore" label in `RunestoneTipCard`.
        let isLore: Bool
    }

    /// ~15 genuinely useful tips followed by ~10 lore-ish lines. Every entry
    /// is unique (see `DebugCheck`'s "fun" section, which asserts this).
    static let all: [Tip] = [
        // MARK: Useful tips
        Tip(text: "Drag any mod zip onto this window to install it.", isLore: false),
        Tip(text: "Shift+H toggles first person — check keybind chips on Installed rows.", isLore: false),
        Tip(text: "Backups live in Settings → Backups.", isLore: false),
        Tip(text: "The dice button in Browse rolls a random well-rated mod worth trying.", isLore: false),
        Tip(text: "Profiles let you swap your whole modlist before joining a friend's server.", isLore: false),
        Tip(text: "\"Join a Server…\" builds a safe modlist automatically before you connect.", isLore: false),
        Tip(text: "An nxm:// link from Nexus Mods installs straight into Bifrost — no manual download.", isLore: false),
        Tip(text: "Disabling a mod keeps its files on disk — no need to reinstall it later.", isLore: false),
        Tip(text: "The Installed tab's colored badges show how risky a mod is on someone else's server.", isLore: false),
        Tip(text: "Bifrost always launches through Steam, never directly — so your playtime still counts.", isLore: false),
        Tip(text: "A stale automatic backup gets refreshed for you right before every modded launch.", isLore: false),
        Tip(text: "You can restore an older backup from Settings without touching your current save.", isLore: false),
        Tip(text: "Update checks skip mods installed from a local zip — there's no index entry to compare.", isLore: false),
        Tip(text: "The refresh icon on Home re-runs every setup check without restarting the app.", isLore: false),
        Tip(text: "A mod with a config file gets an in-app editor — no digging through BepInEx/config by hand.", isLore: false),
        // MARK: Lore
        Tip(text: "Hugin appears to guide the fallen — some say he also debugs mod conflicts, for a price.", isLore: true),
        Tip(text: "A karve is small enough for a river, brave enough for the sea.", isLore: true),
        Tip(text: "Greydwarves fear fire, sunlight, and moderately competent base defenses.", isLore: true),
        Tip(text: "The Elder does not care about your ping.", isLore: true),
        Tip(text: "A well-fed Viking hits harder — bring more than one food to the fight.", isLore: true),
        Tip(text: "Portals cannot carry ore, but they carry grudges just fine.", isLore: true),
        Tip(text: "Odin walks Midgard in disguise, usually asking oddly specific questions.", isLore: true),
        Tip(text: "Mistlands fog hides cliffs, ticks, and your own poor life choices equally well.", isLore: true),
        Tip(text: "A lox never forgets who fed it, and never forgets who didn't.", isLore: true),
        Tip(text: "Valheim's stars are the same every night — the deaths rarely are.", isLore: true),
    ]
}
