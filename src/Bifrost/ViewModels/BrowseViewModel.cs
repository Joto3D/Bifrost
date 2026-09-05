using System.Collections.ObjectModel;
using Bifrost.Core.Models;
using Bifrost.Core.Services;
using Bifrost.Services;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace Bifrost.ViewModels;

public enum BrowseSortOrder { Rating, Downloads, Updated, Name }

/// <summary>
/// The Browse tab: searchable Thunderstore package list with sort, an
/// Install flow with a dependency-resolution confirmation step. Mirrors the
/// macOS app's ModBrowserView.swift + ModDetailView.swift.
/// </summary>
public partial class BrowseViewModel : ViewModelBase
{
    private readonly AppServices _services;
    private List<ThunderstorePackage> _index = new();

    /// <summary>Exposed so the view can construct the package-detail dialog against the same service instances.</summary>
    public AppServices Services => _services;

    /// <summary>Raised after an install completes, so other tabs can refresh.</summary>
    public event Func<Task>? ModsChanged;

    [ObservableProperty] private string _searchText = "";
    [ObservableProperty] private BrowseSortOrder _sortOrder = BrowseSortOrder.Rating;
    [ObservableProperty] private bool _isLoading;
    [ObservableProperty] private string _statusMessage = "";

    public ObservableCollection<PackageRowViewModel> Packages { get; } = new();

    // Pending-install confirmation state (populated when a resolve() plan
    // pulls in more than just the package the user clicked Install on).
    [ObservableProperty] private PackageRowViewModel? _pendingInstall;
    [ObservableProperty] private string _pendingInstallSummary = "";
    [ObservableProperty] private bool _isConfirmingInstall;
    private List<ModManager.ResolvedInstall> _pendingPlan = new();

    public static IReadOnlyList<BrowseSortOrder> SortOrders { get; } = Enum.GetValues<BrowseSortOrder>();

    public BrowseViewModel(AppServices services)
    {
        _services = services;
    }

    [RelayCommand]
    public async Task LoadAsync(bool force = false)
    {
        IsLoading = true;
        StatusMessage = "Loading Thunderstore index...";
        try
        {
            _index = await _services.ThunderstoreClient.FetchIndexAsync(force);
            ApplyFilter();
            StatusMessage = $"{_index.Count} packages loaded.";
        }
        catch (Exception ex)
        {
            StatusMessage = $"Couldn't load the Thunderstore index: {ex.Message}";
        }
        finally
        {
            IsLoading = false;
        }
    }

    partial void OnSearchTextChanged(string value) => ApplyFilter();
    partial void OnSortOrderChanged(BrowseSortOrder value) => ApplyFilter();

    private void ApplyFilter()
    {
        var manifest = _services.ModManager.LoadManifest();
        var installedNames = new HashSet<string>(manifest.Mods.Select(m => m.FullName));

        IEnumerable<ThunderstorePackage> query = _index;
        if (!string.IsNullOrWhiteSpace(SearchText))
        {
            var needle = SearchText.Trim();
            query = query.Where(p =>
                p.Name.Contains(needle, StringComparison.OrdinalIgnoreCase) ||
                p.Owner.Contains(needle, StringComparison.OrdinalIgnoreCase) ||
                (p.LatestVersion?.Description.Contains(needle, StringComparison.OrdinalIgnoreCase) ?? false));
        }

        query = SortOrder switch
        {
            BrowseSortOrder.Rating => query.OrderByDescending(p => p.RatingScore),
            BrowseSortOrder.Downloads => query.OrderByDescending(p => p.TotalDownloads),
            BrowseSortOrder.Updated => query.OrderByDescending(p => p.DateUpdated),
            BrowseSortOrder.Name => query.OrderBy(p => p.Name, StringComparer.OrdinalIgnoreCase),
            _ => query,
        };

        Packages.Clear();
        foreach (var package in query.Take(300))
        {
            Packages.Add(new PackageRowViewModel(package, installedNames.Contains(package.FullName)));
        }
    }

    [RelayCommand]
    private async Task InstallAsync(PackageRowViewModel? row)
    {
        if (row is null)
        {
            return;
        }

        var gameDir = _services.LocateGameDir();
        if (gameDir is null)
        {
            StatusMessage = "Valheim wasn't found — check Settings.";
            return;
        }

        try
        {
            var plan = await _services.ModManager.ResolveAsync(row.Package, _index);
            if (plan.Count == 0)
            {
                StatusMessage = $"{row.Name} is already up to date.";
                return;
            }

            if (plan.Count == 1 && plan[0] is ModManager.ResolvedInstall.Mod)
            {
                await RunInstallAsync(gameDir, plan);
                return;
            }

            // More than just the mod itself (the loader and/or
            // dependencies) — ask for confirmation before touching disk.
            _pendingPlan = plan;
            PendingInstall = row;
            PendingInstallSummary = "This will also install:\n" + string.Join("\n", plan.Select(DescribeResolved));
            IsConfirmingInstall = true;
        }
        catch (Exception ex)
        {
            StatusMessage = $"Couldn't resolve {row.Name}: {ex.Message}";
        }
    }

    [RelayCommand]
    private async Task ConfirmInstallAsync()
    {
        var gameDir = _services.LocateGameDir();
        if (gameDir is null || _pendingPlan.Count == 0)
        {
            CancelInstall();
            return;
        }
        await RunInstallAsync(gameDir, _pendingPlan);
        CancelInstall();
    }

    [RelayCommand]
    private void CancelInstall()
    {
        IsConfirmingInstall = false;
        PendingInstall = null;
        PendingInstallSummary = "";
        _pendingPlan = new List<ModManager.ResolvedInstall>();
    }

    private async Task RunInstallAsync(string gameDir, List<ModManager.ResolvedInstall> plan)
    {
        IsLoading = true;
        try
        {
            StatusMessage = "Installing...";
            await Task.Run(() => _services.ModManager.InstallResolvedAsync(plan, gameDir,
                p => StatusMessage = $"{p.Stage}: {p.FullName}"));
            StatusMessage = "Install complete.";
            ApplyFilter();
            await Task.Run(() => _services.ProfileStore.SyncActiveProfile());
            if (ModsChanged is not null)
            {
                await ModsChanged.Invoke();
            }
        }
        catch (Exception ex)
        {
            StatusMessage = $"Install failed: {ex.Message}";
        }
        finally
        {
            IsLoading = false;
        }
    }

    private static string DescribeResolved(ModManager.ResolvedInstall item) => item switch
    {
        ModManager.ResolvedInstall.Loader => "denikson-BepInExPack_Valheim (loader)",
        ModManager.ResolvedInstall.Mod m => $"{m.FullName} @ {m.Version.VersionNumber}",
        _ => item.GetFullName(),
    };
}
