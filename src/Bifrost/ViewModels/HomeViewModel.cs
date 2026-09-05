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

    /// <summary>Whether BepInEx is currently being installed from the first-run banner (see <see cref="InstallBepInExAsync"/>) — separate from <see cref="IsBusy"/> so Play/Refresh stay disabled without also disabling the banner's own progress display.</summary>
    [ObservableProperty] private bool _isInstallingBepInEx;
    [ObservableProperty] private string? _bannerProgressLine;

    /// <summary>"Saves last backed up: …" caption shown under the Play buttons — see <see cref="AppServices.SaveBackup"/>.</summary>
    [ObservableProperty] private string _lastBackedUpCaption = "Saves last backed up: never";

    public ObservableCollection<Profile> Profiles { get; } = new();

    [ObservableProperty]
    private Profile? _selectedProfile;

    public bool ReadyToPlay => GameFound && BepInExInstalled;

    /// <summary>
    /// Friendly first-run guidance shown as a banner on Home whenever setup
    /// isn't finished yet — Valheim not found, or found but BepInEx isn't
    /// installed. Keeps things simple (two states, reusing the existing
    /// BepInExInstaller service) rather than a full wizard, per the
    /// distribution phase's "keep it simple" first-run requirement.
    /// </summary>
    public bool ShowSetupBanner => !GameFound || !BepInExInstalled;

    public string BannerTitle => !GameFound ? "Valheim wasn't found" : "BepInEx isn't installed yet";

    public string BannerMessage => !GameFound
        ? "Bifrost looks for Valheim through Steam's own library bookkeeping. Make sure Valheim is installed through Steam and has been launched at least once, then hit Refresh."
        : "Playing modded needs the BepInEx mod loader. This downloads it from Thunderstore and copies it next to Valheim — your saves and any existing plugins/config are never touched.";

    public string GameFoundSubtitle => GameFound ? "Located via Steam" : "Could not locate Valheim";
    public string BepInExSubtitle => BepInExInstalled ? "Mod loader present" : "Not installed";
    public string SteamSubtitle => SteamRunning ? "Running" : "Not running";

    public HomeViewModel(AppServices services)
    {
        _services = services;
    }

    partial void OnGameFoundChanged(bool value)
    {
        OnPropertyChanged(nameof(ReadyToPlay));
        OnPropertyChanged(nameof(ShowSetupBanner));
        OnPropertyChanged(nameof(BannerTitle));
        OnPropertyChanged(nameof(BannerMessage));
        OnPropertyChanged(nameof(GameFoundSubtitle));
    }

    partial void OnBepInExInstalledChanged(bool value)
    {
        OnPropertyChanged(nameof(ReadyToPlay));
        OnPropertyChanged(nameof(ShowSetupBanner));
        OnPropertyChanged(nameof(BannerTitle));
        OnPropertyChanged(nameof(BannerMessage));
        OnPropertyChanged(nameof(BepInExSubtitle));
    }

    partial void OnSteamRunningChanged(bool value) => OnPropertyChanged(nameof(SteamSubtitle));

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

            await RefreshLastBackedUpCaptionAsync();
        }
        finally
        {
            IsBusy = false;
        }
    }

    /// <summary>Recomputes <see cref="LastBackedUpCaption"/> from the newest backup on disk (any reason, manual or automatic).</summary>
    public async Task RefreshLastBackedUpCaptionAsync()
    {
        var last = await Task.Run(() => _services.SaveBackup.List().FirstOrDefault()?.Date);
        LastBackedUpCaption = last is { } date ? $"Saves last backed up: {FormatRelative(date)}" : "Saves last backed up: never";
    }

    private static string FormatRelative(DateTime date)
    {
        var span = DateTime.Now - date;
        if (span < TimeSpan.FromMinutes(1))
        {
            return "just now";
        }
        if (span < TimeSpan.FromHours(1))
        {
            var minutes = (int)span.TotalMinutes;
            return $"{minutes} minute{(minutes == 1 ? "" : "s")} ago";
        }
        if (span < TimeSpan.FromDays(1))
        {
            var hours = (int)span.TotalHours;
            return $"{hours} hour{(hours == 1 ? "" : "s")} ago";
        }
        var days = (int)span.TotalDays;
        return $"{days} day{(days == 1 ? "" : "s")} ago";
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
            await Launcher.PlayAsync(
                modded,
                GameDir,
                startSteamSilently: _services.Settings.StartSteamSilently,
                backupSavesBeforeModdedLaunch: _services.Settings.BackupSavesBeforeModdedLaunch,
                onPhase: phase => StatusMessage = Describe(phase));
            ModdedEnabled = modded;
            StatusMessage = $"Launched Steam ({(modded ? "modded" : "vanilla")}).";
            await RefreshLastBackedUpCaptionAsync();
        }
        catch (Exception ex)
        {
            StatusMessage = $"Couldn't launch: {ex.Message}";
        }
    }

    private static string Describe(Launcher.LaunchPhase phase) => phase switch
    {
        Launcher.LaunchPhase.BackingUpSaves => "Backing up saves…",
        Launcher.LaunchPhase.StartingSteam => "Starting Steam…",
        Launcher.LaunchPhase.WaitingForSteam => "Waiting for Steam to finish starting…",
        Launcher.LaunchPhase.Launching => "Launching…",
        _ => "Working…",
    };

    /// <summary>
    /// The first-run banner's "Install BepInEx" action — reuses
    /// <see cref="AppServices.BepInExInstaller"/> exactly the way a full
    /// setup wizard would, just without the wizard chrome.
    /// </summary>
    [RelayCommand]
    private async Task InstallBepInExAsync()
    {
        if (GameDir is null || IsInstallingBepInEx)
        {
            return;
        }
        IsInstallingBepInEx = true;
        BannerProgressLine = "Checking latest BepInEx version...";
        try
        {
            var outcome = await _services.BepInExInstaller.InstallAsync(
                GameDir,
                manifestVersion: _services.ModManager.LoaderVersion(),
                onProgress: p => BannerProgressLine = Describe(p));
            _services.ModManager.SetLoaderVersion(outcome.VersionNumber);
            BepInExInstalled = true;
            BannerProgressLine = null;
            StatusMessage = $"Installed BepInEx {outcome.VersionNumber}. Ready to play modded.";
        }
        catch (Exception ex)
        {
            BannerProgressLine = null;
            StatusMessage = $"Couldn't install BepInEx: {ex.Message}";
        }
        finally
        {
            IsInstallingBepInEx = false;
        }
    }

    private static string Describe(BepInExInstaller.Progress progress) => progress.Stage switch
    {
        BepInExInstaller.ProgressStage.FetchingVersionInfo => "Checking latest BepInEx version...",
        BepInExInstaller.ProgressStage.PackAlreadyUpToDate => $"BepInEx {progress.VersionNumber} already up to date",
        BepInExInstaller.ProgressStage.Downloading => $"Downloading BepInEx {progress.VersionNumber}...",
        BepInExInstaller.ProgressStage.Extracting => "Extracting...",
        BepInExInstaller.ProgressStage.CopyingFiles => "Copying files into place...",
        BepInExInstaller.ProgressStage.Done => $"Installed BepInEx {progress.VersionNumber}",
        _ => "Working...",
    };

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
