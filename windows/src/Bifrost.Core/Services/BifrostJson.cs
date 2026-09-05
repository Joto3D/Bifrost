using System.Text.Json;

namespace Bifrost.Core.Services;

/// <summary>
/// Shared JSON options for everything Bifrost persists
/// (manifest.json/profiles.json/package-index.json) and for models decoded
/// straight off the Thunderstore API. camelCase output matches the macOS
/// reference implementation's <c>JSONEncoder</c> defaults (Swift's own
/// property names, which are already camelCase) for the models that rely on
/// the naming policy; <see cref="Models.ThunderstorePackage"/> and the
/// "activeProfileID" field instead use explicit
/// <c>JsonPropertyName</c> attributes for exactness.
/// </summary>
public static class BifrostJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        Converters = { new UppercaseGuidConverter() },
    };
}
