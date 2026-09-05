import Foundation

/// Exporting and importing Bifrost profiles for sharing a mod list with
/// friends — either Bifrost's own compact native format (a base64 string,
/// or a pretty-printed `.bifrostprofile` file) or, when reachable, direct
/// interop with r2modman/Thunderstore Mod Manager's "profile code" system
/// (`exportR2Code`/`importR2Code`), so a friend on Windows/Linux running
/// r2modman can generate a code Bifrost imports directly, and vice versa.
///
/// A profile only ever records membership + enabled state (see `Profile`);
/// sharing follows the same contract. The exported *version* travels along
/// for reference, but importing always re-resolves against the recipient's
/// own cached Thunderstore index and installs whatever that index currently
/// calls latest — exactly `ModManager.resolve`'s own long-standing
/// convention (Bifrost has never pinned exact dependency versions). When
/// the recipient's index has moved on since the export, that's surfaced as
/// a "substituted" version in the built `ImportPlan` rather than silently
/// applied.
enum ProfileShare {
    enum ProfileShareError: Error, CustomStringConvertible {
        case invalidFormat
        case unsupportedVersion(Int)
        case emptyMods
        case badResponse(status: Int)
        case r2xNotFound

        var description: String {
            switch self {
            case .invalidFormat:
                return "That doesn't look like a Bifrost share code or profile file"
            case .unsupportedVersion(let version):
                return "This profile was exported by a newer version of Bifrost (format \(version)) and can't be read"
            case .emptyMods:
                return "That profile has no shareable mods in it"
            case .badResponse(let status):
                return "Thunderstore's profile-code service returned HTTP \(status)"
            case .r2xNotFound:
                return "That profile code's archive didn't contain an export.r2x"
            }
        }
    }

    // MARK: - Native format

    /// One mod entry in the native exported JSON. `source`/`nexusModId` are
    /// only ever present together, marking a mod that was installed via
    /// the `nxm://` flow (`source == "nexus"`) — there's no Thunderstore
    /// identity to resolve on the recipient's end, so importing explains
    /// rather than resolves these (see `ImportPlan.UnresolvableReason`).
    /// `source == "local"` mods never appear here at all — see `export`.
    struct ExportedMod: Codable, Equatable, Sendable {
        var fullName: String
        var version: String
        var enabled: Bool
        var source: String?
        var nexusModId: Int?
    }

    /// The full shape of a native share — both the base64 string handed to
    /// `plan(nativeString:index:manifest:)` and the pretty-printed
    /// `.bifrostprofile` file are exactly this JSON. `bifrost` is a format
    /// version, bumped only if this shape ever needs a breaking change;
    /// `plan` rejects anything other than `1`.
    struct ExportedProfile: Codable, Equatable, Sendable {
        var bifrost: Int
        var name: String
        var mods: [ExportedMod]
    }

    /// What `export`/`exportFile` produced: the JSON document itself (for
    /// `exportFile` to write pretty-printed), the compact base64 string
    /// (for a share code), and the full names of any `source == "local"`
    /// mods that got left out because they have no identity a recipient
    /// could ever resolve.
    struct ExportOutcome: Sendable {
        let json: ExportedProfile
        let encodedString: String
        let skippedLocalMods: [String]
    }

