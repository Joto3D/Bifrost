using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.Platform.Storage;
using Bifrost.ViewModels;

namespace Bifrost.Views;

public partial class ImportProfileWindow : Window
{
    public ImportProfileWindow()
    {
        InitializeComponent();
    }

    private async void OnImportFromFileClick(object? sender, RoutedEventArgs e)
    {
        if (DataContext is not ImportProfileViewModel vm)
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
            Title = "Import profile",
            AllowMultiple = false,
            FileTypeFilter = new[]
            {
                new FilePickerFileType("Bifrost profile (*.bifrostprofile)") { Patterns = new[] { "*.bifrostprofile", "*.json" } },
            },
        });
        var path = files.FirstOrDefault()?.TryGetLocalPath();
        if (path is not null)
        {
            await vm.ParseFileAsync(path);
        }
    }

    private void OnDoneClick(object? sender, RoutedEventArgs e) => Close();
}
