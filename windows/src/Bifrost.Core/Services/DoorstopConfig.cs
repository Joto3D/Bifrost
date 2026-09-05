using System.Text.RegularExpressions;

namespace Bifrost.Core.Services;

/// <summary>
/// A tiny, line-oriented reader/splicer for UnityDoorstop's
/// <c>doorstop_config.ini</c>, scoped to exactly what Bifrost needs on
/// Windows: the modded/vanilla toggle. Inspecting a real copy of the pack
/// (denikson-BepInExPack_Valheim) shows the file is a plain Windows INI with
/// a <c>[General]</c> section and an <c>enabled = true|false</c> key —
/// that's the switch Windows Valheim honors when winhttp.dll (the doorstop
/// shim) loads at startup.
///
/// Same surgical philosophy as the macOS reference implementation's
/// <c>VDF.swift</c> splicer for <c>localconfig.vdf</c>: every line outside
/// the one being changed is preserved byte-for-byte. If the key already
/// holds the desired value, the returned text is byte-identical
/// (<see cref="SpliceResult.Changed"/> is false).
/// </summary>
public static class DoorstopConfig
{
    private const string SectionHeader = "[General]";
    private static readonly Regex EnabledLine = new(@"^(\s*)enabled(\s*)=(\s*)(\S+)(.*)$", RegexOptions.IgnoreCase | RegexOptions.Compiled);

    public sealed record SpliceResult(string Text, bool Changed);

    /// <summary>
    /// Reads the current value of <c>enabled</c> under <c>[General]</c>, or
    /// <c>null</c> if the section/key can't be found.
    /// </summary>
    public static bool? GetEnabled(string text)
    {
        var lines = text.Split('\n');
        var inGeneral = false;
        foreach (var line in lines)
        {
            var trimmed = line.Trim();
            if (trimmed.StartsWith('[') && trimmed.EndsWith(']'))
            {
                inGeneral = trimmed.Equals(SectionHeader, StringComparison.OrdinalIgnoreCase);
                continue;
            }
            if (!inGeneral)
            {
                continue;
            }
            var match = EnabledLine.Match(line.TrimEnd('\r'));
            if (match.Success)
            {
                return ParseBool(match.Groups[4].Value);
            }
        }
        return null;
    }

    /// <summary>
    /// Sets <c>enabled</c> under <c>[General]</c> to <paramref name="value"/>.
    /// Rewrites only that one line — everything else, including the exact
    /// whitespace around <c>=</c> and any trailing comment on the line,
    /// round-trips untouched. If the key already holds the requested value,
    /// the returned text is byte-identical to <paramref name="text"/>. If
    /// <c>[General]</c> exists but has no <c>enabled</c> line, one is
    /// inserted right after the section header.
    /// </summary>
    public static SpliceResult SetEnabled(string text, bool value)
    {
        var lines = text.Split('\n');
        var sectionLineIndex = -1;
        var keyLineIndex = -1;

        for (var i = 0; i < lines.Length; i++)
        {
            var trimmed = lines[i].Trim();
            if (trimmed.StartsWith('[') && trimmed.EndsWith(']'))
            {
                if (trimmed.Equals(SectionHeader, StringComparison.OrdinalIgnoreCase))
                {
                    sectionLineIndex = i;
                }
                else if (sectionLineIndex >= 0 && keyLineIndex < 0)
                {
                    // Left [General]'s body without finding the key — stop.
                    break;
                }
                continue;
            }

            if (sectionLineIndex >= 0)
            {
                var match = EnabledLine.Match(lines[i].TrimEnd('\r'));
                if (match.Success)
                {
                    keyLineIndex = i;
                    break;
                }
            }
        }

        if (sectionLineIndex < 0)
        {
            throw new InvalidOperationException("doorstop_config.ini has no [General] section");
        }

        var desired = value ? "true" : "false";

        if (keyLineIndex >= 0)
        {
            var hadCr = lines[keyLineIndex].EndsWith('\r');
            var body = hadCr ? lines[keyLineIndex][..^1] : lines[keyLineIndex];
            var match = EnabledLine.Match(body);
            var currentValue = match.Groups[4].Value;
            if (string.Equals(currentValue, desired, StringComparison.OrdinalIgnoreCase))
            {
                return new SpliceResult(text, false);
            }

            var replaced = $"{match.Groups[1].Value}enabled{match.Groups[2].Value}={match.Groups[3].Value}{desired}{match.Groups[5].Value}";
            lines[keyLineIndex] = hadCr ? replaced + "\r" : replaced;
            return new SpliceResult(string.Join('\n', lines), true);
        }

        var newLines = lines.ToList();
        newLines.Insert(sectionLineIndex + 1, $"enabled = {desired}");
        return new SpliceResult(string.Join('\n', newLines), true);
    }

    private static bool? ParseBool(string raw) => raw.Trim().ToLowerInvariant() switch
    {
        "true" => true,
        "false" => false,
        _ => null,
    };
}
