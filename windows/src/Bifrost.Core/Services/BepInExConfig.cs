namespace Bifrost.Core.Services;

/// <summary>
/// A tiny, line-oriented reader/splicer for BepInEx's <c>.cfg</c> (ConfigFile)
/// text format, scoped to exactly what Bifrost needs: <c>[Section]</c>
/// headers, <c>Key = value</c> entries, and the preceding comment block
/// BepInEx itself generates for every entry —
/// <code>
/// ## &lt;description, possibly wrapped across several `##` lines&gt;
/// # Setting type: Toggle
/// # Default value: On
/// # Acceptable values: Off, On
/// Key = On
/// </code>
/// (<c># Acceptable value range: ...</c> shows up instead of
/// <c># Acceptable values:</c> for clamped numeric settings, and BepInEx
/// itself sometimes adds its own extra <c>#</c>-prefixed explainer lines
/// after those, e.g. for multi-valued flag settings — those are tolerated
/// but not modeled.)
///
/// Ported from the macOS reference implementation's <c>BepInExConfig.swift</c>,
/// including its later hardening pass (conflict-safe keyed saves, CRLF-safe
/// trimming). This deliberately does not build a full parse tree or
/// re-serialize the document — every line outside the one being changed is
/// preserved byte-for-byte; <see cref="Applying(IReadOnlyDictionary{int,string},string)"/>
/// mutates only the specific <c>Key = value</c> line(s) that changed and
/// leaves everything else (comments, blank lines, other entries) untouched.
///
/// Line splitting uses a bare <c>'\n'</c> split (matching the reference
/// implementation) and every trim below uses the parameterless
/// <see cref="string.Trim()"/> overload, which strips every Unicode
/// whitespace character — carriage returns included — rather than just
/// spaces/tabs. That matters because Windows <c>.cfg</c> files are commonly
/// CRLF-terminated: splitting on <c>'\n'</c> alone leaves a dangling
/// <c>'\r'</c> on every line, and a trim that didn't strip it would corrupt
/// section names, keys, and values alike (exactly the bug the macOS port's
/// own hardening pass had to fix, since Swift's <c>.whitespaces</c> character
/// set — unlike <c>.whitespacesAndNewlines</c> — doesn't include the
/// carriage-return control character).
/// </summary>
public static class BepInExConfig
{
    /// <summary>
    /// One <c>Key = value</c> entry, with whatever BepInEx's own preceding
    /// comment block told us about it.
    /// </summary>
    public sealed class Entry : IEquatable<Entry>
    {
        public string Section { get; }
        public string Key { get; }
        public string RawValue { get; }
        public string? Description { get; }

        /// <summary>
        /// The literal type name from <c># Setting type: ...</c>, e.g.
        /// "Toggle", "Boolean", "Single", "Int32", "KeyboardShortcut",
        /// "Vector3".
        /// </summary>
        public string? SettingType { get; }
        public string? DefaultValue { get; }

        /// <summary>The comma-separated list from <c># Acceptable values: ...</c>, if present.</summary>
        public IReadOnlyList<string>? AcceptableValues { get; }

        /// <summary>
        /// The raw text of <c># Acceptable value range: ...</c> (e.g. "From
        /// 1 to 999"), if present, for numeric settings that are clamped
        /// rather than enumerated.
        /// </summary>
        public string? AcceptableRange { get; }

        /// <summary>
        /// Zero-based index into the source text's <c>'\n'</c>-split lines
        /// — where <see cref="Applying(IReadOnlyDictionary{int,string},string)"/>
        /// rewrites this entry's value.
        /// </summary>
        public int LineIndex { get; }

        public Entry(
            string section,
            string key,
            string rawValue,
            string? description,
            string? settingType,
            string? defaultValue,
            IReadOnlyList<string>? acceptableValues,
            string? acceptableRange,
            int lineIndex)
        {
            Section = section;
            Key = key;
            RawValue = rawValue;
            Description = description;
            SettingType = settingType;
            DefaultValue = defaultValue;
            AcceptableValues = acceptableValues;
            AcceptableRange = acceptableRange;
            LineIndex = lineIndex;
        }

