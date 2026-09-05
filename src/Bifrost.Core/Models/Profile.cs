using System.Text.Json.Serialization;

namespace Bifrost.Core.Models;

/// <summary>
/// A named, desired set of mods layered over Bifrost's single shared install
/// pool — every profile draws from the same BepInEx/plugins on disk and the
/// same <see cref="InstalledManifest"/>. A profile only records membership
/// and enabled state; the mod's actual installed version is still tracked
/// solely by <see cref="InstalledManifest"/>.
///
/// Persisted as JSON at <c>%AppData%\Bifrost\profiles.json</c> (see
/// <see cref="ProfilesFile"/>), owned and mutated by
/// <see cref="Services.ProfileStore"/>. Field names match the macOS reference
/// implementation's <c>Profile.swift</c> exactly.
/// </summary>
public sealed class Profile
{
    public Guid Id { get; set; }
    public string Name { get; set; } = string.Empty;
    public List<ProfileMod> Mods { get; set; } = new();

    /// <summary>One mod's desired membership in a profile.</summary>
    public sealed class ProfileMod : IEquatable<ProfileMod>
    {
        public string FullName { get; set; } = string.Empty;
        public bool Enabled { get; set; }

        public bool Equals(ProfileMod? other) =>
            other is not null && FullName == other.FullName && Enabled == other.Enabled;

        public override bool Equals(object? obj) => Equals(obj as ProfileMod);
        public override int GetHashCode() => HashCode.Combine(FullName, Enabled);
    }
}

/// <summary>The full shape of profiles.json.</summary>
public sealed class ProfilesFile
{
    // The macOS app's JSONEncoder (sortedKeys) emits this field as
    // "activeProfileID" (capital ID) — an explicit name keeps that exact
    // shape regardless of whatever naming policy the serializer options use.
    [JsonPropertyName("activeProfileID")]
    public Guid? ActiveProfileId { get; set; }

    public List<Profile> Profiles { get; set; } = new();

    public static ProfilesFile Empty => new();
}
