using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;

namespace Bifrost.Services;

/// <summary>
/// Attached property that turns a plain <see cref="Border"/> into an
/// async-loaded mod icon: bind <c>IconLoader.SourceUrl</c> to a package's
/// icon URL and this fills the border's <see cref="Border.Background"/>
/// with the downloaded (and disk-cached, see <see cref="IconCache"/>)
/// bitmap once it arrives, via an <see cref="ImageBrush"/> — clipping to
/// the border's own <c>CornerRadius</c> comes for free since it's a
/// background fill rather than a child <see cref="Image"/> element.
/// Until the icon loads (or if the URL is null/the load fails), a quiet
/// neutral placeholder fill is shown instead of a blank box.
/// </summary>
public static class IconLoader
{
    public static readonly AttachedProperty<string?> SourceUrlProperty =
        AvaloniaProperty.RegisterAttached<Border, string?>("SourceUrl", typeof(IconLoader));

    private static readonly IBrush PlaceholderBrush = new SolidColorBrush(Color.FromArgb(36, 128, 128, 128));

    static IconLoader()
    {
        SourceUrlProperty.Changed.AddClassHandler<Border>(OnSourceUrlChanged);
    }

    public static void SetSourceUrl(Border border, string? value) => border.SetValue(SourceUrlProperty, value);
    public static string? GetSourceUrl(Border border) => border.GetValue(SourceUrlProperty);

    private static async void OnSourceUrlChanged(Border border, AvaloniaPropertyChangedEventArgs e)
    {
        var url = e.NewValue as string;
        border.Background = PlaceholderBrush;
        if (string.IsNullOrWhiteSpace(url))
        {
            return;
        }

        var bitmap = await IconCache.GetAsync(url);
        // The bound URL may have changed (row recycled/scrolled) while the
        // download was in flight — only apply if it's still current.
        if (bitmap is not null && GetSourceUrl(border) == url)
        {
            border.Background = new ImageBrush(bitmap) { Stretch = Stretch.UniformToFill };
        }
    }
}
