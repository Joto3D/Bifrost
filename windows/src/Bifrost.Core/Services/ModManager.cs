using System.IO.Compression;
using System.Text.Json;
using System.Text.RegularExpressions;
using Bifrost.Core.Models;

namespace Bifrost.Core.Services;

/// <summary>
/// Installs, updates, enables/disables, and uninstalls Thunderstore mods
/// into the Valheim game directory, and owns Bifrost's manifest. Ported
/// from the macOS reference implementation's <c>ModManager.swift</c>.
///
/// Resolution and mapping follow r2modman-compatible conventions: a
/// dependency string is "Author-Name-Version" (always resolved to the
/// index's current latest version, since Thunderstore's own convention is
/// that the pinned version is a minimum), and
/// denikson-BepInExPack_Valheim (the loader pack) is special-cased to route
/// through <see cref="BepInExInstaller"/> rather than being unpacked as a
/// plugin. No xattr/quarantine handling — that's a macOS-only concept.
/// </summary>
public sealed class ModManager
{
    public sealed class ModManagerException(string message) : Exception(message);

    public abstract record ResolvedInstall
    {
        public sealed record Loader : ResolvedInstall;
        public sealed record Mod(string FullName, ThunderstorePackage Package, ThunderstorePackage.Version Version) : ResolvedInstall;

        public string GetFullName() => this switch
        {
            Loader => ModManager.LoaderFullName,
            Mod m => m.FullName,
            _ => throw new InvalidOperationException(),
        };
    }

    public enum ProgressStage { InstallingLoader, Downloading, Extracting, CopyingFiles, Done }
    public sealed record Progress(ProgressStage Stage, string? FullName = null);

    public sealed record UpdateInfo(string FullName, string InstalledVersion, string LatestVersion);

    public const string LoaderFullName = "denikson-BepInExPack_Valheim";

