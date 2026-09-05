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
