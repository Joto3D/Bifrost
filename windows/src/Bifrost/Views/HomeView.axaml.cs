using Avalonia.Controls;
using Avalonia.Interactivity;
using Bifrost.ViewModels;

namespace Bifrost.Views;

public partial class HomeView : UserControl
{
    public HomeView()
    {
        InitializeComponent();
    }

    /// <summary>Opens the guided "Join a Server" window (see <see cref="ServerJoinViewModel"/>) against this tab's own service instances, wiring its completion back into the "Back to my profile" hint and its "Play Modded" button back into this tab's own launch action.</summary>
    private void OnJoinAServerClick(object? sender, RoutedEventArgs e)
    {
        if (DataContext is not HomeViewModel vm)
        {
            return;
        }

        var serverJoinVm = new ServerJoinViewModel(vm.Services)
        {
            OnApplied = previousProfileId => vm.NotePriorProfileBeforeGuest(previousProfileId),
            OnPlayModded = () => vm.PlayModdedCommand.Execute(null),
        };
        var window = new ServerJoinWindow { DataContext = serverJoinVm };

        window.Closed += async (_, _) => await vm.RefreshCommand.ExecuteAsync(null);

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
