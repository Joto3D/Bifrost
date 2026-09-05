using System.Text.Json.Serialization;

namespace Bifrost.Core.Models;

/// <summary>
/// A single mod package as returned by Thunderstore's v1 package index for
/// the Valheim community. Only the fields Bifrost actually uses are decoded;
/// everything else in the response is ignored. Mirrors the macOS reference
/// implementation's <c>ThunderstorePackage.swift</c>.
/// </summary>
public sealed class ThunderstorePackage
{
    [JsonPropertyName("name")]
    public string Name { get; set; } = string.Empty;

    [JsonPropertyName("full_name")]
    public string FullName { get; set; } = string.Empty;

    [JsonPropertyName("owner")]
    public string Owner { get; set; } = string.Empty;

    [JsonPropertyName("package_url")]
    public string PackageUrl { get; set; } = string.Empty;

    [JsonPropertyName("date_updated")]
    public DateTimeOffset DateUpdated { get; set; }

    [JsonPropertyName("rating_score")]
    public int RatingScore { get; set; }

    [JsonPropertyName("is_deprecated")]
    public bool IsDeprecated { get; set; }

    [JsonPropertyName("categories")]
    public List<string> Categories { get; set; } = new();

    [JsonPropertyName("versions")]
    public List<Version> Versions { get; set; } = new();

    /// <summary>The most recent version, which the index always lists first.</summary>
    [JsonIgnore]
    public Version? LatestVersion => Versions.Count > 0 ? Versions[0] : null;

    /// <summary>Total downloads across all versions.</summary>
    [JsonIgnore]
    public int TotalDownloads => Versions.Sum(v => v.Downloads);

    public sealed class Version
    {
        [JsonPropertyName("name")]
        public string Name { get; set; } = string.Empty;

        [JsonPropertyName("full_name")]
        public string FullName { get; set; } = string.Empty;

        [JsonPropertyName("description")]
        public string Description { get; set; } = string.Empty;

        [JsonPropertyName("icon")]
        public string? Icon { get; set; }

        [JsonPropertyName("version_number")]
        public string VersionNumber { get; set; } = string.Empty;

        /// <summary>Dependency identifiers in "Author-Name-Version" form.</summary>
        [JsonPropertyName("dependencies")]
        public List<string> Dependencies { get; set; } = new();

        [JsonPropertyName("download_url")]
        public string DownloadUrl { get; set; } = string.Empty;

        [JsonPropertyName("downloads")]
        public int Downloads { get; set; }

        [JsonPropertyName("file_size")]
        public long FileSize { get; set; }
    }
}
