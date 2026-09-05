using System.Collections.ObjectModel;
using Bifrost.Core.Models;
using Bifrost.Core.Services;
using Bifrost.Services;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace Bifrost.ViewModels;

/// <summary>
/// The Installed tab: manifest list with enable/disable, update, remove.
/// Mirrors the macOS app's InstalledModsView.swift.
/// </summary>
public partial class InstalledViewModel : ViewModelBase
{
    private readonly AppServices _services;
    private List<ThunderstorePackage> _index = new();

    /// <summary>Exposed so the view can construct the profiles management dialog against the same service instances.</summary>
    public AppServices Services => _services;

    /// <summary>Raised after an install/uninstall/update/toggle, so other tabs can refresh.</summary>
    public event Func<Task>? ModsChanged;

    public ObservableCollection<InstalledModRowViewModel> Mods { get; } = new();

    [ObservableProperty] private string? _loaderVersion;
    [ObservableProperty] private bool _isBusy;
    [ObservableProperty] private string _statusMessage = "";

    /// <summary>One pending "this name is already installed" decision, surfaced as an inline overlay while <see cref="InstallFilesAsync"/> is mid-loop.</summary>
    [ObservableProperty] private bool _isConfirmingReplace;
    [ObservableProperty] private string? _replaceConfirmFullName;
    private TaskCompletionSource<bool>? _replaceConfirmTcs;

    [ObservableProperty] private bool _isInstallingFromFile;

    [ObservableProperty] private bool _isUpdatingAll;
    [ObservableProperty] private string? _updateAllProgressLine;

    public int UpdatableCount => Mods.Count(m => m.UpdateAvailable);
    public bool HasUpdatable => UpdatableCount > 0;

    public InstalledViewModel(AppServices services)
    {
        _services = services;
        Mods.CollectionChanged += (_, _) =>
        {
            OnPropertyChanged(nameof(HasMods));
            OnPropertyChanged(nameof(UpdatableCount));
            OnPropertyChanged(nameof(HasUpdatable));
            UpdateAllCommand.NotifyCanExecuteChanged();
        };
    }

    public bool HasMods => Mods.Count > 0;

    [RelayCommand]
    public async Task RefreshAsync() => await RefreshCoreAsync(forceIndexRefresh: false);

    /// <summary>
    /// Forces a fresh Thunderstore index fetch before recomputing update
    /// availability — used by the game-update banner's "Check Mod Updates"
    /// action (see <c>MainViewModel</c>), which wants a live re-check rather
    /// than whatever's already cached.
    /// </summary>
    public async Task CheckForUpdatesAsync() => await RefreshCoreAsync(forceIndexRefresh: true);

    private async Task RefreshCoreAsync(bool forceIndexRefresh)
    {
        IsBusy = true;
        try
        {
            var manifest = _services.ModManager.LoadManifest();
            LoaderVersion = manifest.Loader?.Version;

            // Best-effort: pull the index (cached is fine unless a caller
            // asked for a forced refresh) so update availability can be
            // shown; missing/stale index just means we show no "update
            // available" badges.
            try { _index = await _services.ThunderstoreClient.FetchIndexAsync(force: forceIndexRefresh); }
            catch { _index = new List<ThunderstorePackage>(); }

            var byFullName = _index.ToDictionary(p => p.FullName);
            Mods.Clear();
            foreach (var mod in manifest.Mods.OrderBy(m => m.FullName, StringComparer.OrdinalIgnoreCase))
            {
                byFullName.TryGetValue(mod.FullName, out var pkg);
                // A "local" mod was never resolved against the Thunderstore
                // index, so even a coincidental FullName match there is not
                // an update — mirrors ModManager.UpdatesAvailable's own
                // source == "local" skip.
                var latest = mod.Source == "local" ? null : pkg?.LatestVersion?.VersionNumber;
                var row = new InstalledModRowViewModel(mod, latest) { IconUrl = pkg is not null ? ThunderstoreClient.IconUrl(pkg) : null };
                row.PropertyChanged += async (_, e) =>
                {
                    if (e.PropertyName == nameof(InstalledModRowViewModel.Enabled))
                    {
                        await ToggleEnabledAsync(row);
                    }
                };
                Mods.Add(row);
            }

            LoadConfigAssociations(byFullName);

            StatusMessage = $"{Mods.Count} mod(s) installed.";
        }
        finally
        {
            IsBusy = false;
        }
    }

