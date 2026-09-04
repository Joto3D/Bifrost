import Foundation

/// A tiny, line-oriented reader/splicer for BepInEx's `.cfg` (ConfigFile)
/// text format, scoped to exactly what Bifrost needs: `[Section]` headers,
/// `Key = value` entries, and the preceding comment block BepInEx itself
/// generates for every entry —
/// ```
/// ## <description, possibly wrapped across several `##` lines>
/// # Setting type: Toggle
/// # Default value: On
/// # Acceptable values: Off, On
/// Key = On
/// ```
/// (`# Acceptable value range: ...` shows up instead of `# Acceptable
/// values:` for clamped numeric settings, and BepInEx itself sometimes adds
/// its own extra `#`-prefixed explainer lines after those, e.g. for
/// multi-valued flag settings — those are tolerated but not modeled.)
///
/// This deliberately does not build a full parse tree or re-serialize the
/// document. Same philosophy as `VDF.swift`: every line outside the one
/// being changed is preserved byte-for-byte — `applying(_:to:)` mutates
/// only the specific `Key = value` line(s) that changed and leaves
/// everything else (comments, blank lines, other entries) untouched.
enum BepInExConfig {
    /// One `Key = value` entry, with whatever BepInEx's own preceding
    /// comment block told us about it.
    struct Entry: Sendable, Equatable, Identifiable {
        /// "Section/Key" — unique within one parsed file.
        var id: String { "\(section)/\(key)" }

        let section: String
        let key: String
        var rawValue: String
        let description: String?
        /// The literal type name from `# Setting type: ...`, e.g. "Toggle",
        /// "Boolean", "Single", "Int32", "KeyboardShortcut", "Vector3".
        let settingType: String?
        let defaultValue: String?
        /// The comma-separated list from `# Acceptable values: ...`, if
        /// present.
        let acceptableValues: [String]?
        /// The raw text of `# Acceptable value range: ...` (e.g. "From 1
        /// to 999"), if present, for numeric settings that are clamped
        /// rather than enumerated.
        let acceptableRange: String?
        /// Zero-based index into the source text's `\n`-split lines —
        /// where `applying(_:to:)` rewrites this entry's value.
        let lineIndex: Int

        /// True for BepInEx's two boolean conventions: `Toggle`
        /// (Off/On) and `Boolean` (true/false).
        var isBoolean: Bool {
            settingType == "Toggle" || settingType == "Boolean"
        }

        /// `rawValue` normalized to a `Bool`, tolerating both boolean
        /// conventions. `nil` if it's neither.
        var boolValue: Bool? {
            switch rawValue.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "on": return true
            case "false", "off": return false
            default: return nil
            }
        }

