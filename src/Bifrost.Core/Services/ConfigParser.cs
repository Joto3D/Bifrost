namespace Bifrost.Core.Services;

/// <summary>
/// Placeholder for parsing/editing BepInEx .cfg files, the same role the
/// macOS app's BepInExConfig service fills.
/// </summary>
public sealed class ConfigParser
{
    public IReadOnlyDictionary<string, string> Parse(string configText) =>
        new Dictionary<string, string>();
}
