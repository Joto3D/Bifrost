using System.IO.Compression;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Bifrost.Core.Models;

namespace Bifrost.Core.Services;

/// <summary>
/// Exporting and importing Bifrost profiles for sharing a mod list with
/// friends — either Bifrost's own compact native format (a base64 string, or
/// a pretty-printed <c>.bifrostprofile</c> file) or, when reachable, direct
/// interop with r2modman/Thunderstore Mod Manager's "profile code" system
/// (<see cref="ExportR2CodeAsync"/>/<see cref="ImportR2CodeAsync"/>), so a
/// friend on Windows/Linux/Mac running r2modman can generate a code Bifrost
/// imports directly, and vice versa. Ported from the macOS reference
/// implementation's <c>ProfileShare.swift</c> — the native JSON shape is
/// intentionally byte-for-byte compatible so a share code or
/// <c>.bifrostprofile</c> file works identically on either platform.
///
/// A profile only ever records membership + enabled state (see
/// <see cref="Profile"/>); sharing follows the same contract. The exported
/// version travels along for reference, but importing always re-resolves
/// against the recipient's own cached Thunderstore index and installs
/// whatever that index currently calls latest — exactly
/// <see cref="ModManager.ResolveAsync"/>'s own long-standing convention
/// (Bifrost has never pinned exact dependency versions). When the
/// recipient's index has moved on since the export, that's surfaced as a
/// "substituted" version in the built <see cref="ImportPlan"/> rather than
/// silently applied.
/// </summary>
public static class ProfileShare
{
    public abstract class ProfileShareException(string message) : Exception(message)
    {
        public sealed class InvalidFormat() : ProfileShareException("That doesn't look like a Bifrost share code or profile file");
        public sealed class UnsupportedVersion(int version) : ProfileShareException($"This profile was exported by a newer version of Bifrost (format {version}) and can't be read");
        public sealed class EmptyMods() : ProfileShareException("That profile has no shareable mods in it");
        public sealed class BadResponse(int status) : ProfileShareException($"Thunderstore's profile-code service returned HTTP {status}");
        public sealed class R2xNotFound() : ProfileShareException("That profile code's archive didn't contain an export.r2x");
    }

    // MARK: - Native format

    /// <summary>
    /// One mod entry in the native exported JSON. <see cref="Source"/>/<see cref="NexusModId"/>
    /// are only ever present together, marking a mod that was installed via
    /// the <c>nxm://</c> flow (source == "nexus") — there's no Thunderstore
    /// identity to resolve on the recipient's end, so importing explains
    /// rather than resolves these (see <see cref="ImportPlan.UnresolvableReason"/>).
    /// source == "local" mods never appear here at all — see <see cref="Export"/>.
    /// </summary>
    public sealed class ExportedMod
    {
        [JsonPropertyName("fullName")] public string FullName { get; set; } = "";
        [JsonPropertyName("version")] public string Version { get; set; } = "";
        [JsonPropertyName("enabled")] public bool Enabled { get; set; }
        [JsonPropertyName("source")] public string? Source { get; set; }
        [JsonPropertyName("nexusModId")] public int? NexusModId { get; set; }
    }

    /// <summary>
    /// The full shape of a native share — both the base64 string handed to
    /// <see cref="Plan(string,IReadOnlyList{ThunderstorePackage},InstalledManifest)"/>
    /// and the pretty-printed <c>.bifrostprofile</c> file are exactly this
    /// JSON. <see cref="Bifrost"/> is a format version, bumped only if this
    /// shape ever needs a breaking change; <c>Plan</c> rejects anything
    /// other than 1.
    /// </summary>
    public sealed class ExportedProfile
    {
        [JsonPropertyName("bifrost")] public int Bifrost { get; set; } = 1;
        [JsonPropertyName("name")] public string Name { get; set; } = "";
        [JsonPropertyName("mods")] public List<ExportedMod> Mods { get; set; } = new();
    }

