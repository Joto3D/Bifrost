using System.Collections.ObjectModel;
using System.Text.RegularExpressions;
using Bifrost.Core.Models;
using Bifrost.Core.Services;
using Bifrost.Services;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace Bifrost.ViewModels;

public enum ReadmeLoadState { Idle, Loading, Loaded, Failed }

/// <summary>
/// Package detail dialog opened from a Browse row: description/stats, the
/// associated config (if the mod is installed and one was found) with its
/// keybind chips and a direct "Edit Config" launch, and an on-demand
/// Thunderstore README fetch rendered as lightly-stripped plain text (no
/// Markdown renderer in Avalonia — this is deliberately simple, per the
/// porting brief). Mirrors the config/keybinds/README sections of the
/// macOS app's ModDetailView.swift.
/// </summary>
public sealed partial class PackageDetailViewModel : ViewModelBase
{
    private readonly AppServices _services;

    public ThunderstorePackage Package { get; }

    public string Name => Package.Name;
    public string Owner => Package.Owner;
    public string Description => Package.LatestVersion?.Description ?? "";
    public bool HasDescription => Description.Length > 0;
    public string LatestVersion => Package.LatestVersion?.VersionNumber ?? "?";
    public string PackageUrl => Package.PackageUrl;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasConfig))]
    private string? _associatedConfigPath;
    public bool HasConfig => AssociatedConfigPath is not null;

    public ObservableCollection<string> Keybinds { get; } = new();

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsReadmeIdle))]
    [NotifyPropertyChangedFor(nameof(IsReadmeLoading))]
    [NotifyPropertyChangedFor(nameof(IsReadmeLoaded))]
    [NotifyPropertyChangedFor(nameof(IsReadmeFailed))]
    private ReadmeLoadState _readmeState = ReadmeLoadState.Idle;
    public bool IsReadmeIdle => ReadmeState == ReadmeLoadState.Idle;
    public bool IsReadmeLoading => ReadmeState == ReadmeLoadState.Loading;
    public bool IsReadmeLoaded => ReadmeState == ReadmeLoadState.Loaded;
    public bool IsReadmeFailed => ReadmeState == ReadmeLoadState.Failed;

    [ObservableProperty] private string _readmeText = "";
    [ObservableProperty] private string _readmeError = "";

    /// <summary>Raised when the user clicks "Edit Config" — the view owns opening the actual editor window.</summary>
    public event Action<string>? EditConfigRequested;

    public PackageDetailViewModel(ThunderstorePackage package, AppServices services)
    {
        Package = package;
        _services = services;
        LoadConfigAssociation();
    }

    /// <summary>
    /// Finds this mod's associated <c>.cfg</c> file (if installed and one
    /// matches — see <see cref="BepInExConfig.Associate"/>) and parses its
    /// <c>KeyboardShortcut</c> entries for the summary chips above.
    /// </summary>
    private void LoadConfigAssociation()
    {
        var gameDir = _services.LocateGameDir();
        var manifest = _services.ModManager.LoadManifest();
        Keybinds.Clear();

        if (gameDir is null || !manifest.Mods.Any(m => m.FullName == Package.FullName))
        {
            AssociatedConfigPath = null;
            return;
        }

        var configDir = Path.Combine(gameDir, "BepInEx", "config");
        var path = BepInExConfig.FindAssociatedConfig(configDir, Package.FullName, Package.Name);
        AssociatedConfigPath = path;
        if (path is null)
        {
            return;
        }

        var text = BepInExConfig.ReadTextOrNull(path);
        if (text is null)
        {
            return;
        }
        foreach (var entry in BepInExConfig.Parse(text).KeyboardShortcuts)
        {
            Keybinds.Add($"{entry.Key}: {entry.RawValue}");
        }
    }

    [RelayCommand]
    private void EditConfig()
    {
        if (AssociatedConfigPath is not null)
        {
            EditConfigRequested?.Invoke(AssociatedConfigPath);
        }
    }

    [RelayCommand]
    private async Task LoadReadmeAsync()
    {
        var version = Package.LatestVersion;
        if (version is null)
        {
            ReadmeError = "No published version";
            ReadmeState = ReadmeLoadState.Failed;
            return;
        }

        ReadmeState = ReadmeLoadState.Loading;
        try
        {
            var markdown = await _services.ThunderstoreClient.FetchReadmeAsync(Package.Owner, Package.Name, version.VersionNumber);
            ReadmeText = StripMarkdown(markdown);
            ReadmeState = ReadmeLoadState.Loaded;
        }
        catch (Exception ex)
        {
            ReadmeError = ex.Message;
            ReadmeState = ReadmeLoadState.Failed;
        }
    }

    /// <summary>
    /// A small Markdown-to-plain-text pass: strips heading markers,
    /// emphasis, inline code, and link syntax (keeping the link text plus
    /// its target in parentheses), and turns "-"/"*" bullets into "•".
    /// Avalonia has no built-in Markdown renderer, and the brief calls for
    /// "plain text with basic markdown stripping" rather than a full one.
    /// </summary>
    private static string StripMarkdown(string markdown)
    {
        var lines = markdown.Replace("\r\n", "\n").Split('\n');
        var result = new List<string>(lines.Length);
        foreach (var rawLine in lines)
        {
            var line = rawLine;
            line = Regex.Replace(line, @"^\s{0,3}#{1,6}\s*", "");
            line = Regex.Replace(line, @"\*\*(.+?)\*\*", "$1");
            line = Regex.Replace(line, @"__(.+?)__", "$1");
            line = Regex.Replace(line, @"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)", "$1");
            line = Regex.Replace(line, @"`([^`]+?)`", "$1");
            line = Regex.Replace(line, @"\[(.+?)\]\((.+?)\)", "$1 ($2)");
            line = Regex.Replace(line, @"^\s*[-*]\s+", "• ");
            result.Add(line);
        }
        return string.Join("\n", result);
    }
}
