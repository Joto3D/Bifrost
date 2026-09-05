using Bifrost.Core.Services;

namespace Bifrost.ViewModels;

/// <summary>One row of the Configs list dialog, wrapping a discovered <c>.cfg</c> file.</summary>
public sealed class ConfigRowViewModel
{
    public BepInExConfig.DiscoveredConfig Config { get; }

    public ConfigRowViewModel(BepInExConfig.DiscoveredConfig config) => Config = config;

    public string FilePath => Config.FilePath;
    public string Title => Config.AssociatedFullName ?? Config.FileName;
    public string? SubtitleFileName => Config.AssociatedFullName is not null ? Config.FileName : null;
    public bool HasSubtitle => SubtitleFileName is not null;
}