        /// <summary>"Section/Key" — unique within one parsed file.</summary>
        public string Id => $"{Section}/{Key}";

        /// <summary>
        /// True for BepInEx's two boolean conventions: "Toggle" (Off/On) and
        /// "Boolean" (true/false).
        /// </summary>
        public bool IsBoolean => SettingType is "Toggle" or "Boolean";

        /// <summary>
        /// <see cref="RawValue"/> normalized to a <see cref="bool"/>,
        /// tolerating both boolean conventions. <c>null</c> if it's neither.
        /// </summary>
        public bool? BoolValue => RawValue.Trim().ToLowerInvariant() switch
        {
            "true" or "on" => true,
            "false" or "off" => false,
            _ => null,
        };

        /// <summary>
        /// The raw string a given <see cref="bool"/> should round-trip to
        /// for this entry's own convention ("Toggle" -&gt; Off/On, "Boolean"
        /// -&gt; true/false).
        /// </summary>
        public string RawValueForBool(bool value) =>
            SettingType == "Toggle" ? (value ? "On" : "Off") : (value ? "true" : "false");

        public bool Equals(Entry? other)
        {
            if (other is null) return false;
            if (ReferenceEquals(this, other)) return true;
            return Section == other.Section
                && Key == other.Key
                && RawValue == other.RawValue
                && Description == other.Description
                && SettingType == other.SettingType
                && DefaultValue == other.DefaultValue
                && AcceptableRange == other.AcceptableRange
                && LineIndex == other.LineIndex
                && AcceptableValuesEqual(AcceptableValues, other.AcceptableValues);
        }

        private static bool AcceptableValuesEqual(IReadOnlyList<string>? a, IReadOnlyList<string>? b)
        {
            if (a is null || b is null) return a is null && b is null;
            return a.SequenceEqual(b);
        }

        public override bool Equals(object? obj) => Equals(obj as Entry);

        public override int GetHashCode() => HashCode.Combine(Section, Key, RawValue, LineIndex);
    }

    public sealed class Section
    {
        public string Name { get; }
        public List<Entry> Entries { get; }

        public Section(string name, List<Entry> entries)
        {
            Name = name;
            Entries = entries;
        }
    }

    public sealed class ConfigFile
    {
        public List<Section> Sections { get; }

        public ConfigFile(List<Section> sections) => Sections = sections;

        public static ConfigFile Empty => new(new List<Section>());

        public IEnumerable<Entry> AllEntries => Sections.SelectMany(s => s.Entries);

        /// <summary>Every <c>KeyboardShortcut</c> entry across all sections, for keybind surfacing.</summary>
        public IEnumerable<Entry> KeyboardShortcuts => AllEntries.Where(e => e.SettingType == "KeyboardShortcut");
    }

    /// <summary>
    /// A <c>.cfg</c> file discovered under <c>BepInEx/config</c>, with its
    /// heuristic association (see <see cref="Associate"/>) to an installed
    /// mod's full name.
    /// </summary>
    public sealed record DiscoveredConfig(string FilePath, string? AssociatedFullName)
    {
        public string FileName => Path.GetFileName(FilePath);
    }

    // MARK: - Parsing

