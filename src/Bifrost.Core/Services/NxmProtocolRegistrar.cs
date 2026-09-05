namespace Bifrost.Core.Services;

/// <summary>
/// Registers Bifrost as the handler for the <c>nxm://</c> URL scheme —
/// Nexus Mods' "Mod Manager Download" links (see <c>Models.NxmLink</c>) —
/// under the current user's registry hive:
/// <c>HKCU\Software\Classes\nxm\shell\open\command</c> = <c>"&lt;exe path&gt;" "%1"</c>,
/// plus the <c>URL Protocol</c> marker value on the <c>nxm</c> key itself.
/// This is the standard per-user (no elevation needed) way to claim a
/// custom URL scheme on Windows — the exact registry shape Nexus's own
/// Vortex/other mod managers use for the same link type.
///
/// Guarded entirely by <see cref="OperatingSystem.IsWindows"/> at the call
/// site, mirroring <see cref="WindowsRegistry"/> — never touched on
/// macOS/Linux, where <c>Microsoft.Win32.Registry</c> doesn't exist at
/// runtime.
/// </summary>
public static class NxmProtocolRegistrar
{
    private const string ProtocolKeyPath = @"Software\Classes\nxm";
    private const string CommandKeyPath = @"Software\Classes\nxm\shell\open\command";

    /// <summary>
    /// Writes the registry keys pointing <c>nxm://</c> at
    /// <paramref name="exePath"/>. Safe to call on every startup — each
    /// value is simply overwritten, so a Bifrost.exe that moved (a fresh
    /// self-contained publish to a new folder, for instance) gets
    /// re-registered automatically rather than leaving a stale path behind.
    /// </summary>
    public static void Register(string exePath)
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var protocolKey = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(ProtocolKeyPath);
        protocolKey.SetValue(null, "URL:Nexus Mods Manager Download Link");
        protocolKey.SetValue("URL Protocol", "", Microsoft.Win32.RegistryValueKind.String);

        using var commandKey = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(CommandKeyPath);
        commandKey.SetValue(null, $"\"{exePath}\" \"%1\"");
    }

    /// <summary>Removes the registration, e.g. when the user turns the "Handle nxm:// links" setting off.</summary>
    public static void Unregister()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        try
        {
            Microsoft.Win32.Registry.CurrentUser.DeleteSubKeyTree(ProtocolKeyPath, throwOnMissingSubKey: false);
        }
        catch
        {
            // Best effort — a locked-down machine (e.g. corporate policy
            // blocking HKCU\Software\Classes writes) shouldn't crash the app.
        }
    }

    /// <summary>
    /// Whether <c>nxm://</c> is currently registered to point at
    /// <paramref name="exePath"/> specifically (not just registered to
    /// something) — used by <c>--check</c> and Settings to report accurate
    /// status without assuming <see cref="Register"/> was ever called.
    /// </summary>
    public static bool IsRegisteredTo(string exePath)
    {
        if (!OperatingSystem.IsWindows())
        {
            return false;
        }

        try
        {
            using var commandKey = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(CommandKeyPath);
            var value = commandKey?.GetValue(null) as string;
            return value is not null && value.Contains(exePath, StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return false;
        }
    }
}
