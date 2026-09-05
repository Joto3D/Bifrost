using Avalonia.Media;
using Bifrost.Theming;
using CommunityToolkit.Mvvm.ComponentModel;

namespace Bifrost.ViewModels;

/// <summary>
/// One row in Settings' Appearance theme picker: a precomputed gradient
/// swatch + surface chip for one <see cref="ThemePalette"/>, plus whether
/// it's the currently-applied palette. Mirrors the macOS app's
/// <c>SettingsView.ThemeRow</c>.
/// </summary>
public partial class PaletteRowViewModel : ObservableObject
{
    public ThemePalette Palette { get; }
    public string DisplayName => Palette.DisplayName;
    public IBrush GradientBrush { get; }
    public IBrush SurfaceBrush { get; }
    public IBrush SecondaryAccentBrush { get; }

    [ObservableProperty]
    private bool _isSelected;

    public PaletteRowViewModel(ThemePalette palette, bool isSelected)
    {
        Palette = palette;
        _isSelected = isSelected;
        GradientBrush = ThemeStore.MakeGradient(palette.AccentColors);
        SurfaceBrush = new SolidColorBrush(palette.Surface);
        SecondaryAccentBrush = new SolidColorBrush(palette.SecondaryAccent);
    }
}
