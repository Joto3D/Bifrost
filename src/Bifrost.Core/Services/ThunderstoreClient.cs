using Bifrost.Core.Models;

namespace Bifrost.Core.Services;

/// <summary>
/// Placeholder for the Thunderstore API client (package index fetch,
/// download, dependency resolution). Windows counterpart of the macOS
/// app's ThunderstoreClient service. Not yet wired to the network.
/// </summary>
public sealed class ThunderstoreClient
{
    public Task<IReadOnlyList<ThunderstorePackage>> GetPackagesAsync(CancellationToken cancellationToken = default)
    {
        return Task.FromResult<IReadOnlyList<ThunderstorePackage>>(Array.Empty<ThunderstorePackage>());
    }
}
