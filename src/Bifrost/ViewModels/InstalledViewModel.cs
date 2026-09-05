using System.Collections.ObjectModel;
using Bifrost.Core.Models;
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

    public InstalledViewModel(AppServices services)
    {
        _services = services;
    }

    [RelayCommand]
    public async Task RefreshAsync()
    {
        IsBusy = true;
        try
        {
            var manifest = _services.ModManager.LoadManifest();
            LoaderVersion = manifest.Loader?.Version;

            // Best-effort: pull the index (cached is fine) so update
            // availability can be shown; missing/stale index just means we
            // show no "update available" badges.
            try { _index = await _services.ThunderstoreClient.FetchIndexAsync(force: false); }
            catch { _index = new List<ThunderstorePackage>(); }

            var byFullName = _index.ToDictionary(p => p.FullName);
            Mods.Clear();
            foreach (var mod in manifest.Mods.OrderBy(m => m.FullName, StringComparer.OrdinalIgnoreCase))
            {
                var latest = byFullName.TryGetValue(mod.FullName, out var pkg) ? pkg.LatestVersion?.VersionNumber : null;
                var row = new InstalledModRowViewModel(mod, latest);
                row.PropertyChanged += async (_, e) =>
                {
                    if (e.PropertyName == nameof(InstalledModRowViewModel.Enabled))
                    {
                        await ToggleEnabledAsync(row);
                    }
                };
                Mods.Add(row);
            }
            StatusMessage = $"{Mods.Count} mod(s) installed.";
        }
        finally
        {
            IsBusy = false;
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
}
