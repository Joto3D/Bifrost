namespace Bifrost.Core.Models;

/// <summary>
/// A single package (mod) as returned by the Thunderstore package index for
/// the Valheim community. Mirrors the shape of the macOS app's
/// ThunderstorePackage model. Population from the live API lands with
/// Bifrost.Core.Services.ThunderstoreClient.
/// </summary>
public sealed class ThunderstorePackage
{
    public string Namespace { get; init; } = string.Empty;
    public string Name { get; init; } = string.Empty;
    public string FullName { get; init; } = string.Empty;
    public string Description { get; init; } = string.Empty;
    public IReadOnlyList<string> Categories { get; init; } = Array.Empty<string>();
    public string LatestVersion { get; init; } = string.Empty;
    public DateTimeOffset DateUpdated { get; init; }
}
