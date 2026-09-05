using System.Runtime.InteropServices;

namespace Bifrost.Core.Services;

/// <summary>
/// Windows' reduced-motion signal, for the two purely-decorative animations
/// the "fun round" adds (the Surprise Me dice bounce and the post-launch
/// celebration shimmer) — the counterparts of the macOS app's
/// <c>NSWorkspace.shared.accessibilityDisplayShouldReduceMotion</c> checks
/// in <c>SurpriseMeButton.swift</c>/<c>AuroraCelebration.swift</c>. Windows
/// has no exact equivalent API; the closest signal is the
/// <c>SPI_GETCLIENTAREAANIMATION</c> system parameter (unchecking Settings
/// → Accessibility → Visual effects → "Animation effects" clears it),
/// read here via a small <c>user32.dll</c> P/Invoke guarded by
/// <see cref="OperatingSystem.IsWindows"/> the same way
/// <see cref="WindowsRegistry"/>/<see cref="WindowsCredentials"/> guard
/// their own Windows-only calls.
/// </summary>
public static class WindowsAccessibility
{
    private const uint SpiGetClientAreaAnimation = 0x1042;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SystemParametersInfo(uint action, uint param, ref bool value, uint winIni);

    /// <summary>
    /// True (animations allowed) on any non-Windows platform or if the
    /// system call itself fails — a missing signal should never silently
    /// disable a purely cosmetic effect. False only when Windows explicitly
    /// reports "Animation effects" turned off.
    /// </summary>
    public static bool AnimationsEnabled()
    {
        if (!OperatingSystem.IsWindows())
        {
            return true;
        }
        try
        {
            var enabled = true;
            return !SystemParametersInfo(SpiGetClientAreaAnimation, 0, ref enabled, 0) || enabled;
        }
        catch
        {
            return true;
        }
    }
}
