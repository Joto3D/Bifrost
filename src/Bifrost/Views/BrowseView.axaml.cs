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

        var window = new PackageDetailWindow
        {
            DataContext = new PackageDetailViewModel(row.Package, vm.Services),
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