    /// <summary>
    /// Parses <paramref name="text"/> into sections and entries. Never
    /// throws — a malformed or empty file just yields empty/partial
    /// results.
    /// </summary>
    public static ConfigFile Parse(string text)
    {
        var lines = text.Split('\n');
        var sections = new List<Section>();
        string? currentSectionName = null;
        var currentEntries = new List<Entry>();

        var pendingDescriptionLines = new List<string>();
        string? pendingSettingType = null;
        string? pendingDefaultValue = null;
        List<string>? pendingAcceptableValues = null;
        string? pendingAcceptableRange = null;

        void FlushSection()
        {
            if (currentSectionName is null) return;
            sections.Add(new Section(currentSectionName, currentEntries));
            currentEntries = new List<Entry>();
        }

        void ResetPendingComment()
        {
            pendingDescriptionLines = new List<string>();
            pendingSettingType = null;
            pendingDefaultValue = null;
            pendingAcceptableValues = null;
            pendingAcceptableRange = null;
        }

        for (var index = 0; index < lines.Length; index++)
        {
            var rawLine = lines[index];
            var trimmed = rawLine.Trim();

            if (trimmed.Length >= 2 && trimmed.StartsWith('[') && trimmed.EndsWith(']'))
            {
                FlushSection();
                currentSectionName = trimmed[1..^1];
                ResetPendingComment();
                continue;
            }

            if (trimmed.StartsWith("##", StringComparison.Ordinal))
            {
                var content = trimmed.StartsWith("## ", StringComparison.Ordinal) ? trimmed[3..] : trimmed[2..];
                pendingDescriptionLines.Add(content);
                continue;
            }

            if (TryFieldValue(trimmed, "# Setting type:", out var settingType)) { pendingSettingType = settingType; continue; }
            if (TryFieldValue(trimmed, "# Default value:", out var defaultValue)) { pendingDefaultValue = defaultValue; continue; }
            if (TryFieldValue(trimmed, "# Acceptable values:", out var acceptableValuesRaw))
            {
                pendingAcceptableValues = acceptableValuesRaw.Split(',').Select(v => v.Trim()).ToList();
                continue;
            }
            if (TryFieldValue(trimmed, "# Acceptable value range:", out var acceptableRange)) { pendingAcceptableRange = acceptableRange; continue; }
            if (trimmed.StartsWith('#'))
            {
                // Some other explanatory comment line BepInEx tacked on
                // (e.g. "Multiple values can be set..." after a
                // multi-valued Acceptable values line) — preserved on disk
                // untouched, just not modeled as one of our known fields.
                continue;
            }

            if (trimmed.Length == 0) continue;

            if (currentSectionName is null || !TryParseKeyValueLine(rawLine, out var key, out var value))
            {
                ResetPendingComment();
                continue;
            }

            var description = string.Join(" ", pendingDescriptionLines).Trim();
            currentEntries.Add(new Entry(
                currentSectionName,
                key,
                value,
                description.Length == 0 ? null : description,
                pendingSettingType,
                pendingDefaultValue,
                pendingAcceptableValues,
                pendingAcceptableRange,
                index));
            ResetPendingComment();
        }
        FlushSection();
        return new ConfigFile(sections);
    }

    // MARK: - Writing

    /// <summary>
    /// Applies <paramref name="changes"/> (line index -&gt; new raw value) to
    /// <paramref name="text"/>, rewriting only those <c>Key = value</c>
    /// lines and leaving every other byte untouched. Passing an empty
    /// <paramref name="changes"/> returns <paramref name="text"/> itself
    /// unchanged (byte-identical round trip, CRLF included). Callers should
    /// only include entries whose value actually differs from what was
    /// parsed — an entry edited back to its original value should simply be
    /// omitted.
    ///
    /// Line indices are only stable against the exact text they were parsed
    /// from — if <paramref name="text"/> may have changed since those
    /// indices were captured (e.g. the game rewrote the file while the
    /// editor was open), use
    /// <see cref="Applying(IReadOnlyList{KeyedChange},string)"/> instead,
    /// which re-targets each edit by (section, key) against
    /// <paramref name="text"/> as it stands right now.
    /// </summary>
    public static string Applying(IReadOnlyDictionary<int, string> changes, string text)
    {
        if (changes.Count == 0) return text;
        var lines = text.Split('\n');
        foreach (var (lineIndex, newValue) in changes)
        {
            if (lineIndex < 0 || lineIndex >= lines.Length) continue;
            if (!TryParseKeyValueLine(lines[lineIndex], out var key, out _)) continue;
            // Preserve a CRLF line's trailing "\r" on the specific line
            // being rewritten too, not just on every untouched line — a
            // porting improvement over the macOS reference, whose own
            // reconstructed line always drops it. Windows .cfg files are
            // routinely CRLF-terminated, and losing the "\r" on just the
            // edited line would otherwise leave the file with mixed line
            // endings after a single save.
            var hadCarriageReturn = lines[lineIndex].EndsWith('\r');
            lines[lineIndex] = hadCarriageReturn ? $"{key} = {newValue}\r" : $"{key} = {newValue}";
        }
        return string.Join("\n", lines);
    }

