using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using Bifrost.Core.Models;

namespace Bifrost.Core.Services;

/// <summary>
/// Fetches and caches the Thunderstore package index for the Valheim
/// community. Ported from the macOS reference implementation's
/// <c>ThunderstoreClient.swift</c>.
///
/// Thunderstore's package index endpoint does not send an <c>ETag</c> in
/// practice (verified against the live API) — only <c>Last-Modified</c>,
/// honored via <c>If-Modified-Since</c> for a real 304 response. The
/// validator sidecar stores whichever validator(s) the server provides and
/// sends both back on the next request, so this keeps working unchanged if
/// Thunderstore ever starts sending an ETag too.
/// </summary>
public sealed class ThunderstoreClient
{
    public sealed class ThunderstoreClientException(string message) : Exception(message);

    private sealed class Validators
    {
        public string? ETag { get; set; }
        public string? LastModified { get; set; }
    }

    private static readonly Uri IndexUri = new("https://thunderstore.io/c/valheim/api/v1/package/");
    private const string LoaderPackageFullName = "denikson-BepInExPack_Valheim";

    private readonly HttpClient _http;
    private readonly string _cacheFilePath;
    private readonly string _validatorsFilePath;

    public ThunderstoreClient(HttpClient? httpClient = null, string? cacheFilePath = null, string? validatorsFilePath = null)
    {
        _http = httpClient ?? SharedHttpClient;
        _cacheFilePath = cacheFilePath ?? BifrostPaths.PackageIndexCachePath;
        _validatorsFilePath = validatorsFilePath ?? BifrostPaths.PackageIndexValidatorsPath;
        Directory.CreateDirectory(Path.GetDirectoryName(_cacheFilePath)!);
    }

    private static readonly HttpClient SharedHttpClient = new()
    {
        Timeout = TimeSpan.FromSeconds(60),
    };

    /// <summary>
    /// Fetches the current package index, using the on-disk cache where
    /// possible. <paramref name="force"/> = false sends a conditional
    /// request using the last known validators; a 304 loads the disk cache.
    /// <paramref name="force"/> = true always requests a fresh copy. If the
    /// network request fails outright and a disk cache exists, that cache is
    /// returned rather than throwing.
    /// </summary>
    public async Task<List<ThunderstorePackage>> FetchIndexAsync(bool force = false, CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, IndexUri);
        if (!force)
        {
            var validators = LoadValidators();
            if (validators is not null)
            {
                if (!string.IsNullOrEmpty(validators.ETag))
                {
                    request.Headers.TryAddWithoutValidation("If-None-Match", validators.ETag);
                }
                if (!string.IsNullOrEmpty(validators.LastModified))
                {
                    request.Headers.TryAddWithoutValidation("If-Modified-Since", validators.LastModified);
                }
            }
        }

        HttpResponseMessage response;
        try
        {
            response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        }
        catch when (TryLoadCachedPackages(out var cached))
        {
            return cached!;
        }

        using (response)
        {
            if (response.StatusCode == HttpStatusCode.NotModified)
            {
                if (TryLoadCachedPackages(out var cached))
                {
                    return cached!;
                }
                // Shouldn't happen (server wouldn't 304 without a validator
                // we sent), but fall back to a fresh fetch just in case the
                // cache went missing.
                return await FetchIndexAsync(force: true, cancellationToken);
            }

            if (response.IsSuccessStatusCode)
            {
                var data = await response.Content.ReadAsByteArrayAsync(cancellationToken);
                var packages = Decode(data);
                await File.WriteAllBytesAsync(_cacheFilePath, data, cancellationToken);

                var validators = new Validators
                {
                    ETag = response.Headers.ETag?.ToString(),
                    LastModified = response.Content.Headers.LastModified?.ToString("R")
                        ?? GetRawHeader(response, "Last-Modified"),
                };
                SaveValidators(validators);
                return Filter(packages);
            }

            if (TryLoadCachedPackages(out var fallbackCached))
            {
                return fallbackCached!;
            }
            throw new ThunderstoreClientException($"Thunderstore index request failed with status {(int)response.StatusCode}");
        }
    }

    private static string? GetRawHeader(HttpResponseMessage response, string name) =>
        response.Headers.TryGetValues(name, out var values) ? values.FirstOrDefault() : null;

    /// <summary>The icon URL for a package's latest version, if it has one.</summary>
    public static string? IconUrl(ThunderstorePackage package)
    {
        var icon = package.LatestVersion?.Icon;
        return string.IsNullOrEmpty(icon) ? null : icon;
    }

    private Validators? LoadValidators()
    {
        try
        {
            if (!File.Exists(_validatorsFilePath))
            {
                return null;
            }
            var json = File.ReadAllText(_validatorsFilePath);
            return JsonSerializer.Deserialize<Validators>(json, BifrostJson.Options);
        }
        catch
        {
            return null;
        }
    }

    private void SaveValidators(Validators validators)
    {
        if (string.IsNullOrEmpty(validators.ETag) && string.IsNullOrEmpty(validators.LastModified))
        {
            return;
        }
        try
        {
            File.WriteAllText(_validatorsFilePath, JsonSerializer.Serialize(validators, BifrostJson.Options));
        }
        catch
        {
            // best effort
        }
    }

    private bool TryLoadCachedPackages(out List<ThunderstorePackage>? packages)
    {
        try
        {
            if (!File.Exists(_cacheFilePath))
            {
                packages = null;
                return false;
            }
            var data = File.ReadAllBytes(_cacheFilePath);
            packages = Filter(Decode(data));
            return true;
        }
        catch
        {
            packages = null;
            return false;
        }
    }

    private static List<ThunderstorePackage> Decode(byte[] data)
    {
        var packages = JsonSerializer.Deserialize<List<ThunderstorePackage>>(data, ThunderstorePackageJsonOptions);
        return packages ?? new List<ThunderstorePackage>();
    }

    private static readonly JsonSerializerOptions ThunderstorePackageJsonOptions = new();

    private static List<ThunderstorePackage> Filter(List<ThunderstorePackage> packages) =>
        packages.Where(p => !p.IsDeprecated && p.FullName != LoaderPackageFullName).ToList();
}
