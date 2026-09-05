using Bifrost.Core.Services;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace Bifrost.ViewModels;

/// <summary>Which typed control an entry's row renders, chosen the same way the macOS reference implementation's ConfigEditorView does.</summary>
public enum ConfigEntryKind { Checkbox, Combo, KeyboardShortcut, Text }

/// <summary>
/// One row in the config editor form: wraps a parsed
/// <see cref="BepInExConfig.Entry"/> with the UI-facing typed-control state
/// — a checkbox for booleans, a combo for an enumerated
/// "Acceptable values" list, a keyboard-shortcut display + text box, or a
/// plain text box for everything else (numerics included, no
/// reformatting). Edits are written straight back into the owning
/// <see cref="ConfigEditorViewModel"/>'s pending-edits dictionary rather
/// than mutating <see cref="Entry"/>, so "dirty" tracking, Revert, and the
/// conflict-safe keyed save all stay centralized there. Mirrors the macOS
/// app's per-entry row logic in ConfigEditorView.swift.
/// </summary>
public sealed partial class ConfigEntryRowViewModel : ObservableObject
{
    private readonly ConfigEditorViewModel _owner;

    public BepInExConfig.Entry Entry { get; }

    public ConfigEntryRowViewModel(BepInExConfig.Entry entry, ConfigEditorViewModel owner)
    {
        Entry = entry;
        _owner = owner;
        _currentValue = owner.CurrentValue(entry);
    }

    public string Key => Entry.Key;
    public string? Description => Entry.Description;
    public bool HasDescription => Description is not null;

    public string? DefaultCaption => Entry.DefaultValue is null ? null : $"Default: {Entry.DefaultValue}";
    public bool HasDefaultCaption => DefaultCaption is not null;

    public string? RangeCaption => Entry.AcceptableRange;
    public bool HasRangeCaption => RangeCaption is not null;

    public ConfigEntryKind Kind =>
        Entry.IsBoolean ? ConfigEntryKind.Checkbox :
        Entry.AcceptableValues is { Count: > 0 } ? ConfigEntryKind.Combo :
        Entry.SettingType == "KeyboardShortcut" ? ConfigEntryKind.KeyboardShortcut :
        ConfigEntryKind.Text;

    public bool IsCheckbox => Kind == ConfigEntryKind.Checkbox;
    public bool IsCombo => Kind == ConfigEntryKind.Combo;
    public bool IsKeyboardShortcut => Kind == ConfigEntryKind.KeyboardShortcut;
    public bool IsPlainText => Kind == ConfigEntryKind.Text;

    public IReadOnlyList<string> AcceptableValues => Entry.AcceptableValues ?? Array.Empty<string>();

    [ObservableProperty]
    private string _currentValue;

    partial void OnCurrentValueChanged(string value)
    {
        _owner.SetValue(Entry, value);
        OnPropertyChanged(nameof(CurrentBool));
        OnPropertyChanged(nameof(ShowReset));
        OnPropertyChanged(nameof(KeyboardShortcutDisplay));
    }

    /// <summary><see cref="CurrentValue"/> normalized to a bool for the checkbox control, tolerating both BepInEx boolean conventions (Toggle Off/On, Boolean true/false).</summary>
    public bool CurrentBool
    {
        get => CurrentValue.Trim().ToLowerInvariant() is "true" or "on";
        set => CurrentValue = Entry.RawValueForBool(value);
    }

    /// <summary>What the keyboard-shortcut chip shows — "(none)" for an empty binding, matching the macOS app's display.</summary>
    public string KeyboardShortcutDisplay => string.IsNullOrEmpty(CurrentValue) ? "(none)" : CurrentValue;

    public bool ShowReset => Entry.DefaultValue is not null && CurrentValue != Entry.DefaultValue;

    [RelayCommand]
    private void ResetToDefault()
    {
        if (Entry.DefaultValue is not null)
        {
            CurrentValue = Entry.DefaultValue;
        }
    }
}
