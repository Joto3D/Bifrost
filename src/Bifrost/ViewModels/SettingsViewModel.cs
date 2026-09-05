using Bifrost.Core.Services;
using Bifrost.Services;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace Bifrost.ViewModels;

/// <summary>
/// The Settings tab: detected paths, refresh index, open logs/app-data
/// folders. Mirrors the macOS app's SettingsView.swift.
/// </summary>
public partial class SettingsViewModel : ViewModelBase
{
    private readonly AppServices _services;

    [ObservableProperty] private string _steamRoot = "";
    [ObservableProperty] private string? _gameDir;
    [ObservableProperty] private string _appDataDir = "";
    [ObservableProperty] private string _statusMessage = "";
    [ObservableProperty] private bool _isBusy;

    public SettingsViewModel(AppServices services)
    {
        _services = services;
        Refresh();
    }

    private void Refresh()
    {
        SteamRoot = _services.GameLocator.SteamRoot;
        GameDir = _services.LocateGameDir();
        AppDataDir = BifrostPaths.AppDataDir;
    }

    [RelayCommand]
    private async Task RefreshIndexAsync()
    {
        IsBusy = true;
        try
        {
            var packages = await _services.ThunderstoreClient.FetchIndexAsync(force: true);
            StatusMessage = $"Refreshed — {packages.Count} packages.";
        }
        catch (Exception ex)
        {
            StatusMessage = $"Couldn't refresh: {ex.Message}";
        }
        finally
        {
            IsBusy = false;
        }
    }

    [RelayCommand]
    private void OpenLogsFolder()
    {
        if (GameDir is not null)
        {
            Launcher.OpenBepInExLog(GameDir);
        }
    }

    [RelayCommand]
    private void OpenPluginsFolder()
    {
        if (GameDir is not null)
        {
            Launcher.OpenPluginsFolder(GameDir);
        }
    }

    [RelayCommand]
    private void OpenAppDataFolder() => Launcher.OpenAppDataFolder();

    [RelayCommand]
    private void RefreshPaths() => Refresh();
}
