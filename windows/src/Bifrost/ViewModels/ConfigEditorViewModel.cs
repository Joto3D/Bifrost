using System.Collections.ObjectModel;
using Bifrost.Core.Services;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace Bifrost.ViewModels;

/// <summary>
/// Per-file BepInEx <c>.cfg</c> editor: parses the file
/// (<see cref="BepInExConfig"/>) and exposes each section as a
/// <see cref="ConfigSectionViewModel"/> of typed rows. Mirrors the macOS
/// reference implementation's <c>ConfigEditorView.swift</c>, including its
/// later hardening pass:
///
/// <list type="bullet">
/// <item>Saves surgically via <see cref="BepInExConfig.Applying(IReadOnlyList{BepInExConfig.KeyedChange},string)"/>:
/// at save time the file is re-read from disk and the user's edits are
/// re-targeted by (section, key) — not a stale line index — so a rewrite
/// that happened while the editor was open (mods commonly rewrite their own
/// <c>.cfg</c> at game exit) doesn't get clobbered, and doesn't silently
/// revert the user's own save either.</item>
/// <item>Polls (~2s) for external changes: silently reloads when there are
/// no pending edits, or raises <see cref="ExternalChangeDetected"/> as a
/// non-blocking notice when there are.</item>
/// <item>Tracks whether Valheim is currently running
/// (<see cref="ValheimRunning"/>) so the save status line can note "applies
/// next game launch" — the game only reads configs at startup.</item>
/// </list>
/// </summary>
public sealed partial class ConfigEditorViewModel : ObservableObject, IDisposable
{
    private readonly Dictionary<string, string> _editedValues = new();
    private CancellationTokenSource? _pollCts;
    private DateTime? _loadedWriteTimeUtc;

    public string FilePath { get; }
    public string Title { get; }

