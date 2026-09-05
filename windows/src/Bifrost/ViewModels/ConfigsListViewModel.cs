using System.Collections.ObjectModel;
using Bifrost.Core.Models;
using Bifrost.Core.Services;
using Bifrost.Services;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace Bifrost.ViewModels;

/// <summary>
/// Browses every <c>.cfg</c> file under <c>BepInEx/config</c>, grouped into
/// mod configs (heuristically associated via <see cref="BepInExConfig.Associate"/>)
/// and unmatched "Other configs". Selecting a row raises
/// <see cref="ConfigSelected"/> so the view can open the config editor.
/// Mirrors the macOS app's ConfigsListView.
/// </summary>
public sealed partial class ConfigsListViewModel : ViewModelBase
{
    private readonly AppServices _services;

    public ObservableCollection<ConfigRowViewModel> Matched { get; } = new();
    public ObservableCollection<ConfigRowViewModel> Unmatched { get; } = new();

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasNoConfigs))]
    private bool _isEmpty;
    public bool HasNoConfigs => IsEmpty;

    [ObservableProperty] private bool _hasMatched;
    [ObservableProperty] private bool _hasUnmatched;

    public event Action<ConfigRowViewModel>? ConfigSelected;

    public ConfigsListViewModel(AppServices services)
    {
        _services = services;
        _ = RefreshAsync();
    }

    [RelayCommand]
    public async Task RefreshAsync()
    {
        Matched.Clear();
        Unmatched.Clear();

        var gameDir = _services.LocateGameDir();
        if (gameDir is null)
        {
            IsEmpty = true;
            HasMatched = false;
            HasUnmatched = false;
            return;
        }

        List<ThunderstorePackage> index;
        try { index = await _services.ThunderstoreClient.FetchIndexAsync(force: false); }
        catch { index = new List<ThunderstorePackage>(); }
        var namesByFullName = index.ToDictionary(p => p.FullName, p => p.Name);

        var manifest = _services.ModManager.LoadManifest();
        var candidates = manifest.Mods
            .Select(m => (FullName: m.FullName, Name: namesByFullName.TryGetValue(m.FullName, out var name) ? name : ""))
            .ToList();

        var configDir = Path.Combine(gameDir, "BepInEx", "config");
        var configs = BepInExConfig.DiscoverConfigs(configDir, candidates);
        foreach (var config in configs)
        {
            var row = new ConfigRowViewModel(config);
            if (config.AssociatedFullName is not null)
            {
                Matched.Add(row);
            }
            else
            {
                Unmatched.Add(row);
            }
        }

        IsEmpty = configs.Count == 0;
        HasMatched = Matched.Count > 0;
        HasUnmatched = Unmatched.Count > 0;
    }

    [RelayCommand]
    private void Select(ConfigRowViewModel? row)
    {
        if (row is not null)
        {
            ConfigSelected?.Invoke(row);
        }
    }
}
