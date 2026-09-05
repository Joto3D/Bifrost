namespace Bifrost.Core.Services;

/// <summary>
/// A tiny, line-oriented reader for Valve's VDF (KeyValues) text format,
/// scoped to exactly what Bifrost needs on Windows: reading
/// <c>libraryfolders.vdf</c> (to find every Steam library) and
/// <c>appmanifest_*.acf</c> (to find Valheim's install directory). Ported
/// from the macOS reference implementation's line-scanning approach in
/// <c>GameLocator.swift</c> — deliberately not a full recursive parser,
/// since Bifrost never needs to *write* Steam's VDF files on Windows (no
/// launch-options splicing here, unlike the Mac app's <c>SteamConfigurator</c>).
/// </summary>
public static class VdfParser
{
    /// <summary>
    /// Extracts the value for <c>"key" "value"</c> anywhere in a multi-line
    /// VDF blob (used for flat manifest files like appmanifest_*.acf).
    /// </summary>
    public static string? GetValue(string key, string contents)
    {
        foreach (var line in contents.Split('\n'))
        {
            var value = LineValue(key, line);
            if (value is not null)
            {
                return value;
            }
        }
        return null;
    }

    /// <summary>
    /// Extracts the value for <c>"key"    "value"</c> from a single VDF
    /// line.
    /// </summary>
    public static string? LineValue(string key, string line)
    {
        var trimmed = line.Trim();
        var quotedKey = $"\"{key}\"";
        if (!trimmed.StartsWith(quotedKey, StringComparison.Ordinal))
        {
            return null;
        }

        var afterKey = trimmed[quotedKey.Length..];
        return FirstQuotedToken(afterKey);
    }

    /// <summary>
    /// Every library folder path declared in <c>libraryfolders.vdf</c>'s
    /// contents. The modern format nests each library under a numeric key
    /// with its own <c>{ ... }</c> block carrying a <c>"path" "..."</c>
    /// line; the legacy flat format Steam used for years instead maps the
    /// numeric key straight to the path string
    /// (<c>"1"&#9;&#9;"D:\\SteamLibrary"</c>), with no nested block at all.
    /// Prefers any "path" lines found (modern format); only falls back to
    /// the legacy numeric-key-is-the-value reading when none are found, so
    /// a modern file's numeric app-id lines (e.g. under a library's "apps"
    /// block) are never misread as library paths.
    /// </summary>
    public static List<string> ParseLibraryFolderPaths(string contents)
    {
        var paths = new List<string>();
        foreach (var line in contents.Split('\n'))
        {
            var path = LineValue("path", line);
            if (path is not null && !paths.Contains(path))
            {
                paths.Add(path);
            }
        }
        if (paths.Count > 0)
        {
            return paths;
        }

        foreach (var line in contents.Split('\n'))
        {
            var pair = KeyValue(line);
            if (pair is not { } kv || !kv.Key.All(char.IsDigit) || kv.Key.Length == 0)
            {
                continue;
            }
            if (LooksLikePath(kv.Value) && !paths.Contains(kv.Value))
            {
                paths.Add(kv.Value);
            }
        }
        return paths;
    }

    /// <summary>
    /// Walks a nested VDF block structure by key (case-insensitive at every
    /// level, matching Steam's own inconsistent casing across files/versions)
    /// and returns the value of <paramref name="key"/> at depth 0 inside the
    /// block found by following <paramref name="path"/> — e.g. for
    /// <c>localconfig.vdf</c>'s <c>Playtime</c> stat (see
    /// <see cref="SagaStats"/>): <c>path = ["UserLocalConfigStore","Software","Valve","Steam","apps","892970"], key = "Playtime"</c>.
    /// Returns null if any path segment's block, or the final key, isn't
    /// found. A line-oriented splicer, not a tree-building parser — the same
    /// approach as the rest of this type, ported from the macOS reference
    /// implementation's <c>VDF.swift</c>.
    /// </summary>
    public static string? FindNestedValue(string key, IReadOnlyList<string> path, string contents)
    {
        var lines = contents.Split('\n');
        var start = 0;
        var end = lines.Length;
        foreach (var segment in path)
        {
            var block = FindChildBlock(segment, lines, start, end);
            if (block is null)
            {
                return null;
            }
            (start, end) = block.Value;
        }
        return FindKeyValueInRange(key, lines, start, end);
    }