    /// Builds a shareable export of `profile`, cross-referencing
    /// `manifest` for each mod's actual installed version/source (a
    /// `Profile.ProfileMod` itself only records membership + enabled
    /// state — see `Profile`). Three kinds of profile mod never make it
    /// into the export:
    ///  - `source == "local"`: no identity a recipient could ever resolve
    ///    against Thunderstore — collected into `skippedLocalMods` so the
    ///    caller can warn about them.
    ///  - not currently in `manifest` at all (the profile drifted from
    ///    what's actually installed) — there's no version to share, and
    ///    silently skipping matches how `ProfileStore.apply` already
    ///    treats a profile/manifest mismatch elsewhere.
    ///  - (neither of the above needs special-casing for `source ==
    ///    "nexus"`: those DO get exported, just marked — see `ExportedMod`.)
    static func export(profile: Profile, manifest: InstalledManifest) -> ExportOutcome {
        let installedByFullName = Dictionary(uniqueKeysWithValues: manifest.mods.map { ($0.fullName, $0) })

        var mods: [ExportedMod] = []
        var skippedLocal: [String] = []
        for profileMod in profile.mods {
            guard let installed = installedByFullName[profileMod.fullName] else { continue }
            guard installed.source != "local" else {
                skippedLocal.append(profileMod.fullName)
                continue
            }
            let isNexus = installed.source == "nexus"
            mods.append(ExportedMod(
                fullName: profileMod.fullName,
                version: installed.version,
                enabled: profileMod.enabled,
                source: isNexus ? "nexus" : nil,
                nexusModId: isNexus ? installed.nexusModId : nil
            ))
        }

        let json = ExportedProfile(bifrost: 1, name: profile.name, mods: mods)
        let compactData = (try? JSONEncoder().encode(json)) ?? Data()
        return ExportOutcome(json: json, encodedString: compactData.base64EncodedString(), skippedLocalMods: skippedLocal)
    }

    /// `export`, written pretty-printed to `url` (a `.bifrostprofile`
    /// file) instead of returned as a base64 string. Returns the same
    /// `skippedLocalMods` warning list `export` would.
    @discardableResult
    static func exportFile(profile: Profile, manifest: InstalledManifest, to url: URL) throws -> [String] {
        let outcome = export(profile: profile, manifest: manifest)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(outcome.json)
        try data.write(to: url, options: .atomic)
        return outcome.skippedLocalMods
    }

    /// Parses a native share string (as produced by `export`'s
    /// `encodedString`) and resolves it into an `ImportPlan` against
    /// `index`/`manifest`.
    static func plan(nativeString: String, index: [ThunderstorePackage], manifest: InstalledManifest) throws -> ImportPlan {
        guard let data = Data(base64Encoded: nativeString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ProfileShareError.invalidFormat
        }
        return try plan(nativeData: data, index: index, manifest: manifest)
    }

