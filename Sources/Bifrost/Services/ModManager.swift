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
        case unsupportedFileType(url: URL)
        case nameCollision(fullName: String)

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
            case .unsupportedFileType(let url):
                return "\(url.lastPathComponent) isn't a .zip or .dll file"
            case .nameCollision(let fullName):
                return "\(fullName) is already installed"
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
    /// Used only for `updatesAvailable`'s `source == "nexus"` version
    /// checks (`NexusClient.modInfo`) — the nxm install flow itself
    /// (`installFromNexus`) resolves its own download URL upstream and
    /// hands this actor a plain URL to download, same as any other
    /// install.
    private let nexusClient: NexusClient
    let manifestURL: URL
    /// Where the loader special case installs the launch wrapper + mode
    /// file. Defaults to the real Bifrost support directory; tests exercising
    /// a fake `gameDir` must override this with a matching temp directory —
    /// `BepInExInstaller` takes no launch-dir default of its own precisely
    /// so this pairing has to be made explicit here instead of silently
    /// falling back to the real one (see `BepInExInstaller`'s init doc).
    let launchDir: URL

    /// - Parameters:
    ///   - session: Defaults to `.shared`. Overridable for tests.
    ///   - bepInExInstaller: Overridable for tests so the loader special
    ///     case can use an isolated `URLSession`.
    ///   - manifestURL: Defaults to the real Bifrost support directory;
    ///     tests should override this with a temp file.
    ///   - launchDir: Defaults to the real Bifrost launch directory; tests
    ///     that pass a fake `gameDir` to `install`/`resolve` must override
    ///     this with a matching temp directory.
    init(
        session: URLSession = .shared,
        bepInExInstaller: BepInExInstaller = BepInExInstaller(),
        manifestURL: URL = ModManager.defaultManifestURL,
        launchDir: URL = BepInExInstaller.defaultLaunchDir,
        nexusClient: NexusClient = NexusClient()
    ) {
        self.session = session
        self.bepInExInstaller = bepInExInstaller
        self.manifestURL = manifestURL
        self.launchDir = launchDir
        self.nexusClient = nexusClient
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
                let outcome = try await bepInExInstaller.install(gameDir: gameDir, launchDir: launchDir, manifestVersion: loaderVersion())
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

    private func recordInstalledMod(
        fullName: String,
        version: String,
        files: [String],
        source: String = "thunderstore",
        nexusModId: Int? = nil,
        nexusFileId: Int? = nil
    ) throws {
        var manifest = loadManifest()
        manifest.mods.removeAll { $0.fullName == fullName }
        manifest.mods.append(.init(fullName: fullName, version: version, enabled: true, files: files.sorted(), source: source, nexusModId: nexusModId, nexusFileId: nexusFileId))
        try save(manifest)
    }

    // MARK: - Install from file

    /// A minimal, lenient decode of a Thunderstore-style `manifest.json` —
    /// just enough to derive a stable identity and starting version for a
    /// local install that happens to carry one. `author` isn't part of
    /// Thunderstore's own documented schema (a package's author is site
    /// metadata, not manifest content), but some community packaging tools
    /// include it anyway, so it's read when present and folded into the
    /// derived full name the same way Thunderstore's own "Author-Name"
    /// convention would.
    private struct LocalPackageManifest: Decodable {
        let name: String?
        let versionNumber: String?
        let author: String?

        enum CodingKeys: String, CodingKey {
            case name
            case versionNumber = "version_number"
            case author
        }
    }

    /// Replaces every character outside `[A-Za-z0-9]` with `-`, collapses
    /// runs of `-`, and trims leading/trailing `-` — keeps a user-supplied
    /// file name or a manifest's free-text `name`/`author` field safe to use
    /// as a manifest full name and a `BepInEx/plugins` directory component.
    private static func sanitizeForFullName(_ raw: String) -> String {
        var result = String(raw.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" })
        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? "Mod" : result
    }

    /// Derives the manifest identity for a local install: if `payloadRoot`
    /// carries a parseable `manifest.json` with a non-empty `name`, uses
    /// that (folded with `author` when present, Thunderstore-"Author-Name"
    /// style; otherwise "Local-Name"), and its `version_number` when
    /// present. Otherwise falls back to "Local-<sanitized fallbackStem>"
    /// (the dropped-file or zip's own file name) and version
    /// "0.0.0-local" — Thunderstore payloads carry no other reliable
    /// version marker once extracted (see the type doc up top), and a
    /// local file carries even less.
    private static func resolveLocalIdentity(payloadRoot: URL?, fallbackStem: String) -> (fullName: String, version: String) {
        guard let payloadRoot,
              let data = try? Data(contentsOf: payloadRoot.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(LocalPackageManifest.self, from: data),
              let name = manifest.name, !name.isEmpty else {
            return ("Local-\(sanitizeForFullName(fallbackStem))", "0.0.0-local")
        }

        let sanitizedName = sanitizeForFullName(name)
        let fullName: String
        if let author = manifest.author, !author.isEmpty {
            fullName = "\(sanitizeForFullName(author))-\(sanitizedName)"
        } else {
            fullName = "Local-\(sanitizedName)"
        }
        let version = (manifest.versionNumber?.isEmpty == false) ? manifest.versionNumber! : "0.0.0-local"
        return (fullName, version)
    }

    /// An explicit identity to record instead of `resolveLocalIdentity`'s
    /// manifest.json-or-filename guessing — currently only used by the
    /// Nexus `nxm://` flow (`installFromNexus`), which already knows its
    /// mod's real name/author/version from Nexus's own API and has no use
    /// for a payload's bundled `manifest.json` even when one happens to be
    /// present. `nexusModId`/`nexusFileId` are recorded on the manifest
    /// entry so `updatesAvailable` can check back with Nexus later.
    struct IdentityOverride: Sendable {
        let fullName: String
        let version: String
        let source: String
        let nexusModId: Int?
        let nexusFileId: Int?
    }

    /// If `fullName` is already installed, either throws `.nameCollision`
    /// (the caller should offer the user a replace/skip choice) or, when
    /// `replaceExisting` is true, uninstalls the existing entry's files
    /// first so the fresh install starts from a clean slate.
    private func prepareForInstall(fullName: String, gameDir: URL, replaceExisting: Bool) throws {
        guard isInstalled(fullName: fullName) else { return }
        guard replaceExisting else { throw ModManagerError.nameCollision(fullName: fullName) }
        try uninstall(fullName: fullName, gameDir: gameDir)
    }

    /// Installs a mod from a local `.zip` or bare `.dll` file — the
    /// Nexus/GitHub/anywhere path, for mods that never went through
    /// Thunderstore at all. A `.zip` is extracted with the same `ditto`
    /// step `installMod` uses and mapped into `gameDir` with the exact
    /// same r2modman-compatible heuristics (`mapPayload`): a `BepInEx/`
    /// wrapper merges, `plugins`/`patchers`/`config`/`core` subdirs map
    /// individually, and a flat payload (including a Thunderstore-style
    /// zip carrying its own `manifest.json`/`icon.png`) falls back to one
    /// `BepInEx/plugins/<fullName>/` folder with Thunderstore's own
    /// metadata files filtered out. A bare `.dll` is copied straight into
    /// its own `BepInEx/plugins/<stem>/` folder.
    ///
    /// The installed identity is derived by `resolveLocalIdentity` — from
    /// a bundled `manifest.json` when the zip has one, otherwise from the
    /// file's own name — and recorded with `source: "local"` so
    /// `updatesAvailable` skips it and `uninstall`/`setEnabled` work
    /// exactly as they do for a Thunderstore install.
    ///
    /// If the derived identity collides with an already-installed mod,
    /// throws `ModManagerError.nameCollision` unless `replaceExisting` is
    /// true, in which case the existing install is uninstalled first. On
    /// success, returns the installed `fullName`.
    @discardableResult
    func installFromFile(
        url: URL,
        gameDir: URL,
        replaceExisting: Bool = false,
        identityOverride: IdentityOverride? = nil,
        onProgress: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> String {
        switch url.pathExtension.lowercased() {
        case "zip":
            return try await installZipFile(url: url, gameDir: gameDir, replaceExisting: replaceExisting, identityOverride: identityOverride, onProgress: onProgress)
        case "dll":
            return try await installDLLFile(url: url, gameDir: gameDir, replaceExisting: replaceExisting, identityOverride: identityOverride, onProgress: onProgress)
        default:
            throw ModManagerError.unsupportedFileType(url: url)
        }
    }

    private func installDLLFile(
        url: URL,
        gameDir: URL,
        replaceExisting: Bool,
        identityOverride: IdentityOverride?,
        onProgress: @Sendable (Progress) -> Void
    ) async throws -> String {
        let fm = FileManager.default
        let (fullName, version) = identityOverride.map { ($0.fullName, $0.version) }
            ?? Self.resolveLocalIdentity(payloadRoot: nil, fallbackStem: url.deletingPathExtension().lastPathComponent)

        try prepareForInstall(fullName: fullName, gameDir: gameDir, replaceExisting: replaceExisting)

        onProgress(.copyingFiles(fullName: fullName))
        let destDir = gameDir.appendingPathComponent("BepInEx/plugins/\(fullName)")
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        let destURL = destDir.appendingPathComponent(url.lastPathComponent)
        if fm.fileExists(atPath: destURL.path) {
            try fm.removeItem(at: destURL)
        }
        try fm.copyItem(at: url, to: destURL)
        let relative = relativePath(of: destURL, from: gameDir)

        _ = try? await ShellRunner.run("/usr/bin/xattr", ["-d", "com.apple.quarantine", destURL.path])

        try recordInstalledMod(
            fullName: fullName,
            version: version,
            files: [relative],
            source: identityOverride?.source ?? "local",
            nexusModId: identityOverride?.nexusModId,
            nexusFileId: identityOverride?.nexusFileId
        )
        onProgress(.done(fullName: fullName))
        return fullName
    }

    private func installZipFile(
        url: URL,
        gameDir: URL,
        replaceExisting: Bool,
        identityOverride: IdentityOverride?,
        onProgress: @Sendable (Progress) -> Void
    ) async throws -> String {
        let fm = FileManager.default
        let zipStem = url.deletingPathExtension().lastPathComponent

        let workDir = fm.temporaryDirectory.appendingPathComponent("Bifrost-LocalInstall-\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        onProgress(.extracting(fullName: zipStem))
        let extractDir = workDir.appendingPathComponent("extracted")
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let dittoResult = try await ShellRunner.run("/usr/bin/ditto", ["-xk", url.path, extractDir.path])
        guard dittoResult.status == 0 else {
            throw ModManagerError.extractionFailed(status: dittoResult.status)
        }

        let payloadRoot = try resolvePayloadRoot(extractDir: extractDir)
        let (fullName, version) = identityOverride.map { ($0.fullName, $0.version) }
            ?? Self.resolveLocalIdentity(payloadRoot: payloadRoot, fallbackStem: zipStem)

        try prepareForInstall(fullName: fullName, gameDir: gameDir, replaceExisting: replaceExisting)

        onProgress(.copyingFiles(fullName: fullName))
        let writtenFiles = try mapPayload(from: payloadRoot, gameDir: gameDir, fullName: fullName)
        guard !writtenFiles.isEmpty else { throw ModManagerError.emptyPayload(fullName: fullName) }

        for relativePath in writtenFiles {
            _ = try? await ShellRunner.run("/usr/bin/xattr", ["-d", "com.apple.quarantine", gameDir.appendingPathComponent(relativePath).path])
        }

        try recordInstalledMod(
            fullName: fullName,
            version: version,
            files: writtenFiles,
            source: identityOverride?.source ?? "local",
            nexusModId: identityOverride?.nexusModId,
            nexusFileId: identityOverride?.nexusFileId
        )
        onProgress(.done(fullName: fullName))
        return fullName
    }

    // MARK: - Install from Nexus

    /// Installs a mod fetched via the `nxm://` "Mod Manager Download"
    /// flow: downloads `downloadURL` (a resolved Nexus CDN mirror — see
    /// `NexusClient.downloadLink`) to a temp file, then feeds it through
    /// the exact same `installFromFile` pipeline a local drag-and-drop zip
    /// uses, with an `IdentityOverride` so the installed identity is
    /// Nexus's own "<author>-<name>" (sanitized the same way
    /// `resolveLocalIdentity` sanitizes a manifest.json's fields) and
    /// version, rather than anything guessed from the downloaded archive
    /// — recorded with `source: "nexus"` plus the mod/file ids so
    /// `updatesAvailable` can check back with Nexus for a newer version
    /// later.
    ///
    /// `author`/`name`/`version` come from `NexusClient.modInfo` (a file's
    /// specific version when the caller has one more precise than the
    /// mod's own `version`, otherwise the mod's version is fine — Nexus
    /// exposes both).
    @discardableResult
    func installFromNexus(
        downloadURL: URL,
        gameDir: URL,
        author: String,
        name: String,
        version: String,
        nexusModId: Int,
        nexusFileId: Int,
        replaceExisting: Bool = false,
        onProgress: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> String {
        let fullName = "\(Self.sanitizeForFullName(author))-\(Self.sanitizeForFullName(name))"

        onProgress(.downloading(fullName: fullName))
        let (downloadedURL, response) = try await session.download(from: downloadURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ModManagerError.badDownloadResponse(status: status)
        }

        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("Bifrost-NexusInstall-\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        // Nexus's CDN URLs carry the file's real name (with extension) in
        // their path even though the query string is what actually
        // authenticates the request, so this is safe unlike a fully
        // opaque URL would be; fall back to .zip (essentially every
        // Nexus Valheim mod file) if that's ever not true.
        let ext = downloadURL.pathExtension.isEmpty ? "zip" : downloadURL.pathExtension
        let stagedURL = workDir.appendingPathComponent("\(fullName).\(ext)")
        try fm.moveItem(at: downloadedURL, to: stagedURL)

        return try await installFromFile(
            url: stagedURL,
            gameDir: gameDir,
            replaceExisting: replaceExisting,
            identityOverride: IdentityOverride(fullName: fullName, version: version, source: "nexus", nexusModId: nexusModId, nexusFileId: nexusFileId),
            onProgress: onProgress
        )
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
    ///
    /// Mods installed from a local file (`source == "local"`) are never in
    /// the Thunderstore index under their derived identity, so they're
    /// skipped outright rather than compared. `source == "nexus"` entries
    /// are checked separately and live, against Nexus's own API
    /// (`NexusClient.modInfo`) rather than `index` — only when both a
    /// Keychain API key is configured *and* the entry carries a recorded
    /// `nexusModId` (an older nexus-sourced manifest entry might not);
    /// missing either skips that entry silently, same as a `local` mod,
    /// rather than erroring the whole check. Thunderstore behavior is
    /// otherwise unchanged.
    func updatesAvailable(index: [ThunderstorePackage]) async -> [UpdateInfo] {
        let byFullName = Dictionary(uniqueKeysWithValues: index.map { ($0.fullName, $0) })

        var results: [UpdateInfo] = []
        for mod in loadManifest().mods {
            if mod.source == "nexus" {
                if let update = await nexusUpdateInfo(for: mod) {
                    results.append(update)
                }
                continue
            }
            guard mod.source != "local" else { continue }
            guard let latest = byFullName[mod.fullName]?.latestVersion, latest.versionNumber != mod.version else {
                continue
            }
            results.append(UpdateInfo(fullName: mod.fullName, installedVersion: mod.version, latestVersion: latest.versionNumber))
        }
        return results
    }

    private func nexusUpdateInfo(for mod: InstalledManifest.InstalledMod) async -> UpdateInfo? {
        guard let modId = mod.nexusModId, let key = Keychain.read(service: Keychain.nexusAPIKeyService) else {
            return nil
        }
        guard let info = try? await nexusClient.modInfo(modId: modId, key: key), info.version != mod.version else {
            return nil
        }
        return UpdateInfo(fullName: mod.fullName, installedVersion: mod.version, latestVersion: info.version)
    }

    /// Uninstalls and reinstalls `fullName` at `index`'s current latest
    /// version, preserving its enabled state.
    func update(fullName: String, index: [ThunderstorePackage], gameDir: URL, onProgress: @Sendable (Progress) -> Void = { _ in }) async throws {
        guard let mod = loadManifest().mods.first(where: { $0.fullName == fullName }) else {
            throw ModManagerError.notInstalled(fullName: fullName)
        }
        guard mod.source != "local" else {
            throw ModManagerError.packageNotFound(fullName: fullName) // no Thunderstore identity to update against
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
