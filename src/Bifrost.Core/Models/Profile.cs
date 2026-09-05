namespace Bifrost.Core.Models;

/// <summary>
/// A named set of enabled mods/config, analogous to the macOS app's
/// Profile model. Persistence lands with Bifrost.Core.Services.ProfileStore.
/// </summary>
public sealed class Profile
{
    public string Id { get; init; } = Guid.NewGuid().ToString("N");
    public string Name { get; set; } = "Default";
    public List<string> EnabledPackageIds { get; init; } = new();
}
