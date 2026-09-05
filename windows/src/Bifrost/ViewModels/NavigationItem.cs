namespace Bifrost.ViewModels;

/// <summary>
/// One entry in the sidebar navigation list.
/// </summary>
public sealed class NavigationItem
{
    public required string Title { get; init; }
    public required string Glyph { get; init; }
    public required ViewModelBase Page { get; init; }
}
