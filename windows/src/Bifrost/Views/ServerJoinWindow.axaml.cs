using Avalonia.Controls;
using Bifrost.ViewModels;

namespace Bifrost.Views;

public partial class ServerJoinWindow : Window
{
    public ServerJoinWindow()
    {
        InitializeComponent();
        DataContextChanged += (_, _) =>
        {
            if (DataContext is ServerJoinViewModel vm)
            {
                vm.RequestClose = Close;
            }
        };
    }
}
