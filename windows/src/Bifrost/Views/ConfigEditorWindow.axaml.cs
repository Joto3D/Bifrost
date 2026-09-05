using Avalonia.Controls;
using Avalonia.Interactivity;
using Bifrost.ViewModels;

namespace Bifrost.Views;

/// <summary>
/// Modal window hosting <see cref="ConfigEditorViewModel"/>. Owns the parts
/// that genuinely need a real Window: starting/stopping the staleness poll
/// with the window's lifetime, re-checking on activation (the nearest
/// Avalonia equivalent of the macOS app's "app became active" recheck), and
/// intercepting a close request while there are unsaved edits so the
/// view model's inline confirmation overlay gets a chance to run instead of
/// the window just closing.
/// </summary>
public partial class ConfigEditorWindow : Window
{
    private bool _forceClose;

    public ConfigEditorWindow()
    {
        InitializeComponent();

        Opened += OnOpened;
        Closing += OnClosing;
        Closed += OnClosed;
        Activated += (_, _) => (DataContext as ConfigEditorViewModel)?.CheckForExternalChange();
    }

    private void OnOpened(object? sender, EventArgs e)
    {
        if (DataContext is ConfigEditorViewModel vm)
        {
            vm.CloseRequested += OnCloseRequested;
            vm.Load();
            vm.StartPolling();
        }
    }

    private void OnClosing(object? sender, WindowClosingEventArgs e)
    {
        if (_forceClose)
        {
            return;
        }
        if (DataContext is ConfigEditorViewModel { IsDirty: true } vm)
        {
            e.Cancel = true;
            vm.RequestClose();
        }
    }

    private void OnClosed(object? sender, EventArgs e)
    {
        if (DataContext is ConfigEditorViewModel vm)
        {
            vm.CloseRequested -= OnCloseRequested;
            vm.StopPolling();
        }
    }

    private void OnCloseRequested()
    {
        _forceClose = true;
        Close();
    }

    private void OnCloseClick(object? sender, RoutedEventArgs e)
    {
        (DataContext as ConfigEditorViewModel)?.RequestClose();
    }

    private void OnRevealClick(object? sender, RoutedEventArgs e)
    {
        (DataContext as ConfigEditorViewModel)?.RevealInExplorer();
    }
}
