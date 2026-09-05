using Avalonia.Media;

namespace Bifrost.Theming;

/// <summary>
/// One selectable Bifrost color identity: an accent gradient (the "one
/// splash of color" used sparingly for primary actions, badges, progress,
/// and underlines) plus a base surface tone layered under card materials.
/// Ported 1:1 from the macOS reference implementation's
/// <c>Views/Theme.swift</c> — every RGB triple below is byte-identical to
/// that file's <c>Color(red:green:blue:)</c> literals (rounded the same way
/// SwiftUI rounds a 0-1 float to a color byte), so picking a given palette
/// name reproduces the same colors on both platforms.
///
/// Fonts, spacing, radii, and motion are deliberately not part of this —
/// those stay shared/global across every palette in both apps.
/// </summary>
public sealed class ThemePalette
{
    public required string Id { get; init; }
    public required string DisplayName { get; init; }

    /// <summary>The accent gradient's stops, left-to-right. A single-color palette (see <see cref="Plain"/>) is one element, which renders as a plain solid fill.</summary>
    public required IReadOnlyList<Color> AccentColors { get; init; }

    /// <summary>The deep base/surface tone layered at low opacity under card materials and icon roundels.</summary>
    public required Color Surface { get; init; }

    /// <summary>A single calmer accent that complements the gradient — used where the full multi-stop sweep would be too busy for a small shape.</summary>
    public required Color SecondaryAccent { get; init; }

    /// <summary>A flat wash used behind palette-flavored surfaces that want a tinted background rather than the full gradient sweep.</summary>
    public required Color BadgeTint { get; init; }

    private static Color Rgb(byte r, byte g, byte b) => Color.FromRgb(r, g, b);

    /// <summary>The original "deep night sky + rainbow bridge" identity — Bifrost's default palette.</summary>
    public static readonly ThemePalette Bifrost = new()
    {
        Id = "bifrost",
        DisplayName = "Bifrost",
        AccentColors = new[]
        {
            Rgb(237, 82, 94),
            Rgb(242, 148, 71),
            Rgb(245, 204, 97),
            Rgb(112, 199, 140),
            Rgb(97, 171, 235),
            Rgb(158, 133, 222),
        },
        Surface = Rgb(11, 14, 37),
        SecondaryAccent = Rgb(97, 171, 235),
        BadgeTint = Rgb(158, 133, 222),
    };

    /// <summary>Meadows and viking gold — deep forest-green surfaces under a gold-to-moss accent sweep.</summary>
    public static readonly ThemePalette Midgard = new()
    {
        Id = "midgard",
        DisplayName = "Midgard",
        AccentColors = new[]
        {
            Rgb(217, 178, 56),
            Rgb(184, 168, 66),
            Rgb(143, 153, 76),
            Rgb(107, 143, 82),
            Rgb(76, 122, 84),
        },
        Surface = Rgb(9, 23, 13),
        SecondaryAccent = Rgb(115, 148, 92),
        BadgeTint = Rgb(217, 178, 56),
    };

    /// <summary>Deep red-to-amber embers over a near-black charcoal surface.</summary>
    public static readonly ThemePalette Ashlands = new()
    {
        Id = "ashlands",
        DisplayName = "Ashlands",
        AccentColors = new[]
        {
            Rgb(140, 20, 26),
            Rgb(204, 56, 26),
            Rgb(237, 115, 31),
            Rgb(245, 173, 64),
        },
        Surface = Rgb(15, 9, 8),
        SecondaryAccent = Rgb(209, 92, 38),
        BadgeTint = Rgb(245, 173, 64),
    };

    /// <summary>Dusky indigo surfaces under a teal-to-violet mist accent.</summary>
    public static readonly ThemePalette Mistlands = new()
    {
        Id = "mistlands",
        DisplayName = "Mistlands",
        AccentColors = new[]
        {
            Rgb(51, 140, 140),
            Rgb(76, 128, 161),
            Rgb(115, 117, 181),
            Rgb(148, 107, 191),
        },
        Surface = Rgb(23, 18, 41),
        SecondaryAccent = Rgb(107, 122, 173),
        BadgeTint = Rgb(143, 112, 186),
    };

    /// <summary>Steel-blue ice surfaces under a white-to-pale-blue accent.</summary>
    public static readonly ThemePalette DeepNorth = new()
    {
        Id = "deep-north",
        DisplayName = "Deep North",
        AccentColors = new[]
        {
            Rgb(217, 237, 247),
            Rgb(140, 209, 237),
            Rgb(89, 158, 217),
            Rgb(140, 178, 224),
        },
        Surface = Rgb(18, 26, 38),
        SecondaryAccent = Rgb(115, 178, 224),
        BadgeTint = Rgb(140, 209, 237),
    };

    /// <summary>
    /// Minimal: a quiet blue standing in for the platform accent color (the
    /// macOS original uses <c>Color.accentColor</c> directly; Avalonia's
    /// per-OS accent isn't a fixed RGB triple, so this uses the same blue
    /// Fluent's own default accent swatch uses) over neutral, near-system
    /// surfaces — for people who want it quiet.
    /// </summary>
    public static readonly ThemePalette Plain = new()
    {
        Id = "plain",
        DisplayName = "Plain",
        AccentColors = new[] { Rgb(0, 120, 212) },
        Surface = Rgb(20, 20, 20),
        SecondaryAccent = Colors.Gray,
        BadgeTint = Rgb(0, 120, 212),
    };

    /// <summary>Every selectable palette, in the order shown by Settings' theme picker. <see cref="Bifrost"/> stays first as the default.</summary>
    public static readonly IReadOnlyList<ThemePalette> All = new[] { Bifrost, Midgard, Ashlands, Mistlands, DeepNorth, Plain };
}
