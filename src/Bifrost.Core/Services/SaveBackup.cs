using System.Globalization;
using System.IO.Compression;
using System.Text.RegularExpressions;

namespace Bifrost.Core.Services;

/// <summary>
/// Zips up Valheim's world/character saves before anything risky happens to
/// them (a modded launch, a manual click, a restore about to overwrite the
/// current state) and can restore one of those archives back out again.
/// Ported from the macOS reference implementation's <c>SaveBackup.swift</c>.
///
/// The real save directory (<see cref="BifrostPaths.ValheimSaveDir"/>) holds
/// more than just saves on macOS (server lists, ban lists, a Player.log
/// symlink); on Windows <c>AppData\LocalLow\IronGate\Valheim</c> is simpler,
/// but the same filtered-staging-copy approach is used regardless, so a
/// backup archive only ever contains <see cref="SavedSubdirectories"/> at its
/// top level — exactly what <see cref="Restore"/> needs to see to reproduce
/// them under an arbitrary target dir.
///
/// Unlike the macOS port's <c>actor</c> isolation (concurrent-call safety),
/// this is a plain sealed class — Bifrost's Windows UI never fires two
/// backup operations at once (a manual "Back Up Now" click and the
/// pre-launch hook both run on the UI's own single command-execution path),
/// so no extra synchronization is needed here.
/// </summary>
public sealed class SaveBackup
{
    public sealed record Summary(string Path, int FileCount, long ByteSize);

    public abstract record BackupOutcome
    {
        public sealed record Created(Summary Summary) : BackupOutcome;
        public sealed record Skipped(string Reason) : BackupOutcome;
    }

    public sealed record Backup(string Path, DateTime Date, string Reason, long ByteSize)
    {
        public string Id => System.IO.Path.GetFileName(Path);
    }

    public sealed class GameRunningException() : Exception("Valheim is currently running — close the game before restoring a backup.");
    public sealed class ArchiveFailedException(string detail) : Exception($"Couldn't create the backup archive: {detail}");
    public sealed class ExtractionFailedException(string detail) : Exception($"Couldn't restore the backup archive: {detail}");

    /// <summary>Subdirectories of the save dir that actually hold save data.</summary>
    public static readonly string[] SavedSubdirectories = { "worlds_local", "characters_local", "worlds", "characters" };

    /// <summary>The reason string used for user-initiated backups. Exempt from <see cref="Prune"/>'s automatic-backup cap.</summary>
    public const string ManualReason = "manual";

    /// <summary>How many automatic (non-manual) backups <see cref="Prune"/> keeps.</summary>
    public const int AutoRetentionCount = 15;

    private readonly string _saveDir;
    private readonly string _backupsDir;

    public SaveBackup(string? saveDir = null, string? backupsDir = null)
    {
        _saveDir = saveDir ?? BifrostPaths.ValheimSaveDir;
        _backupsDir = backupsDir ?? BifrostPaths.SaveBackupsDir;
    }

    // MARK: - Backup

    /// <summary>
    /// Zips whichever of <see cref="SavedSubdirectories"/> exist under this
    /// instance's save dir into a new archive in the backups dir, named
    /// <c>&lt;yyyyMMdd-HHmmss.fff&gt;-&lt;reason&gt;.zip</c>, then prunes old
    /// automatic backups. Returns <see cref="BackupOutcome.Skipped"/> rather
    /// than throwing if there's no save data at all yet.
    /// </summary>
    public BackupOutcome BackupNow(string reason) => Archive(_saveDir, reason);

    // MARK: - List

    /// <summary>Every backup currently in the backups dir, newest first.</summary>
    public List<Backup> List()
    {
        if (!Directory.Exists(_backupsDir))
        {
            return new List<Backup>();
        }
        var backups = new List<Backup>();
        foreach (var path in Directory.EnumerateFiles(_backupsDir, "*.zip"))
        {
            var parsed = ParseFilename(System.IO.Path.GetFileName(path));
            if (parsed is null)
            {
                continue;
            }
            backups.Add(new Backup(path, parsed.Value.Date, parsed.Value.Reason, FileSize(path)));
        }
        return backups.OrderByDescending(b => b.Date).ToList();
    }

    // MARK: - Restore

    /// <summary>
    /// Restores <paramref name="backup"/> into <paramref name="targetDir"/>.
    /// Refuses outright if <paramref name="isGameRunning"/> reports the game
    /// is running. Otherwise takes a "pre-restore" safety backup of whatever
    /// is currently in <paramref name="targetDir"/> first, then extracts
    /// <paramref name="backup"/>'s archive on top (merging — existing files
    /// not in the archive are left alone).
    /// </summary>
    public Summary Restore(Backup backup, string targetDir, Func<bool>? isGameRunning = null)
    {
        isGameRunning ??= GameLocator.ValheimIsRunning;
        if (isGameRunning())
        {
            throw new GameRunningException();
        }

        Archive(targetDir, "pre-restore");

        Directory.CreateDirectory(targetDir);
        try
        {
            ZipFile.ExtractToDirectory(backup.Path, targetDir, overwriteFiles: true);
        }
        catch (Exception ex)
        {
            throw new ExtractionFailedException(ex.Message);
        }

        var fileCount = SavedSubdirectories.Sum(subdir => CountFiles(System.IO.Path.Combine(targetDir, subdir)));
        return new Summary(targetDir, fileCount, backup.ByteSize);
    }

