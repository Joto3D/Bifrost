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
}
