using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;

namespace Bifrost.ViewModels;

/// <summary>
/// Root view model: owns the sidebar navigation and which of the four
/// tab pages (Home / Browse / Installed / Settings) is currently shown.
/// Mirrors the macOS app's Views/MainWindow.swift TabView.
/// </summary>
public partial class MainViewModel : ViewModelBase
{
    public ObservableCollection<NavigationItem> NavigationItems { get; }

    [ObservableProperty]
    private NavigationItem _selectedItem;

    public MainViewModel()
    {
        NavigationItems = new ObservableCollection<NavigationItem>
        {
            new() { Title = "Home", Glyph = "Home", Page = new HomeViewModel() },
            new() { Title = "Browse", Glyph = "Browse", Page = new BrowseViewModel() },
            new() { Title = "Installed", Glyph = "Installed", Page = new InstalledViewModel() },
            new() { Title = "Settings", Glyph = "Settings", Page = new SettingsViewModel() },
        };

        _selectedItem = NavigationItems[0];
    }

    public ViewModelBase CurrentPage => SelectedItem.Page;

    partial void OnSelectedItemChanged(NavigationItem value)
    {
        OnPropertyChanged(nameof(CurrentPage));
    }
}
