using System.Globalization;
using Avalonia.Data.Converters;
using Avalonia.Media;

namespace Bifrost.Converters;

/// <summary>Small value converters used by the Home hero's status pills and Installed's update badges — kept here rather than pulled in as a dependency since Bifrost only needs a handful of one-line conversions.</summary>
public static class StatusConverters
{
    /// <summary>bool -> "✓" (ok) / "✕" (not ok), for a status pill's leading glyph.</summary>
    public static readonly IValueConverter OkGlyph =
        new FuncValueConverter<bool, string>(ok => ok ? "✓" : "✕");

    /// <summary>bool -> a green (ok) or red (not ok) solid brush, for a status pill's glyph/tint.</summary>
    public static readonly IValueConverter OkBrush =
        new FuncValueConverter<bool, IBrush>(ok => ok
            ? new SolidColorBrush(Color.FromRgb(0x3C, 0xB3, 0x71))
            : new SolidColorBrush(Color.FromRgb(0xE0, 0x5A, 0x5A)));

    /// <summary>bool -> a soft green/red background wash for a status pill's icon roundel.</summary>
    public static readonly IValueConverter OkBackground =
        new FuncValueConverter<bool, IBrush>(ok => ok
            ? new SolidColorBrush(Color.FromArgb(38, 0x3C, 0xB3, 0x71))
            : new SolidColorBrush(Color.FromArgb(38, 0xE0, 0x5A, 0x5A)));

    public static readonly IValueConverter Inverse =
        new FuncValueConverter<bool, bool>(v => !v);

    /// <summary>null-or-empty string -> false (used to gate "Not found" style banners).</summary>
    public static readonly IValueConverter IsNullOrEmpty =
        new FuncValueConverter<string?, bool>(string.IsNullOrEmpty);

    /// <summary>non-null-and-non-empty string -> true (used to hide a row when e.g. a description is blank).</summary>
    public static readonly IValueConverter HasText =
        new FuncValueConverter<string?, bool>(v => !string.IsNullOrEmpty(v));

    // The doorstop modded/vanilla toggle is informational rather than
    // pass/fail (vanilla isn't a "failure"), so its status tile uses a
    // neutral gray for false/null instead of red — these three converters
    // are only used by that one tile.
    private static readonly IBrush NeutralBrush = new SolidColorBrush(Color.FromRgb(0x8A, 0x8A, 0x92));
    private static readonly IBrush NeutralBackground = new SolidColorBrush(Color.FromArgb(30, 0x8A, 0x8A, 0x92));

    private static readonly IBrush OkBrushColor = new SolidColorBrush(Color.FromRgb(0x3C, 0xB3, 0x71));
    private static readonly IBrush OkBackgroundColor = new SolidColorBrush(Color.FromArgb(38, 0x3C, 0xB3, 0x71));

    public static readonly IValueConverter TriGlyph =
        new FuncValueConverter<bool?, string>(v => v switch { true => "✓", false => "–", _ => "?" });

    public static readonly IValueConverter TriBrush =
        new FuncValueConverter<bool?, IBrush>(v => v == true ? OkBrushColor : NeutralBrush);

    public static readonly IValueConverter TriBackground =
        new FuncValueConverter<bool?, IBrush>(v => v == true ? OkBackgroundColor : NeutralBackground);

    public static readonly IValueConverter TriSubtitle =
        new FuncValueConverter<bool?, string>(v => v switch { true => "Modded", false => "Vanilla", _ => "Unknown" });
}
