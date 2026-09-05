using System.Linq;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Bifrost.Services;
using Bifrost.Theming;
using Bifrost.ViewModels;
using Bifrost.Views;

namespace Bifrost;

public partial class App : Application
{
    private TrayIcon? _trayIcon;
    private NativeMenu? _trayMenu;
    private MainViewModel? _mainViewModel;
    private MainWindow? _mainWindow;
    private IClassicDesktopStyleApplicationLifetime? _desktop;
    private bool _isQuitting;

    public override void Initialize()
    {
        AvaloniaXamlLoader.Load(this);
    }

    public override void OnFrameworkInitializationCompleted()
    {
        // Apply the persisted (or default) palette before any window is
        // shown, and keep it in sync if the OS/Fluent theme variant itself
        // flips at runtime (light <-> dark) — the palette's card/sidebar
        // tint opacity and border color depend on which base variant is
        // active, see ThemeStore.Apply.
        ThemeStore.Instance.Apply(this);
        ActualThemeVariantChanged += (_, _) => ThemeStore.Instance.Apply(this);

        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            _desktop = desktop;
            _mainViewModel = new MainViewModel();
            _mainWindow = new MainWindow { DataContext = _mainViewModel };
            desktop.MainWindow = _mainWindow;

            SetUpTrayIcon(desktop, _mainViewModel, _mainWindow);
        }

