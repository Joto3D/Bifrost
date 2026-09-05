import Foundation

/// Builds a read-only "Saga" snapshot for Home's stats card: total Valheim
/// playtime (from Steam's `localconfig.vdf`), installed mod count and
/// multiplayer-safety breakdown, backup count/size, and world/character
/// names — all presented with a bit of viking flair.
///
/// Deliberately takes every input as a plain value rather than reaching out
/// and fetching things itself (manifest, index, backups, save directory,
/// localconfig text) — that keeps this trivially testable against fixtures
/// (see `DebugCheck`'s "fun" section) and lets `SagaCard` reuse state the
/// rest of the app has already loaded instead of re-fetching it. The only
/// I/O this file performs directly is a read-only directory listing of the
/// save directory to discover world/character file names and sizes.
enum SagaStats {
    /// One multiplayer-safety class's share of the installed mods (see
    /// `ModClassifier`).
    struct ClassCount: Sendable, Equatable {
        let modClass: ModClass
        let count: Int
    }

    /// One world or character save file (or pair of files, for a world),
    /// grouped by its name stem.
    struct SaveEntry: Sendable, Equatable, Identifiable {
        let name: String
        let byteSize: Int64
        var id: String { name }
    }

    struct Snapshot: Sendable, Equatable {
        /// `nil` when `localconfig.vdf` couldn't be read or had no
        /// `Playtime` entry for Valheim yet (a fresh Steam library, or the
        /// game has never been launched through Steam).
        var playtimeMinutes: Int?
        var modCount: Int
        /// Only classes with at least one installed mod, in `ModClass`'s
        /// declared order.
        var classBreakdown: [ClassCount]
        var backupCount: Int
        var backupTotalBytes: Int64
        var worlds: [SaveEntry]
        var characters: [SaveEntry]

        static let empty = Snapshot(playtimeMinutes: nil, modCount: 0, classBreakdown: [], backupCount: 0, backupTotalBytes: 0, worlds: [], characters: [])
    }

    /// Builds a snapshot from already-loaded pieces. `localConfigText` is
    /// the raw contents of the most-recently-used Steam profile's
    /// `localconfig.vdf` (see `SteamConfigurator.realLocalConfigURL`), or
    /// `nil` if it couldn't be read — every field degrades gracefully when
    /// its source is missing rather than throwing.
    static func snapshot(
        manifest: InstalledManifest,
        index: [ThunderstorePackage],
        backups: [SaveBackup.Backup],
        saveDir: URL,
        localConfigText: String?
    ) -> Snapshot {
        Snapshot(
            playtimeMinutes: localConfigText.flatMap(playtimeMinutes(inLocalConfig:)),
            modCount: manifest.mods.count,
            classBreakdown: classBreakdown(mods: manifest.mods, index: index),
            backupCount: backups.count,
            backupTotalBytes: backups.reduce(Int64(0)) { $0 + $1.byteSize },
            worlds: worldEntries(in: saveDir),
            characters: characterEntries(in: saveDir)
        )
    }

    /// Reads Valheim's (`892970`) `Playtime` key (minutes) from a
    /// `localconfig.vdf`'s text, via `VDF`/`SteamConfigurator.appPath` — the
    /// same splice path Bifrost already uses for `LaunchOptions`.
    static func playtimeMinutes(inLocalConfig text: String) -> Int? {
        VDF.value(forKey: "Playtime", atPath: SteamConfigurator.appPath, in: text).flatMap { Int($0) }
    }

    /// Classifies every installed mod (`ModClassifier`) and tallies counts
    /// per class, omitting classes with zero mods.
    static func classBreakdown(mods: [InstalledManifest.InstalledMod], index: [ThunderstorePackage]) -> [ClassCount] {
        var counts: [String: Int] = [:]
        for mod in mods {
            let classification = ModClassifier.classify(mod: mod, index: index)
            counts[classification.modClass.rawValue, default: 0] += 1
        }
        return ModClass.allCases.compactMap { modClass in
            guard let count = counts[modClass.rawValue], count > 0 else { return nil }
            return ClassCount(modClass: modClass, count: count)
        }
    }

    /// Every `.fwl`/`.db` pair under `worlds_local` (falling back to the
    /// legacy `worlds` directory), grouped by name stem with their combined
    /// size.
    static func worldEntries(in saveDir: URL) -> [SaveEntry] {
        entries(in: resolveDir(saveDir, primary: "worlds_local", legacy: "worlds"), matchingExtensions: ["fwl", "db"])
    }

    /// Every `.fch` under `characters_local` (falling back to the legacy
    /// `characters` directory), one entry per character.
    static func characterEntries(in saveDir: URL) -> [SaveEntry] {
        entries(in: resolveDir(saveDir, primary: "characters_local", legacy: "characters"), matchingExtensions: ["fch"])
    }

    private static func resolveDir(_ saveDir: URL, primary: String, legacy: String) -> URL {
        let primaryURL = saveDir.appendingPathComponent(primary)
        return FileManager.default.fileExists(atPath: primaryURL.path) ? primaryURL : saveDir.appendingPathComponent(legacy)
    }

    private static func entries(in dir: URL, matchingExtensions extensions: [String]) -> [SaveEntry] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return []
        }
        var sizeByStem: [String: Int64] = [:]
        for file in files {
            guard extensions.contains(file.pathExtension.lowercased()) else { continue }
            let stem = file.deletingPathExtension().lastPathComponent
            let size: Int = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            sizeByStem[stem, default: 0] += Int64(size)
        }
        return sizeByStem.map { SaveEntry(name: $0.key, byteSize: $0.value) }.sorted { $0.name < $1.name }
    }

    /// Short, viking-flavored one-line summaries of `snapshot`, in a fixed
    /// priority order (playtime, worlds, characters, mods, backups). Always
    /// returns at least one line, even when every source is missing.
    static func flavorLines(for snapshot: Snapshot) -> [String] {
        var lines: [String] = []

        if let minutes = snapshot.playtimeMinutes {
            let hours = minutes / 60
            lines.append("⚔️ \(hours) hour\(hours == 1 ? "" : "s") carved into the saga so far")
        }
        if !snapshot.worlds.isEmpty {
            lines.append("🌍 \(snapshot.worlds.count) world\(snapshot.worlds.count == 1 ? "" : "s") under your protection")
        }
        if !snapshot.characters.isEmpty {
            lines.append("🛡️ \(snapshot.characters.count) hero\(snapshot.characters.count == 1 ? "" : "es") answering the call")
        }
        if snapshot.modCount > 0 {
            lines.append("🔨 \(snapshot.modCount) mod\(snapshot.modCount == 1 ? "" : "s") reinforcing the longship")
        }
        if snapshot.backupCount > 0 {
            lines.append("💾 \(snapshot.backupCount) backup\(snapshot.backupCount == 1 ? "" : "s") guarding \(formatBytes(snapshot.backupTotalBytes)) of saga")
        }

        if lines.isEmpty {
            lines.append("🪓 No saga recorded yet — sharpen your axe and begin")
        }
        return lines
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
