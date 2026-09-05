using Avalonia.Controls;
using Avalonia.Input.Platform;
using Avalonia.Interactivity;
using Avalonia.Platform.Storage;
using Bifrost.Core.Services;
using Bifrost.ViewModels;

namespace Bifrost.Views;

public partial class ProfilesWindow : Window
{
    public ProfilesWindow()
    {
        InitializeComponent();
    }

    /// <summary>Copies the selected profile's native share code (base64 JSON — see <see cref="ProfileShare.Export"/>) to the clipboard.</summary>
    private async void OnCopyShareCodeClick(object? sender, RoutedEventArgs e)
    {
        if (DataContext is not ProfilesViewModel vm || vm.SelectedProfile is not { } profile)
        {
            return;
        }
        var manifest = vm.Services.ModManager.LoadManifest();
        var outcome = ProfileShare.Export(profile, manifest);

        var clipboard = TopLevel.GetTopLevel(this)?.Clipboard;
        if (clipboard is not null)
        {
            await clipboard.SetTextAsync(outcome.EncodedString);
        }
        vm.StatusMessage = outcome.SkippedLocalMods.Count == 0
            ? $"Copied share code for \"{profile.Name}\" to the clipboard."
            : $"Copied share code for \"{profile.Name}\" (skipped local-only mods: {string.Join(", ", outcome.SkippedLocalMods)}).";
    }

    /// <summary>Presents a save dialog and writes the selected profile to the chosen .bifrostprofile file (see <see cref="ProfileShare.ExportFile"/>).</summary>
    private async void OnExportToFileClick(object? sender, RoutedEventArgs e)
    {
        if (DataContext is not ProfilesViewModel vm || vm.SelectedProfile is not { } profile)
        {
            return;
        }
        var topLevel = TopLevel.GetTopLevel(this);
        if (topLevel is null)
        {
            return;
        }

        var file = await topLevel.StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title = "Export profile",
            SuggestedFileName = $"{profile.Name}.bifrostprofile",
            FileTypeChoices = new[] { new FilePickerFileType("Bifrost profile (*.bifrostprofile)") { Patterns = new[] { "*.bifrostprofile" } } },
            DefaultExtension = "bifrostprofile",
        });
        var path = file?.TryGetLocalPath();
        if (path is null)
        {
            return;
        }

        try
        {
            var manifest = vm.Services.ModManager.LoadManifest();
            var skipped = ProfileShare.ExportFile(profile, manifest, path);
            vm.StatusMessage = skipped.Count == 0
                ? $"Exported \"{profile.Name}\" to {System.IO.Path.GetFileName(path)}."
                : $"Exported \"{profile.Name}\" to {System.IO.Path.GetFileName(path)} (skipped local-only mods: {string.Join(", ", skipped)}).";
        }
        catch (Exception ex)
        {
            vm.StatusMessage = $"Couldn't export \"{profile.Name}\": {ex.Message}";
        }
    }

    /// <summary>Uploads the selected profile as an r2modman-compatible profile code (see <see cref="ProfileShare.ExportR2CodeAsync"/>) and copies the resulting code to the clipboard.</summary>
    private async void OnCopyR2CodeClick(object? sender, RoutedEventArgs e)
    {
        if (DataContext is not ProfilesViewModel vm || vm.SelectedProfile is not { } profile)
        {
            return;
        }
        vm.StatusMessage = $"Uploading r2modman code for \"{profile.Name}\"…";
        try
        {
            var manifest = vm.Services.ModManager.LoadManifest();
            var code = await ProfileShare.ExportR2CodeAsync(profile, manifest);
            var clipboard = TopLevel.GetTopLevel(this)?.Clipboard;
            if (clipboard is not null)
            {
                await clipboard.SetTextAsync(code);
            }
            vm.StatusMessage = $"Copied r2modman code for \"{profile.Name}\" to the clipboard: {code}";
        }
        catch (Exception ex)
        {
            vm.StatusMessage = $"Couldn't create an r2modman code for \"{profile.Name}\": {ex.Message}";
        }
    }

    private void OnImportClick(object? sender, RoutedEventArgs e)
    {
        if (DataContext is not ProfilesViewModel vm)
        {
            return;
        }

        var window = new ImportProfileWindow { DataContext = new ImportProfileViewModel(vm.Services) };
        window.Closed += async (_, _) => await vm.RefreshCommand.ExecuteAsync(null);

        if (TopLevel.GetTopLevel(this) is Window owner)
        {
            window.ShowDialog(owner);
        }
        else
        {
            window.Show();
        }
    }
}
