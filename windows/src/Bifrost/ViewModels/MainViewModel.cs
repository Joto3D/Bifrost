using System.Collections.ObjectModel;
using Bifrost.Core.Models;
using Bifrost.Core.Services;
using Bifrost.Services;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace Bifrost.ViewModels;

/// <summary>
/// Root view model: owns the sidebar navigation and which of the four
/// tab pages (Home / Browse / Installed / Settings) is currently shown,
/// plus the couple of things that live above the tabs entirely — the
/// game-update banner (see <see cref="GameUpdateWatcher"/>) and the
/// startup background index refresh (see <see cref="IndexAutoRefresher"/>).
/// Mirrors the macOS app's Views/MainWindow.swift TabView plus the bits of
/// AppState it drives.
/// </summary>
public partial class MainViewModel : ViewModelBase
{
    private readonly AppServices _services = new();

    /// <summary>Exposed so <c>App.axaml.cs</c>'s tray icon can drive the same play/profile actions the Home tab uses, and so <c>MainWindow</c>'s drag-and-drop handler can reach the Installed tab directly.</summary>
    public AppServices Services => _services;

    public HomeViewModel Home { get; }
    public InstalledViewModel Installed { get; }

    public ObservableCollection<NavigationItem> NavigationItems { get; }

    [ObservableProperty]
    private NavigationItem _selectedItem;

    /// <summary>Result of the most recent Valheim build-change check, for the game-update banner. Populated once, on startup.</summary>
    [ObservableProperty]
    private GameUpdateWatcher.CheckResult? _gameUpdateCheck;

    [ObservableProperty]
    private bool _gameUpdateBannerDismissed;

    [ObservableProperty]
    private bool _isVerifyingBepInEx;

    [ObservableProperty]
    private string? _verifyBepInExStatusLine;

    public bool ShowGameUpdateBanner => GameUpdateCheck?.Kind == GameUpdateWatcher.ResultKind.Updated && !GameUpdateBannerDismissed;
    public string GameUpdateMessage => GameUpdateCheck?.Message ?? "";

    /// <summary>
    /// Drives a small non-blocking status banner while an <c>nxm://</c>
    /// install (see <see cref="HandleNexusLinkAsync"/>) is in flight — the
    /// Windows counterpart of the macOS app's <c>NexusInstallState</c>/the
    /// small in-window progress pill <c>MainWindow.swift</c> shows.
    /// </summary>
    [ObservableProperty]
    private bool _isInstallingFromNexus;

    [ObservableProperty]
    private string? _nexusInstallStatusLine;

    public MainViewModel()
    {
        var home = new HomeViewModel(_services);
        var browse = new BrowseViewModel(_services);
        var installed = new InstalledViewModel(_services);
        var settings = new SettingsViewModel(_services);
        Home = home;
        Installed = installed;

        // Installing or removing a mod from Browse/Installed should be
        // reflected everywhere else without the user having to switch tabs
        // back and forth.
        browse.ModsChanged += async () => { await installed.RefreshCommand.ExecuteAsync(null); await home.RefreshCommand.ExecuteAsync(null); };
        installed.ModsChanged += async () => { await home.RefreshCommand.ExecuteAsync(null); };

        NavigationItems = new ObservableCollection<NavigationItem>
        {
            new() { Title = "Home", Glyph = "Home", Page = home },
            new() { Title = "Browse", Glyph = "Browse", Page = browse },
            new() { Title = "Installed", Glyph = "Installed", Page = installed },
            new() { Title = "Settings", Glyph = "Settings", Page = settings },
        };

        _selectedItem = NavigationItems[0];

        _ = InitializeAsync();
    }

    public ViewModelBase CurrentPage => SelectedItem.Page;

    partial void OnSelectedItemChanged(NavigationItem value)
    {
        OnPropertyChanged(nameof(CurrentPage));
    }

    partial void OnGameUpdateCheckChanged(GameUpdateWatcher.CheckResult? value)
    {
        OnPropertyChanged(nameof(ShowGameUpdateBanner));
        OnPropertyChanged(nameof(GameUpdateMessage));
    }

    partial void OnGameUpdateBannerDismissedChanged(bool value) => OnPropertyChanged(nameof(ShowGameUpdateBanner));

    [RelayCommand]
    private void DismissGameUpdateBanner() => GameUpdateBannerDismissed = true;

    private async Task InitializeAsync()
    {
        await Home.RefreshCommand.ExecuteAsync(null);

        // Runs once per launch — the check itself persists the buildid it
        // reads, so a second call would just see that value back and report
        // "unchanged".
        var gameDir = _services.LocateGameDir();
        GameUpdateCheck = GameUpdateWatcher.Check(gameDir);

        // Quiet background refresh — never blocks startup, never shows a
        // modal; a stale/missing cache is refreshed silently.
        _ = IndexAutoRefresher.RefreshIfStaleAsync(_services.ThunderstoreClient);
    }