        base.OnFrameworkInitializationCompleted();
    }

    // MARK: - Tray icon

    /// <summary>
    /// Sets up the Windows counterpart of the macOS app's menu-bar extra
    /// (<c>MenuBarContent.swift</c>): Play Modded/Vanilla, a profile-switch
    /// submenu, Open Bifrost, and Quit. The menu's items are rebuilt every
    /// time it's about to open (<see cref="NativeMenu.Opening"/>) rather
    /// than kept in sync incrementally, mirroring how the SwiftUI menu
    /// recomputes its content from <c>AppState</c> on every open.
    ///
    /// "Show tray icon" defaults to on (<see cref="Bifrost.Core.Models.AppSettings.ShowTrayIcon"/>)
    /// and toggling it live (see <c>SettingsViewModel</c>) both hides/shows
    /// the icon and switches whether closing the main window quits Bifrost
    /// or just hides it to the tray.
    /// </summary>
    private void SetUpTrayIcon(IClassicDesktopStyleApplicationLifetime desktop, MainViewModel mainViewModel, MainWindow mainWindow)
    {
        var services = mainViewModel.Services;

        _trayMenu = new NativeMenu();
        _trayMenu.Opening += (_, _) => RebuildTrayMenu(_trayMenu, mainViewModel, mainWindow, desktop);

        _trayIcon = new TrayIcon
        {
            Icon = mainWindow.Icon,
            ToolTipText = "Bifrost",
            Menu = _trayMenu,
            IsVisible = services.Settings.ShowTrayIcon,
        };
        _trayIcon.Clicked += (_, _) => ActivateMainWindow(mainWindow);

        TrayIcon.SetIcons(this, new TrayIcons { _trayIcon });

        desktop.ShutdownMode = services.Settings.ShowTrayIcon ? ShutdownMode.OnExplicitShutdown : ShutdownMode.OnMainWindowClose;

        // Closing the window hides it to the tray instead of quitting,
        // as long as the tray icon is actually on — otherwise (or when the
        // user picked Quit from the tray menu) the close proceeds normally.
        mainWindow.Closing += (_, e) =>
        {
            if (!_isQuitting && services.Settings.ShowTrayIcon)
            {
                e.Cancel = true;
                mainWindow.Hide();
            }
        };

        services.SettingsChanged += () =>
        {
            _trayIcon.IsVisible = services.Settings.ShowTrayIcon;
            desktop.ShutdownMode = services.Settings.ShowTrayIcon ? ShutdownMode.OnExplicitShutdown : ShutdownMode.OnMainWindowClose;
        };
    }

    private void RebuildTrayMenu(NativeMenu menu, MainViewModel mainViewModel, MainWindow mainWindow, IClassicDesktopStyleApplicationLifetime desktop)
    {
        menu.Items.Clear();
        var home = mainViewModel.Home;
        var services = mainViewModel.Services;

        var playModded = new NativeMenuItem("Play Modded") { IsEnabled = home.ReadyToPlay };
        playModded.Click += async (_, _) =>
        {
            if (home.ReadyToPlay)
            {
                await home.PlayModdedCommand.ExecuteAsync(null);
            }
        };
        menu.Items.Add(playModded);

        var playVanilla = new NativeMenuItem("Play Vanilla") { IsEnabled = home.ReadyToPlay };
        playVanilla.Click += async (_, _) =>
        {
            if (home.ReadyToPlay)
            {
                await home.PlayVanillaCommand.ExecuteAsync(null);
            }
        };
        menu.Items.Add(playVanilla);

        menu.Items.Add(new NativeMenuItemSeparator());

        var profileMenu = new NativeMenu();
        var profileItem = new NativeMenuItem("Profile") { Menu = profileMenu, IsEnabled = home.Profiles.Count > 0 && home.GameFound };
        if (home.Profiles.Count == 0)
        {
            profileMenu.Items.Add(new NativeMenuItem("No profiles yet") { IsEnabled = false });
        }
        else
        {
            foreach (var profile in home.Profiles.OrderBy(p => p.Name, StringComparer.OrdinalIgnoreCase))
            {
                var profileId = profile.Id;
                var item = new NativeMenuItem(profile.Name)
                {
                    ToggleType = MenuItemToggleType.CheckBox,
                    IsChecked = profile.Id == home.SelectedProfile?.Id,
                };
                item.Click += async (_, _) => await SwitchProfileAsync(profileId, mainViewModel, mainWindow);
                profileMenu.Items.Add(item);
            }
        }
        menu.Items.Add(profileItem);

        menu.Items.Add(new NativeMenuItemSeparator());

        var openItem = new NativeMenuItem("Open Bifrost");
        openItem.Click += (_, _) => ActivateMainWindow(mainWindow);
        menu.Items.Add(openItem);

        menu.Items.Add(new NativeMenuItemSeparator());

        var quitItem = new NativeMenuItem("Quit Bifrost");
        quitItem.Click += (_, _) =>
        {
            _isQuitting = true;
            desktop.TryShutdown(0);
        };
        menu.Items.Add(quitItem);
    }

    /// <summary>
    /// Applies <paramref name="profileId"/> via the same
    /// <see cref="Bifrost.Core.Services.ProfileStore.Apply"/> the Home tab
    /// uses. If it reports mods the profile wants that aren't installed
    /// yet, this never installs them on its own initiative from a
    /// background menu click — it raises the main window instead, so the
    /// user sees exactly what's missing through the normal Home tab flow
    /// before anything gets installed.
    /// </summary>
    private async Task SwitchProfileAsync(Guid profileId, MainViewModel mainViewModel, MainWindow mainWindow)
    {
        var services = mainViewModel.Services;
        var gameDir = services.LocateGameDir();
        if (gameDir is null)
        {
            ActivateMainWindow(mainWindow);
            return;
        }
        try
        {
            var result = await Task.Run(() => services.ProfileStore.Apply(profileId, gameDir));
            await mainViewModel.Home.RefreshCommand.ExecuteAsync(null);
            if (result.Missing.Count > 0)
            {
                ActivateMainWindow(mainWindow);
            }
        }
        catch
        {
            ActivateMainWindow(mainWindow);
        }
    }

    /// <summary>Brings Bifrost's main window to the front, reshowing it first if it had been hidden to the tray.</summary>
    private static void ActivateMainWindow(MainWindow window)
    {
        window.Show();
        window.WindowState = WindowState.Normal;
        window.Activate();
    }
}
