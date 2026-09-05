using System.Collections.ObjectModel;
using Bifrost.Core.Models;
using CommunityToolkit.Mvvm.ComponentModel;

namespace Bifrost.ViewModels;

/// <summary>One row of the Installed tab, wrapping an <see cref="InstalledManifest.InstalledMod"/>.</summary>
public partial class InstalledModRowViewModel : ObservableObject
{
    public InstalledManifest.InstalledMod Mod { get; }

    public InstalledModRowViewModel(InstalledManifest.InstalledMod mod, string? latestVersion)
    {
        Mod = mod;
        LatestVersion = latestVersion;
        _enabled = mod.Enabled;
    }

    public string FullName => Mod.FullName;
    public string InstalledVersion => Mod.Version;

    [ObservableProperty]
    private string? _latestVersion;

    public bool UpdateAvailable => LatestVersion is not null && LatestVersion != InstalledVersion;

    [ObservableProperty]
    private bool _enabled = true;

    /// <summary>This mod's associated <c>.cfg</c> file (see <c>BepInExConfig.Associate</c>), if one was found — populated by <c>InstalledViewModel.RefreshAsync</c>.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasConfig))]
    private string? _configPath;
    public bool HasConfig => ConfigPath is not null;

    /// <summary>This mod's <c>KeyboardShortcut</c> entries from its associated config, as "Key: Value" chips.</summary>
    public ObservableCollection<string> Keybinds { get; } = new();
    public bool HasKeybinds => Keybinds.Count > 0;

    partial void OnLatestVersionChanged(string? value) => OnPropertyChanged(nameof(UpdateAvailable));

    public void SetKeybinds(IEnumerable<string> keybinds)
    {
        Keybinds.Clear();
        foreach (var keybind in keybinds)
        {
            Keybinds.Add(keybind);
        }
        OnPropertyChanged(nameof(HasKeybinds));
    }
}
