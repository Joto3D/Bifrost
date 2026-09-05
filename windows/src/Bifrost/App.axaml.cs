using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using Bifrost.Theming;
using Bifrost.ViewModels;
using Bifrost.Views;

namespace Bifrost;

public partial class App : Application
{
    public override void Initialize()
    {
        AvaloniaXamlLoader.Load(this);
    }

    public override void OnFrameworkInitializationCompleted()
    {
        // Apply the persisted (or default) palette before any window is
        // shown, and keep it in sync if the OS/Fluent theme variant itself
        // flips at runtime (light <-> dark) — the palette's card/sidebar
        // tint opacity and border color depend on which base variant is
        // active, see ThemeStore.Apply.
        ThemeStore.Instance.Apply(this);
        ActualThemeVariantChanged += (_, _) => ThemeStore.Instance.Apply(this);

        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            desktop.MainWindow = new MainWindow
            {
                DataContext = new MainViewModel(),
            };
        }

        base.OnFrameworkInitializationCompleted();
    }
}