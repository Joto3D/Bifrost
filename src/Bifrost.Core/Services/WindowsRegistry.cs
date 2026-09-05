namespace Bifrost.Core.Services;

/// <summary>
/// Isolates the one real Windows-registry read Bifrost needs (Steam's
/// install path) behind a tiny surface, guarded entirely by
/// <see cref="OperatingSystem.IsWindows"/> at the call site
/// (<see cref="BifrostPaths.ResolveSteamRoot"/>) so this type is never
/// touched — and the <c>Microsoft.Win32.Registry</c> APIs it calls never
/// execute — on macOS/Linux.
/// </summary>
public static class WindowsRegistry
{
    public static string? ReadSteamInstallPath()
    {
        if (!OperatingSystem.IsWindows())
        {
            return null;
        }

        using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"SOFTWARE\Valve\Steam");
        return key?.GetValue("InstallPath") as string;
    }
}
