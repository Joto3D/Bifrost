namespace Bifrost.Core.Models;

/// <summary>
/// Bifrost's own record of what it has installed into the game directory —
/// the source of truth <see cref="Services.ModManager"/> reads and writes for
/// every install/uninstall/update/enable operation, and for update-availability
/// checks. This is deliberately independent of anything actually on disk.
///
/// Persisted as JSON at <c>%AppData%\Bifrost\manifest.json</c>. Field names
/// match the macOS reference implementation's <c>InstalledManifest.swift</c>
/// exactly (camelCase, no snake_case), so a manifest could conceptually be
/// shared across platforms later.
/// </summary>
public sealed class InstalledManifest
{
    /// <summary>
    /// The installed BepInEx loader pack (denikson-BepInExPack_Valheim), if
    /// Bifrost has installed or recorded one.
    /// </summary>
    public LoaderInfo? Loader { get; set; }

    /// <summary>Every mod Bifrost has installed, keyed by full name ("Author-Name").</summary>
    public List<InstalledMod> Mods { get; set; } = new();

    public static InstalledManifest Empty => new();

    public sealed class LoaderInfo
    {
        public string Version { get; set; } = string.Empty;
    }

    public sealed class InstalledMod
    {
        /// <summary>Thunderstore's "Author-Name" full name.</summary>
        public string FullName { get; set; } = string.Empty;
        public string Version { get; set; } = string.Empty;
        public bool Enabled { get; set; }

        /// <summary>
        /// Every file this mod's install wrote, as paths relative to the game
        /// directory (e.g. "BepInEx/plugins/Author-Name/Foo.dll"), using
        /// forward slashes regardless of OS so the JSON shape matches the
        /// macOS app byte-for-byte. These always reflect the *current*
        /// on-disk names — enable/disable rewrites the .dll/.dll.disabled
        /// entries in place.
        /// </summary>
        public List<string> Files { get; set; } = new();

        /// <summary>
        /// Where this mod came from: "thunderstore" for anything
        /// resolved/installed against the Thunderstore index (Browse tab,
        /// dependency resolution, updates), or "local" for a mod installed
        /// from a file on disk (see <see cref="Services.ModManager.InstallFromFileAsync"/>)
        /// — local mods are excluded from update checks since there's no
        /// index entry to compare against. Missing from an older
        /// manifest.json written before this field existed decodes as
        /// "thunderstore" (the property initializer below), never fails to
        /// load.
        /// </summary>
        public string Source { get; set; } = "thunderstore";

        /// <summary>
        /// For a <see cref="Source"/> == "nexus" entry (installed via the
        /// <c>nxm://</c> "Mod Manager Download" flow — see
        /// <see cref="Services.ModManager.InstallFromNexusAsync"/>): the
        /// Nexus mod id, used by <see cref="Services.ModManager.UpdatesAvailableAsync"/>
        /// to check back with Nexus's own API for a newer version instead of
        /// the Thunderstore index. Null for every other source.
        /// </summary>
        public int? NexusModId { get; set; }

        /// <summary>The Nexus file id alongside <see cref="NexusModId"/> for the same "nexus"-sourced entries. Recorded for reference; not currently used to resolve anything on its own.</summary>
        public int? NexusFileId { get; set; }
    }
}
