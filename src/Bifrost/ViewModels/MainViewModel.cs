using System.Collections.ObjectModel;
using Bifrost.Services;
using CommunityToolkit.Mvvm.ComponentModel;

namespace Bifrost.ViewModels;

/// <summary>
/// Root view model: owns the sidebar navigation and which of the four
/// tab pages (Home / Browse / Installed / Settings) is currently shown.
/// Mirrors the macOS app's Views/MainWindow.swift TabView.
/// </summary>
public partial class MainViewModel : ViewModelBase
{
    private readonly AppServices _services = new();

    public ObservableCollection<NavigationItem> NavigationItems { get; }

    [ObservableProperty]
    private NavigationItem _selectedItem;

    public MainViewModel()
    {
        var home = new HomeViewModel(_services);
        var browse = new BrowseViewModel(_services);
        var installed = new InstalledViewModel(_services);
        var settings = new SettingsViewModel(_services);

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

        _ = home.RefreshCommand.ExecuteAsync(null);
    }

    public ViewModelBase CurrentPage => SelectedItem.Page;

    partial void OnSelectedItemChanged(NavigationItem value)
    {
        OnPropertyChanged(nameof(CurrentPage));
    }
}
