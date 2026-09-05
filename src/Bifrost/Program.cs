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
        Console.WriteLine("Bifrost self-test (Windows scaffold)");
        Console.WriteLine("=====================================");

        var results = SelfTest.RunAll();
        var allPassed = true;

        foreach (var result in results)
        {
            allPassed &= result.Passed;
            var status = result.Passed ? "PASS" : "FAIL";
            Console.WriteLine($"[{status}] {result.Name} - {result.Detail}");
        }

        Console.WriteLine();
        Console.WriteLine(allPassed
            ? "All checks passed."
            : "One or more checks failed.");

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
