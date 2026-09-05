import Foundation

/// Zips up Valheim's world/character saves before anything risky happens to
/// them (a modded launch, a manual click, a restore about to overwrite the
/// current state) and can restore one of those archives back out again.
///
/// The real save directory (`defaultSaveDir`,
/// `~/Library/Application Support/IronGate/Valheim`) holds more than just
/// saves — server lists, ban lists, a `Player.log` symlink — so a backup
/// archive is built by copying only the save-bearing subdirectories
/// (`savedSubdirectories`) into a throwaway staging directory and zipping
/// *that*, rather than zipping the save directory itself. `ditto`'s archive
/// form only accepts a single source path, and doesn't follow symlinks it
/// meets while traversing (only a top-level src argument), so a filtered
/// staging copy is the only reliable way to end up with a zip containing
/// exactly `worlds_local/`, `characters_local/`, and any legacy
/// `worlds`/`characters` dirs at its top level — which is also exactly what
/// `restore` needs to see to reproduce them under an arbitrary target dir.
///
/// An actor because every operation here is a handful of `ditto`
/// invocations and directory scans chained together — actor isolation keeps
/// concurrent calls (e.g. a manual "Back Up Now" click racing the
/// pre-launch hook) from interleaving mid-archive.
actor SaveBackup {
    // MARK: - Types

    /// What a completed backup or restore produced.
    struct Summary: Sendable, Equatable {
        let url: URL
        let fileCount: Int
        let byteSize: Int64
    }

    /// `backupNow`'s result: either a backup was actually created, or there
    /// was nothing worth backing up (no save dir yet — a fresh install with
    /// no world ever created).
    enum BackupOutcome: Sendable, Equatable {
        case created(Summary)
        case skipped(reason: String)
    }

    /// One archive already sitting in `backupsDir`, as parsed back out of
    /// its filename (see `parseFilename`).
    struct Backup: Sendable, Equatable, Identifiable, Hashable {
        let url: URL
        let date: Date
        let reason: String
        let byteSize: Int64

        var id: String { url.lastPathComponent }
    }

    enum SaveBackupError: LocalizedError, Sendable, Equatable {
        case gameRunning
        case archiveFailed(String)
        case extractionFailed(String)

        var errorDescription: String? {
            switch self {
            case .gameRunning:
                return "Valheim is currently running — close the game before restoring a backup."
            case .archiveFailed(let detail):
                return "Couldn't create the backup archive: \(detail)"
            case .extractionFailed(let detail):
                return "Couldn't restore the backup archive: \(detail)"
            }
        }
    }

    // MARK: - Locations

    /// The real Valheim save directory on macOS.
    static let defaultSaveDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/IronGate/Valheim")

    /// Where Bifrost keeps its own backup archives.
    static let defaultBackupsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Bifrost/backups")

    /// Subdirectories of the save dir that actually hold save data — the
    /// current format (`worlds_local`, `characters_local`) plus the legacy
    /// pre-existing names, included if a machine still has them lying
    /// around from an older Valheim version.
    static let savedSubdirectories = ["worlds_local", "characters_local", "worlds", "characters"]

    /// The reason string used for user-initiated backups. Backups with this
    /// reason are exempt from `prune()`'s automatic-backup cap.
    static let manualReason = "manual"

    /// How many automatic (non-manual) backups `prune()` keeps.
    static let autoRetentionCount = 15

    private let saveDir: URL
    private let backupsDir: URL

    init(saveDir: URL = SaveBackup.defaultSaveDir, backupsDir: URL = SaveBackup.defaultBackupsDir) {
        self.saveDir = saveDir
        self.backupsDir = backupsDir
    }

    // MARK: - Backup

    /// Zips whichever of `savedSubdirectories` exist under this instance's
    /// save dir into a new archive in `backupsDir`, named
    /// `<yyyyMMdd-HHmmss>-<reason>.zip`, then prunes old automatic backups.
    /// Returns `.skipped` rather than throwing if there's no save data at
    /// all yet (a fresh install with no world ever created) — that's an
    /// expected, unremarkable state, not a failure.
    @discardableResult
    func backupNow(reason: String) async throws -> BackupOutcome {
        try await archive(source: saveDir, reason: reason)
    }

    // MARK: - List

    /// Every backup currently in `backupsDir`, newest first. Entries whose
    /// filename doesn't match the `<timestamp>-<reason>.zip` shape are
    /// silently skipped rather than surfaced as errors — this only ever
    /// lists a directory Bifrost itself writes to, but a stray file
    /// shouldn't crash the list.
    func list() -> [Backup] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: backupsDir, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries.compactMap { url -> Backup? in
            guard url.pathExtension.lowercased() == "zip",
                  let parsed = Self.parseFilename(url.lastPathComponent) else { return nil }
            return Backup(url: url, date: parsed.date, reason: parsed.reason, byteSize: Self.fileSize(at: url))
        }
        .sorted { $0.date > $1.date }
    }

    // MARK: - Restore

    /// Restores `backup` into `targetDir` (the UI passes the real save dir;
    /// tests pass a throwaway temp dir). Refuses outright — before touching
    /// anything — if `isGameRunning` reports the game is running, since
    /// Valheim can be writing to the very files this is about to overwrite.
    /// Otherwise takes a "pre-restore" safety backup of whatever is
    /// currently in `targetDir` first, so a bad restore is itself
    /// recoverable, then extracts `backup`'s archive on top.
    @discardableResult
    func restore(
        backup: Backup,
        into targetDir: URL,
        isGameRunning: @Sendable () async -> Bool = { await SaveBackup.isRealGameRunning() }
    ) async throws -> Summary {
        if await isGameRunning() {
            throw SaveBackupError.gameRunning
        }

        _ = try await archive(source: targetDir, reason: "pre-restore")

        let fm = FileManager.default
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let result = try await ShellRunner.run("/usr/bin/ditto", ["-x", "-k", backup.url.path, targetDir.path])
        guard result.status == 0 else {
            throw SaveBackupError.extractionFailed(result.stderr)
        }

        let fileCount = Self.savedSubdirectories.reduce(0) { $0 + Self.countFiles(at: targetDir.appendingPathComponent($1)) }
        return Summary(url: targetDir, fileCount: fileCount, byteSize: backup.byteSize)
    }

    /// Default `isGameRunning` check for real restores: true if a process
    /// named "Valheim" is currently running.
    static func isRealGameRunning() async -> Bool {
        (try? await ShellRunner.run("/usr/bin/pgrep", ["-x", "Valheim"]))?.status == 0
    }

    // MARK: - Archive (shared by backupNow and restore's pre-restore step)

    /// Builds a throwaway staging directory containing only the
    /// save-bearing subdirectories that exist under `source`, zips that
    /// staging directory into `backupsDir` (see the type doc for why a
    /// staging copy, rather than zipping `source` directly, is necessary),
    /// then prunes. Used both for `backupNow` (source = this instance's
    /// configured save dir) and for `restore`'s pre-restore safety backup
    /// (source = the restore's target dir, whatever state it's currently
    /// in).
    private func archive(source: URL, reason: String) async throws -> BackupOutcome {
        let fm = FileManager.default
        let presentSubdirs = Self.savedSubdirectories.filter {
            fm.fileExists(atPath: source.appendingPathComponent($0).path)
        }
        guard !presentSubdirs.isEmpty else {
            return .skipped(reason: "No Valheim save data found at \(source.path)")
        }

        try fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)

        let stagingDir = fm.temporaryDirectory.appendingPathComponent("BifrostBackupStaging-\(UUID().uuidString)")
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingDir) }

        for subdir in presentSubdirs {
            let copyResult = try await ShellRunner.run("/usr/bin/ditto", [
                source.appendingPathComponent(subdir).path,
                stagingDir.appendingPathComponent(subdir).path,
            ])
            guard copyResult.status == 0 else {
                throw SaveBackupError.archiveFailed(copyResult.stderr)
            }
        }

        let archiveURL = backupsDir.appendingPathComponent("\(Self.timestampFormatter.string(from: Date()))-\(Self.sanitize(reason)).zip")
        let zipResult = try await ShellRunner.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", stagingDir.path, archiveURL.path])
        guard zipResult.status == 0 else {
            throw SaveBackupError.archiveFailed(zipResult.stderr)
        }

        let fileCount = presentSubdirs.reduce(0) { $0 + Self.countFiles(at: source.appendingPathComponent($1)) }
        let byteSize = Self.fileSize(at: archiveURL)

        prune()

        return .created(Summary(url: archiveURL, fileCount: fileCount, byteSize: byteSize))
    }

    /// Deletes automatic (non-`manualReason`) backups beyond
    /// `autoRetentionCount`, oldest first. Manual backups are never
    /// touched, regardless of how many there are.
    private func prune() {
        let automatic = list().filter { $0.reason != Self.manualReason }
        guard automatic.count > Self.autoRetentionCount else { return }
        for backup in automatic.dropFirst(Self.autoRetentionCount) {
            try? FileManager.default.removeItem(at: backup.url)
        }
    }

    private static func sanitize(_ reason: String) -> String {
        let cleaned = reason.replacingOccurrences(of: "/", with: "-")
        return cleaned.isEmpty ? "backup" : cleaned
    }

    private static func countFiles(at dir: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        var count = 0
        for case let url as URL in enumerator {
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true {
                count += 1
            }
        }
        return count
    }

    private static func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - Filename <-> (date, reason)

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    /// Parses `<yyyyMMdd-HHmmss.SSS>-<reason>.zip` back into its date and
    /// reason. The timestamp is a fixed 19 characters (15 for the legacy
    /// second-resolution form), so this looks for exactly that many
    /// characters followed by a "-" rather than splitting generically —
    /// `reason` itself may contain dashes (e.g. "pre-launch"). Millisecond
    /// precision keeps filenames unique and their sort order stable when
    /// several backups land within the same second.
    static func parseFilename(_ name: String) -> (date: Date, reason: String)? {
        guard name.hasSuffix(".zip") else { return nil }
        let stem = String(name.dropLast(4))
        for (length, formatter) in [(19, timestampFormatter), (15, legacyTimestampFormatter)] {
            guard stem.count > length + 1 else { continue }
            let timestampEnd = stem.index(stem.startIndex, offsetBy: length)
            guard stem[timestampEnd] == "-" else { continue }
            let timestampPart = String(stem[..<timestampEnd])
            let reason = String(stem[stem.index(after: timestampEnd)...])
            if let date = formatter.date(from: timestampPart), !reason.isEmpty {
                return (date, reason)
            }
        }
        return nil
    }

    private static let legacyTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()
}
