import Foundation

/// Installs, updates, enables/disables, and uninstalls Thunderstore mods
/// into the Valheim game directory, and owns Bifrost's manifest — the only
/// place a mod's installed *version* is tracked (see `InstalledManifest`).
///
/// Resolution and mapping follow r2modman-compatible conventions: a
/// dependency string is "Author-Name-Version" (Thunderstore's own
/// convention is that this is a *minimum* version, so Bifrost always
/// installs the dependency's current latest index version instead of the
/// exact pinned one), and `denikson-BepInExPack_Valheim` — the loader
/// pack — is special-cased to route through `BepInExInstaller` rather than
/// being unpacked as a plugin.
actor ModManager {
    enum ModManagerError: Error, CustomStringConvertible {
        case packageNotFound(fullName: String)
        case versionNotFound(fullName: String)
        case badDownloadResponse(status: Int)
        case extractionFailed(status: Int32)
        case emptyPayload(fullName: String)
        case notInstalled(fullName: String)

        var description: String {
            switch self {
            case .packageNotFound(let fullName):
                return "\(fullName) was not found in the cached Thunderstore index"
            case .versionNotFound(let fullName):
                return "\(fullName) has no published version in the index"
            case .badDownloadResponse(let status):
                return "Download failed with HTTP status \(status)"
            case .extractionFailed(let status):
                return "ditto extraction failed (exit \(status))"
            case .emptyPayload(let fullName):
                return "Extracted archive for \(fullName) contained no recognizable mod files"
            case .notInstalled(let fullName):
                return "\(fullName) is not installed"
            }
        }
    }

    /// One entry of a dependency-resolved install plan, in dependency-first
    /// order (installing in this order guarantees every mod's dependencies
    /// are already on disk by the time it's installed).
    enum ResolvedInstall: Sendable, Equatable {
        /// The BepInEx loader pack needs installing/updating. Carries no
        /// `ThunderstorePackage` — the loader is excluded from the regular
        /// package index (see `ThunderstoreClient`) and its version comes
        /// from `BepInExInstaller.fetchLatestVersionInfo()` instead.
        case loader
        case mod(fullName: String, package: ThunderstorePackage, version: ThunderstorePackage.Version)

        var fullName: String {
            switch self {
            case .loader: return ModManager.loaderFullName
            case .mod(let fullName, _, _): return fullName
            }
        }
    }

    /// One step of progress reported during an install.
    enum Progress: Sendable, Equatable {
        case installingLoader
        case downloading(fullName: String)
        case extracting(fullName: String)
        case copyingFiles(fullName: String)
        case done(fullName: String)
    }

    struct UpdateInfo: Sendable, Equatable {
        let fullName: String
        let installedVersion: String
        let latestVersion: String
    }

    static let loaderFullName = "denikson-BepInExPack_Valheim"

    /// Root-level files every Thunderstore package zip carries that are
    /// never part of the mod payload itself.
    private static let skippedRootFileNames: Set<String> = [
        "manifest.json", "icon.png", "readme.md", "changelog.md",
        "license", "license.md", "license.txt",
    ]
    private static let knownBepInExSubdirs = ["plugins", "patchers", "config", "core"]

    private let session: URLSession
    private let bepInExInstaller: BepInExInstaller
    let manifestURL: URL

    /// - Parameters:
    ///   - session: Defaults to `.shared`. Overridable for tests.
    ///   - bepInExInstaller: Overridable for tests so the loader special
    ///     case never touches a real launch setup.
    ///   - manifestURL: Defaults to the real Bifrost support directory;
    ///     tests should override this with a temp file.
    init(
        session: URLSession = .shared,
        bepInExInstaller: BepInExInstaller = BepInExInstaller(),
        manifestURL: URL = ModManager.defaultManifestURL
    ) {
        self.session = session
        self.bepInExInstaller = bepInExInstaller
        self.manifestURL = manifestURL
    }

    static var defaultManifestURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Bifrost/manifest.json")
    }

    // MARK: - Manifest I/O

    /// Loads the manifest from disk, or `.empty` if it doesn't exist yet or
    /// fails to parse.
    func loadManifest() -> InstalledManifest {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(InstalledManifest.self, from: data) else {
            return .empty
        }
        return manifest
    }

    private func save(_ manifest: InstalledManifest) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    func loaderVersion() -> String? { loadManifest().loader?.version }

    func isInstalled(fullName: String) -> Bool {
        loadManifest().mods.contains { $0.fullName == fullName }
    }

    func installedMod(fullName: String) -> InstalledManifest.InstalledMod? {
        loadManifest().mods.first { $0.fullName == fullName }
    }

    /// Records a loader version directly, without installing anything.
    /// Used to recover from a pre-Bifrost manual BepInEx install that has
    /// pack files on disk but no manifest record yet — the update-detection
    /// fix (`BepInExInstaller.dryRun`) only works once a version is on
    /// record.
    func setLoaderVersion(_ version: String) throws {
        var manifest = loadManifest()
        manifest.loader = .init(version: version)
        try save(manifest)
    }

    // MARK: - Resolve

    /// Resolves `package`'s latest version plus every dependency,
    /// recursively, against the given (already-fetched) Thunderstore
    /// `index`. Dependencies are looked up by full name and always
    /// resolved to the *index's* latest version, never the version pinned
    /// in the dependency string (Thunderstore's convention is that pin is a
    /// minimum). Already-installed-and-up-to-date entries are skipped
    /// entirely, and the loader special case is de-duplicated to at most
    /// one entry regardless of how many mods in the tree depend on it.
    ///
    /// Returns entries in dependency-first order: installing in this order
    /// guarantees every mod's dependencies are on disk first.
    func resolve(package: ThunderstorePackage, index: [ThunderstorePackage]) async throws -> [ResolvedInstall] {
        let manifest = loadManifest()
        let byFullName = Dictionary(uniqueKeysWithValues: index.map { ($0.fullName, $0) })

        var needsLoader = false
        var visited = Set<String>()
        var order: [ResolvedInstall] = []

        func visit(fullName: String) throws {
            if fullName == Self.loaderFullName {
                needsLoader = true
                return
            }
            guard !visited.contains(fullName) else { return }
            visited.insert(fullName)

            guard let pkg = byFullName[fullName] else {
                throw ModManagerError.packageNotFound(fullName: fullName)
            }
            guard let latest = pkg.latestVersion else {
                throw ModManagerError.versionNotFound(fullName: fullName)
            }

            // Dependencies first, so the returned order is dependency-first.
            for dependency in latest.dependencies {
                try visit(fullName: Self.fullName(fromDependencyID: dependency))
            }

            let installedVersion = manifest.mods.first { $0.fullName == fullName }?.version
            guard installedVersion != latest.versionNumber else { return } // up to date — nothing to do
            order.append(.mod(fullName: fullName, package: pkg, version: latest))
        }

        try visit(fullName: package.fullName)

        if needsLoader {
            let latestLoader = try? await bepInExInstaller.fetchLatestVersionInfo()
            let currentLoader = manifest.loader?.version
            if currentLoader == nil || currentLoader != latestLoader?.versionNumber {
                order.insert(.loader, at: 0)
            }
        }

        return order
    }

    /// "Author-Name-Version" -> "Author-Name". Version is always the
    /// trailing `x.y.z` component; splitting on the last `-` instead would
    /// break on names that themselves contain a hyphen.
    private static func fullName(fromDependencyID id: String) -> String {
        guard let versionRange = id.range(of: #"-\d+\.\d+\.\d+$"#, options: .regularExpression) else {
            return id
        }
        return String(id[id.startIndex..<versionRange.lowerBound])
    }

    // MARK: - Install

    /// Resolves `package` against `index` and installs the resulting plan
    /// into `gameDir`. Convenience for callers that don't need to show the
    /// plan for confirmation first; returns the plan that was installed.
    @discardableResult
    func install(
        package: ThunderstorePackage,
        index: [ThunderstorePackage],
        gameDir: URL,
        onProgress: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> [ResolvedInstall] {
        let plan = try await resolve(package: package, index: index)
        try await install(resolved: plan, gameDir: gameDir, onProgress: onProgress)
        return plan
    }

    /// Installs an already-resolved plan (see `resolve`), in order,
    /// special-casing the loader.
    func install(resolved: [ResolvedInstall], gameDir: URL, onProgress: @Sendable (Progress) -> Void = { _ in }) async throws {
        for item in resolved {
            switch item {
            case .loader:
                onProgress(.installingLoader)
                let outcome = try await bepInExInstaller.install(gameDir: gameDir, manifestVersion: loaderVersion())
                try setLoaderVersion(outcome.versionNumber)
            case .mod(let fullName, _, let version):
                try await installMod(fullName: fullName, version: version, gameDir: gameDir, onProgress: onProgress)
            }
        }
    }

    private func installMod(
        fullName: String,
        version: ThunderstorePackage.Version,
        gameDir: URL,
        onProgress: @Sendable (Progress) -> Void
    ) async throws {
        let fm = FileManager.default

        onProgress(.downloading(fullName: fullName))
        let (downloadedURL, response) = try await session.download(from: version.downloadURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ModManagerError.badDownloadResponse(status: status)
        }

        let workDir = fm.temporaryDirectory.appendingPathComponent("Bifrost-ModInstall-\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let zipURL = workDir.appendingPathComponent("\(fullName).zip")
        try fm.moveItem(at: downloadedURL, to: zipURL)

        onProgress(.extracting(fullName: fullName))
        let extractDir = workDir.appendingPathComponent("extracted")
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let dittoResult = try await ShellRunner.run("/usr/bin/ditto", ["-xk", zipURL.path, extractDir.path])
        guard dittoResult.status == 0 else {
            throw ModManagerError.extractionFailed(status: dittoResult.status)
        }

        onProgress(.copyingFiles(fullName: fullName))
        let payloadRoot = try resolvePayloadRoot(extractDir: extractDir)
        let writtenFiles = try mapPayload(from: payloadRoot, gameDir: gameDir, fullName: fullName)
        guard !writtenFiles.isEmpty else { throw ModManagerError.emptyPayload(fullName: fullName) }

        for relativePath in writtenFiles {
            _ = try? await ShellRunner.run("/usr/bin/xattr", ["-d", "com.apple.quarantine", gameDir.appendingPathComponent(relativePath).path])
        }

        try recordInstalledMod(fullName: fullName, version: version.versionNumber, files: writtenFiles)
        onProgress(.done(fullName: fullName))
    }

    /// If the extracted archive's only top-level entry is a single
    /// directory (some Thunderstore packages nest their whole payload in
    /// one wrapper folder), descends into it; otherwise returns the
    /// extraction root itself.
    private func resolvePayloadRoot(extractDir: URL) throws -> URL {
        let entries = try topLevelEntries(of: extractDir)
        if entries.count == 1, isDirectory(entries[0]) {
            return entries[0]
        }
        return extractDir
    }

    /// Maps an extracted payload into `gameDir` using r2modman-compatible
    /// heuristics, in priority order:
    ///  1. A `BepInEx/` directory at the root — merge that whole tree into
    ///     `<gameDir>/BepInEx/`.
    ///  2. Any of `plugins/`, `patchers/`, `config/`, `core/` at the root
    ///     (no `BepInEx/` wrapper) — map each into `<gameDir>/BepInEx/<dir>/`,
    ///     with `plugins/` content nested one level deeper under
    ///     `BepInEx/plugins/<fullName>/` so different mods' plugin DLLs
    ///     never collide.
    ///  3. Otherwise (a flat payload) — every `.dll`/`.pdb` plus sibling
    ///     asset files, excluding Thunderstore's own package metadata, into
    ///     `BepInEx/plugins/<fullName>/`.
    /// Returns the game-dir-relative paths of every file actually written.
    private func mapPayload(from root: URL, gameDir: URL, fullName: String) throws -> [String] {
        let entryNames = Set(try topLevelEntries(of: root).map { $0.lastPathComponent })

        if entryNames.contains("BepInEx") {
            return try copyTree(from: root.appendingPathComponent("BepInEx"), toRelative: "BepInEx", gameDir: gameDir)
        }

        let presentSubdirs = Self.knownBepInExSubdirs.filter { entryNames.contains($0) }
        if !presentSubdirs.isEmpty {
            var written: [String] = []
            for subdir in presentSubdirs {
                let src = root.appendingPathComponent(subdir)
                let destRelative = (subdir == "plugins") ? "BepInEx/plugins/\(fullName)" : "BepInEx/\(subdir)"
                written += try copyTree(from: src, toRelative: destRelative, gameDir: gameDir)
            }
            return written
        }

        let fm = FileManager.default
        let destRelative = "BepInEx/plugins/\(fullName)"
        let destRoot = gameDir.appendingPathComponent(destRelative)
        try fm.createDirectory(at: destRoot, withIntermediateDirectories: true)

        var written: [String] = []
        for relativeToRoot in relativeFilePaths(under: root) {
            guard !Self.skippedRootFileNames.contains((relativeToRoot as NSString).lastPathComponent.lowercased()) else { continue }
            let src = root.appendingPathComponent(relativeToRoot)
            let dest = destRoot.appendingPathComponent(relativeToRoot)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: src, to: dest)
            written.append(relativePath(of: dest, from: gameDir))
        }
        return written
    }

    /// Recursively copies every file under `src` into
    /// `gameDir/<destRelative>`, creating directories as needed and merging
    /// into whatever's already there. A `.cfg` file landing under
    /// `BepInEx/config` that would overwrite an existing file is skipped
    /// (preserves the user's settings) rather than overwritten. Returns the
    /// game-dir-relative paths of every file actually written.
    private func copyTree(from src: URL, toRelative destRelative: String, gameDir: URL) throws -> [String] {
        let fm = FileManager.default
        let destRoot = gameDir.appendingPathComponent(destRelative)
        var written: [String] = []

        for relativeToSrc in relativeFilePaths(under: src) {
            let file = src.appendingPathComponent(relativeToSrc)
            let dest = destRoot.appendingPathComponent(relativeToSrc)
            let gameRelative = relativePath(of: dest, from: gameDir)

            if gameRelative.hasPrefix("BepInEx/config/"), dest.pathExtension.lowercased() == "cfg", fm.fileExists(atPath: dest.path) {
                continue // preserve the user's existing config
            }

            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: file, to: dest)
            written.append(gameRelative)
        }
        return written
    }

    private func topLevelEntries(of dir: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { $0.lastPathComponent != "__MACOSX" }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    /// Every file (never directories) under `root`, as paths relative to
    /// `root`. Deliberately uses the string-`atPath` enumerator rather than
    /// the URL-based one: the URL enumerator resolves symlinks in the
    /// paths it returns (notably `/var` -> `/private/var`, which the whole
    /// system temp directory sits under), which would silently desync from
    /// `root`'s own unresolved path and corrupt every relative path
    /// computed against it. `atPath` sidesteps that entirely by returning
    /// paths already relative to what was passed in.
    private func relativeFilePaths(under root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var paths: [String] = []
        for case let relativePath as String in enumerator {
            let components = relativePath.split(separator: "/")
            guard components.first != "__MACOSX", !components.contains(where: { $0.hasPrefix(".") }) else { continue }
            var isDir: ObjCBool = false
            let fullPath = root.appendingPathComponent(relativePath).path
            guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue else { continue }
            paths.append(relativePath)
        }
        return paths
    }

    private func relativePath(of url: URL, from base: URL) -> String {
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard url.path.hasPrefix(basePath) else { return url.path }
        return String(url.path.dropFirst(basePath.count))
    }

    private func recordInstalledMod(fullName: String, version: String, files: [String]) throws {
        var manifest = loadManifest()
        manifest.mods.removeAll { $0.fullName == fullName }
        manifest.mods.append(.init(fullName: fullName, version: version, enabled: true, files: files.sorted()))
        try save(manifest)
    }

    // MARK: - Uninstall

    /// Deletes exactly the files `fullName`'s manifest entry recorded,
    /// cleans up any now-empty directories that leaves behind under
    /// `BepInEx/plugins`, and removes the manifest entry. Other mods'
    /// files are never touched.
    func uninstall(fullName: String, gameDir: URL) throws {
        var manifest = loadManifest()
        guard let index = manifest.mods.firstIndex(where: { $0.fullName == fullName }) else {
            throw ModManagerError.notInstalled(fullName: fullName)
        }
        let mod = manifest.mods[index]
        let fm = FileManager.default

        for relativePath in mod.files {
            try? fm.removeItem(at: gameDir.appendingPathComponent(relativePath))
        }

        let pluginsRoot = gameDir.appendingPathComponent("BepInEx/plugins")
        var candidateDirs = Set(mod.files.map { gameDir.appendingPathComponent($0).deletingLastPathComponent() })
        while !candidateDirs.isEmpty {
            var parents = Set<URL>()
            for dir in candidateDirs {
                guard dir.path.hasPrefix(pluginsRoot.path), dir.path != pluginsRoot.path else { continue }
                guard let contents = try? fm.contentsOfDirectory(atPath: dir.path), contents.isEmpty else { continue }
                try? fm.removeItem(at: dir)
                parents.insert(dir.deletingLastPathComponent())
            }
            candidateDirs = parents
        }

        manifest.mods.remove(at: index)
        try save(manifest)
    }

    // MARK: - Enable / disable

    /// Toggles every recorded `.dll`/`.dll.disabled` file for `fullName`
    /// between the two, updating the manifest's recorded paths to match so
    /// `uninstall` always deletes exactly what's on disk. Non-DLL files
    /// (config, assets, pdb) are left alone — BepInEx only loads `.dll`.
    func setEnabled(fullName: String, enabled: Bool, gameDir: URL) throws {
        var manifest = loadManifest()
        guard let index = manifest.mods.firstIndex(where: { $0.fullName == fullName }) else {
            throw ModManagerError.notInstalled(fullName: fullName)
        }
        guard manifest.mods[index].enabled != enabled else { return }

        let fm = FileManager.default
        var newFiles: [String] = []
        for relativePath in manifest.mods[index].files {
            guard relativePath.hasSuffix(".dll") || relativePath.hasSuffix(".dll.disabled") else {
                newFiles.append(relativePath)
                continue
            }

            let newRelativePath = enabled
                ? String(relativePath.dropLast(".disabled".count))
                : relativePath + ".disabled"

            let currentURL = gameDir.appendingPathComponent(relativePath)
            let newURL = gameDir.appendingPathComponent(newRelativePath)
            if fm.fileExists(atPath: currentURL.path) {
                try fm.moveItem(at: currentURL, to: newURL)
            }
            newFiles.append(newRelativePath)
        }

        manifest.mods[index].files = newFiles
        manifest.mods[index].enabled = enabled
        try save(manifest)
    }

    // MARK: - Updates

    /// Compares every installed mod's recorded version against `index`'s
    /// current latest, returning one entry per mod that has a newer
    /// version available.
    func updatesAvailable(index: [ThunderstorePackage]) -> [UpdateInfo] {
        let byFullName = Dictionary(uniqueKeysWithValues: index.map { ($0.fullName, $0) })
        return loadManifest().mods.compactMap { mod in
            guard let latest = byFullName[mod.fullName]?.latestVersion, latest.versionNumber != mod.version else {
                return nil
            }
            return UpdateInfo(fullName: mod.fullName, installedVersion: mod.version, latestVersion: latest.versionNumber)
        }
    }

    /// Uninstalls and reinstalls `fullName` at `index`'s current latest
    /// version, preserving its enabled state.
    func update(fullName: String, index: [ThunderstorePackage], gameDir: URL, onProgress: @Sendable (Progress) -> Void = { _ in }) async throws {
        guard let mod = loadManifest().mods.first(where: { $0.fullName == fullName }) else {
            throw ModManagerError.notInstalled(fullName: fullName)
        }
        guard let package = index.first(where: { $0.fullName == fullName }) else {
            throw ModManagerError.packageNotFound(fullName: fullName)
        }
        guard let latest = package.latestVersion else {
            throw ModManagerError.versionNotFound(fullName: fullName)
        }
        let wasEnabled = mod.enabled

        try uninstall(fullName: fullName, gameDir: gameDir)
        try await installMod(fullName: fullName, version: latest, gameDir: gameDir, onProgress: onProgress)

        if !wasEnabled {
            try setEnabled(fullName: fullName, enabled: false, gameDir: gameDir)
        }
    }
}
