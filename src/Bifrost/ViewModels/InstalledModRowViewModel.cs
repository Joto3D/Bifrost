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

    partial void OnLatestVersionChanged(string? value) => OnPropertyChanged(nameof(UpdateAvailable));
}