    // MARK: - Archive (shared by BackupNow and Restore's pre-restore step)

    private BackupOutcome Archive(string source, string reason)
    {
        var presentSubdirs = SavedSubdirectories.Where(subdir => Directory.Exists(System.IO.Path.Combine(source, subdir))).ToList();
        if (presentSubdirs.Count == 0)
        {
            return new BackupOutcome.Skipped($"No Valheim save data found at {source}");
        }

        Directory.CreateDirectory(_backupsDir);

        var stagingDir = System.IO.Path.Combine(Path.GetTempPath(), $"BifrostBackupStaging-{Guid.NewGuid()}");
        Directory.CreateDirectory(stagingDir);
        try
        {
            foreach (var subdir in presentSubdirs)
            {
                CopyDirectoryRecursive(System.IO.Path.Combine(source, subdir), System.IO.Path.Combine(stagingDir, subdir));
            }

            var archivePath = System.IO.Path.Combine(_backupsDir, $"{Timestamp()}-{Sanitize(reason)}.zip");
            try
            {
                ZipFile.CreateFromDirectory(stagingDir, archivePath, CompressionLevel.Optimal, includeBaseDirectory: false);
            }
            catch (Exception ex)
            {
                throw new ArchiveFailedException(ex.Message);
            }

            var fileCount = presentSubdirs.Sum(subdir => CountFiles(System.IO.Path.Combine(source, subdir)));
            var byteSize = FileSize(archivePath);

            Prune();

            return new BackupOutcome.Created(new Summary(archivePath, fileCount, byteSize));
        }
        finally
        {
            try { Directory.Delete(stagingDir, recursive: true); } catch { /* best effort */ }
        }
    }

    /// <summary>Deletes automatic (non-<see cref="ManualReason"/>) backups beyond <see cref="AutoRetentionCount"/>, oldest first. Manual backups are never touched.</summary>
    private void Prune()
    {
        var automatic = List().Where(b => b.Reason != ManualReason).ToList();
        if (automatic.Count <= AutoRetentionCount)
        {
            return;
        }
        foreach (var backup in automatic.Skip(AutoRetentionCount))
        {
            try { File.Delete(backup.Path); } catch { /* best effort */ }
        }
    }

    private static void CopyDirectoryRecursive(string src, string dst)
    {
        Directory.CreateDirectory(dst);
        foreach (var file in Directory.EnumerateFiles(src))
        {
            File.Copy(file, System.IO.Path.Combine(dst, System.IO.Path.GetFileName(file)), overwrite: true);
        }
        foreach (var dir in Directory.EnumerateDirectories(src))
        {
            CopyDirectoryRecursive(dir, System.IO.Path.Combine(dst, System.IO.Path.GetFileName(dir)));
        }
    }

    private static string Sanitize(string reason)
    {
        var cleaned = reason.Replace("/", "-").Replace("\\", "-");
        return cleaned.Length == 0 ? "backup" : cleaned;
    }

    private static int CountFiles(string dir)
    {
        if (!Directory.Exists(dir))
        {
            return 0;
        }
        return Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories).Count();
    }

    private static long FileSize(string path)
    {
        try { return new FileInfo(path).Length; } catch { return 0; }
    }

    // MARK: - Filename <-> (date, reason)

    private const string TimestampFormat = "yyyyMMdd-HHmmss.fff";
    private const string LegacyTimestampFormat = "yyyyMMdd-HHmmss";

    private static string Timestamp() => DateTime.Now.ToString(TimestampFormat, CultureInfo.InvariantCulture);

    /// <summary>
    /// Parses <c>&lt;timestamp&gt;-&lt;reason&gt;.zip</c> back into its date
    /// and reason. The timestamp is a fixed 19 characters (15 for the legacy
    /// second-resolution form used before millisecond precision was added to
    /// avoid a same-second pruning collision), so this looks for exactly
    /// that many characters followed by a "-" rather than splitting
    /// generically — <c>reason</c> itself may contain dashes (e.g.
    /// "pre-launch").
    /// </summary>
    public static (DateTime Date, string Reason)? ParseFilename(string name)
    {
        if (!name.EndsWith(".zip", StringComparison.Ordinal))
        {
            return null;
        }
        var stem = name[..^4];
        foreach (var (length, format) in new[] { (19, TimestampFormat), (15, LegacyTimestampFormat) })
        {
            if (stem.Length <= length + 1 || stem[length] != '-')
            {
                continue;
            }
            var timestampPart = stem[..length];
            var reason = stem[(length + 1)..];
            if (reason.Length == 0)
            {
                continue;
            }
            if (DateTime.TryParseExact(timestampPart, format, CultureInfo.InvariantCulture, DateTimeStyles.None, out var date))
            {
                return (date, reason);
            }
        }
        return null;
    }
}
