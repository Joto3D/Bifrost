using System.Linq;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Platform.Storage;
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

    /// <summary>"Install from File…" — opens a native file picker for .zip/.dll and hands the chosen paths to <see cref="InstalledViewModel.InstallFilesAsync"/>. The whole-window drag-and-drop path in <c>MainWindow</c> reaches the same method directly.</summary>
    private async void OnInstallFromFileClick(object? sender, RoutedEventArgs e)
    {
        if (DataContext is not InstalledViewModel vm)
        {
            return;
        }
        var topLevel = TopLevel.GetTopLevel(this);
        if (topLevel is null)
        {
            return;
        }

        var files = await topLevel.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = "Install mod from file",
            AllowMultiple = true,
            FileTypeFilter = new[]
            {
                new FilePickerFileType("Mod files (*.zip, *.dll)") { Patterns = new[] { "*.zip", "*.dll" } },
            },
        });

        var paths = files
            .Select(f => f.TryGetLocalPath())
            .Where(p => p is not null)
            .Select(p => p!)
            .ToList();
        if (paths.Count > 0)
        {
            await vm.InstallFilesAsync(paths);
        }
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
