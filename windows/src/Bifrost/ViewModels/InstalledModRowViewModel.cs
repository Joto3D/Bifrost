using System.Collections.ObjectModel;
using Avalonia.Media;
using Bifrost.Core.Models;
using Bifrost.Core.Services;
using CommunityToolkit.Mvvm.ComponentModel;

namespace Bifrost.ViewModels;

/// <summary>One row of the Installed tab, wrapping an <see cref="InstalledManifest.InstalledMod"/>.</summary>
public partial class InstalledModRowViewModel : ObservableObject
{
    public InstalledManifest.InstalledMod Mod { get; }

    /// <summary>This mod's multiplayer-safety classification (see <see cref="ModClassifier"/>) — informational only, drives the badge below and the guided "Join a Server" flow.</summary>
    public ModClassification Classification { get; }

    public InstalledModRowViewModel(InstalledManifest.InstalledMod mod, string? latestVersion, ModClassification classification)
    {
        Mod = mod;
        Classification = classification;
        LatestVersion = latestVersion;
        _enabled = mod.Enabled;
    }

    public string FullName => Mod.FullName;
    public string InstalledVersion => Mod.Version;

    /// <summary>"local" or "nexus" for a mod installed outside Thunderstore, null for an ordinary Thunderstore install — the row's source chip.</summary>
    public string? SourceChipText => Mod.Source is "local" or "nexus" ? Mod.Source : null;

    public string ClassBadgeGlyph => Classification.ModClass.Glyph();
    public string ClassBadgeLabel => Classification.ModClass.DisplayName();
    public string ClassBadgeTooltip => $"{Classification.ModClass.Explanation()} ({Classification.Basis})";

    private Color ClassColor => Classification.ModClass switch
    {
        ModClass.ClientOnly => Color.Parse("#2ECC71"),
        ModClass.AddsItems => Color.Parse("#F39C12"),
        ModClass.WorldAltering => Color.Parse("#E74C3C"),
        ModClass.ServerSynced => Color.Parse("#3498DB"),
        _ => Color.Parse("#909090"),
    };

    /// <summary>The badge's tinted-capsule background.</summary>
    public IBrush ClassBadgeBrush => new SolidColorBrush(ClassColor, 0.16);

    /// <summary>The badge's glyph/label text — full-strength version of the same color.</summary>
    public IBrush ClassBadgeTextBrush => new SolidColorBrush(ClassColor);

    /// <summary>This mod's Thunderstore icon URL, if the index has loaded and contains it — set by <c>InstalledViewModel.RefreshAsync</c>.</summary>
    [ObservableProperty]
    private string? _iconUrl;

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
