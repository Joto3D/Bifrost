using System.Net.Http.Json;
using System.Text.Json.Serialization;

namespace Bifrost.Core.Services;

/// <summary>
/// Client for the Nexus Mods API (<c>https://api.nexusmods.com/v1/</c>) —
/// the "Mod Manager Download" (<c>nxm://</c>) flow's only network
/// dependency: validating a user's personal API key, fetching a mod's
/// display metadata for install progress, and resolving a CDN download link
/// for a specific mod/file pair. Ported from the macOS reference
/// implementation's <c>NexusClient.swift</c>.
///
/// Every request carries the key as the <c>apikey</c> header, exactly as
/// Nexus's own docs specify. The key itself never lives here — callers read
/// it from <see cref="WindowsCredentials"/> (target
/// <see cref="WindowsCredentials.NexusApiKeyTarget"/>) and pass it in per
/// call, so <see cref="NexusClient"/> stays stateless with nothing sensitive
/// to leak.
/// </summary>
public sealed class NexusClient
{
    public sealed class NexusException(string message) : Exception(message)
    {
        public static NexusException BadResponse() => new("Nexus returned an unrecognized response");
        public static NexusException HttpError(int status, string body) =>
            new($"Nexus API error {status}{(string.IsNullOrEmpty(body) ? "" : $": {body}")}");
        public static NexusException FreeAccountNeedsManagerDownload() =>
            new("Free Nexus accounts must use the “Mod Manager Download” button on the website (Slow download tab)");
        public static NexusException DecodingFailed() => new("Couldn't parse Nexus's response");
    }

    public sealed record ValidationResult(string Name, bool IsPremium);
    public sealed record ModInfo(string Name, string Version, string Author, string Summary);

    private static readonly Uri BaseUrl = new("https://api.nexusmods.com/v1/");
    private const string Game = "valheim";

    private readonly HttpClient _http;

    public NexusClient(HttpClient? httpClient = null)
    {
        _http = httpClient ?? new HttpClient();
    }

    private sealed class ValidateResponse
    {
        [JsonPropertyName("name")] public string Name { get; set; } = "";
        [JsonPropertyName("is_premium")] public bool IsPremium { get; set; }
    }

    /// <summary>GET /users/validate.json — confirms the key works and reports the account's display name and premium status.</summary>
    public async Task<ValidationResult> ValidateKeyAsync(string key)
    {
        var response = await GetAsync<ValidateResponse>(new Uri(BaseUrl, "users/validate.json"), key);
        return new ValidationResult(response.Name, response.IsPremium);
    }

    private sealed class ModInfoResponse
    {
        [JsonPropertyName("name")] public string Name { get; set; } = "";
        [JsonPropertyName("version")] public string Version { get; set; } = "";
        [JsonPropertyName("author")] public string Author { get; set; } = "";
        [JsonPropertyName("summary")] public string? Summary { get; set; }
    }

    /// <summary>
    /// GET /games/valheim/mods/{id}.json — a mod's name, latest version,
    /// author, and summary, used both for the nxm-install progress line and
    /// (via <see cref="ModManager.UpdatesAvailableAsync"/>) for checking a
    /// source == "nexus" entry's installed version against Nexus's current
    /// one.
    /// </summary>
    public async Task<ModInfo> ModInfoAsync(int modId, string key)
    {
        var response = await GetAsync<ModInfoResponse>(new Uri(BaseUrl, $"games/{Game}/mods/{modId}.json"), key);
        return new ModInfo(response.Name, response.Version, response.Author, response.Summary ?? "");
    }

    private sealed class Mirror
    {
        [JsonPropertyName("URI")] public string Uri { get; set; } = "";
    }

    /// <summary>
    /// GET /games/valheim/mods/{mod_id}/files/{file_id}/download_link.json —
    /// resolves the CDN mirror(s) for a specific file and returns the first
    /// one's URI. <paramref name="nxmKey"/>/<paramref name="expires"/> come
    /// straight off the nxm:// link for a free account's "Slow download"
    /// click and are appended as query parameters exactly as Nexus's own
    /// Vortex/r2modman clients do — required for a non-premium key (Nexus
    /// 403s the endpoint outright without them); a premium key works with
    /// neither.
    /// </summary>
    public async Task<Uri> DownloadLinkAsync(int modId, int fileId, string apiKey, string? nxmKey, string? expires)
    {
        var path = $"games/{Game}/mods/{modId}/files/{fileId}/download_link.json";
        var query = new List<string>();
        if (nxmKey is not null)
        {
            query.Add($"key={Uri.EscapeDataString(nxmKey)}");
        }
        if (expires is not null)
        {
            query.Add($"expires={Uri.EscapeDataString(expires)}");
        }
        var url = new Uri(BaseUrl, query.Count > 0 ? $"{path}?{string.Join("&", query)}" : path);

        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Add("apikey", apiKey);
        using var response = await _http.SendAsync(request);

        if ((int)response.StatusCode == 403 && nxmKey is null && expires is null)
        {
            throw NexusException.FreeAccountNeedsManagerDownload();
        }
        if (!response.IsSuccessStatusCode)
        {
            var body = await response.Content.ReadAsStringAsync();
            throw NexusException.HttpError((int)response.StatusCode, body);
        }

        List<Mirror>? mirrors;
        try
        {
            mirrors = await response.Content.ReadFromJsonAsync<List<Mirror>>();
        }
        catch
        {
            throw NexusException.DecodingFailed();
        }
        var first = mirrors?.FirstOrDefault();
        if (first is null || !Uri.TryCreate(first.Uri, UriKind.Absolute, out var uri))
        {
            throw NexusException.BadResponse();
        }
        return uri;
    }

    private async Task<T> GetAsync<T>(Uri url, string key)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Add("apikey", key);
        using var response = await _http.SendAsync(request);
        if (!response.IsSuccessStatusCode)
        {
            var body = await response.Content.ReadAsStringAsync();
            throw NexusException.HttpError((int)response.StatusCode, body);
        }
        try
        {
            var result = await response.Content.ReadFromJsonAsync<T>();
            return result ?? throw NexusException.DecodingFailed();
        }
        catch (NexusException)
        {
            throw;
        }
        catch
        {
            throw NexusException.DecodingFailed();
        }
    }
}