    /// Parses a native `.bifrostprofile` file (as produced by
    /// `exportFile`) and resolves it into an `ImportPlan` against
    /// `index`/`manifest`.
    static func plan(nativeFileURL url: URL, index: [ThunderstorePackage], manifest: InstalledManifest) throws -> ImportPlan {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ProfileShareError.invalidFormat
        }
        return try plan(nativeData: data, index: index, manifest: manifest)
    }

    private static func plan(nativeData data: Data, index: [ThunderstorePackage], manifest: InstalledManifest) throws -> ImportPlan {
        let decoded: ExportedProfile
        do {
            decoded = try JSONDecoder().decode(ExportedProfile.self, from: data)
        } catch {
            throw ProfileShareError.invalidFormat
        }
        guard decoded.bifrost == 1 else { throw ProfileShareError.unsupportedVersion(decoded.bifrost) }

        let normalized = decoded.mods.map {
            NormalizedMod(fullName: $0.fullName, version: $0.version, enabled: $0.enabled, isNexus: $0.source == "nexus", nexusModId: $0.nexusModId)
        }
        let name = decoded.name.trimmingCharacters(in: .whitespaces)
        return buildPlan(name: name.isEmpty ? "Imported Profile" : name, mods: normalized, index: index, manifest: manifest)
    }

    // MARK: - Plan

    /// What importing a shared profile would do, computed without
    /// changing anything — resolved against the recipient's own
    /// Thunderstore index and installed-mod manifest so it reflects
    /// exactly what `apply` would install/skip on THIS machine, before the
    /// caller confirms anything with the user.
    struct ImportPlan: Sendable, Equatable {
        /// Wants installing — not currently on this machine at all.
        /// `resolvedVersion` is what will actually be installed (the
        /// index's current latest for this mod, per `ModManager`'s
        /// always-latest convention); it differs from `requestedVersion`
        /// exactly when the exporter's version has since been superseded.
        struct ResolvableMod: Sendable, Equatable, Identifiable {
            var id: String { fullName }
            let fullName: String
            let requestedVersion: String
            let resolvedVersion: String
            let enabled: Bool
            var wasSubstituted: Bool { resolvedVersion != requestedVersion }
        }

        /// Already installed on this machine under the same full name —
        /// nothing to download, `apply` only needs to carry its imported
        /// `enabled` state into the new profile.
        struct AlreadyInstalledMod: Sendable, Equatable, Identifiable {
            var id: String { fullName }
            let fullName: String
            let installedVersion: String
            let enabled: Bool
        }

        enum UnresolvableReason: Sendable, Equatable {
            /// Not present in the recipient's cached Thunderstore index at
            /// all — could be a private/removed package, a game-specific
            /// index mismatch, or simply a stale local index cache.
            case notInIndex
            /// Exported with a `source == "nexus"` marker: this mod was
            /// installed via Nexus Mods, which has no shared identity
            /// `ModManager.resolve` can look up — the recipient has to
            /// grab it from Nexus themselves. `modId`, when present, is
            /// the exporter's own recorded Nexus mod id, so the UI can
            /// link straight to its Nexus page.
            case nexusOnly(modId: Int?)
        }

        struct UnresolvableMod: Sendable, Equatable, Identifiable {
            var id: String { fullName }
            let fullName: String
            let reason: UnresolvableReason
        }

        let importedName: String
        let resolvable: [ResolvableMod]
        let alreadyInstalled: [AlreadyInstalledMod]
        let unresolvable: [UnresolvableMod]

        /// Every mod that will actually land in the profile `apply`
        /// creates — installed fresh, or already present.
        var installableCount: Int { resolvable.count + alreadyInstalled.count }
        var isEmpty: Bool { installableCount == 0 }
    }

    /// A share-format-agnostic mod entry — both the native JSON and the
    /// r2modman YAML get normalized to this before `buildPlan` runs, so
    /// the actual resolution logic only has to be written once.
    private struct NormalizedMod {
        let fullName: String
        let version: String
        let enabled: Bool
        let isNexus: Bool
        let nexusModId: Int?
    }

    /// Classifies every mod in `mods` against `index`/`manifest`. Order of
    /// checks matters: a `source == "nexus"` marker always wins (there's
    /// nothing to resolve regardless of what else might be true of it),
    /// then an already-installed match, then a normal index lookup.
    private static func buildPlan(
        name: String,
        mods: [NormalizedMod],
        index: [ThunderstorePackage],
        manifest: InstalledManifest
    ) -> ImportPlan {
        let byFullName = Dictionary(uniqueKeysWithValues: index.map { ($0.fullName, $0) })
        let installedByFullName = Dictionary(uniqueKeysWithValues: manifest.mods.map { ($0.fullName, $0) })

        var resolvable: [ImportPlan.ResolvableMod] = []
        var alreadyInstalled: [ImportPlan.AlreadyInstalledMod] = []
        var unresolvable: [ImportPlan.UnresolvableMod] = []

        for mod in mods {
            if mod.isNexus {
                unresolvable.append(.init(fullName: mod.fullName, reason: .nexusOnly(modId: mod.nexusModId)))
                continue
            }
            if let installed = installedByFullName[mod.fullName] {
                alreadyInstalled.append(.init(fullName: mod.fullName, installedVersion: installed.version, enabled: mod.enabled))
                continue
            }
            guard let package = byFullName[mod.fullName], let latest = package.latestVersion else {
                unresolvable.append(.init(fullName: mod.fullName, reason: .notInIndex))
                continue
            }
            resolvable.append(.init(fullName: mod.fullName, requestedVersion: mod.version, resolvedVersion: latest.versionNumber, enabled: mod.enabled))
        }

        return ImportPlan(importedName: name, resolvable: resolvable, alreadyInstalled: alreadyInstalled, unresolvable: unresolvable)
    }

    // MARK: - Apply

    /// Installs every `plan.resolvable` mod (via `ModManager.resolve`
    /// through the ordinary `install(package:index:gameDir:)` path, so
    /// each one's own dependencies come along too, exactly like installing
    /// it from the Browse tab would), then creates a new profile carrying
    /// every resolvable-or-already-installed mod's imported enabled state.
    /// `plan.unresolvable` mods are never referenced by the created
    /// profile — they were already surfaced to the user via the plan
    /// itself before this was called.
    ///
    /// The new profile's name is `plan.importedName`, deduplicated against
    /// existing profile names as "name (2)", "name (3)", etc. Doesn't
    /// switch to the new profile or reconcile the real install's
    /// enabled/disabled state — same as every other profile-creation path
    /// (`ProfileStore.create`), applying is a separate, explicit step the
    /// caller already has (the Profiles sheet's own "Apply").
    @discardableResult
    static func apply(
        _ plan: ImportPlan,
        index: [ThunderstorePackage],
        modManager: ModManager,
        profileStore: ProfileStore,
        gameDir: URL,
        onProgress: @Sendable (ModManager.Progress) -> Void = { _ in }
    ) async throws -> Profile {
        let byFullName = Dictionary(uniqueKeysWithValues: index.map { ($0.fullName, $0) })
        for mod in plan.resolvable {
            guard let package = byFullName[mod.fullName] else { continue } // buildPlan already verified this; defensive only
            try await modManager.install(package: package, index: index, gameDir: gameDir, onProgress: onProgress)
        }

        var profileMods = plan.resolvable.map { Profile.ProfileMod(fullName: $0.fullName, enabled: $0.enabled) }
        profileMods += plan.alreadyInstalled.map { Profile.ProfileMod(fullName: $0.fullName, enabled: $0.enabled) }

        let name = await dedupedName(plan.importedName, profileStore: profileStore)
        return await profileStore.create(name: name, mods: profileMods)
    }

    private static func dedupedName(_ base: String, profileStore: ProfileStore) async -> String {
        let existingNames = Set(await profileStore.load().profiles.map(\.name))
        guard existingNames.contains(base) else { return base }
        var suffix = 2
        while existingNames.contains("\(base) (\(suffix))") {
            suffix += 1
        }
        return "\(base) (\(suffix))"
    }

    // MARK: - r2modman interop

    /// Thunderstore's own (undocumented but public, unauthenticated)
    /// "legacy profile" endpoints — the same ones r2modman/Thunderstore
    /// Mod Manager's own "Import/Export code" feature uses. Verified
    /// directly against the live API: `POST create/` with an arbitrary
    /// body returns `{"key": "<uuid>"}`, and `GET get/<uuid>/` 302s to a
    /// CDN URL serving that exact body back — the service is an opaque
    /// blob store keyed by UUID, with no format validation of its own, so
    /// what actually makes this interop rather than just a pastebin is
    /// putting real r2modman-shaped content (`export.r2x` YAML, zipped,
    /// base64-encoded) in the blob, matching the shape `r2modman-headless`
    /// (a third-party r2modman-compatible CLI) parses and the real
    /// r2modman GUI itself writes.
    private static let r2CreateURL = URL(string: "https://thunderstore.io/api/experimental/legacyprofile/create/")!

    private static func r2GetURL(code: String) -> URL {
        URL(string: "https://thunderstore.io/api/experimental/legacyprofile/get/\(code)/")!
    }

    /// r2modman's own share codes are bare UUIDs; Bifrost's native codes
    /// are base64 (of JSON starting `{"bifrost":1,...`) and never parse as
    /// one — so a pasted code's format alone tells the two apart, which is
    /// what the Import sheet's single paste field relies on to auto-detect
    /// which importer to call.
    static func looksLikeR2ModManCode(_ string: String) -> Bool {
        UUID(uuidString: string.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    /// Uploads `profile` as an r2modman-compatible profile code: builds an
    /// `export.r2x` YAML (the same `profileName`/`mods[].name` +
    /// `version.{major,minor,patch}` + `enabled` shape r2modman itself
    /// writes — verified against a real r2modman-produced fixture), zips
    /// it with `/usr/bin/zip` (no in-process zip library exists in this
    /// target — same convention `ModManager`/`DebugCheck`'s own fixtures
    /// use), base64-encodes the zip, and `POST`s that to Thunderstore's
    /// `legacyprofile/create/` endpoint. Returns the resulting code (a
    /// bare UUID) for the user to share.
    ///
    /// Like `export`, `source == "local"` mods have no shareable identity
    /// and are left out; unlike `export`, `source == "nexus"` mods are
    /// ALSO left out here — r2modman's format has no field for a
    /// non-Thunderstore origin at all, so there's nothing to mark them
    /// with the way the native format's `ExportedMod.source` does.
    /// Throws `.emptyMods` if that leaves nothing to share.
    static func exportR2Code(profile: Profile, manifest: InstalledManifest, session: URLSession = .shared) async throws -> String {
        let installedByFullName = Dictionary(uniqueKeysWithValues: manifest.mods.map { ($0.fullName, $0) })

        var lines = ["profileName: \(profile.name)", "mods:"]
        var includedAny = false
        for profileMod in profile.mods {
            guard let installed = installedByFullName[profileMod.fullName], installed.source == "thunderstore" else { continue }
            let (major, minor, patch) = versionComponents(installed.version)
            lines.append("  - name: \(profileMod.fullName)")
            lines.append("    version:")
            lines.append("      major: \(major)")
            lines.append("      minor: \(minor)")
            lines.append("      patch: \(patch)")
            lines.append("    enabled: \(profileMod.enabled)")
            includedAny = true
        }
        guard includedAny else { throw ProfileShareError.emptyMods }
        let r2x = lines.joined(separator: "\n") + "\n"

        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("Bifrost-R2Export-\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let r2xURL = workDir.appendingPathComponent("export.r2x")
        try r2x.write(to: r2xURL, atomically: true, encoding: .utf8)

        let zipURL = workDir.appendingPathComponent("export.r2z")
        let zipResult = try await ShellRunner.run("/usr/bin/zip", ["-X", zipURL.path, "export.r2x"], currentDirectory: workDir)
        guard zipResult.status == 0 else { throw ProfileShareError.invalidFormat }

        let zipData = try Data(contentsOf: zipURL)
        let base64 = zipData.base64EncodedString()

        var request = URLRequest(url: r2CreateURL)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(base64.utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ProfileShareError.badResponse(status: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        struct CreateResponse: Decodable { let key: String }
        return try JSONDecoder().decode(CreateResponse.self, from: data).key
    }

    /// Fetches an r2modman profile `code` (a bare UUID) from Thunderstore's
    /// `legacyprofile/get/` endpoint, base64-decodes the response,
    /// extracts its `export.r2x` (via `/usr/bin/ditto`, same as every
    /// other zip Bifrost extracts), parses it, and resolves the result
    /// into an `ImportPlan` — same shape and same resolution rules as a
    /// native import, so the UI shows both identically.
    static func importR2Code(_ code: String, index: [ThunderstorePackage], manifest: InstalledManifest, session: URLSession = .shared) async throws -> ImportPlan {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: trimmed) != nil else { throw ProfileShareError.invalidFormat }

        let (data, response) = try await session.data(from: r2GetURL(code: trimmed))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ProfileShareError.badResponse(status: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let base64String = String(data: data, encoding: .utf8),
              let zipData = Data(base64Encoded: base64String.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ProfileShareError.invalidFormat
        }

        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("Bifrost-R2Import-\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let zipURL = workDir.appendingPathComponent("import.r2z")
        try zipData.write(to: zipURL)
        let extractDir = workDir.appendingPathComponent("extracted")
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let dittoResult = try await ShellRunner.run("/usr/bin/ditto", ["-xk", zipURL.path, extractDir.path])
        guard dittoResult.status == 0 else { throw ProfileShareError.invalidFormat }

        guard let r2xURL = findR2x(in: extractDir), let r2xText = try? String(contentsOf: r2xURL, encoding: .utf8) else {
            throw ProfileShareError.r2xNotFound
        }

        let (profileName, parsedMods) = try parseR2x(r2xText)
        let normalized = parsedMods.map {
            NormalizedMod(fullName: $0.fullName, version: $0.version, enabled: $0.enabled, isNexus: false, nexusModId: nil)
        }
        return buildPlan(name: profileName, mods: normalized, index: index, manifest: manifest)
    }

    private static func findR2x(in dir: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent.lowercased() == "export.r2x" {
            return url
        }
        return nil
    }

    private struct ParsedR2xMod {
        let fullName: String
        let version: String
        let enabled: Bool
    }

    /// A deliberately minimal, hand-rolled reader for r2modman's
    /// `export.r2x` — not a general YAML parser, just enough to pull the
    /// handful of scalar keys that format actually carries
    /// (`profileName`, and per mod: `name`, `version.major/minor/patch`,
    /// `enabled`), tracked line by line regardless of exact indentation.
    /// Verified against a real r2modman-produced fixture (a public
    /// Valheim modpack export fetched for this feature's development),
    /// not just Bifrost's own output — see `exportR2Code`'s doc.
    private static func parseR2x(_ text: String) throws -> (profileName: String, mods: [ParsedR2xMod]) {
        var profileName = "Imported Profile"
        var mods: [ParsedR2xMod] = []

        var currentName: String?
        var currentMajor: Int?
        var currentMinor: Int?
        var currentPatch: Int?
        var currentEnabled: Bool?

        func flush() {
            guard let name = currentName else { return }
            let version = "\(currentMajor ?? 0).\(currentMinor ?? 0).\(currentPatch ?? 0)"
            mods.append(ParsedR2xMod(fullName: name, version: version, enabled: currentEnabled ?? true))
            currentName = nil
            currentMajor = nil
            currentMinor = nil
            currentPatch = nil
            currentEnabled = nil
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if trimmed.hasPrefix("profileName:") {
                profileName = yamlScalar(after: "profileName:", in: trimmed)
            } else if trimmed.hasPrefix("- name:") {
                flush()
                currentName = yamlScalar(after: "- name:", in: trimmed)
            } else if trimmed.hasPrefix("major:") {
                currentMajor = Int(yamlScalar(after: "major:", in: trimmed))
            } else if trimmed.hasPrefix("minor:") {
                currentMinor = Int(yamlScalar(after: "minor:", in: trimmed))
            } else if trimmed.hasPrefix("patch:") {
                currentPatch = Int(yamlScalar(after: "patch:", in: trimmed))
            } else if trimmed.hasPrefix("enabled:") {
                currentEnabled = yamlScalar(after: "enabled:", in: trimmed).lowercased() == "true"
            }
            // Everything else (bare "version:", "mods:", unrelated keys) is
            // structural or irrelevant to the fixed set of scalars above.
        }
        flush()

        guard !mods.isEmpty else { throw ProfileShareError.emptyMods }
        return (profileName, mods)
    }

    private static func yamlScalar(after prefix: String, in line: String) -> String {
        var value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func versionComponents(_ version: String) -> (major: Int, minor: Int, patch: Int) {
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        return (parts.count > 0 ? parts[0] : 0, parts.count > 1 ? parts[1] : 0, parts.count > 2 ? parts[2] : 0)
    }
}
