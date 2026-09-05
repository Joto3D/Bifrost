using System.IO.Compression;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Bifrost.Core.Services;

/// <summary>
/// Installs and updates the BepInEx mod loader pack
/// (denikson-BepInExPack_Valheim from Thunderstore) next to Valheim on
/// Windows. Ported from the macOS reference implementation's
/// <c>BepInExInstaller.swift</c>, with the Windows delta: the payload is
/// <c>BepInEx/</c>, <c>winhttp.dll</c>, <c>doorstop_config.ini</c> and
/// <c>.doorstop_version</c> — no <c>doorstop_libs</c> (that's the
/// macOS/Linux dylib/so pair; winhttp.dll *is* Windows' doorstop shim,
/// loaded automatically because Windows Valheim loads winhttp.dll from the
/// game directory) and no unix start scripts. No launch wrapper, no
/// quarantine/chmod step, no Steam launch-options config — BepInEx just
/// works once the payload is copied in.
///
/// Reinstalling to pick up a newer pack version never touches
/// <c>BepInEx/plugins</c> or <c>BepInEx/config</c> — those hold
/// user-installed mods and settings and must survive an upgrade untouched.
/// </summary>
public sealed class BepInExInstaller
{
    public sealed class InstallerException(string message) : Exception(message);

    public sealed record InstallStatus(bool BepInExCorePresent, bool WinhttpPresent, bool DoorstopConfigPresent)
    {
        public bool PackFilesPresent => BepInExCorePresent && WinhttpPresent && DoorstopConfigPresent;
    }

    public sealed record VersionInfo(string VersionNumber, Uri DownloadUrl);

    public enum ProgressStage { FetchingVersionInfo, PackAlreadyUpToDate, Downloading, Extracting, CopyingFiles, Done }
    public sealed record Progress(ProgressStage Stage, string? VersionNumber = null);

    public sealed record InstallOutcome(string VersionNumber, bool PackWasUpToDate);

    private static readonly Uri PackageIndexUri = new("https://thunderstore.io/api/experimental/package/denikson/BepInExPack_Valheim/");
    private const string PayloadFolderName = "BepInExPack_Valheim";

    /// <summary>
    /// Payload items copied from inside the pack's BepInExPack_Valheim/
    /// folder to sit next to valheim.exe. doorstop_libs, changelog.txt, and
    /// the unix start_*.sh scripts are part of the upstream pack but
    /// irrelevant (or actively wrong) on Windows and deliberately skipped.
    /// </summary>
    private static readonly string[] PayloadItems = { "BepInEx", "winhttp.dll", "doorstop_config.ini", ".doorstop_version" };

    private readonly HttpClient _http;

    public BepInExInstaller(HttpClient? httpClient = null)
    {
        _http = httpClient ?? SharedHttpClient;
    }

    private static readonly HttpClient SharedHttpClient = new() { Timeout = TimeSpan.FromMinutes(5) };

    // MARK: - Status

    /// <summary>Reads what's on disk right now. Filesystem-only, no network.</summary>
    public static InstallStatus Status(string gameDir) => new(
        Directory.Exists(Path.Combine(gameDir, "BepInEx", "core")),
        File.Exists(Path.Combine(gameDir, "winhttp.dll")),
        File.Exists(Path.Combine(gameDir, "doorstop_config.ini")));

    /// <summary>Fetches the latest published pack version from Thunderstore's experimental package API.</summary>
    public async Task<VersionInfo> FetchLatestVersionInfoAsync(CancellationToken cancellationToken = default)
    {
        using var response = await _http.GetAsync(PackageIndexUri, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            throw new InstallerException("Could not read the BepInExPack_Valheim package listing from Thunderstore");
        }
        var data = await response.Content.ReadAsByteArrayAsync(cancellationToken);
        var decoded = JsonSerializer.Deserialize<PackageResponse>(data) ?? throw new InstallerException("Malformed package response");
        return new VersionInfo(decoded.Latest.VersionNumber, new Uri(decoded.Latest.DownloadUrl));
    }

    /// <summary>
    /// Describes, without changing anything, what <see cref="InstallAsync"/>
    /// would do right now. Fetches the latest version info best-effort — a
    /// network failure just means version comparisons are skipped.
    /// </summary>
    public async Task<List<string>> DryRunAsync(string gameDir, string? manifestVersion = null, CancellationToken cancellationToken = default)
    {
        var actions = new List<string>();
        var local = Status(gameDir);
        VersionInfo? latest = null;
        try { latest = await FetchLatestVersionInfoAsync(cancellationToken); } catch { /* best-effort */ }

        if (local.PackFilesPresent)
        {
            if (manifestVersion is not null)
            {
                if (latest is not null && manifestVersion != latest.VersionNumber)
                {
                    actions.Add($"Update BepInEx pack: {manifestVersion} -> {latest.VersionNumber} (plugins/config left untouched)");
                }
                else
                {
                    actions.Add($"BepInEx pack already installed (version {manifestVersion}) — nothing to do");
                }
            }
            else
            {
                actions.Add("BepInEx pack files present but not recorded in Bifrost's manifest — version unknown; reinstall/update available (not forced, plugins/config left untouched)");
            }
        }
        else
        {
            var versionDescription = latest?.VersionNumber ?? "latest";
            actions.Add($"Download BepInExPack_Valheim {versionDescription} from Thunderstore");
            actions.Add($"Extract and copy pack files into {gameDir}");
        }

        return actions;
    }

    // MARK: - Install

