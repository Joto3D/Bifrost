using System.Text.Json;
using Bifrost.Core.Models;

namespace Bifrost.Core.Services;

/// <summary>
/// Owns profiles.json — CRUD over named <see cref="Profile"/>s, and
/// <see cref="Apply"/>, which reconciles a profile's desired mod membership
/// against what's actually installed (via <see cref="ModManager"/>). Ported
/// from the macOS reference implementation's <c>ProfileStore.swift</c>.
///
/// Profiles express intent; the manifest remains the source of truth for
/// what's actually installed. Apply never installs or uninstalls anything
/// itself — it only enables/disables mods that are already installed, and
/// reports back any profile mods that aren't installed yet.
/// </summary>
public sealed class ProfileStore
{
    public sealed class ProfileStoreException(string message) : Exception(message);

    public sealed record ApplyResult(List<string> Missing);

    public sealed record ApplyPreview(List<string> ToDisable, List<string> Missing)
    {
        public bool IsNoOp => ToDisable.Count == 0 && Missing.Count == 0;
    }

    public string ProfilesPath { get; }
    private readonly ModManager _modManager;

    public ProfileStore(ModManager modManager, string? profilesPath = null)
    {
        ProfilesPath = profilesPath ?? BifrostPaths.ProfilesPath;
        _modManager = modManager;
    }

    // MARK: - I/O

    public ProfilesFile Load()
    {
        try
        {
            if (!File.Exists(ProfilesPath))
            {
                return ProfilesFile.Empty;
            }
            var json = File.ReadAllText(ProfilesPath);
            return JsonSerializer.Deserialize<ProfilesFile>(json, BifrostJson.Options) ?? ProfilesFile.Empty;
        }
        catch
        {
            return ProfilesFile.Empty;
        }
    }

