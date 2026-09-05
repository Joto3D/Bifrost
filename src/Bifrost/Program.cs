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

        // Single-instance + nxm:// forwarding: a Windows-registered URL
        // protocol always spawns a brand-new process for each click (see
        // NxmProtocolRegistrar), so a second launch needs to hand its
        // argument to the already-running instance and exit rather than
        // opening a confusing second window. Only engaged when the "Handle
        // nxm:// links" setting is on — otherwise every launch behaves
        // exactly as it did before this feature existed.
        var settings = new AppSettingsStore().Load();
        SingleInstance? singleInstance = null;
        if (settings.EnableNxmProtocol)
        {
            singleInstance = new SingleInstance();
            if (!singleInstance.AcquirePrimary())
            {
                var nxmArgument = Array.Find(args, a => a.StartsWith("nxm://", StringComparison.OrdinalIgnoreCase));
                // Always forward *something* — a real nxm link when this
                // launch carried one, otherwise just an "activate" nudge so
                // a plain second double-click still raises the running
                // window instead of silently doing nothing.
                SingleInstance.TryForward(nxmArgument ?? "activate");
                singleInstance.Dispose();
                return 0;
            }
        }

        App.PendingNxmArgument = Array.Find(args, a => a.StartsWith("nxm://", StringComparison.OrdinalIgnoreCase));
        App.SingleInstanceHost = singleInstance;

        try
        {
            BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);
        }
        finally
        {
            singleInstance?.Dispose();
        }
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