    /// <summary>
    /// Installs (or updates) the BepInEx pack into <paramref name="gameDir"/>.
    /// Idempotent: skips the download/copy entirely when the pack files are
    /// present and <paramref name="manifestVersion"/> already matches the
    /// latest published version. A reinstall/upgrade never touches
    /// BepInEx/plugins or BepInEx/config.
    /// </summary>
    public async Task<InstallOutcome> InstallAsync(string gameDir, string? manifestVersion = null, Action<Progress>? onProgress = null, CancellationToken cancellationToken = default)
    {
        onProgress?.Invoke(new Progress(ProgressStage.FetchingVersionInfo));
        var latest = await FetchLatestVersionInfoAsync(cancellationToken);
        var local = Status(gameDir);

        var packUpToDate = local.PackFilesPresent && manifestVersion == latest.VersionNumber;
        if (packUpToDate)
        {
            onProgress?.Invoke(new Progress(ProgressStage.PackAlreadyUpToDate, latest.VersionNumber));
        }
        else
        {
            await InstallPackFilesAsync(gameDir, latest, onProgress, cancellationToken);
        }

        onProgress?.Invoke(new Progress(ProgressStage.Done, latest.VersionNumber));
        return new InstallOutcome(latest.VersionNumber, packUpToDate);
    }

    private async Task InstallPackFilesAsync(string gameDir, VersionInfo version, Action<Progress>? onProgress, CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(gameDir);

        var workDir = Path.Combine(Path.GetTempPath(), $"Bifrost-BepInExInstall-{Guid.NewGuid()}");
        Directory.CreateDirectory(workDir);
        try
        {
            onProgress?.Invoke(new Progress(ProgressStage.Downloading, version.VersionNumber));
            var zipPath = Path.Combine(workDir, "BepInExPack_Valheim.zip");
            using (var response = await _http.GetAsync(version.DownloadUrl, HttpCompletionOption.ResponseHeadersRead, cancellationToken))
            {
                if (!response.IsSuccessStatusCode)
                {
                    throw new InstallerException($"Download failed with HTTP status {(int)response.StatusCode}");
                }
                await using var fileStream = File.Create(zipPath);
                await response.Content.CopyToAsync(fileStream, cancellationToken);
            }

            onProgress?.Invoke(new Progress(ProgressStage.Extracting));
            var extractDir = Path.Combine(workDir, "extracted");
            Directory.CreateDirectory(extractDir);
            ZipFile.ExtractToDirectory(zipPath, extractDir);

            var payloadDir = Path.Combine(extractDir, PayloadFolderName);
            if (!Directory.Exists(payloadDir))
            {
                throw new InstallerException("Extracted archive did not contain a BepInExPack_Valheim folder");
            }

            onProgress?.Invoke(new Progress(ProgressStage.CopyingFiles));
            CopyPayload(payloadDir, gameDir);
        }
        finally
        {
            try { Directory.Delete(workDir, recursive: true); } catch { /* best effort cleanup */ }
        }
    }

    /// <summary>
    /// Copies each payload item into gameDir. BepInEx is merged rather than
    /// replaced wholesale, so existing plugins/ and config/ contents are
    /// never touched.
    /// </summary>
    private static void CopyPayload(string payloadDir, string gameDir)
    {
        foreach (var item in PayloadItems)
        {
            var src = Path.Combine(payloadDir, item);
            if (item == "BepInEx")
            {
                if (Directory.Exists(src))
                {
                    MergeBepInExDirectory(src, Path.Combine(gameDir, item));
                }
                continue;
            }

            if (!File.Exists(src))
            {
                continue;
            }
            var dst = Path.Combine(gameDir, item);
            File.Copy(src, dst, overwrite: true);
        }
    }

    private static readonly HashSet<string> PreservedBepInExNames = new(StringComparer.OrdinalIgnoreCase) { "plugins", "config" };

    private static void MergeBepInExDirectory(string src, string dst)
    {
        Directory.CreateDirectory(dst);
        foreach (var entryPath in Directory.EnumerateFileSystemEntries(src))
        {
            var name = Path.GetFileName(entryPath);
            var target = Path.Combine(dst, name);
            var isDir = Directory.Exists(entryPath);

            if (PreservedBepInExNames.Contains(name) && (Directory.Exists(target) || File.Exists(target)))
            {
                continue; // never touch existing plugins/config — user data.
            }

            if (isDir)
            {
                CopyDirectoryRecursive(entryPath, target);
            }
            else
            {
                File.Copy(entryPath, target, overwrite: true);
            }
        }
    }

    private static void CopyDirectoryRecursive(string src, string dst)
    {
        Directory.CreateDirectory(dst);
        foreach (var file in Directory.EnumerateFiles(src))
        {
            File.Copy(file, Path.Combine(dst, Path.GetFileName(file)), overwrite: true);
        }
        foreach (var dir in Directory.EnumerateDirectories(src))
        {
            CopyDirectoryRecursive(dir, Path.Combine(dst, Path.GetFileName(dir)));
        }
    }

    // MARK: - Thunderstore experimental package API

    private sealed class PackageResponse
    {
        [JsonPropertyName("latest")]
        public LatestInfo Latest { get; set; } = new();

        public sealed class LatestInfo
        {
            [JsonPropertyName("version_number")]
            public string VersionNumber { get; set; } = string.Empty;

            [JsonPropertyName("download_url")]
            public string DownloadUrl { get; set; } = string.Empty;
        }
    }
}
