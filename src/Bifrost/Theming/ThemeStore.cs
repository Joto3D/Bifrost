using System.Text.Json;
using System.Text.Json.Serialization;
using Avalonia;
using Avalonia.Media;
using Avalonia.Styling;
using Bifrost.Core.Services;
using CommunityToolkit.Mvvm.ComponentModel;

namespace Bifrost.Theming;

/// <summary>
/// Owns the currently-selected <see cref="ThemePalette"/>, persisted across
/// launches under <c>%AppData%\Bifrost\theme.json</c>, and applied to the
/// running <see cref="Application"/> as a set of <c>DynamicResource</c>
/// brushes so switching a palette in Settings updates every open window
/// live — the Avalonia counterpart of the macOS reference implementation's
/// <c>ThemeStore</c> (<c>Views/Theme.swift</c>), which does the same thing
/// via SwiftUI's <c>.environment(_:)</c>.
///
/// A single process-wide instance (<see cref="Instance"/>) is used rather
/// than threading a store through every view model's constructor — the
/// theme is presentation-only, global, singleton state, exactly like
/// <see cref="Application.Current"/> itself.
/// </summary>
public sealed partial class ThemeStore : ObservableObject
{
    public static ThemeStore Instance { get; } = new();

    private static string SettingsPath => Path.Combine(BifrostPaths.AppDataDir, "theme.json");

    private sealed class StoredSettings
    {
        [JsonPropertyName("paletteId")]
        public string? PaletteId { get; set; }
    }

    [ObservableProperty]
    private ThemePalette _current;

    private ThemeStore()
    {
        _current = LoadPersisted();
    }

    partial void OnCurrentChanged(ThemePalette value)
    {
        Save(value);
        if (Application.Current is { } app)
        {
            Apply(app);
        }
    }

    private static ThemePalette LoadPersisted()
    {
        try
        {
            if (File.Exists(SettingsPath))
            {
                var json = File.ReadAllText(SettingsPath);
                var stored = JsonSerializer.Deserialize<StoredSettings>(json);
                var match = ThemePalette.All.FirstOrDefault(p => p.Id == stored?.PaletteId);
                if (match is not null)
                {
                    return match;
                }
            }
        }
        catch
        {
            // Corrupt or unreadable settings file — fall back to the default palette.
        }
        return ThemePalette.Bifrost;
    }