    /// <summary>
    /// One user edit addressed by (section, key) identity rather than a
    /// fixed line index — stays valid even if lines above it shifted or the
    /// file was rewritten entirely, as long as that section/key still
    /// exists somewhere in the target text.
    /// </summary>
    public sealed record KeyedChange(string Section, string Key, string Value);

    /// <summary>The result of a keyed <see cref="Applying(IReadOnlyList{KeyedChange},string)"/> pass.</summary>
    public sealed class KeyedApplyResult
    {
        /// <summary><paramref name="Text"/> with every still-existing change applied.</summary>
        public string Text { get; }

        /// <summary>
        /// Changes whose (section, key) could not be found in the target
        /// text — e.g. the mod that owns that setting rewrote its config
        /// without that key, or the section was renamed — and so were
        /// silently dropped rather than applied. Surfaced here so the
        /// caller can tell the user.
        /// </summary>
        public IReadOnlyList<KeyedChange> Skipped { get; }

        public KeyedApplyResult(string text, IReadOnlyList<KeyedChange> skipped)
        {
            Text = text;
            Skipped = skipped;
        }
    }

    /// <summary>
    /// Conflict-safe counterpart to
    /// <see cref="Applying(IReadOnlyDictionary{int,string},string)"/>:
    /// re-parses <paramref name="text"/> — which may be a completely
    /// different snapshot of the file than whatever <paramref name="changes"/>
    /// were originally computed against (the whole point: the game or
    /// another mod may have rewritten it since) — and re-targets each
    /// change by (section, key) rather than trusting a stale line index.
    /// Only edits whose (section, key) still exists in <paramref name="text"/>
    /// are applied; every entry untouched by <paramref name="changes"/>,
    /// including ones a concurrent external rewrite added or changed, is
    /// preserved byte-for-byte exactly as the line-indexed overload already
    /// guarantees.
    /// </summary>
    public static KeyedApplyResult Applying(IReadOnlyList<KeyedChange> changes, string text)
    {
        if (changes.Count == 0) return new KeyedApplyResult(text, Array.Empty<KeyedChange>());

        var current = Parse(text);
        var lineIndexById = new Dictionary<string, int>();
        foreach (var entry in current.AllEntries)
        {
            lineIndexById[entry.Id] = entry.LineIndex;
        }

        var lineChanges = new Dictionary<int, string>();
        var skipped = new List<KeyedChange>();
        foreach (var change in changes)
        {
            var id = $"{change.Section}/{change.Key}";
            if (lineIndexById.TryGetValue(id, out var lineIndex))
            {
                lineChanges[lineIndex] = change.Value;
            }
            else
            {
                skipped.Add(change);
            }
        }

        return new KeyedApplyResult(Applying(lineChanges, text), skipped);
    }

    // MARK: - Discovery / association