        /// The raw string a given `Bool` should round-trip to for this
        /// entry's own convention (`Toggle` -> Off/On, `Boolean` ->
        /// true/false).
        func rawValue(for bool: Bool) -> String {
            settingType == "Toggle" ? (bool ? "On" : "Off") : (bool ? "true" : "false")
        }
    }

    struct Section: Sendable, Equatable, Identifiable {
        var id: String { name }
        let name: String
        var entries: [Entry]
    }

    struct ConfigFile: Sendable, Equatable {
        var sections: [Section]

        static let empty = ConfigFile(sections: [])

        var allEntries: [Entry] { sections.flatMap(\.entries) }

        /// Every `KeyboardShortcut` entry across all sections, for keybind
        /// surfacing.
        var keyboardShortcuts: [Entry] {
            allEntries.filter { $0.settingType == "KeyboardShortcut" }
        }
    }

    /// A `.cfg` file discovered under `BepInEx/config`, with its heuristic
    /// association (see `associate`) to an installed mod's full name.
    struct DiscoveredConfig: Sendable, Equatable, Identifiable {
        let url: URL
        var id: URL { url }
        var fileName: String { url.lastPathComponent }
        let associatedFullName: String?
    }

    // MARK: - Parsing

    /// Parses `text` into sections and entries. Never throws — a
    /// malformed or empty file just yields empty/partial results, the same
    /// tolerant spirit as `VDF`'s line scanning.
    static func parse(_ text: String) -> ConfigFile {
        let lines = text.components(separatedBy: "\n")
        var sections: [Section] = []
        var currentSectionName: String?
        var currentEntries: [Entry] = []

        var pendingDescriptionLines: [String] = []
        var pendingSettingType: String?
        var pendingDefaultValue: String?
        var pendingAcceptableValues: [String]?
        var pendingAcceptableRange: String?

        func flushSection() {
            guard let name = currentSectionName else { return }
            sections.append(Section(name: name, entries: currentEntries))
            currentEntries = []
        }

        func resetPendingComment() {
            pendingDescriptionLines = []
            pendingSettingType = nil
            pendingDefaultValue = nil
            pendingAcceptableValues = nil
            pendingAcceptableRange = nil
        }

        for (index, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.count >= 2, trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                flushSection()
                currentSectionName = String(trimmed.dropFirst().dropLast())
                resetPendingComment()
                continue
            }

            if trimmed.hasPrefix("##") {
                let content = trimmed.hasPrefix("## ") ? String(trimmed.dropFirst(3)) : String(trimmed.dropFirst(2))
                pendingDescriptionLines.append(content)
                continue
            }

            if let value = fieldValue(after: "# Setting type:", in: trimmed) {
                pendingSettingType = value
                continue
            }
            if let value = fieldValue(after: "# Default value:", in: trimmed) {
                pendingDefaultValue = value
                continue
            }
            if let value = fieldValue(after: "# Acceptable values:", in: trimmed) {
                pendingAcceptableValues = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                continue
            }
            if let value = fieldValue(after: "# Acceptable value range:", in: trimmed) {
                pendingAcceptableRange = value
                continue
            }
            if trimmed.hasPrefix("#") {
                // Some other explanatory comment line BepInEx tacked on
                // (e.g. "Multiple values can be set..." after a
                // multi-valued Acceptable values line) — preserved on disk
                // untouched, just not modeled as one of our known fields.
                continue
            }

            if trimmed.isEmpty {
                continue
            }

            guard currentSectionName != nil, let parsedLine = parseKeyValueLine(rawLine) else {
                resetPendingComment()
                continue
            }

            let description = pendingDescriptionLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            currentEntries.append(Entry(
                section: currentSectionName!,
                key: parsedLine.key,
                rawValue: parsedLine.value,
                description: description.isEmpty ? nil : description,
                settingType: pendingSettingType,
                defaultValue: pendingDefaultValue,
                acceptableValues: pendingAcceptableValues,
                acceptableRange: pendingAcceptableRange,
                lineIndex: index
            ))
            resetPendingComment()
        }
        flushSection()
        return ConfigFile(sections: sections)
    }

    // MARK: - Writing

    /// Applies `changes` (line index -> new raw value) to `text`,
    /// rewriting only those `Key = value` lines and leaving every other
    /// byte untouched. Passing an empty `changes` returns `text` itself
    /// unchanged (byte-identical round trip). Callers should only include
    /// entries whose value actually differs from what was parsed — an
    /// entry edited back to its original value should simply be omitted.
    static func applying(_ changes: [Int: String], to text: String) -> String {
        guard !changes.isEmpty else { return text }
        var lines = text.components(separatedBy: "\n")
        for (lineIndex, newValue) in changes {
            guard lines.indices.contains(lineIndex), let parsed = parseKeyValueLine(lines[lineIndex]) else { continue }
            lines[lineIndex] = "\(parsed.key) = \(newValue)"
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Discovery / association

    /// Scans `configDir` for `.cfg` files and heuristically associates
    /// each with an installed mod's full name via `associate`.
    static func discoverConfigs(in configDir: URL, candidates: [(fullName: String, name: String)]) -> [DiscoveredConfig] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: configDir, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries
            .filter { $0.pathExtension.lowercased() == "cfg" }
            .map { url in
                DiscoveredConfig(url: url, associatedFullName: associate(cfgFileName: url.lastPathComponent, candidates: candidates))
            }
            .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    }

    /// The single best-matching `.cfg` file for one mod (`fullName`/
    /// `name`) in `configDir`, if any — used by the detail/row views that
    /// only care about one mod's config rather than the full list.
    static func findAssociatedConfig(in configDir: URL, fullName: String, name: String) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: configDir, includingPropertiesForKeys: nil) else {
            return nil
        }
        return entries.first { url in
            url.pathExtension.lowercased() == "cfg" &&
                associate(cfgFileName: url.lastPathComponent, candidates: [(fullName, name)]) != nil
        }
    }

    /// Heuristic association between a `.cfg` filename and a candidate
    /// mod's `fullName`/`name`: normalize both (lowercase, strip every
    /// non-alphanumeric character) and match if either normalized string
    /// contains the other. Returns the first matching candidate's
    /// `fullName`, or `nil`.
    static func associate(cfgFileName: String, candidates: [(fullName: String, name: String)]) -> String? {
        let base = (cfgFileName as NSString).deletingPathExtension
        let normalizedCfg = normalizedForMatching(base)
        guard !normalizedCfg.isEmpty else { return nil }

        for candidate in candidates {
            let normalizedFullName = normalizedForMatching(candidate.fullName)
            if !normalizedFullName.isEmpty, normalizedCfg.contains(normalizedFullName) || normalizedFullName.contains(normalizedCfg) {
                return candidate.fullName
            }
            let normalizedName = normalizedForMatching(candidate.name)
            if !normalizedName.isEmpty, normalizedCfg.contains(normalizedName) || normalizedName.contains(normalizedCfg) {
                return candidate.fullName
            }
        }
        return nil
    }

    private static func normalizedForMatching(_ string: String) -> String {
        string.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: - Line tokenizing

    /// Extracts the trimmed value following `prefix` when `line` starts
    /// with it, e.g. `fieldValue(after: "# Setting type:", in: "# Setting
    /// type: Toggle")` -> `"Toggle"`.
    private static func fieldValue(after prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    /// A `Key = value` line's key and value, or `nil` if the line doesn't
    /// contain a top-level `=` (so isn't a key/value line at all). The key
    /// may itself contain spaces (BepInEx entry names commonly do, e.g.
    /// "Lock Configuration"); everything before the *first* `=` is the
    /// key, everything after is the value — BepInEx never emits a raw
    /// (unescaped) `=` inside either.
    private static func parseKeyValueLine(_ line: String) -> (key: String, value: String)? {
        guard let equalsIndex = line.firstIndex(of: "=") else { return nil }
        let key = line[line.startIndex..<equalsIndex].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        let value = line[line.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces)
        return (key, value)
    }
}