    private static void Save(ThemePalette palette)
    {
        try
        {
            Directory.CreateDirectory(BifrostPaths.AppDataDir);
            var json = JsonSerializer.Serialize(new StoredSettings { PaletteId = palette.Id }, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(SettingsPath, json);
        }
        catch
        {
            // Best-effort — a failed save just means the choice doesn't survive a relaunch.
        }
    }

    // MARK: - Resource keys

    public const string AccentBrushKey = "BifrostAccentBrush";
    public const string AccentGradientBrushKey = "BifrostAccentGradientBrush";
    public const string AccentButtonFillBrushKey = "BifrostAccentButtonFillBrush";
    public const string SecondaryAccentBrushKey = "BifrostSecondaryAccentBrush";
    public const string BadgeTintBrushKey = "BifrostBadgeTintBrush";
    public const string BadgeTintSoftBrushKey = "BifrostBadgeTintSoftBrush";
    public const string CardBackgroundBrushKey = "BifrostCardBackgroundBrush";
    public const string CardBorderBrushKey = "BifrostCardBorderBrush";
    public const string SidebarBrushKey = "BifrostSidebarBrush";

    /// <summary>
    /// Pushes <see cref="Current"/>'s colors into <paramref name="app"/>'s
    /// top-level resource dictionary as the keys above, recomputing the
    /// theme-variant-sensitive ones (card/sidebar tint opacity, border
    /// color) against <see cref="Application.ActualThemeVariant"/> so both
    /// Fluent light and dark look intentional rather than just "the dark
    /// palette colors forced onto a light background."
    /// </summary>
    public void Apply(Application app)
    {
        var palette = Current;
        var isDark = app.ActualThemeVariant == ThemeVariant.Dark;

        app.Resources[AccentBrushKey] = new SolidColorBrush(palette.AccentColors[0]);
        app.Resources[AccentGradientBrushKey] = MakeGradient(palette.AccentColors, alphaScale: 1.0);
        app.Resources[AccentButtonFillBrushKey] = MakeGradient(palette.AccentColors, alphaScale: 0.9);
        app.Resources[SecondaryAccentBrushKey] = new SolidColorBrush(palette.SecondaryAccent);
        app.Resources[BadgeTintBrushKey] = new SolidColorBrush(palette.BadgeTint);
        app.Resources[BadgeTintSoftBrushKey] = new SolidColorBrush(palette.BadgeTint) { Opacity = 0.14 };

        // Card surface: a neutral chrome tone with the palette's surface
        // color blended in at low opacity — mirrors the macOS
        // BifrostCardBackground modifier's `.regularMaterial` + tint
        // overlay (0.4 opacity in dark mode, 0.045 in light, since a
        // fully-opaque dark tint would just look muddy on a light window).
        var cardBase = isDark ? Color.FromRgb(32, 32, 35) : Color.FromRgb(250, 250, 251);
        var cardTintAlpha = isDark ? 0.40 : 0.045;
        app.Resources[CardBackgroundBrushKey] = new SolidColorBrush(Blend(cardBase, palette.Surface, cardTintAlpha));

        var borderColor = isDark ? Color.FromArgb(31, 255, 255, 255) : Color.FromArgb(20, 0, 0, 0);
        app.Resources[CardBorderBrushKey] = new SolidColorBrush(borderColor);

        // Sidebar: same idea as the card surface but a touch stronger, so
        // the nav rail still reads as a distinct panel next to the content
        // area (replaces the old two-color light/dark placeholder).
        var sidebarBase = isDark ? Color.FromRgb(18, 18, 21) : Color.FromRgb(246, 247, 250);
        var sidebarTintAlpha = isDark ? 0.55 : 0.10;
        app.Resources[SidebarBrushKey] = new SolidColorBrush(Blend(sidebarBase, palette.Surface, sidebarTintAlpha));
    }

    /// <summary>Builds a standalone left-to-right accent gradient brush for a given palette's colors — used for the Settings Appearance swatches, which need every palette's gradient at once rather than just the currently-applied one.</summary>
    public static LinearGradientBrush MakeGradient(IReadOnlyList<Color> colors) => MakeGradient(colors, alphaScale: 1.0);

    private static LinearGradientBrush MakeGradient(IReadOnlyList<Color> colors, double alphaScale)
    {
        var brush = new LinearGradientBrush
        {
            StartPoint = new RelativePoint(0, 0.5, RelativeUnit.Relative),
            EndPoint = new RelativePoint(1, 0.5, RelativeUnit.Relative),
        };

        if (colors.Count == 1)
        {
            // A one-stop "gradient" renders as a plain solid fill — mirrors
            // SwiftUI's LinearGradient behavior for `.plain`'s single-color list.
            var c = Scaled(colors[0], alphaScale);
            brush.GradientStops.Add(new GradientStop(c, 0));
            brush.GradientStops.Add(new GradientStop(c, 1));
            return brush;
        }

        for (var i = 0; i < colors.Count; i++)
        {
            var offset = colors.Count == 1 ? 0 : (double)i / (colors.Count - 1);
            brush.GradientStops.Add(new GradientStop(Scaled(colors[i], alphaScale), offset));
        }
        return brush;
    }

    private static Color Scaled(Color c, double alphaScale) =>
        Color.FromArgb((byte)Math.Round(c.A * alphaScale), c.R, c.G, c.B);

    /// <summary>Straight alpha compositing of <paramref name="tint"/> over <paramref name="baseColor"/> at <paramref name="tintAlpha"/> (0-1), both fully opaque inputs.</summary>
    private static Color Blend(Color baseColor, Color tint, double tintAlpha)
    {
        byte Mix(byte b, byte t) => (byte)Math.Round(b * (1 - tintAlpha) + t * tintAlpha);
        return Color.FromRgb(Mix(baseColor.R, tint.R), Mix(baseColor.G, tint.G), Mix(baseColor.B, tint.B));
    }
}
