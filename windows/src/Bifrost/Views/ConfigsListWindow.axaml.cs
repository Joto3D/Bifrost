using Avalonia.Controls;
using Bifrost.ViewModels;

namespace Bifrost.Views;

/// <summary>Lists every discovered <c>.cfg</c> file; selecting one opens <see cref="ConfigEditorWindow"/> for it.</summary>
public partial class ConfigsListWindow : Window
{
    public ConfigsListWindow()
    {
        InitializeComponent();
        DataContextChanged += (_, _) =>
        {
            if (DataContext is ConfigsListViewModel vm)
            {
                vm.ConfigSelected += OnConfigSelected;
            }
        };
    }

    private void OnConfigSelected(ConfigRowViewModel row)
    {
        var window = new ConfigEditorWindow
        {
            DataContext = new ConfigEditorViewModel(row.FilePath, row.Title),
        };
        window.ShowDialog(this);
    }
}
