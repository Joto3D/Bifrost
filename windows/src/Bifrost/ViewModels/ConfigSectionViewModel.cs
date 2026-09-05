using System.Collections.ObjectModel;

namespace Bifrost.ViewModels;

/// <summary>One <c>[Section]</c> of a parsed BepInEx <c>.cfg</c> file, with its entry rows.</summary>
public sealed class ConfigSectionViewModel
{
    public string Name { get; }
    public ObservableCollection<ConfigEntryRowViewModel> Rows { get; }

    public ConfigSectionViewModel(string name, IEnumerable<ConfigEntryRowViewModel> rows)
    {
        Name = name;
        Rows = new ObservableCollection<ConfigEntryRowViewModel>(rows);
    }
}