    /// <summary>
    /// Scans depth-0 lines in <c>[start,end)</c> for a line that is solely
    /// one quoted token matching <paramref name="key"/> (case-insensitive),
    /// immediately followed (skipping blank lines) by a lone <c>{</c> line;
    /// returns the body range between that <c>{</c> and its matching
    /// closing <c>}</c> (found by brace-depth counting). Null on unbalanced
    /// braces or no match.
    /// </summary>
    private static (int Start, int End)? FindChildBlock(string key, string[] lines, int start, int end)
    {
        var depth = 0;
        for (var i = start; i < end; i++)
        {
            var trimmed = lines[i].Trim();
            if (depth == 0)
            {
                var tokens = QuotedTokens(lines[i]);
                if (tokens.Count == 1 && string.Equals(tokens[0], key, StringComparison.OrdinalIgnoreCase))
                {
                    var j = i + 1;
                    while (j < end && lines[j].Trim().Length == 0)
                    {
                        j++;
                    }
                    if (j < end && lines[j].Trim() == "{")
                    {
                        var braceDepth = 1;
                        var k = j + 1;
                        for (; k < end; k++)
                        {
                            var t = lines[k].Trim();
                            if (t == "{")
                            {
                                braceDepth++;
                            }
                            else if (t == "}")
                            {
                                braceDepth--;
                                if (braceDepth == 0)
                                {
                                    break;
                                }
                            }
                        }
                        return braceDepth == 0 ? (j + 1, k) : null;
                    }
                }
            }
            if (trimmed == "{")
            {
                depth++;
            }
            else if (trimmed == "}")
            {
                depth--;
            }
        }
        return null;
    }

    /// <summary>Within a block's body range, at depth 0 (skipping nested blocks), finds a line parsing to a ("key","value") pair whose key matches case-insensitively.</summary>
    private static string? FindKeyValueInRange(string key, string[] lines, int start, int end)
    {
        var depth = 0;
        for (var i = start; i < end; i++)
        {
            var trimmed = lines[i].Trim();
            if (depth == 0)
            {
                var tokens = QuotedTokens(lines[i]);
                if (tokens.Count >= 2 && string.Equals(tokens[0], key, StringComparison.OrdinalIgnoreCase))
                {
                    return tokens[1];
                }
            }
            if (trimmed == "{")
            {
                depth++;
            }
            else if (trimmed == "}")
            {
                depth--;
            }
        }
        return null;
    }

    private static bool LooksLikePath(string value) =>
        value.Contains('\\') || value.Contains('/') || (value.Length > 1 && value[1] == ':');

    /// <summary>The first two quoted, escape-aware tokens on a line, if present.</summary>
    private static (string Key, string Value)? KeyValue(string line)
    {
        var tokens = QuotedTokens(line);
        return tokens.Count >= 2 ? (tokens[0], tokens[1]) : null;
    }

    private static List<string> QuotedTokens(string line)
    {
        var tokens = new List<string>();
        var i = 0;
        while (i < line.Length)
        {
            if (line[i] != '"')
            {
                i++;
                continue;
            }
            i++;
            var content = new System.Text.StringBuilder();
            while (i < line.Length)
            {
                if (line[i] == '\\' && i + 1 < line.Length)
                {
                    content.Append(line[i + 1]);
                    i += 2;
                    continue;
                }
                if (line[i] == '"')
                {
                    i++;
                    break;
                }
                content.Append(line[i]);
                i++;
            }
            tokens.Add(content.ToString());
        }
        return tokens;
    }

    /// <summary>
    /// Extracts the first quoted, backslash-escape-aware token in
    /// <paramref name="text"/> — Valve's VDF format escapes a literal
    /// backslash as <c>\\</c> (paths on Windows are full of these), so a
    /// naive "text between the first two quote characters" scan would leave
    /// every path double-backslashed.
    /// </summary>
    private static string? FirstQuotedToken(string text)
    {
        var firstQuote = text.IndexOf('"');
        if (firstQuote < 0)
        {
            return null;
        }

        var content = new System.Text.StringBuilder();
        var i = firstQuote + 1;
        while (i < text.Length)
        {
            if (text[i] == '\\' && i + 1 < text.Length)
            {
                content.Append(text[i + 1]);
                i += 2;
                continue;
            }
            if (text[i] == '"')
            {
                return content.ToString();
            }
            content.Append(text[i]);
            i++;
        }
        return null; // unterminated quote
    }
}
