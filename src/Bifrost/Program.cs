using Avalonia;
using Bifrost.Core.Services;
using System;

namespace Bifrost;

sealed class Program
{
    // Initialization code. Don't use any Avalonia, third-party APIs or any
    // SynchronizationContext-reliant code before AppMain is called: things aren't initialized
    // yet and stuff might break.
    [STAThread]
    public static int Main(string[] args)
    {
        if (Array.IndexOf(args, "--check") >= 0)
        {
            return RunSelfCheck();
        }

        BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
        return 0;
    }

    /// <summary>
    /// Headless diagnostics mode, mirroring the macOS app's
    /// `Bifrost --check` (Sources/Bifrost/DebugCheck.swift). Runs before any
    /// Avalonia/UI initialization so it works over SSH, in CI, etc.
    /// </summary>
    private static int RunSelfCheck()
    {
        Console.WriteLine("Bifrost --check");
        Console.WriteLine("================");

        var allPassed = SelfTest.RunAllAsync(Console.Out).GetAwaiter().GetResult();
        return allPassed ? 0 : 1;
    }

    // Avalonia configuration, don't remove; also used by visual designer.
    public static AppBuilder BuildAvaloniaApp()
        => AppBuilder.Configure<App>()
            .UsePlatformDetect()
#if DEBUG
            .WithDeveloperTools()
#endif
            .WithInterFont()
            .LogToTrace();
}