    private void Save(ProfilesFile file)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(ProfilesPath)!);
        File.WriteAllText(ProfilesPath, JsonSerializer.Serialize(file, BifrostJson.Options));
    }

    /// <summary>
    /// Loads profiles.json, auto-migrating on first run: if the file
    /// doesn't exist yet, creates a "Default" profile capturing the
    /// manifest's current mod membership and enabled state, marks it
    /// active, and persists that as the new profiles.json.
    /// </summary>
    public ProfilesFile LoadOrMigrate()
    {
        if (File.Exists(ProfilesPath))
        {
            return Load();
        }
        var manifest = _modManager.LoadManifest();
        var defaultProfile = new Profile
        {
            Id = Guid.NewGuid(),
            Name = "Default",
            Mods = manifest.Mods.Select(m => new Profile.ProfileMod { FullName = m.FullName, Enabled = m.Enabled }).ToList(),
        };
        var file = new ProfilesFile { ActiveProfileId = defaultProfile.Id, Profiles = { defaultProfile } };
        Save(file);
        return file;
    }

    // MARK: - CRUD

    /// <summary>
    /// Creates a new profile named <paramref name="name"/>. When
    /// <paramref name="fromCurrent"/> is true, it starts out matching every
    /// currently-installed mod's membership and enabled state; otherwise it
    /// starts empty.
    /// </summary>
    public Profile Create(string name, bool fromCurrent)
    {
        var file = LoadOrMigrate();
        var mods = fromCurrent
            ? _modManager.LoadManifest().Mods.Select(m => new Profile.ProfileMod { FullName = m.FullName, Enabled = m.Enabled }).ToList()
            : new List<Profile.ProfileMod>();
        var profile = new Profile { Id = Guid.NewGuid(), Name = name, Mods = mods };
        file.Profiles.Add(profile);
        Save(file);
        return profile;
    }

    /// <summary>
    /// Creates a new profile named <paramref name="name"/> with an explicit
    /// mod list, optionally marked as a server-guest profile (see
    /// <see cref="Profile.IsServerGuest"/>). Used by
    /// <see cref="ServerJoinPlanner"/> and <see cref="ProfileShare"/> rather
    /// than the <see cref="Create(string,bool)"/> overload above, which only
    /// knows how to start empty or copy the current install.
    /// </summary>
    public Profile Create(string name, List<Profile.ProfileMod> mods, bool isServerGuest = false)
    {
        var file = LoadOrMigrate();
        var profile = new Profile { Id = Guid.NewGuid(), Name = name, Mods = mods, IsServerGuest = isServerGuest };
        file.Profiles.Add(profile);
        Save(file);
        return profile;
    }

    /// <summary>
    /// Overwrites <paramref name="profileId"/>'s mod list with
    /// <paramref name="mods"/>, and — when <paramref name="isServerGuest"/>
    /// is non-null — also overwrites the profile's guest marker (see
    /// <see cref="Profile.IsServerGuest"/>). Left null, the existing marker
    /// is untouched. Used by <see cref="ServerJoinPlanner.Apply"/> to write
    /// a computed plan into the target profile before reconciling the real
    /// install.
    /// </summary>
    public void SetMods(Guid profileId, List<Profile.ProfileMod> mods, bool? isServerGuest = null)
    {
        var file = LoadOrMigrate();
        var profile = file.Profiles.FirstOrDefault(p => p.Id == profileId) ?? throw new ProfileStoreException($"No profile with id {profileId}");
        profile.Mods = mods;
        if (isServerGuest is { } guest)
        {
            profile.IsServerGuest = guest;
        }
        Save(file);
    }

    /// <summary>Creates a copy of <paramref name="id"/> named <paramref name="newName"/>.</summary>
    public Profile Duplicate(Guid id, string newName)
    {
        var file = LoadOrMigrate();
        var source = file.Profiles.FirstOrDefault(p => p.Id == id) ?? throw new ProfileStoreException($"No profile with id {id}");
        var copy = new Profile { Id = Guid.NewGuid(), Name = newName, Mods = source.Mods.Select(m => new Profile.ProfileMod { FullName = m.FullName, Enabled = m.Enabled }).ToList() };
        file.Profiles.Add(copy);
        Save(file);
        return copy;
    }

    public void Rename(Guid id, string newName)
    {
        var file = LoadOrMigrate();
        var profile = file.Profiles.FirstOrDefault(p => p.Id == id) ?? throw new ProfileStoreException($"No profile with id {id}");
        profile.Name = newName;
        Save(file);
    }

    /// <summary>Deletes profile id. Refuses to delete the active profile.</summary>
    public void Delete(Guid id)
    {
        var file = LoadOrMigrate();
        if (!file.Profiles.Any(p => p.Id == id))
        {
            throw new ProfileStoreException($"No profile with id {id}");
        }
        if (file.ActiveProfileId == id)
        {
            throw new ProfileStoreException("Can't delete the active profile — switch to another profile first");
        }
        file.Profiles.RemoveAll(p => p.Id == id);
        Save(file);
    }

    // MARK: - Apply / reconcile

    /// <summary>
    /// Computes what <see cref="Apply"/> would do to the real install right
    /// now, without changing anything.
    /// </summary>
    public ApplyPreview PreviewApply(Guid profileId)
    {
        var file = LoadOrMigrate();
        var profile = file.Profiles.FirstOrDefault(p => p.Id == profileId) ?? throw new ProfileStoreException($"No profile with id {profileId}");
        var manifest = _modManager.LoadManifest();
        return ComputePreview(profile, manifest);
    }

    /// <summary>
    /// Reconciles the installed mods against profileId's desired membership.
    /// On success, marks profileId as the active profile.
    /// </summary>
    public ApplyResult Apply(Guid profileId, string gameDir)
    {
        var file = LoadOrMigrate();
        var profile = file.Profiles.FirstOrDefault(p => p.Id == profileId) ?? throw new ProfileStoreException($"No profile with id {profileId}");
        var manifest = _modManager.LoadManifest();
        var installedFullNames = new HashSet<string>(manifest.Mods.Select(m => m.FullName));
        var profileByFullName = profile.Mods.ToDictionary(m => m.FullName);

        var missing = new List<string>();
        foreach (var profileMod in profile.Mods)
        {
            if (!installedFullNames.Contains(profileMod.FullName))
            {
                missing.Add(profileMod.FullName);
                continue;
            }
            _modManager.SetEnabled(profileMod.FullName, profileMod.Enabled, gameDir);
        }
        foreach (var installedMod in manifest.Mods)
        {
            if (!profileByFullName.ContainsKey(installedMod.FullName))
            {
                _modManager.SetEnabled(installedMod.FullName, false, gameDir);
            }
        }

        file.ActiveProfileId = profileId;
        Save(file);

        return new ApplyResult(missing);
    }

    /// <summary>
    /// Updates the active profile's mod list to exactly match what's
    /// currently in the manifest. No-op if no profile is active.
    /// </summary>
    public void SyncActiveProfile()
    {
        var file = LoadOrMigrate();
        if (file.ActiveProfileId is not { } activeId)
        {
            return;
        }
        var profile = file.Profiles.FirstOrDefault(p => p.Id == activeId);
        if (profile is null)
        {
            return;
        }
        var manifest = _modManager.LoadManifest();
        profile.Mods = manifest.Mods.Select(m => new Profile.ProfileMod { FullName = m.FullName, Enabled = m.Enabled }).ToList();
        Save(file);
    }

    private static ApplyPreview ComputePreview(Profile profile, InstalledManifest manifest)
    {
        var profileByFullName = profile.Mods.ToDictionary(m => m.FullName);

        var toDisable = manifest.Mods
            .Where(m => m.Enabled && !(profileByFullName.TryGetValue(m.FullName, out var pm) && pm.Enabled))
            .Select(m => m.FullName)
            .ToList();

        var installedFullNames = new HashSet<string>(manifest.Mods.Select(m => m.FullName));
        var missing = profile.Mods.Select(m => m.FullName).Where(fn => !installedFullNames.Contains(fn)).ToList();

        return new ApplyPreview(toDisable, missing);
    }
}