    /// <summary>
    /// What <see cref="Export"/>/<see cref="ExportFile"/> produced: the JSON
    /// document itself (for <see cref="ExportFile"/> to write
    /// pretty-printed), the compact base64 string (for a share code), and
    /// the full names of any source == "local" mods that got left out
    /// because they have no identity a recipient could ever resolve.
    /// </summary>
    public sealed record ExportOutcome(ExportedProfile Json, string EncodedString, List<string> SkippedLocalMods);

    private static readonly JsonSerializerOptions CompactOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    private static readonly JsonSerializerOptions PrettyOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };

    /// <summary>
    /// Builds a shareable export of <paramref name="profile"/>,
    /// cross-referencing <paramref name="manifest"/> for each mod's actual
    /// installed version/source (a <see cref="Profile.ProfileMod"/> itself
    /// only records membership + enabled state — see <see cref="Profile"/>).
    /// Three kinds of profile mod never make it into the export:
    ///  - source == "local": no identity a recipient could ever resolve
    ///    against Thunderstore — collected into <see cref="ExportOutcome.SkippedLocalMods"/>
    ///    so the caller can warn about them.
    ///  - not currently in <paramref name="manifest"/> at all (the profile
    ///    drifted from what's actually installed) — there's no version to
    ///    share, and silently skipping matches how
    ///    <see cref="ProfileStore.Apply"/> already treats a profile/manifest
    ///    mismatch elsewhere.
    ///  - (neither of the above needs special-casing for source == "nexus":
    ///    those DO get exported, just marked — see <see cref="ExportedMod"/>.)
    /// </summary>
    public static ExportOutcome Export(Profile profile, InstalledManifest manifest)
    {
        var installedByFullName = manifest.Mods.ToDictionary(m => m.FullName);

        var mods = new List<ExportedMod>();
        var skippedLocal = new List<string>();
        foreach (var profileMod in profile.Mods)
        {
            if (!installedByFullName.TryGetValue(profileMod.FullName, out var installed))
            {
                continue;
            }
            if (installed.Source == "local")
            {
                skippedLocal.Add(profileMod.FullName);
                continue;
            }
            var isNexus = installed.Source == "nexus";
            mods.Add(new ExportedMod
            {
                FullName = profileMod.FullName,
                Version = installed.Version,
                Enabled = profileMod.Enabled,
                Source = isNexus ? "nexus" : null,
                NexusModId = isNexus ? installed.NexusModId : null,
            });
        }

        var json = new ExportedProfile { Bifrost = 1, Name = profile.Name, Mods = mods };
        var encoded = Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(json, CompactOptions));
        return new ExportOutcome(json, encoded, skippedLocal);
    }

    /// <summary>
    /// <see cref="Export"/>, written pretty-printed to
    /// <paramref name="path"/> (a <c>.bifrostprofile</c> file) instead of
    /// returned as a base64 string. Returns the same
    /// <see cref="ExportOutcome.SkippedLocalMods"/> warning list
    /// <see cref="Export"/> would.
    /// </summary>
    public static List<string> ExportFile(Profile profile, InstalledManifest manifest, string path)
    {
        var outcome = Export(profile, manifest);
        File.WriteAllText(path, JsonSerializer.Serialize(outcome.Json, PrettyOptions));
        return outcome.SkippedLocalMods;
    }

    /// <summary>
    /// Parses a native share string (as produced by <see cref="Export"/>'s
    /// <see cref="ExportOutcome.EncodedString"/>) and resolves it into an
    /// <see cref="ImportPlan"/> against <paramref name="index"/>/<paramref name="manifest"/>.
    /// </summary>
    public static ImportPlan Plan(string nativeString, IReadOnlyList<ThunderstorePackage> index, InstalledManifest manifest)
    {
        byte[] data;
        try
        {
            data = Convert.FromBase64String(nativeString.Trim());
        }
        catch
        {
            throw new ProfileShareException.InvalidFormat();
        }
        return PlanFromData(data, index, manifest);
    }

    /// <summary>Parses a native <c>.bifrostprofile</c> file (as produced by <see cref="ExportFile"/>) and resolves it into an <see cref="ImportPlan"/> against <paramref name="index"/>/<paramref name="manifest"/>.</summary>
    public static ImportPlan PlanFromFile(string path, IReadOnlyList<ThunderstorePackage> index, InstalledManifest manifest)
    {
        byte[] data;
        try
        {
            data = File.ReadAllBytes(path);
        }
        catch
        {
            throw new ProfileShareException.InvalidFormat();
        }
        return PlanFromData(data, index, manifest);
    }

    private static ImportPlan PlanFromData(byte[] data, IReadOnlyList<ThunderstorePackage> index, InstalledManifest manifest)
    {
        ExportedProfile? decoded;
        try
        {
            decoded = JsonSerializer.Deserialize<ExportedProfile>(data, CompactOptions);
        }
        catch
        {
            throw new ProfileShareException.InvalidFormat();
        }
        if (decoded is null)
        {
            throw new ProfileShareException.InvalidFormat();
        }
        if (decoded.Bifrost != 1)
        {
            throw new ProfileShareException.UnsupportedVersion(decoded.Bifrost);
        }

        var normalized = decoded.Mods.Select(m => new NormalizedMod(m.FullName, m.Version, m.Enabled, m.Source == "nexus", m.NexusModId)).ToList();
        var name = decoded.Name.Trim();
        return BuildPlan(name.Length == 0 ? "Imported Profile" : name, normalized, index, manifest);
    }

    // MARK: - Plan

    /// <summary>
    /// What importing a shared profile would do, computed without changing
    /// anything — resolved against the recipient's own Thunderstore index
    /// and installed-mod manifest so it reflects exactly what
    /// <see cref="Apply"/> would install/skip on THIS machine, before the
    /// caller confirms anything with the user.
    /// </summary>
    public sealed class ImportPlan
    {
        /// <summary>
        /// Wants installing — not currently on this machine at all.
        /// <see cref="ResolvedVersion"/> is what will actually be installed
        /// (the index's current latest for this mod, per
        /// <see cref="ModManager"/>'s always-latest convention); it differs
        /// from <see cref="RequestedVersion"/> exactly when the exporter's
        /// version has since been superseded.
        /// </summary>
        public sealed record ResolvableMod(string FullName, string RequestedVersion, string ResolvedVersion, bool Enabled)
        {
            public bool WasSubstituted => ResolvedVersion != RequestedVersion;
        }

        /// <summary>Already installed on this machine under the same full name — nothing to download, <see cref="Apply"/> only needs to carry its imported enabled state into the new profile.</summary>
        public sealed record AlreadyInstalledMod(string FullName, string InstalledVersion, bool Enabled);

        public abstract record UnresolvableReason
        {
            /// <summary>Not present in the recipient's cached Thunderstore index at all — could be a private/removed package, a game-specific index mismatch, or simply a stale local index cache.</summary>
            public sealed record NotInIndex : UnresolvableReason;

            /// <summary>
            /// Exported with a source == "nexus" marker: this mod was
            /// installed via Nexus Mods, which has no shared identity
            /// <see cref="ModManager.ResolveAsync"/> can look up — the
            /// recipient has to grab it from Nexus themselves.
            /// <see cref="ModId"/>, when present, is the exporter's own
            /// recorded Nexus mod id, so the UI can link straight to its
            /// Nexus page.
            /// </summary>
            public sealed record NexusOnly(int? ModId) : UnresolvableReason;
        }

        public sealed record UnresolvableMod(string FullName, UnresolvableReason Reason);

        public required string ImportedName { get; init; }
        public required List<ResolvableMod> Resolvable { get; init; }
        public required List<AlreadyInstalledMod> AlreadyInstalled { get; init; }
        public required List<UnresolvableMod> Unresolvable { get; init; }

        /// <summary>Every mod that will actually land in the profile <see cref="Apply"/> creates — installed fresh, or already present.</summary>
        public int InstallableCount => Resolvable.Count + AlreadyInstalled.Count;
        public bool IsEmpty => InstallableCount == 0;
    }

    /// <summary>A share-format-agnostic mod entry — both the native JSON and the r2modman YAML get normalized to this before <see cref="BuildPlan"/> runs, so the actual resolution logic only has to be written once.</summary>
    private sealed record NormalizedMod(string FullName, string Version, bool Enabled, bool IsNexus, int? NexusModId);

    /// <summary>
    /// Classifies every mod in <paramref name="mods"/> against
    /// <paramref name="index"/>/<paramref name="manifest"/>. Order of checks
    /// matters: a source == "nexus" marker always wins (there's nothing to
    /// resolve regardless of what else might be true of it), then an
    /// already-installed match, then a normal index lookup.
    /// </summary>
    private static ImportPlan BuildPlan(string name, List<NormalizedMod> mods, IReadOnlyList<ThunderstorePackage> index, InstalledManifest manifest)
    {
        var byFullName = index.ToDictionary(p => p.FullName);
        var installedByFullName = manifest.Mods.ToDictionary(m => m.FullName);

        var resolvable = new List<ImportPlan.ResolvableMod>();
        var alreadyInstalled = new List<ImportPlan.AlreadyInstalledMod>();
        var unresolvable = new List<ImportPlan.UnresolvableMod>();

        foreach (var mod in mods)
        {
            if (mod.IsNexus)
            {
                unresolvable.Add(new ImportPlan.UnresolvableMod(mod.FullName, new ImportPlan.UnresolvableReason.NexusOnly(mod.NexusModId)));
                continue;
            }
            if (installedByFullName.TryGetValue(mod.FullName, out var installed))
            {
                alreadyInstalled.Add(new ImportPlan.AlreadyInstalledMod(mod.FullName, installed.Version, mod.Enabled));
                continue;
            }
            if (!byFullName.TryGetValue(mod.FullName, out var package) || package.LatestVersion is not { } latest)
            {
                unresolvable.Add(new ImportPlan.UnresolvableMod(mod.FullName, new ImportPlan.UnresolvableReason.NotInIndex()));
                continue;
            }
            resolvable.Add(new ImportPlan.ResolvableMod(mod.FullName, mod.Version, latest.VersionNumber, mod.Enabled));
        }

        return new ImportPlan { ImportedName = name, Resolvable = resolvable, AlreadyInstalled = alreadyInstalled, Unresolvable = unresolvable };
    }

    // MARK: - Apply

    /// <summary>
    /// Installs every <see cref="ImportPlan.Resolvable"/> mod (via
    /// <see cref="ModManager.ResolveAsync"/> through the ordinary
    /// <see cref="ModManager.InstallAsync"/> path, so each one's own
    /// dependencies come along too, exactly like installing it from the
    /// Browse tab would), then creates a new profile carrying every
    /// resolvable-or-already-installed mod's imported enabled state.
    /// <see cref="ImportPlan.Unresolvable"/> mods are never referenced by
    /// the created profile — they were already surfaced to the user via the
    /// plan itself before this was called.
    ///
    /// The new profile's name is <see cref="ImportPlan.ImportedName"/>,
    /// deduplicated against existing profile names as "name (2)", "name
    /// (3)", etc. Doesn't switch to the new profile or reconcile the real
    /// install's enabled/disabled state — same as every other
    /// profile-creation path, applying is a separate, explicit step the
    /// caller already has (the Profiles dialog's own "Apply").
    /// </summary>
    public static async Task<Profile> ApplyAsync(
        ImportPlan plan,
        IReadOnlyList<ThunderstorePackage> index,
        ModManager modManager,
        ProfileStore profileStore,
        string gameDir,
        Action<ModManager.Progress>? onProgress = null)
    {
        var byFullName = index.ToDictionary(p => p.FullName);
        foreach (var mod in plan.Resolvable)
        {
            if (!byFullName.TryGetValue(mod.FullName, out var package))
            {
                continue; // BuildPlan already verified this; defensive only
            }
            await modManager.InstallAsync(package, index, gameDir, onProgress);
        }

        var profileMods = plan.Resolvable.Select(m => new Profile.ProfileMod { FullName = m.FullName, Enabled = m.Enabled }).ToList();
        profileMods.AddRange(plan.AlreadyInstalled.Select(m => new Profile.ProfileMod { FullName = m.FullName, Enabled = m.Enabled }));

        var name = DedupedName(plan.ImportedName, profileStore);
        return profileStore.Create(name, profileMods);
    }

    private static string DedupedName(string baseName, ProfileStore profileStore)
    {
        var existingNames = new HashSet<string>(profileStore.Load().Profiles.Select(p => p.Name));
        if (!existingNames.Contains(baseName))
        {
            return baseName;
        }
        var suffix = 2;
        while (existingNames.Contains($"{baseName} ({suffix})"))
        {
            suffix++;
        }
        return $"{baseName} ({suffix})";
    }

    // MARK: - r2modman interop

    /// <summary>
    /// Thunderstore's own (undocumented but public, unauthenticated) "legacy
    /// profile" endpoints — the same ones r2modman/Thunderstore Mod
    /// Manager's own "Import/Export code" feature uses. Verified directly
    /// against the live API: POST create/ with an arbitrary body returns
    /// {"key": "&lt;uuid&gt;"}, and GET get/&lt;uuid&gt;/ 302s to a CDN URL
    /// serving that exact body back — the service is an opaque blob store
    /// keyed by UUID, with no format validation of its own, so what actually
    /// makes this interop rather than just a pastebin is putting real
    /// r2modman-shaped content (export.r2x YAML, zipped, base64-encoded) in
    /// the blob, matching the shape the real r2modman GUI itself writes.
    /// </summary>
    private const string R2CreateUrl = "https://thunderstore.io/api/experimental/legacyprofile/create/";

    private static string R2GetUrl(string code) => $"https://thunderstore.io/api/experimental/legacyprofile/get/{code}/";

    /// <summary>
    /// r2modman's own share codes are bare UUIDs; Bifrost's native codes are
    /// base64 (of JSON starting <c>{"bifrost":1,...</c>) and never parse as
    /// one — so a pasted code's format alone tells the two apart, which is
    /// what the Import dialog's single paste field relies on to auto-detect
    /// which importer to call.
    /// </summary>
    public static bool LooksLikeR2ModManCode(string value) => Guid.TryParse(value.Trim(), out _);

    /// <summary>
    /// Uploads <paramref name="profile"/> as an r2modman-compatible profile
    /// code: builds an export.r2x YAML (the same profileName/mods[].name +
    /// version.{major,minor,patch} + enabled shape r2modman itself writes),
    /// zips it in-memory, base64-encodes the zip, and POSTs that to
    /// Thunderstore's legacyprofile/create/ endpoint. Returns the resulting
    /// code (a bare UUID) for the user to share.
    ///
    /// Like <see cref="Export"/>, source == "local" mods have no shareable
    /// identity and are left out; unlike <see cref="Export"/>, source ==
    /// "nexus" mods are ALSO left out here — r2modman's format has no field
    /// for a non-Thunderstore origin at all, so there's nothing to mark them
    /// with the way the native format's <see cref="ExportedMod.Source"/> does.
    /// Throws <see cref="ProfileShareException.EmptyMods"/> if that leaves
    /// nothing to share.
    /// </summary>
    public static async Task<string> ExportR2CodeAsync(Profile profile, InstalledManifest manifest, HttpClient? httpClient = null)
    {
        var installedByFullName = manifest.Mods.ToDictionary(m => m.FullName);

        var lines = new List<string> { $"profileName: {profile.Name}", "mods:" };
        var includedAny = false;
        foreach (var profileMod in profile.Mods)
        {
            if (!installedByFullName.TryGetValue(profileMod.FullName, out var installed) || installed.Source != "thunderstore")
            {
                continue;
            }
            var (major, minor, patch) = VersionComponents(installed.Version);
            lines.Add($"  - name: {profileMod.FullName}");
            lines.Add("    version:");
            lines.Add($"      major: {major}");
            lines.Add($"      minor: {minor}");
            lines.Add($"      patch: {patch}");
            lines.Add($"    enabled: {(profileMod.Enabled ? "true" : "false")}");
            includedAny = true;
        }
        if (!includedAny)
        {
            throw new ProfileShareException.EmptyMods();
        }
        var r2x = string.Join("\n", lines) + "\n";

        byte[] zipBytes;
        using (var zipStream = new MemoryStream())
        {
            using (var archive = new ZipArchive(zipStream, ZipArchiveMode.Create, leaveOpen: true))
            {
                var entry = archive.CreateEntry("export.r2x");
                await using var entryStream = entry.Open();
                var bytes = Encoding.UTF8.GetBytes(r2x);
                await entryStream.WriteAsync(bytes);
            }
            zipBytes = zipStream.ToArray();
        }
        var base64 = Convert.ToBase64String(zipBytes);

        using var http = httpClient ?? new HttpClient();
        using var content = new StringContent(base64, Encoding.UTF8, "text/plain");
        using var response = await http.PostAsync(R2CreateUrl, content);
        if (!response.IsSuccessStatusCode)
        {
            throw new ProfileShareException.BadResponse((int)response.StatusCode);
        }
        var created = await response.Content.ReadFromJsonAsync<CreateResponse>();
        return created?.Key ?? throw new ProfileShareException.InvalidFormat();
    }

    private sealed class CreateResponse
    {
        [JsonPropertyName("key")] public string Key { get; set; } = "";
    }

    /// <summary>
    /// Fetches an r2modman profile <paramref name="code"/> (a bare UUID)
    /// from Thunderstore's legacyprofile/get/ endpoint, base64-decodes the
    /// response, extracts its export.r2x, parses it, and resolves the
    /// result into an <see cref="ImportPlan"/> — same shape and same
    /// resolution rules as a native import, so the UI shows both
    /// identically.
    /// </summary>
    public static async Task<ImportPlan> ImportR2CodeAsync(string code, IReadOnlyList<ThunderstorePackage> index, InstalledManifest manifest, HttpClient? httpClient = null)
    {
        var trimmed = code.Trim();
        if (!Guid.TryParse(trimmed, out _))
        {
            throw new ProfileShareException.InvalidFormat();
        }

        using var http = httpClient ?? new HttpClient();
        using var response = await http.GetAsync(R2GetUrl(trimmed));
        if (!response.IsSuccessStatusCode)
        {
            throw new ProfileShareException.BadResponse((int)response.StatusCode);
        }
        var base64String = await response.Content.ReadAsStringAsync();
        byte[] zipBytes;
        try
        {
            zipBytes = Convert.FromBase64String(base64String.Trim());
        }
        catch
        {
            throw new ProfileShareException.InvalidFormat();
        }

        string? r2xText = null;
        try
        {
            using var zipStream = new MemoryStream(zipBytes);
            using var archive = new ZipArchive(zipStream, ZipArchiveMode.Read);
            var entry = archive.Entries.FirstOrDefault(e => e.FullName.Replace('\\', '/').EndsWith("export.r2x", StringComparison.OrdinalIgnoreCase));
            if (entry is not null)
            {
                using var entryStream = entry.Open();
                using var reader = new StreamReader(entryStream, Encoding.UTF8);
                r2xText = await reader.ReadToEndAsync();
            }
        }
        catch
        {
            throw new ProfileShareException.InvalidFormat();
        }
        if (r2xText is null)
        {
            throw new ProfileShareException.R2xNotFound();
        }

        var (profileName, parsedMods) = ParseR2x(r2xText);
        var normalized = parsedMods.Select(m => new NormalizedMod(m.FullName, m.Version, m.Enabled, false, null)).ToList();
        return BuildPlan(profileName, normalized, index, manifest);
    }

    private sealed record ParsedR2xMod(string FullName, string Version, bool Enabled);

    /// <summary>
    /// A deliberately minimal, hand-rolled reader for r2modman's export.r2x
    /// — not a general YAML parser, just enough to pull the handful of
    /// scalar keys that format actually carries (profileName, and per mod:
    /// name, version.major/minor/patch, enabled), tracked line by line
    /// regardless of exact indentation.
    /// </summary>
    private static (string ProfileName, List<ParsedR2xMod> Mods) ParseR2x(string text)
    {
        var profileName = "Imported Profile";
        var mods = new List<ParsedR2xMod>();

        string? currentName = null;
        int? currentMajor = null;
        int? currentMinor = null;
        int? currentPatch = null;
        bool? currentEnabled = null;

        void Flush()
        {
            if (currentName is null)
            {
                return;
            }
            var version = $"{currentMajor ?? 0}.{currentMinor ?? 0}.{currentPatch ?? 0}";
            mods.Add(new ParsedR2xMod(currentName, version, currentEnabled ?? true));
            currentName = null;
            currentMajor = null;
            currentMinor = null;
            currentPatch = null;
            currentEnabled = null;
        }

        foreach (var rawLine in text.Split('\n'))
        {
            var trimmed = rawLine.Trim();
            if (trimmed.Length == 0)
            {
                continue;
            }

            if (trimmed.StartsWith("profileName:", StringComparison.Ordinal))
            {
                profileName = YamlScalar("profileName:", trimmed);
            }
            else if (trimmed.StartsWith("- name:", StringComparison.Ordinal))
            {
                Flush();
                currentName = YamlScalar("- name:", trimmed);
            }
            else if (trimmed.StartsWith("major:", StringComparison.Ordinal))
            {
                currentMajor = int.TryParse(YamlScalar("major:", trimmed), out var v) ? v : null;
            }
            else if (trimmed.StartsWith("minor:", StringComparison.Ordinal))
            {
                currentMinor = int.TryParse(YamlScalar("minor:", trimmed), out var v) ? v : null;
            }
            else if (trimmed.StartsWith("patch:", StringComparison.Ordinal))
            {
                currentPatch = int.TryParse(YamlScalar("patch:", trimmed), out var v) ? v : null;
            }
            else if (trimmed.StartsWith("enabled:", StringComparison.Ordinal))
            {
                currentEnabled = YamlScalar("enabled:", trimmed).Equals("true", StringComparison.OrdinalIgnoreCase);
            }
            // Everything else (bare "version:", "mods:", unrelated keys) is
            // structural or irrelevant to the fixed set of scalars above.
        }
        Flush();

        if (mods.Count == 0)
        {
            throw new ProfileShareException.EmptyMods();
        }
        return (profileName, mods);
    }

    private static string YamlScalar(string prefix, string line)
    {
        var value = line[prefix.Length..].Trim();
        if (value.Length >= 2 && ((value.StartsWith('"') && value.EndsWith('"')) || (value.StartsWith('\'') && value.EndsWith('\''))))
        {
            value = value[1..^1];
        }
        return value;
    }

    private static (int Major, int Minor, int Patch) VersionComponents(string version)
    {
        var parts = version.Split('.').Select(p => int.TryParse(p, out var n) ? n : 0).ToList();
        return (parts.Count > 0 ? parts[0] : 0, parts.Count > 1 ? parts[1] : 0, parts.Count > 2 ? parts[2] : 0);
    }
}