    private static readonly HashSet<string> SkippedRootFileNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "manifest.json", "icon.png", "readme.md", "changelog.md", "license", "license.md", "license.txt",
    };
    private static readonly string[] KnownBepInExSubdirs = { "plugins", "patchers", "config", "core" };

    private readonly HttpClient _http;
    private readonly BepInExInstaller _bepInExInstaller;
    public string ManifestPath { get; }

    public ModManager(HttpClient? httpClient = null, BepInExInstaller? bepInExInstaller = null, string? manifestPath = null)
    {
        _http = httpClient ?? SharedHttpClient;
        _bepInExInstaller = bepInExInstaller ?? new BepInExInstaller();
        ManifestPath = manifestPath ?? BifrostPaths.ManifestPath;
    }

    private static readonly HttpClient SharedHttpClient = new() { Timeout = TimeSpan.FromMinutes(5) };

    // MARK: - Manifest I/O

    public InstalledManifest LoadManifest()
    {
        try
        {
            if (!File.Exists(ManifestPath))
            {
                return InstalledManifest.Empty;
            }
            var json = File.ReadAllText(ManifestPath);
            return JsonSerializer.Deserialize<InstalledManifest>(json, BifrostJson.Options) ?? InstalledManifest.Empty;
        }
        catch
        {
            return InstalledManifest.Empty;
        }
    }

    private void Save(InstalledManifest manifest)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(ManifestPath)!);
        var json = JsonSerializer.Serialize(manifest, BifrostJson.Options);
        File.WriteAllText(ManifestPath, json);
    }

    public string? LoaderVersion() => LoadManifest().Loader?.Version;

    public bool IsInstalled(string fullName) => LoadManifest().Mods.Any(m => m.FullName == fullName);

    public InstalledManifest.InstalledMod? InstalledMod(string fullName) =>
        LoadManifest().Mods.FirstOrDefault(m => m.FullName == fullName);

    public void SetLoaderVersion(string version)
    {
        var manifest = LoadManifest();
        manifest.Loader = new InstalledManifest.LoaderInfo { Version = version };
        Save(manifest);
    }

    // MARK: - Resolve

    /// <summary>
    /// Resolves <paramref name="package"/>'s latest version plus every
    /// dependency, recursively, against the given (already-fetched)
    /// Thunderstore index. Returns entries in dependency-first order.
    /// </summary>
    public async Task<List<ResolvedInstall>> ResolveAsync(ThunderstorePackage package, IReadOnlyList<ThunderstorePackage> index)
    {
        var manifest = LoadManifest();
        var byFullName = index.ToDictionary(p => p.FullName);

        var needsLoader = false;
        var visited = new HashSet<string>();
        var order = new List<ResolvedInstall>();

        void Visit(string fullName)
        {
            if (fullName == LoaderFullName)
            {
                needsLoader = true;
                return;
            }
            if (!visited.Add(fullName))
            {
                return;
            }

            if (!byFullName.TryGetValue(fullName, out var pkg))
            {
                throw new ModManagerException($"{fullName} was not found in the cached Thunderstore index");
            }
            var latest = pkg.LatestVersion ?? throw new ModManagerException($"{fullName} has no published version in the index");

            foreach (var dependency in latest.Dependencies)
            {
                Visit(FullNameFromDependencyId(dependency));
            }

            var installedVersion = manifest.Mods.FirstOrDefault(m => m.FullName == fullName)?.Version;
            if (installedVersion == latest.VersionNumber)
            {
                return; // up to date — nothing to do
            }
            order.Add(new ResolvedInstall.Mod(fullName, pkg, latest));
        }

        Visit(package.FullName);

        if (needsLoader)
        {
            BepInExInstaller.VersionInfo? latestLoader = null;
            try { latestLoader = await _bepInExInstaller.FetchLatestVersionInfoAsync(); } catch { /* best effort */ }
            var currentLoader = manifest.Loader?.Version;
            if (currentLoader is null || currentLoader != latestLoader?.VersionNumber)
            {
                order.Insert(0, new ResolvedInstall.Loader());
            }
        }

        return order;
    }

    private static readonly Regex TrailingVersion = new(@"-\d+\.\d+\.\d+$", RegexOptions.Compiled);

    /// <summary>"Author-Name-Version" -> "Author-Name".</summary>
    private static string FullNameFromDependencyId(string id)
    {
        var match = TrailingVersion.Match(id);
        return match.Success ? id[..match.Index] : id;
    }

    // MARK: - Install

    public async Task<List<ResolvedInstall>> InstallAsync(ThunderstorePackage package, IReadOnlyList<ThunderstorePackage> index, string gameDir, Action<Progress>? onProgress = null)
    {
        var plan = await ResolveAsync(package, index);
        await InstallResolvedAsync(plan, gameDir, onProgress);
        return plan;
    }

    public async Task InstallResolvedAsync(IReadOnlyList<ResolvedInstall> resolved, string gameDir, Action<Progress>? onProgress = null)
    {
        foreach (var item in resolved)
        {
            switch (item)
            {
                case ResolvedInstall.Loader:
                    onProgress?.Invoke(new Progress(ProgressStage.InstallingLoader));
                    var outcome = await _bepInExInstaller.InstallAsync(gameDir, LoaderVersion());
                    SetLoaderVersion(outcome.VersionNumber);
                    break;
                case ResolvedInstall.Mod mod:
                    await InstallModAsync(mod.FullName, mod.Version, gameDir, onProgress);
                    break;
            }
        }
    }

    private async Task InstallModAsync(string fullName, ThunderstorePackage.Version version, string gameDir, Action<Progress>? onProgress)
    {
        onProgress?.Invoke(new Progress(ProgressStage.Downloading, fullName));
        var workDir = Path.Combine(Path.GetTempPath(), $"Bifrost-ModInstall-{Guid.NewGuid()}");
        Directory.CreateDirectory(workDir);
        try
        {
            var zipPath = Path.Combine(workDir, $"{SanitizeForFileName(fullName)}.zip");
            using (var response = await _http.GetAsync(version.DownloadUrl, HttpCompletionOption.ResponseHeadersRead))
            {
                if (!response.IsSuccessStatusCode)
                {
                    throw new ModManagerException($"Download failed with HTTP status {(int)response.StatusCode}");
                }
                await using var fileStream = File.Create(zipPath);
                await response.Content.CopyToAsync(fileStream);
            }

            onProgress?.Invoke(new Progress(ProgressStage.Extracting, fullName));
            var extractDir = Path.Combine(workDir, "extracted");
            Directory.CreateDirectory(extractDir);
            ZipFile.ExtractToDirectory(zipPath, extractDir);

            onProgress?.Invoke(new Progress(ProgressStage.CopyingFiles, fullName));
            var payloadRoot = ResolvePayloadRoot(extractDir);
            var writtenFiles = MapPayload(payloadRoot, gameDir, fullName);
            if (writtenFiles.Count == 0)
            {
                throw new ModManagerException($"Extracted archive for {fullName} contained no recognizable mod files");
            }

            RecordInstalledMod(fullName, version.VersionNumber, writtenFiles);
            onProgress?.Invoke(new Progress(ProgressStage.Done, fullName));
        }
        finally
        {
            try { Directory.Delete(workDir, recursive: true); } catch { /* best effort */ }
        }
    }

    private static string SanitizeForFileName(string s) => string.Concat(s.Select(c => Path.GetInvalidFileNameChars().Contains(c) ? '_' : c));

    /// <summary>
    /// If the extracted archive's only top-level entry is a single
    /// directory, descends into it; otherwise returns the extraction root.
    /// </summary>
    private static string ResolvePayloadRoot(string extractDir)
    {
        var entries = TopLevelEntries(extractDir);
        if (entries.Count == 1 && Directory.Exists(entries[0]))
        {
            return entries[0];
        }
        return extractDir;
    }

    /// <summary>
    /// Maps an extracted payload into gameDir using r2modman-compatible
    /// heuristics. Returns the game-dir-relative paths (forward-slash,
    /// matching the manifest JSON shape used by the macOS app) of every file
    /// actually written.
    /// </summary>
    private static List<string> MapPayload(string root, string gameDir, string fullName)
    {
        var entryNames = new HashSet<string>(TopLevelEntries(root).Select(Path.GetFileName)!, StringComparer.OrdinalIgnoreCase);

        if (entryNames.Contains("BepInEx"))
        {
            return CopyTree(Path.Combine(root, "BepInEx"), "BepInEx", gameDir);
        }

        var presentSubdirs = KnownBepInExSubdirs.Where(entryNames.Contains).ToList();
        if (presentSubdirs.Count > 0)
        {
            var written = new List<string>();
            foreach (var subdir in presentSubdirs)
            {
                var src = Path.Combine(root, subdir);
                var destRelative = subdir == "plugins" ? $"BepInEx/plugins/{fullName}" : $"BepInEx/{subdir}";
                written.AddRange(CopyTree(src, destRelative, gameDir));
            }
            return written;
        }

        var destRelativeFlat = $"BepInEx/plugins/{fullName}";
        var destRoot = Path.Combine(gameDir, "BepInEx", "plugins", fullName);
        Directory.CreateDirectory(destRoot);

        var writtenFlat = new List<string>();
        foreach (var relativeToRoot in RelativeFilePaths(root))
        {
            if (SkippedRootFileNames.Contains(Path.GetFileName(relativeToRoot)))
            {
                continue;
            }
            var src = Path.Combine(root, relativeToRoot);
            var dest = Path.Combine(destRoot, relativeToRoot);
            Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
            File.Copy(src, dest, overwrite: true);
            writtenFlat.Add($"{destRelativeFlat}/{ToForwardSlash(relativeToRoot)}");
        }
        return writtenFlat;
    }

    /// <summary>
    /// Recursively copies every file under src into gameDir/destRelative,
    /// merging into whatever's already there. A .cfg file landing under
    /// BepInEx/config that would overwrite an existing file is skipped
    /// (preserves the user's settings).
    /// </summary>
    private static List<string> CopyTree(string src, string destRelative, string gameDir)
    {
        var destRoot = Path.Combine(gameDir, destRelative.Replace('/', Path.DirectorySeparatorChar));
        var written = new List<string>();

        foreach (var relativeToSrc in RelativeFilePaths(src))
        {
            var file = Path.Combine(src, relativeToSrc);
            var dest = Path.Combine(destRoot, relativeToSrc);
            var gameRelative = $"{destRelative}/{ToForwardSlash(relativeToSrc)}";

            if (gameRelative.StartsWith("BepInEx/config/", StringComparison.Ordinal)
                && string.Equals(Path.GetExtension(dest), ".cfg", StringComparison.OrdinalIgnoreCase)
                && File.Exists(dest))
            {
                continue; // preserve the user's existing config
            }

            Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
            File.Copy(file, dest, overwrite: true);
            written.Add(gameRelative);
        }
        return written;
    }

    private static List<string> TopLevelEntries(string dir) =>
        Directory.EnumerateFileSystemEntries(dir).Where(e => Path.GetFileName(e) != "__MACOSX").ToList();

    /// <summary>Every file (never directories) under root, as forward-slash paths relative to root.</summary>
    private static List<string> RelativeFilePaths(string root)
    {
        var paths = new List<string>();
        if (!Directory.Exists(root))
        {
            return paths;
        }
        foreach (var file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
        {
            var relative = Path.GetRelativePath(root, file);
            var components = relative.Split(Path.DirectorySeparatorChar);
            if (components[0] == "__MACOSX" || components.Any(c => c.StartsWith('.')))
            {
                continue;
            }
            paths.Add(relative);
        }
        return paths;
    }

    private static string ToForwardSlash(string path) => path.Replace(Path.DirectorySeparatorChar, '/').Replace('\\', '/');

    private void RecordInstalledMod(string fullName, string version, List<string> files)
    {
        var manifest = LoadManifest();
        manifest.Mods.RemoveAll(m => m.FullName == fullName);
        manifest.Mods.Add(new InstalledManifest.InstalledMod
        {
            FullName = fullName,
            Version = version,
            Enabled = true,
            Files = files.OrderBy(f => f, StringComparer.Ordinal).ToList(),
        });
        Save(manifest);
    }

    // MARK: - Uninstall

    /// <summary>
    /// Deletes exactly the files fullName's manifest entry recorded, cleans
    /// up any now-empty directories that leaves behind under
    /// BepInEx/plugins, and removes the manifest entry.
    /// </summary>
    public void Uninstall(string fullName, string gameDir)
    {
        var manifest = LoadManifest();
        var index = manifest.Mods.FindIndex(m => m.FullName == fullName);
        if (index < 0)
        {
            throw new ModManagerException($"{fullName} is not installed");
        }
        var mod = manifest.Mods[index];

        foreach (var relativePath in mod.Files)
        {
            try { File.Delete(Path.Combine(gameDir, relativePath.Replace('/', Path.DirectorySeparatorChar))); } catch { /* best effort */ }
        }

        var pluginsRoot = Path.Combine(gameDir, "BepInEx", "plugins");
        var candidateDirs = new HashSet<string>(mod.Files.Select(f => Path.GetDirectoryName(Path.Combine(gameDir, f.Replace('/', Path.DirectorySeparatorChar)))!));
        while (candidateDirs.Count > 0)
        {
            var parents = new HashSet<string>();
            foreach (var dir in candidateDirs)
            {
                if (!dir.StartsWith(pluginsRoot, StringComparison.Ordinal) || dir == pluginsRoot)
                {
                    continue;
                }
                if (!Directory.Exists(dir) || Directory.EnumerateFileSystemEntries(dir).Any())
                {
                    continue;
                }
                try { Directory.Delete(dir); } catch { /* best effort */ }
                var parent = Path.GetDirectoryName(dir);
                if (parent is not null)
                {
                    parents.Add(parent);
                }
            }
            candidateDirs = parents;
        }

        manifest.Mods.RemoveAt(index);
        Save(manifest);
    }

    // MARK: - Enable / disable

    /// <summary>
    /// Toggles every recorded .dll/.dll.disabled file for fullName between
    /// the two, updating the manifest's recorded paths to match. Non-DLL
    /// files (config, assets, pdb) are left alone.
    /// </summary>
    public void SetEnabled(string fullName, bool enabled, string gameDir)
    {
        var manifest = LoadManifest();
        var index = manifest.Mods.FindIndex(m => m.FullName == fullName);
        if (index < 0)
        {
            throw new ModManagerException($"{fullName} is not installed");
        }
        if (manifest.Mods[index].Enabled == enabled)
        {
            return;
        }

        var newFiles = new List<string>();
        foreach (var relativePath in manifest.Mods[index].Files)
        {
            if (!relativePath.EndsWith(".dll", StringComparison.Ordinal) && !relativePath.EndsWith(".dll.disabled", StringComparison.Ordinal))
            {
                newFiles.Add(relativePath);
                continue;
            }

            var newRelativePath = enabled
                ? relativePath[..^".disabled".Length]
                : relativePath + ".disabled";

            var currentPath = Path.Combine(gameDir, relativePath.Replace('/', Path.DirectorySeparatorChar));
            var newPath = Path.Combine(gameDir, newRelativePath.Replace('/', Path.DirectorySeparatorChar));
            if (File.Exists(currentPath))
            {
                if (File.Exists(newPath))
                {
                    File.Delete(newPath);
                }
                File.Move(currentPath, newPath);
            }
            newFiles.Add(newRelativePath);
        }

        manifest.Mods[index].Files = newFiles;
        manifest.Mods[index].Enabled = enabled;
        Save(manifest);
    }

    // MARK: - Updates

    /// <summary>
    /// Compares every installed mod's recorded version against index's
    /// current latest, returning one entry per mod that has a newer version
    /// available.
    /// </summary>
    public List<UpdateInfo> UpdatesAvailable(IReadOnlyList<ThunderstorePackage> index)
    {
        var byFullName = index.ToDictionary(p => p.FullName);
        var result = new List<UpdateInfo>();
        foreach (var mod in LoadManifest().Mods)
        {
            if (!byFullName.TryGetValue(mod.FullName, out var pkg))
            {
                continue;
            }
            var latest = pkg.LatestVersion;
            if (latest is null || latest.VersionNumber == mod.Version)
            {
                continue;
            }
            result.Add(new UpdateInfo(mod.FullName, mod.Version, latest.VersionNumber));
        }
        return result;
    }

    /// <summary>
    /// Uninstalls and reinstalls fullName at index's current latest version,
    /// preserving its enabled state.
    /// </summary>
    public async Task UpdateAsync(string fullName, IReadOnlyList<ThunderstorePackage> index, string gameDir, Action<Progress>? onProgress = null)
    {
        var mod = LoadManifest().Mods.FirstOrDefault(m => m.FullName == fullName)
            ?? throw new ModManagerException($"{fullName} is not installed");
        var package = index.FirstOrDefault(p => p.FullName == fullName)
            ?? throw new ModManagerException($"{fullName} was not found in the cached Thunderstore index");
        var latest = package.LatestVersion ?? throw new ModManagerException($"{fullName} has no published version in the index");
        var wasEnabled = mod.Enabled;

        Uninstall(fullName, gameDir);
        await InstallModAsync(fullName, latest, gameDir, onProgress);

        if (!wasEnabled)
        {
            SetEnabled(fullName, false, gameDir);
        }
    }
}
