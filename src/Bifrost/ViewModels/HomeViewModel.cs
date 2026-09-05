using System.Collections.ObjectModel;
using Bifrost.Core.Models;
using Bifrost.Core.Services;
using Bifrost.Services;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace Bifrost.ViewModels;

/// <summary>
/// The Home tab: setup status (game found / BepInEx installed / doorstop
/// modded-vanilla state / Steam running), Play Modded / Play Vanilla, and
/// the active profile picker. Mirrors the macOS app's Home tab + StatusPanel.
/// </summary>
public partial class HomeViewModel : ViewModelBase
{
    private readonly AppServices _services;

    [ObservableProperty] private string? _gameDir;
    [ObservableProperty] private bool _gameFound;
    [ObservableProperty] private bool _bepInExInstalled;
    [ObservableProperty] private bool? _moddedEnabled;
    [ObservableProperty] private bool _steamRunning;
    [ObservableProperty] private bool _isBusy;
    [ObservableProperty] private string _statusMessage = "";

    public ObservableCollection<Profile> Profiles { get; } = new();

    [ObservableProperty]
    private Profile? _selectedProfile;

    public bool ReadyToPlay => GameFound && BepInExInstalled;

    public HomeViewModel(AppServices services)
    {
        _services = services;
    }

    partial void OnGameFoundChanged(bool value) => OnPropertyChanged(nameof(ReadyToPlay));
    partial void OnBepInExInstalledChanged(bool value) => OnPropertyChanged(nameof(ReadyToPlay));

    [RelayCommand]
    public async Task RefreshAsync()
    {
        IsBusy = true;
        try
        {
            var located = _services.GameLocator.Locate();
            GameDir = located?.Directory;
            GameFound = located is { IsValid: true };
            BepInExInstalled = GameDir is not null && GameLocator.BepInExInstalled(GameDir);
            ModdedEnabled = GameDir is not null ? Launcher.CurrentModdedEnabled(GameDir) : null;
            SteamRunning = GameLocator.SteamIsRunning();

            var profilesFile = await Task.Run(() => _services.ProfileStore.LoadOrMigrate());
            Profiles.Clear();
            foreach (var profile in profilesFile.Profiles)
            {
                Profiles.Add(profile);
            }
            SelectedProfile = Profiles.FirstOrDefault(p => p.Id == profilesFile.ActiveProfileId) ?? Profiles.FirstOrDefault();

            StatusMessage = GameFound
                ? (BepInExInstalled ? "Ready." : "Valheim found, but BepInEx isn't installed yet — install it from the Browse tab.")
                : "Valheim wasn't found through Steam. Check Settings for the detected Steam root.";
        }
        finally
        {
            IsBusy = false;
        }
    }

    [RelayCommand(CanExecute = nameof(CanPlay))]
    private async Task PlayModdedAsync() => await PlayAsync(modded: true);

    [RelayCommand(CanExecute = nameof(CanPlay))]
    private async Task PlayVanillaAsync() => await PlayAsync(modded: false);

    private bool CanPlay() => ReadyToPlay && !IsBusy;

    private async Task PlayAsync(bool modded)
    {
        if (GameDir is null)
        {
            return;
        }
        try
        {
            await Task.Run(() => Launcher.Play(modded, GameDir));
            ModdedEnabled = modded;
            StatusMessage = $"Launched Steam ({(modded ? "modded" : "vanilla")}).";
        }
        catch (Exception ex)
        {
            StatusMessage = $"Couldn't launch: {ex.Message}";
        }
    }

    [RelayCommand]
    private async Task ApplyProfileAsync()
    {
        if (SelectedProfile is null || GameDir is null)
        {
            return;
        }
        IsBusy = true;
        try
        {
            var result = await Task.Run(() => _services.ProfileStore.Apply(SelectedProfile.Id, GameDir));
            StatusMessage = result.Missing.Count == 0
                ? $"Applied profile \"{SelectedProfile.Name}\"."
                : $"Applied profile \"{SelectedProfile.Name}\" — {result.Missing.Count} mod(s) not installed yet: {string.Join(", ", result.Missing)}";
        }
        catch (Exception ex)
        {
            StatusMessage = $"Couldn't apply profile: {ex.Message}";
        }
        finally
        {
            IsBusy = false;
        }
    }
}