    /// <summary>
    /// Discovers every <c>.cfg</c> under <c>BepInEx/config</c>, associates
    /// each with an installed mod (<see cref="BepInExConfig.Associate"/>,
    /// using both the mod's full name and the Thunderstore index's display
    /// name as match candidates), and parses each associated file's
    /// <c>KeyboardShortcut</c> entries for the row-level chips. Mirrors the
    /// macOS app's InstalledModsView.loadConfigs().
    /// </summary>
    private void LoadConfigAssociations(Dictionary<string, ThunderstorePackage> byFullName)
    {
        var gameDir = _services.LocateGameDir();
        if (gameDir is null)
        {
            foreach (var row in Mods)
            {
                row.ConfigPath = null;
                row.SetKeybinds(Array.Empty<string>());
            }
            return;
        }

        var candidates = Mods
            .Select(row => (FullName: row.FullName, Name: byFullName.TryGetValue(row.FullName, out var package) ? package.Name : ""))
            .ToList();
        var configDir = Path.Combine(gameDir, "BepInEx", "config");
        var configs = BepInExConfig.DiscoverConfigs(configDir, candidates);
        var configByFullName = configs
            .Where(c => c.AssociatedFullName is not null)
            .ToDictionary(c => c.AssociatedFullName!);

        foreach (var row in Mods)
        {
            if (!configByFullName.TryGetValue(row.FullName, out var config))
            {
                row.ConfigPath = null;
                row.SetKeybinds(Array.Empty<string>());
                continue;
            }

            row.ConfigPath = config.FilePath;
            var text = BepInExConfig.ReadTextOrNull(config.FilePath);
            row.SetKeybinds(text is null
                ? Array.Empty<string>()
                : BepInExConfig.Parse(text).KeyboardShortcuts.Select(entry => $"{entry.Key}: {entry.RawValue}"));
        }
    }

    private async Task ToggleEnabledAsync(InstalledModRowViewModel row)
    {
        var gameDir = _services.LocateGameDir();
        if (gameDir is null)
        {
            return;
        }
        try
        {
            await Task.Run(() => _services.ModManager.SetEnabled(row.FullName, row.Enabled, gameDir));
            await Task.Run(() => _services.ProfileStore.SyncActiveProfile());
            StatusMessage = $"{row.FullName} {(row.Enabled ? "enabled" : "disabled")}.";
            if (ModsChanged is not null)
            {
                await ModsChanged.Invoke();
            }
        }
        catch (Exception ex)
        {
            StatusMessage = $"Couldn't toggle {row.FullName}: {ex.Message}";
        }
    }

    [RelayCommand]
    private async Task UpdateAsync(InstalledModRowViewModel? row)
    {
        if (row is null)
        {
            return;
        }
        var gameDir = _services.LocateGameDir();
        if (gameDir is null)
        {
            return;
        }
        IsBusy = true;
        try
        {
            StatusMessage = $"Updating {row.FullName}...";
            await Task.Run(() => _services.ModManager.UpdateAsync(row.FullName, _index, gameDir));
            StatusMessage = $"Updated {row.FullName}.";
            await RefreshAsync();
            if (ModsChanged is not null)
            {
                await ModsChanged.Invoke();
            }
        }
        catch (Exception ex)
        {
            StatusMessage = $"Update failed: {ex.Message}";
        }
        finally
        {
            IsBusy = false;
        }
    }

    [RelayCommand]
    private async Task RemoveAsync(InstalledModRowViewModel? row)
    {
        if (row is null)
        {
            return;
        }
        var gameDir = _services.LocateGameDir();
        if (gameDir is null)
        {
            return;
        }
        IsBusy = true;
        try
        {
            await Task.Run(() => _services.ModManager.Uninstall(row.FullName, gameDir));
            await Task.Run(() => _services.ProfileStore.SyncActiveProfile());
            StatusMessage = $"Removed {row.FullName}.";
            await RefreshAsync();
            if (ModsChanged is not null)
            {
                await ModsChanged.Invoke();
            }
        }
        catch (Exception ex)
        {
            StatusMessage = $"Couldn't remove {row.FullName}: {ex.Message}";
        }
        finally
        {
            IsBusy = false;
        }
    }

    // MARK: - Install from file

