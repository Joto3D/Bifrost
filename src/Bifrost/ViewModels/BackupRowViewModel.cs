using Bifrost.Core.Services;

namespace Bifrost.ViewModels;

/// <summary>One row of Settings' Backups section, wrapping a <see cref="SaveBackup.Backup"/> with display-ready strings.</summary>
public sealed class BackupRowViewModel
{
    public SaveBackup.Backup Backup { get; }
    public string DateDisplay { get; }
    public string ReasonDisplay { get; }
    public string SizeDisplay { get; }

    public BackupRowViewModel(SaveBackup.Backup backup)
    {
        Backup = backup;
        DateDisplay = backup.Date.ToString("g");
        ReasonDisplay = backup.Reason;
        SizeDisplay = FormatSize(backup.ByteSize);
    }

    internal static string FormatSize(long bytes)
    {
        string[] units = { "B", "KB", "MB", "GB" };
        double size = bytes;
        var unitIndex = 0;
        while (size >= 1024 && unitIndex < units.Length - 1)
        {
            size /= 1024;
            unitIndex++;
        }
        return $"{size:0.#} {units[unitIndex]}";
    }
}
