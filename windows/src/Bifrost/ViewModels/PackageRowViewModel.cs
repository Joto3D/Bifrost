using Bifrost.Core.Models;
using Bifrost.Core.Services;

namespace Bifrost.ViewModels;

/// <summary>Read-only display wrapper around a <see cref="ThunderstorePackage"/> for the Browse list.</summary>
public sealed class PackageRowViewModel
{
    public ThunderstorePackage Package { get; }

    public PackageRowViewModel(ThunderstorePackage package, bool isInstalled)
    {
        Package = package;
        IsInstalled = isInstalled;
    }

    public string Name => Package.Name;
    public string Owner => Package.Owner;
    public string Description => Package.LatestVersion?.Description ?? "";
    public string LatestVersion => Package.LatestVersion?.VersionNumber ?? "?";
    public int RatingScore => Package.RatingScore;
    public int TotalDownloads => Package.TotalDownloads;
    public DateTimeOffset DateUpdated => Package.DateUpdated;
    public bool IsInstalled { get; }
    public string DisplayTitle => $"{Name} by {Owner}";
    public string? IconUrl => ThunderstoreClient.IconUrl(Package);
    public IReadOnlyList<string> Categories => Package.Categories;
    public string DownloadsCompact => CompactNumber(TotalDownloads);
    public string UpdatedAgo => RelativeTime(DateUpdated);

    private static string CompactNumber(int value) => value switch
    {
        >= 1_000_000 => $"{value / 1_000_000.0:0.#}M",
        >= 1_000 => $"{value / 1_000.0:0.#}K",
        _ => value.ToString(),
    };

    internal static string RelativeTime(DateTimeOffset when)
    {
        var delta = DateTimeOffset.UtcNow - when;
        if (delta.TotalDays >= 365) return $"{(int)(delta.TotalDays / 365)}y ago";
        if (delta.TotalDays >= 30) return $"{(int)(delta.TotalDays / 30)}mo ago";
        if (delta.TotalDays >= 1) return $"{(int)delta.TotalDays}d ago";
        if (delta.TotalHours >= 1) return $"{(int)delta.TotalHours}h ago";
        if (delta.TotalMinutes >= 1) return $"{(int)delta.TotalMinutes}m ago";
        return "just now";
    }
}