    /// <summary>
    /// Scans <paramref name="configDir"/> for <c>.cfg</c> files and
    /// heuristically associates each with an installed mod's full name via
    /// <see cref="Associate"/>.
    /// </summary>
    public static List<DiscoveredConfig> DiscoverConfigs(string configDir, IReadOnlyList<(string FullName, string Name)> candidates)
    {
        var files = ListCfgFiles(configDir);
        return files
            .Select(path => new DiscoveredConfig(path, Associate(Path.GetFileName(path), candidates)))
            .OrderBy(c => c.FileName, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    /// <summary>
    /// The single best-matching <c>.cfg</c> file for one mod
    /// (<paramref name="fullName"/>/<paramref name="name"/>) in
    /// <paramref name="configDir"/>, if any — used by callers that only
    /// care about one mod's config rather than the full list.
    /// </summary>
    public static string? FindAssociatedConfig(string configDir, string fullName, string name)
    {
        var candidates = new List<(string FullName, string Name)> { (fullName, name) };
        return ListCfgFiles(configDir).FirstOrDefault(path => Associate(Path.GetFileName(path), candidates) is not null);
    }

    private static List<string> ListCfgFiles(string configDir)
    {
        try
        {
            if (!Directory.Exists(configDir)) return new List<string>();
            return Directory.EnumerateFiles(configDir)
                .Where(f => Path.GetExtension(f).Equals(".cfg", StringComparison.OrdinalIgnoreCase))
                .ToList();
        }
        catch
        {
            return new List<string>();
        }
    }

    /// <summary>
    /// Heuristic association between a <c>.cfg</c> filename and a candidate
    /// mod's <paramref name="candidates"/>' FullName/Name: normalize both
    /// (lowercase, strip every non-alphanumeric character) and match if
    /// either normalized string contains the other. Returns the first
    /// matching candidate's FullName, or <c>null</c>.
    /// </summary>
    public static string? Associate(string cfgFileName, IReadOnlyList<(string FullName, string Name)> candidates)
    {
        var baseName = Path.GetFileNameWithoutExtension(cfgFileName);
        var normalizedCfg = NormalizedForMatching(baseName);
        if (normalizedCfg.Length == 0) return null;

        foreach (var candidate in candidates)
        {
            var normalizedFullName = NormalizedForMatching(candidate.FullName);
            if (normalizedFullName.Length > 0 && (normalizedCfg.Contains(normalizedFullName, StringComparison.Ordinal) || normalizedFullName.Contains(normalizedCfg, StringComparison.Ordinal)))
            {
                return candidate.FullName;
            }
            var normalizedName = NormalizedForMatching(candidate.Name);
            if (normalizedName.Length > 0 && (normalizedCfg.Contains(normalizedName, StringComparison.Ordinal) || normalizedName.Contains(normalizedCfg, StringComparison.Ordinal)))
            {
                return candidate.FullName;
            }
        }
        return null;
    }

    private static string NormalizedForMatching(string value) =>
        new(value.ToLowerInvariant().Where(char.IsLetterOrDigit).ToArray());

    // MARK: - File IO convenience

    /// <summary>
    /// Reads a file's full text, or <c>null</c> if it doesn't exist or
    /// can't be read — the same tolerant "never throw" spirit as
    /// <see cref="Parse"/>, used throughout the config editor UI so callers
    /// don't each repeat their own try/catch.
    /// </summary>
    public static string? ReadTextOrNull(string path)
    {
        try
        {
            return File.Exists(path) ? File.ReadAllText(path) : null;
        }
        catch
        {
            return null;
        }
    }

    // MARK: - Line tokenizing

    /// <summary>
    /// Extracts the trimmed value following <paramref name="prefix"/> when
    /// <paramref name="line"/> starts with it, e.g.
    /// <c>TryFieldValue("# Setting type: Toggle", "# Setting type:", out value)</c>
    /// -&gt; <c>value == "Toggle"</c>.
    /// </summary>
    private static bool TryFieldValue(string line, string prefix, out string value)
    {
        if (!line.StartsWith(prefix, StringComparison.Ordinal))
        {
            value = "";
            return false;
        }
        value = line[prefix.Length..].Trim();
        return true;
    }

    /// <summary>
    /// A <c>Key = value</c> line's key and value, or <c>false</c> if the
    /// line doesn't contain a top-level <c>=</c> (so isn't a key/value line
    /// at all). The key may itself contain spaces (BepInEx entry names
    /// commonly do, e.g. "Lock Configuration"); everything before the
    /// <b>first</b> <c>=</c> is the key, everything after is the value —
    /// BepInEx never emits a raw (unescaped) <c>=</c> inside either.
    /// </summary>
    private static bool TryParseKeyValueLine(string line, out string key, out string value)
    {
        var equalsIndex = line.IndexOf('=');
        if (equalsIndex < 0)
        {
            key = "";
            value = "";
            return false;
        }
        key = line[..equalsIndex].Trim();
        if (key.Length == 0)
        {
            value = "";
            return false;
        }
        value = line[(equalsIndex + 1)..].Trim();
        return true;
    }
}
