using System.Collections.ObjectModel;
using Bifrost.Core.Models;
using Bifrost.Core.Services;
using Bifrost.Services;
using Bifrost.Theming;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace Bifrost.ViewModels;

/// <summary>
/// The Settings tab: detected paths, refresh index, open logs/app-data
/// folders, launch preference toggles, save backups, and the Appearance
/// theme picker. Mirrors the macOS app's SettingsView.swift.
/// </summary>
public partial class SettingsViewModel : ViewModelBase
{
    private readonly AppServices _services;
    private bool _loadingSettings;

    [ObservableProperty] private string _steamRoot = "";
    [ObservableProperty] private string? _gameDir;
    [ObservableProperty] private string _appDataDir = "";
    [ObservableProperty] private string _statusMessage = "";
    [ObservableProperty] private bool _isBusy;

    /// <summary>Every selectable palette, for Settings' Appearance section — see <see cref="ThemePalette.All"/>.</summary>
    public ObservableCollection<PaletteRowViewModel> Palettes { get; } = new();

    // MARK: - Launch preferences (persisted via AppServices.SaveSettings)

    [ObservableProperty] private bool _startSteamSilently;
    [ObservableProperty] private bool _backupSavesBeforeModdedLaunch;
    [ObservableProperty] private bool _showTrayIcon;
    [ObservableProperty] private bool _enableNxmProtocol;

    // MARK: - Nexus Mods

    [ObservableProperty] private string _nexusApiKeyInput = "";
    [ObservableProperty] private bool _nexusKeySaved;
    [ObservableProperty] private bool _isValidatingNexusKey;
    [ObservableProperty] private string? _nexusValidationLine;
    [ObservableProperty] private bool _nexusValidationFailed;

    // MARK: - Backups

    public ObservableCollection<BackupRowViewModel> Backups { get; } = new();
    [ObservableProperty] private bool _isBackingUpNow;
    [ObservableProperty] private string? _backupStatusLine;
    [ObservableProperty] private bool _isConfirmingRestore;
    [ObservableProperty] private BackupRowViewModel? _pendingRestore;
    public bool HasBackups => Backups.Count > 0;
    public string TotalBackupSize => BackupRowViewModel.FormatSize(Backups.Sum(b => b.Backup.ByteSize));

    public SettingsViewModel(AppServices services)
    {
        _services = services;
        Refresh();

        _loadingSettings = true;
        StartSteamSilently = _services.Settings.StartSteamSilently;
        BackupSavesBeforeModdedLaunch = _services.Settings.BackupSavesBeforeModdedLaunch;
        ShowTrayIcon = _services.Settings.ShowTrayIcon;
        EnableNxmProtocol = _services.Settings.EnableNxmProtocol;
        _loadingSettings = false;

        NexusKeySaved = WindowsCredentials.Read(WindowsCredentials.NexusApiKeyTarget) is not null;

        foreach (var palette in ThemePalette.All)
        {
            Palettes.Add(new PaletteRowViewModel(palette, palette.Id == ThemeStore.Instance.Current.Id));
        }

        Backups.CollectionChanged += (_, _) =>
        {
            OnPropertyChanged(nameof(HasBackups));
            OnPropertyChanged(nameof(TotalBackupSize));
        };
        ReloadBackups();
    }

    partial void OnStartSteamSilentlyChanged(bool value) => PersistSettings();
    partial void OnBackupSavesBeforeModdedLaunchChanged(bool value) => PersistSettings();
    partial void OnShowTrayIconChanged(bool value) => PersistSettings();

    partial void OnEnableNxmProtocolChanged(bool value)
    {
        PersistSettings();
        if (!_loadingSettings)
        {
            ApplyNxmProtocolRegistration(value);
        }
    }

    private void PersistSettings()
    {
        if (_loadingSettings)
        {
            return;
        }
        _services.SaveSettings(new AppSettings
        {
            StartSteamSilently = StartSteamSilently,
            BackupSavesBeforeModdedLaunch = BackupSavesBeforeModdedLaunch,
            ShowTrayIcon = ShowTrayIcon,
            EnableNxmProtocol = EnableNxmProtocol,
        });
    }

