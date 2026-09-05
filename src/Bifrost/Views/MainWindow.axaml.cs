using System.Linq;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Platform.Storage;
using Bifrost.ViewModels;

namespace Bifrost.Views;

/// <summary>
/// Owns the one thing that genuinely needs a real Window rather than living
/// on <see cref="MainViewModel"/>: the whole-window drag-and-drop target for
/// installing mod files regardless of which tab is active (mirrors the
/// macOS reference implementation's <c>MainWindow.swift</c> <c>onDrop</c>
/// handler + drop overlay).
/// </summary>
public partial class MainWindow : Window
{
    private static readonly string[] SupportedExtensions = { ".zip", ".dll" };

    public MainWindow()
    {
        InitializeComponent();

        DragDrop.SetAllowDrop(this, true);
        AddHandler(DragDrop.DragEnterEvent, OnDragOver);
        AddHandler(DragDrop.DragOverEvent, OnDragOver);
        AddHandler(DragDrop.DragLeaveEvent, OnDragLeave);
        AddHandler(DragDrop.DropEvent, OnDrop);
    }

    private void OnDragOver(object? sender, DragEventArgs e)
    {
        var files = e.DataTransfer.TryGetFiles();
        var accepts = files is not null && files.Any(f => IsSupported(f.Name));
        DropOverlay.IsVisible = accepts;
        e.DragEffects = accepts ? DragDropEffects.Copy : DragDropEffects.None;
    }

    private void OnDragLeave(object? sender, DragEventArgs e) => DropOverlay.IsVisible = false;

    private async void OnDrop(object? sender, DragEventArgs e)
    {
        DropOverlay.IsVisible = false;

        var files = e.DataTransfer.TryGetFiles();
        if (files is null || DataContext is not MainViewModel vm)
        {
            return;
        }

        var paths = files
            .Where(f => IsSupported(f.Name))
            .Select(f => f.TryGetLocalPath())
            .Where(p => p is not null)
            .Select(p => p!)
            .ToList();
        if (paths.Count == 0)
        {
            return;
        }

        var installedItem = vm.NavigationItems.FirstOrDefault(n => ReferenceEquals(n.Page, vm.Installed));
        if (installedItem is not null)
        {
            vm.SelectedItem = installedItem;
        }
        await vm.Installed.InstallFilesAsync(paths);
    }

    private static bool IsSupported(string fileName) =>
        SupportedExtensions.Any(ext => fileName.EndsWith(ext, System.StringComparison.OrdinalIgnoreCase));
}