    public ObservableCollection<ConfigSectionViewModel> Sections { get; } = new();

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasLoadError))]
    private string? _loadError;
    public bool HasLoadError => LoadError is not null;

    [ObservableProperty] private string? _statusLine;
    [ObservableProperty] [NotifyCanExecuteChangedFor(nameof(SaveCommand))] private bool _busy;
    [ObservableProperty] private bool _externalChangeDetected;
    [ObservableProperty] private bool _valheimRunning;
    [ObservableProperty] private bool _isConfirmingClose;

    public bool IsDirty => _editedValues.Count > 0;

    /// <summary>Set once the user confirms discarding changes in the close-confirmation overlay, so a second close request bypasses the dirty guard.</summary>
    private bool _confirmedDiscard;

    /// <summary>Raised when this editor should actually close — the view's code-behind owns the Window and does the real <c>Close()</c>.</summary>
    public event Action? CloseRequested;

    public ConfigEditorViewModel(string filePath, string title)
    {
        FilePath = filePath;
        Title = title;
    }

    public string CurrentValue(BepInExConfig.Entry entry) =>
        _editedValues.TryGetValue(entry.Id, out var value) ? value : entry.RawValue;

    public void SetValue(BepInExConfig.Entry entry, string value)
    {
        if (value == entry.RawValue)
        {
            _editedValues.Remove(entry.Id);
        }
        else
        {
            _editedValues[entry.Id] = value;
        }
        OnDirtyChanged();
    }

    private void OnDirtyChanged()
    {
        OnPropertyChanged(nameof(IsDirty));
        SaveCommand.NotifyCanExecuteChanged();
        RevertCommand.NotifyCanExecuteChanged();
    }

    public void Load()
    {
        var text = BepInExConfig.ReadTextOrNull(FilePath);
        if (text is null)
        {
            LoadError = $"Couldn't read {Path.GetFileName(FilePath)}.";
            return;
        }

        var configFile = BepInExConfig.Parse(text);
        _editedValues.Clear();
        LoadError = null;
        StatusLine = null;
        ExternalChangeDetected = false;
        _loadedWriteTimeUtc = TryGetWriteTimeUtc(FilePath);

        Sections.Clear();
        foreach (var section in configFile.Sections)
        {
            var rows = section.Entries.Select(entry => new ConfigEntryRowViewModel(entry, this));
            Sections.Add(new ConfigSectionViewModel(section.Name, rows));
        }
        OnDirtyChanged();
    }

    [RelayCommand(CanExecute = nameof(IsDirty))]
    private void Revert() => Load();

    [RelayCommand(CanExecute = nameof(CanSave))]
    private void Save()
    {
        var edits = Sections
            .SelectMany(s => s.Rows)
            .Where(row => _editedValues.ContainsKey(row.Entry.Id))
            .Select(row => new BepInExConfig.KeyedChange(row.Entry.Section, row.Entry.Key, _editedValues[row.Entry.Id]))
            .ToList();
        if (edits.Count == 0)
        {
            return;
        }

        Busy = true;
        try
        {
            var currentDiskText = BepInExConfig.ReadTextOrNull(FilePath);
            if (currentDiskText is null)
            {
                StatusLine = $"Couldn't save: {Path.GetFileName(FilePath)} is no longer readable.";
                return;
            }

            var result = BepInExConfig.Applying(edits, currentDiskText);
            File.WriteAllText(FilePath, result.Text);
            Load();
            StatusLine = SaveStatusLine(result.Skipped.Count, ValheimRunning);
        }
        catch (Exception ex)
        {
            StatusLine = $"Couldn't save: {ex.Message}";
        }
        finally
        {
            Busy = false;
        }
    }

    private bool CanSave() => IsDirty && !Busy;

    private static string SaveStatusLine(int skippedCount, bool valheimRunning)
    {
        var line = "Saved.";
        if (skippedCount == 1)
        {
            line += " 1 setting no longer exists and was skipped.";
        }
        else if (skippedCount > 1)
        {
            line += $" {skippedCount} settings no longer exist and were skipped.";
        }
        if (valheimRunning)
        {
            line += " (applies next game launch)";
        }
        return line;
    }

    /// <summary>
    /// Called by the view whenever the window is asked to close (the header
    /// Close button, or the OS close box). Raises <see cref="CloseRequested"/>
    /// immediately when there's nothing to lose; otherwise shows the
    /// inline discard-confirmation overlay instead.
    /// </summary>
    public void RequestClose()
    {
        if (IsDirty && !_confirmedDiscard)
        {
            IsConfirmingClose = true;
            return;
        }
        CloseRequested?.Invoke();
    }

    [RelayCommand]
    private void ConfirmDiscardClose()
    {
        _confirmedDiscard = true;
        IsConfirmingClose = false;
        CloseRequested?.Invoke();
    }

    [RelayCommand]
    private void CancelClose() => IsConfirmingClose = false;

    public void RevealInExplorer()
    {
        try
        {
            System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{FilePath}\"");
        }
        catch
        {
            // Best effort — no Explorer on this platform/session.
        }
    }

    // MARK: - Staleness / game-running polling

    /// <summary>
    /// Starts the ~2s background poll for external file changes and
    /// Valheim's running state. Started by the view once the window opens;
    /// call <see cref="StopPolling"/> (or <see cref="Dispose"/>) when it
    /// closes.
    /// </summary>
    public void StartPolling()
    {
        _pollCts?.Cancel();
        var cts = new CancellationTokenSource();
        _pollCts = cts;
        _ = PollLoopAsync(cts.Token);
    }

    public void StopPolling()
    {
        _pollCts?.Cancel();
        _pollCts = null;
    }

    private async Task PollLoopAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            CheckForExternalChange();
            ValheimRunning = GameLocator.ValheimIsRunning();
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(2), token);
            }
            catch (TaskCanceledException)
            {
                break;
            }
        }
    }

    /// <summary>
    /// If the file's write time has moved past what it was at last load:
    /// silently reloads when there are no unsaved edits, or — when there
    /// are — just raises <see cref="ExternalChangeDetected"/> so a banner
    /// can explain that the pending edits will still be re-applied
    /// correctly on top at save time, without yanking the file out from
    /// under whatever the user is mid-edit on.
    /// </summary>
    public void CheckForExternalChange()
    {
        if (_loadedWriteTimeUtc is null)
        {
            return;
        }
        var current = TryGetWriteTimeUtc(FilePath);
        if (current is null || current <= _loadedWriteTimeUtc)
        {
            return;
        }

        if (IsDirty)
        {
            ExternalChangeDetected = true;
        }
        else
        {
            Load();
        }
    }

    private static DateTime? TryGetWriteTimeUtc(string path)
    {
        try
        {
            return File.Exists(path) ? File.GetLastWriteTimeUtc(path) : null;
        }
        catch
        {
            return null;
        }
    }

    public void Dispose() => StopPolling();
}
