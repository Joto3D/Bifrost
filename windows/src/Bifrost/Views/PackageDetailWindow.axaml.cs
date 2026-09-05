using Avalonia.Controls;
using Bifrost.ViewModels;

namespace Bifrost.Views;

/// <summary>Package detail dialog: description, associated config + keybinds, README. Opens <see cref="ConfigEditorWindow"/> for "Edit Config".</summary>
public partial class PackageDetailWindow : Window
{
    public PackageDetailWindow()
    {
        InitializeComponent();
        DataContextChanged += (_, _) =>
        {
            if (DataContext is PackageDetailViewModel vm)
            {
                vm.EditConfigRequested += OnEditConfigRequested;
            }
        };
    }

    private void OnEditConfigRequested(string path)
    {
        if (DataContext is not PackageDetailViewModel vm)
        {
            return;
        }
        var window = new ConfigEditorWindow
        {
            DataContext = new ConfigEditorViewModel(path, vm.Package.FullName),
        };
        window.ShowDialog(this);
    }
}
