using Avalonia.Controls;
using Avalonia.Interactivity;
using Bifrost.ViewModels;

namespace Bifrost.Views;

public partial class BrowseView : UserControl
{
    public BrowseView()
    {
        InitializeComponent();
        DataContextChanged += (_, _) =>
        {
            if (DataContext is BrowseViewModel vm && vm.Packages.Count == 0)
            {
                _ = vm.LoadCommand.ExecuteAsync(false);
            }
        };
    }

    private void OnDetailsClick(object? sender, RoutedEventArgs e)
    {
        if (sender is not Button { DataContext: PackageRowViewModel row } || DataContext is not BrowseViewModel vm)
        {
            return;
        }

        ShowPackageDetail(row.Package, vm);
    }

    /// <summary>"Surprise Me" dice — rolls a random well-rated, not-yet-installed mod and opens it exactly as "Details…" would, whether or not it currently has a visible row.</summary>
    private void OnSurpriseMeClick(object? sender, RoutedEventArgs e)
    {
        if (DataContext is not BrowseViewModel vm)
        {
            return;
        }
        var pick = vm.RollSurpriseMe();
        if (pick is not null)
        {
            ShowPackageDetail(pick, vm);
        }
    }

    private void ShowPackageDetail(Bifrost.Core.Models.ThunderstorePackage package, BrowseViewModel vm)
    {
        var window = new PackageDetailWindow
        {
            DataContext = new PackageDetailViewModel(package, vm.Services),
        };

        var topLevel = TopLevel.GetTopLevel(this);
        if (topLevel is Window owner)
        {
            window.ShowDialog(owner);
        }
        else
        {
            window.Show();
        }
    }
}
