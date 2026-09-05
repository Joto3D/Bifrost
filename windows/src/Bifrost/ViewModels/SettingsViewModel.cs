using System.Collections.ObjectModel;
using Bifrost.Core.Services;
using Bifrost.Services;
using Bifrost.Theming;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace Bifrost.ViewModels;

/// <summary>
/// The Settings tab: detected paths, refresh index, open logs/app-data
/// folders, and the Appearance theme picker. Mirrors the macOS app's
/// SettingsView.swift.
/// </summary>
public partial class SettingsViewModel : ViewModelBase
{
    private readonly AppServices _services;

    [ObservableProperty] private string _steamRoot = "";
    [ObservableProperty] private string? _gameDir;
    [ObservableProperty] private string _appDataDir = "";
    [ObservableProperty] private string _statusMessage = "";
    [ObservableProperty] private bool _isBusy;

    /// <summary>Every selectable palette, for Settings' Appearance section — see <see cref="ThemePalette.All"/>.</summary>
    public ObservableCollection<PaletteRowViewModel> Palettes { get; } = new();

    public SettingsViewModel(AppServices services)
    {
        _services = services;
        Refresh();

        foreach (var palette in ThemePalette.All)
        {
            Palettes.Add(new PaletteRowViewModel(palette, palette.Id == ThemeStore.Instance.Current.Id));
        }
    }

    [RelayCommand]
    private void SelectPalette(PaletteRowViewModel? row)
    {
        if (row is null)
        {
            return;
        }
        ThemeStore.Instance.Current = row.Palette;
        foreach (var candidate in Palettes)
        {
            candidate.IsSelected = candidate.Palette.Id == row.Palette.Id;
        }
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
