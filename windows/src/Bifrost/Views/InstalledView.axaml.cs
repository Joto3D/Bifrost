using Avalonia.Controls;
using Avalonia.Interactivity;
using Bifrost.ViewModels;

namespace Bifrost.Views;

public partial class InstalledView : UserControl
{
    public InstalledView()
    {
        InitializeComponent();
        DataContextChanged += (_, _) =>
        {
            if (DataContext is InstalledViewModel vm)
            {
                _ = vm.RefreshCommand.ExecuteAsync(null);
            }
        };
    }

    private void OnManageProfilesClick(object? sender, RoutedEventArgs e)
    {
        if (DataContext is not InstalledViewModel vm)
        {
            return;
        }

        var window = new ProfilesWindow
        {
            DataContext = new ProfilesViewModel(vm.Services),
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

    private void OnManageConfigsClick(object? sender, RoutedEventArgs e)
    {
        if (DataContext is not InstalledViewModel vm)
        {
            return;
        }

        var window = new ConfigsListWindow
        {
            DataContext = new ConfigsListViewModel(vm.Services),
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

    private void OnEditConfigClick(object? sender, RoutedEventArgs e)
    {
        if (sender is not Button { DataContext: InstalledModRowViewModel row } || row.ConfigPath is null)
        {
            return;
        }

        var window = new ConfigEditorWindow
        {
            DataContext = new ConfigEditorViewModel(row.ConfigPath, row.FullName),
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
