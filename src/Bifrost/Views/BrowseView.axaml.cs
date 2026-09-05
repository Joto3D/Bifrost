using Avalonia.Controls;
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
}
