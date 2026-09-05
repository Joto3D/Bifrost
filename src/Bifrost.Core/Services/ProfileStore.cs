using Bifrost.Core.Models;

namespace Bifrost.Core.Services;

/// <summary>
/// Placeholder for loading/saving Profile data to disk under Bifrost's
/// app-data folder (Windows counterpart of the macOS app's ProfileStore).
/// </summary>
public sealed class ProfileStore
{
    public IReadOnlyList<Profile> LoadProfiles() => Array.Empty<Profile>();

    public void SaveProfile(Profile profile)
    {
        // Not yet implemented.
    }
}