    /// <summary>Registers/unregisters the <c>nxm://</c> handler live when the Settings toggle changes, mirroring the same live-effect the tray-icon toggle already gets — no restart needed either way.</summary>
    private static void ApplyNxmProtocolRegistration(bool enabled)
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }
        if (enabled)
        {
            NxmProtocolRegistrar.Register(Environment.ProcessPath ?? Environment.GetCommandLineArgs()[0]);
        }
        else
        {
            NxmProtocolRegistrar.Unregister();
        }
    }

    [RelayCommand]
    private void SelectPalette(PaletteRowViewModel? row)
    {
        if (row is null)
        {
            return;
        }
        ThemeStore.Instance.Current = row.Palette;
        foreach (var candidate in Palettes)
        {
            candidate.IsSelected = candidate.Palette.Id == row.Palette.Id;
        }
    }

    private void Refresh()
    {
        SteamRoot = _services.GameLocator.SteamRoot;
        GameDir = _services.LocateGameDir();
        AppDataDir = BifrostPaths.AppDataDir;
    }

    [RelayCommand]
    private async Task RefreshIndexAsync()
    {
        IsBusy = true;
        try
        {
            var packages = await _services.ThunderstoreClient.FetchIndexAsync(force: true);
            StatusMessage = $"Refreshed — {packages.Count} packages.";
        }
        catch (Exception ex)
        {
            StatusMessage = $"Couldn't refresh: {ex.Message}";
        }
        finally
        {
            IsBusy = false;
        }
    }

    [RelayCommand]
    private void OpenLogsFolder()
    {
        if (GameDir is not null)
        {
            Launcher.OpenBepInExLog(GameDir);
        }
    }

    [RelayCommand]
    private void OpenPluginsFolder()
    {
        if (GameDir is not null)
        {
            Launcher.OpenPluginsFolder(GameDir);
        }
    }

    [RelayCommand]
    private void OpenAppDataFolder() => Launcher.OpenAppDataFolder();

    [RelayCommand]
    private void RefreshPaths() => Refresh();

    // MARK: - Backups

    private void ReloadBackups()
    {
        Backups.Clear();
        foreach (var backup in _services.SaveBackup.List())
        {
            Backups.Add(new BackupRowViewModel(backup));
        }
    }

    [RelayCommand]
    private async Task BackUpNowAsync()
    {
        IsBackingUpNow = true;
        try
        {
            var outcome = await Task.Run(() => _services.SaveBackup.BackupNow(SaveBackup.ManualReason));
            BackupStatusLine = outcome switch
            {
                SaveBackup.BackupOutcome.Created created =>
                    $"Backed up {created.Summary.FileCount} file{(created.Summary.FileCount == 1 ? "" : "s")} ({BackupRowViewModel.FormatSize(created.Summary.ByteSize)})",
                SaveBackup.BackupOutcome.Skipped skipped => skipped.Reason,
                _ => "Backup finished.",
            };
        }
        catch (Exception ex)
        {
            BackupStatusLine = $"Backup failed: {ex.Message}";
        }
        finally
        {
            IsBackingUpNow = false;
            ReloadBackups();
        }
    }

    [RelayCommand]
    private void OpenBackupsFolder() => Launcher.OpenBackupsFolder();

    // MARK: - Nexus Mods

    [RelayCommand]
    private void SaveNexusApiKey()
    {
        var trimmed = NexusApiKeyInput.Trim();
        if (trimmed.Length == 0)
        {
            return;
        }
        try
        {
            WindowsCredentials.Save(trimmed, WindowsCredentials.NexusApiKeyTarget);
            NexusKeySaved = true;
            NexusApiKeyInput = "";
            NexusValidationLine = null;
            NexusValidationFailed = false;
        }
        catch (Exception ex)
        {
            NexusValidationLine = $"Couldn't save key: {ex.Message}";
            NexusValidationFailed = true;
        }
    }

    [RelayCommand]
    private void RemoveNexusApiKey()
    {
        WindowsCredentials.Delete(WindowsCredentials.NexusApiKeyTarget);
        NexusKeySaved = false;
        NexusApiKeyInput = "";
        NexusValidationLine = null;
        NexusValidationFailed = false;
    }

    [RelayCommand]
    private async Task ValidateNexusKeyAsync()
    {
        var key = WindowsCredentials.Read(WindowsCredentials.NexusApiKeyTarget);
        if (key is null)
        {
            return;
        }
        IsValidatingNexusKey = true;
        try
        {
            var result = await new NexusClient().ValidateKeyAsync(key);
            NexusValidationLine = $"Connected as {result.Name} ({(result.IsPremium ? "Premium" : "Free")})";
            NexusValidationFailed = false;
        }
        catch (Exception ex)
        {
            NexusValidationLine = ex.Message;
            NexusValidationFailed = true;
        }
        finally
        {
            IsValidatingNexusKey = false;
        }
    }

    [RelayCommand]
    private void OpenNexusApiKeyPage() => Launcher.OpenUrl("https://www.nexusmods.com/users/myaccount?tab=api");

    /// <summary>Arms the inline restore-confirmation overlay for <paramref name="row"/> — see <see cref="IsConfirmingRestore"/>.</summary>
    [RelayCommand]
    private void RequestRestore(BackupRowViewModel? row)
    {
        if (row is null)
        {
            return;
        }
        PendingRestore = row;
        IsConfirmingRestore = true;
    }

    [RelayCommand]
    private void CancelRestore()
    {
        IsConfirmingRestore = false;
        PendingRestore = null;
    }

    [RelayCommand]
    private async Task ConfirmRestoreAsync()
    {
        var row = PendingRestore;
        IsConfirmingRestore = false;
        PendingRestore = null;
        if (row is null)
        {
            return;
        }

        try
        {
            var summary = await Task.Run(() => _services.SaveBackup.Restore(row.Backup, BifrostPaths.ValheimSaveDir));
            BackupStatusLine = $"Restored the backup from {row.DateDisplay} ({summary.FileCount} file{(summary.FileCount == 1 ? "" : "s")})";
        }
        catch (SaveBackup.GameRunningException ex)
        {
            BackupStatusLine = ex.Message;
        }
        catch (Exception ex)
        {
            BackupStatusLine = $"Restore failed: {ex.Message}";
        }
        ReloadBackups();
    }
}