    /// <summary>
    /// Installs every dropped/picked .zip/.dll file in <paramref name="paths"/>,
    /// in order, then does the same manifest-refresh + profile-sync dance
    /// the other mutating actions (toggle/update/remove) already do. A name
    /// collision on any one file pauses that file (via the inline
    /// Replace/Skip overlay — see <see cref="IsConfirmingReplace"/>) without
    /// blocking the rest of the batch; any other failure is recorded and
    /// reported once at the end rather than aborting the remaining files.
    /// Called from the view's "Install from File…" file picker and from
    /// <c>MainWindow</c>'s whole-window drag-and-drop handler.
    /// </summary>
    public async Task InstallFilesAsync(IReadOnlyList<string> paths)
    {
        var gameDir = _services.LocateGameDir();
        if (gameDir is null)
        {
            StatusMessage = "Can't install from file — locate the game directory first";
            return;
        }
        if (paths.Count == 0)
        {
            return;
        }

        IsInstallingFromFile = true;
        try
        {
            var installedCount = 0;
            var skippedCount = 0;
            string? lastFailure = null;

            foreach (var path in paths)
            {
                try
                {
                    var installed = await InstallOneFileAsync(path, gameDir);
                    if (installed is not null)
                    {
                        installedCount++;
                    }
                    else
                    {
                        skippedCount++;
                    }
                }
                catch (Exception ex)
                {
                    lastFailure = $"{Path.GetFileName(path)}: {ex.Message}";
                }
            }

            await Task.Run(() => _services.ProfileStore.SyncActiveProfile());
            await RefreshAsync();
            if (ModsChanged is not null)
            {
                await ModsChanged.Invoke();
            }

            var summary = installedCount > 0 ? $"Installed {installedCount} mod{(installedCount == 1 ? "" : "s")} from file" : "";
            if (skippedCount > 0)
            {
                summary = summary.Length == 0 ? $"Skipped {skippedCount} file{(skippedCount == 1 ? "" : "s")}" : $"{summary}, skipped {skippedCount}";
            }
            if (lastFailure is not null)
            {
                summary = summary.Length == 0 ? $"Couldn't install: {lastFailure}" : $"{summary} — {lastFailure}";
            }
            if (summary.Length > 0)
            {
                StatusMessage = summary;
            }
        }
        finally
        {
            IsInstallingFromFile = false;
        }
    }

    /// <summary>
    /// Installs one file, handling a name collision by awaiting the user's
    /// replace/skip choice (<see cref="RequestReplaceConfirmationAsync"/>)
    /// and retrying with <c>replaceExisting: true</c> only if they chose
    /// Replace. Returns the installed full name, or null if the user chose
    /// to skip a collision (not an error — just nothing to count).
    /// </summary>
    private async Task<string?> InstallOneFileAsync(string path, string gameDir)
    {
        try
        {
            return await Task.Run(() => _services.ModManager.InstallFromFileAsync(path, gameDir));
        }
        catch (ModManager.NameCollisionException ex)
        {
            var replace = await RequestReplaceConfirmationAsync(ex.FullName);
            if (!replace)
            {
                return null;
            }
            return await Task.Run(() => _services.ModManager.InstallFromFileAsync(path, gameDir, replaceExisting: true));
        }
    }

    /// <summary>Suspends until the inline "already installed" overlay resolves (Replace -> true, Skip -> false).</summary>
    private Task<bool> RequestReplaceConfirmationAsync(string fullName)
    {
        _replaceConfirmTcs = new TaskCompletionSource<bool>();
        ReplaceConfirmFullName = fullName;
        IsConfirmingReplace = true;
        return _replaceConfirmTcs.Task;
    }

    [RelayCommand]
    private void ConfirmReplace()
    {
        IsConfirmingReplace = false;
        _replaceConfirmTcs?.TrySetResult(true);
    }

    [RelayCommand]
    private void SkipReplace()
    {
        IsConfirmingReplace = false;
        _replaceConfirmTcs?.TrySetResult(false);
    }

    // MARK: - Update All

    private bool CanUpdateAll() => !IsUpdatingAll && !IsBusy && UpdatableCount > 0;

    /// <summary>
    /// Runs every currently-known update sequentially via
    /// <see cref="UpdateAllRunner"/>, so one failing mod never blocks the
    /// rest of the batch. Refreshes the manifest/active profile once at the
    /// end rather than after each mod, and ends with a one-line summary
    /// (succeeded/failed counts, plus each failure's message) in
    /// <see cref="StatusMessage"/>.
    /// </summary>
    [RelayCommand(CanExecute = nameof(CanUpdateAll))]
    private async Task UpdateAllAsync()
    {
        var gameDir = _services.LocateGameDir();
        var updatable = Mods.Where(m => m.UpdateAvailable).Select(m => m.FullName).ToList();
        if (gameDir is null || updatable.Count == 0)
        {
            return;
        }

        IsUpdatingAll = true;
        try
        {
            var summary = await UpdateAllRunner.RunAsync(
                updatable,
                updater: fullName => Task.Run(() => _services.ModManager.UpdateAsync(fullName, _index, gameDir)),
                onProgress: fullName => UpdateAllProgressLine = $"Updating {fullName}…");

            await Task.Run(() => _services.ProfileStore.SyncActiveProfile());
            await RefreshAsync();

            var parts = new List<string>();
            if (summary.SucceededCount > 0)
            {
                parts.Add($"Updated {summary.SucceededCount} mod{(summary.SucceededCount == 1 ? "" : "s")}");
            }
            if (summary.FailedCount > 0)
            {
                var detail = string.Join("; ", summary.Failures.Select(f => $"{f.FullName}: {f.Message}"));
                parts.Add($"{summary.FailedCount} failed ({detail})");
            }
            StatusMessage = parts.Count == 0 ? "Nothing to update" : string.Join(", ", parts);

            if (ModsChanged is not null)
            {
                await ModsChanged.Invoke();
            }
        }
        finally
        {
            IsUpdatingAll = false;
            UpdateAllProgressLine = null;
        }
    }
}