    /// <summary>
    /// The game-update banner's "Verify BepInEx" action: if the pack files
    /// are missing (e.g. after a Steam "verify integrity of game files"
    /// pass stripped them back out), repairs via a normal install — which
    /// never touches BepInEx/plugins or BepInEx/config, so the user's mods
    /// and settings survive.
    /// </summary>
    [RelayCommand]
    private async Task VerifyBepInExAsync()
    {
        var gameDir = _services.LocateGameDir();
        if (gameDir is null)
        {
            return;
        }
        IsVerifyingBepInEx = true;
        try
        {
            var status = BepInExInstaller.Status(gameDir);
            if (status.PackFilesPresent)
            {
                VerifyBepInExStatusLine = "BepInEx looks intact — nothing to repair.";
                return;
            }

            VerifyBepInExStatusLine = "Repairing BepInEx…";
            var outcome = await _services.BepInExInstaller.InstallAsync(gameDir, manifestVersion: _services.ModManager.LoaderVersion());
            _services.ModManager.SetLoaderVersion(outcome.VersionNumber);
            VerifyBepInExStatusLine = $"BepInEx repaired (version {outcome.VersionNumber}).";
            await Home.RefreshCommand.ExecuteAsync(null);
        }
        catch (Exception ex)
        {
            VerifyBepInExStatusLine = $"Couldn't repair BepInEx: {ex.Message}";
        }
        finally
        {
            IsVerifyingBepInEx = false;
        }
    }

    /// <summary>The game-update banner's "Check Mod Updates" action: switches to the Installed tab and forces a fresh update check there.</summary>
    [RelayCommand]
    private async Task CheckModUpdatesAsync()
    {
        var installedItem = NavigationItems.FirstOrDefault(n => ReferenceEquals(n.Page, Installed));
        if (installedItem is not null)
        {
            SelectedItem = installedItem;
        }
        await Installed.CheckForUpdatesAsync();
    }

    /// <summary>
    /// Handles an <c>nxm://</c> "Mod Manager Download" link — the sole
    /// caller is <c>App.axaml.cs</c>, either for this process's own initial
    /// launch argument or for one forwarded over the single-instance pipe
    /// from a second Bifrost.exe a later Nexus click spawned (see
    /// <see cref="SingleInstance"/>). Parses it, requires both a located
    /// game dir and a saved Nexus API key (surfacing a friendly status line
    /// and bailing out otherwise — no silent failures), fetches the mod's
    /// display metadata, resolves the CDN download link (passing the nxm
    /// link's own key/expires through for a free-account "Slow download"),
    /// and installs it via <see cref="ModManager.InstallFromNexusAsync"/>.
    /// Refreshes Home/Installed on success, same as every other install
    /// path. Mirrors the macOS app's <c>AppState.handleNexusLink</c>.
    /// </summary>
    public async Task HandleNexusLinkAsync(string rawUrl)
    {
        NxmLink link;
        try
        {
            link = NxmLink.Parse(rawUrl);
        }
        catch (Exception ex)
        {
            NexusInstallStatusLine = $"Nexus Mods link: {ex.Message}";
            return;
        }

        var gameDir = _services.LocateGameDir();
        if (gameDir is null)
        {
            NexusInstallStatusLine = "Locate the Valheim game folder (Settings) before installing from Nexus.";
            return;
        }
        var apiKey = WindowsCredentials.Read(WindowsCredentials.NexusApiKeyTarget);
        if (apiKey is null)
        {
            NexusInstallStatusLine = "Add your Nexus API key in Settings → Nexus Mods before installing from Nexus.";
            return;
        }

        IsInstallingFromNexus = true;
        NexusInstallStatusLine = "Fetching mod info…";
        try
        {
            var nexusClient = new NexusClient();
            var info = await nexusClient.ModInfoAsync(link.ModId, apiKey);

            NexusInstallStatusLine = $"Resolving download for {info.Name}…";
            var downloadUrl = await nexusClient.DownloadLinkAsync(link.ModId, link.FileId, apiKey, link.Key, link.Expires);

            NexusInstallStatusLine = $"Installing {info.Name}…";
            // Always replace rather than surfacing a collision dialog: the
            // derived identity ("<author>-<name>") is deterministic, so a
            // repeat nxm install of the same mod (e.g. clicking "Mod
            // Manager Download" again for a newer file) is unambiguously
            // meant to update it, not to prompt.
            await Task.Run(() => _services.ModManager.InstallFromNexusAsync(
                downloadUrl, gameDir, info.Author, info.Name, info.Version, link.ModId, link.FileId, replaceExisting: true));

            await Task.Run(() => _services.ProfileStore.SyncActiveProfile());
            await Home.RefreshCommand.ExecuteAsync(null);
            await Installed.RefreshAsync();
            NexusInstallStatusLine = $"Installed {info.Name} from Nexus Mods.";
        }
        catch (Exception ex)
        {
            NexusInstallStatusLine = $"Nexus install failed: {ex.Message}";
        }
        finally
        {
            IsInstallingFromNexus = false;
        }
    }

    [RelayCommand]
    private void DismissNexusInstallStatus() => NexusInstallStatusLine = null;
}
