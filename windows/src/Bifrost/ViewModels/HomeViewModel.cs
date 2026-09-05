using System.Collections.ObjectModel;
using Avalonia.Threading;
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

    /// <summary>Exposed so the view's code-behind can open the guided "Join a Server" window against the same service instances.</summary>
    public AppServices Services => _services;

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

    partial void OnSelectedProfileChanged(Profile? value) => IsOnGuestProfile = value?.IsGuestProfile == true;

    /// <summary>
    /// Whether the active profile is a temporary "join a server" profile
    /// (see <see cref="Profile.IsServerGuest"/>, set by the guided
    /// <c>ServerJoinWindow</c> flow) — drives the "Back to my profile" hint.
    /// </summary>
    [ObservableProperty] private bool _isOnGuestProfile;

    /// <summary>
    /// Whichever profile was active right before the guided "join a server"
    /// flow's last successful apply switched away from it (if any) —
    /// session-only, set via <see cref="NotePriorProfileBeforeGuest"/> from
    /// the flow's completion callback. A relaunch while a guest profile is
    /// active just falls back to the first non-guest profile instead (see
    /// <see cref="ProfileToReturnTo"/>).
    /// </summary>
    private Guid? _priorProfileIdBeforeGuest;

    public void NotePriorProfileBeforeGuest(Guid? profileId) => _priorProfileIdBeforeGuest = profileId;

    private Guid? ProfileToReturnTo()
    {
        if (_priorProfileIdBeforeGuest is { } id && Profiles.Any(p => p.Id == id))
        {
            return id;
        }
        return Profiles.FirstOrDefault(p => !p.IsGuestProfile)?.Id;
    }

    /// <summary>"Back to my profile" hint's action — switches straight back without the usual switch-preview confirmation, mirroring the macOS app's one-click hint.</summary>
    [RelayCommand]
    private async Task BackToMyProfileAsync()
    {
        var targetId = ProfileToReturnTo();
        if (targetId is null || GameDir is null)
        {
            return;
        }
        IsBusy = true;
        try
        {
            var result = await Task.Run(() => _services.ProfileStore.Apply(targetId.Value, GameDir));
            await RefreshAsync();
            StatusMessage = result.Missing.Count == 0
                ? "Switched back to your profile."
                : $"Switched back — {result.Missing.Count} mod(s) not installed yet: {string.Join(", ", result.Missing)}";
        }
        catch (Exception ex)
        {
            StatusMessage = $"Couldn't switch profile: {ex.Message}";
        }
        finally
        {
            IsBusy = false;
        }
    }

    // MARK: - Fun round: runestone tips, saga stats, launch flavor, celebration

    [ObservableProperty] private int _runestoneTipIndex;

    public RunestoneTips.Tip CurrentTip => RunestoneTips.All[RunestoneTipIndex];
    public string RunestoneCategoryLabel => CurrentTip.IsLore ? "RUNESTONE LORE" : "RUNESTONE TIP";

    partial void OnRunestoneTipIndexChanged(int value)
    {
        OnPropertyChanged(nameof(CurrentTip));
        OnPropertyChanged(nameof(RunestoneCategoryLabel));
    }

    [RelayCommand]
    private void NextRunestoneTip() => RunestoneTipIndex = RunestoneTips.NextIndex(RunestoneTipIndex);

    /// <summary>Top 3 "Saga" flavor lines (see <see cref="SagaStats.FlavorLines"/>) — rebuilt by <see cref="RefreshSagaStatsAsync"/> whenever <see cref="RefreshAsync"/> runs, so it reflects mod/backup/save changes without a separate manual refresh.</summary>
    public ObservableCollection<string> SagaLines { get; } = new();
    public bool HasSagaLines => SagaLines.Count > 0;

    private async Task RefreshSagaStatsAsync()
    {
        var manifest = _services.ModManager.LoadManifest();
        List<ThunderstorePackage> index;
        try { index = await _services.ThunderstoreClient.FetchIndexAsync(force: false); }
        catch { index = new List<ThunderstorePackage>(); }

        var backups = await Task.Run(() => _services.SaveBackup.List());

        string? localConfigText = null;
        var localConfigPath = SagaStats.FindMostRecentLocalConfig(_services.GameLocator.SteamRoot);
        if (localConfigPath is not null)
        {
            try { localConfigText = await Task.Run(() => File.ReadAllText(localConfigPath)); }
            catch { /* best effort */ }
        }

        var snapshot = SagaStats.BuildSnapshot(manifest, index, backups, BifrostPaths.ValheimSaveDir, localConfigText);
        SagaLines.Clear();
        foreach (var line in SagaStats.FlavorLines(snapshot).Take(3))
        {
            SagaLines.Add(line);
        }
        OnPropertyChanged(nameof(HasSagaLines));
    }

    /// <summary>Decorative caption shown alongside the real launch status line while a launch is in progress — see <see cref="Flavor"/>. Set once per launch so it doesn't flicker between quips as phases change.</summary>
    [ObservableProperty] private string? _launchFlavorQuip;

    [ObservableProperty] private bool _isLaunching;

    /// <summary>Incremented once each time a modded launch's diagnostics confirm plugins loaded — drives <see cref="CelebrationVisible"/>'s one-time pulse. See <see cref="PlayCelebrationAsync"/>.</summary>
    [ObservableProperty] private int _celebrationPulse;

    partial void OnCelebrationPulseChanged(int value) => _ = PlayCelebrationAsync();

    [ObservableProperty] private bool _celebrationVisible;

    /// <summary>0 or a soft 0.22 — bound directly (rather than <see cref="CelebrationVisible"/>'s IsVisible) so the view's Opacity transition actually animates instead of the element just disappearing instantly on an IsVisible flip.</summary>
    public double CelebrationOpacity => CelebrationVisible ? 0.22 : 0.0;

    partial void OnCelebrationVisibleChanged(bool value) => OnPropertyChanged(nameof(CelebrationOpacity));

    /// <summary>
    /// A short, self-resetting visibility pulse for the Play section's
    /// celebration overlay — respects Windows' reduced-motion setting (see
    /// <see cref="WindowsAccessibility.AnimationsEnabled"/>) by not playing
    /// at all when it's off, mirroring the macOS app's
    /// <c>AuroraCelebration</c> guard.
    /// </summary>
    private async Task PlayCelebrationAsync()
    {
        if (!WindowsAccessibility.AnimationsEnabled())
        {
            return;
        }
        CelebrationVisible = false;
        CelebrationVisible = true;
        await Task.Delay(TimeSpan.FromSeconds(1.5));
        CelebrationVisible = false;
    }

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
        _runestoneTipIndex = RunestoneTips.RandomIndex();
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
            await RefreshSagaStatsAsync();
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
        IsLaunching = true;
        // Purely decorative, alongside (never replacing) StatusMessage —
        // one seed per launch so the caption doesn't flicker between quips
        // as phases change (see Flavor.Quip).
        LaunchFlavorQuip = Flavor.Quip((int)DateTimeOffset.UtcNow.ToUnixTimeSeconds());
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

            if (modded)
            {
                WatchModdedLaunchDiagnostics(GameDir);
            }
        }
        catch (Exception ex)
        {
            StatusMessage = $"Couldn't launch: {ex.Message}";
        }
        finally
        {
            IsLaunching = false;
        }
    }

    /// <summary>
    /// Fire-and-forget: watches BepInEx's log for up to 90s for a
    /// "plugins loaded" diagnosis (see <see cref="Diagnostics"/>) and
    /// updates <see cref="StatusMessage"/> with it, pulsing
    /// <see cref="CelebrationPulse"/> when it lands. Deliberately detached
    /// from <see cref="PlayAsync"/>'s own lifetime/<see cref="IsLaunching"/>
    /// — the launch itself is done once Steam has the process, the
    /// diagnosis is a separate, much longer-running background watch.
    /// Runs off the UI thread (<see cref="Diagnostics.WatchAsync"/> polls a
    /// file once a second), so every property update is marshaled back via
    /// <see cref="Dispatcher.UIThread"/>.
    /// </summary>
    private void WatchModdedLaunchDiagnostics(string gameDir)
    {
        _ = Task.Run(async () =>
        {
            var diagnosis = await Diagnostics.WatchAsync(gameDir, modded: true);
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                StatusMessage = diagnosis.Summary;
                if (diagnosis is Diagnostics.LaunchDiagnosis.ModsLoaded)
                {
                    CelebrationPulse++;
                }
            });
        });
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
