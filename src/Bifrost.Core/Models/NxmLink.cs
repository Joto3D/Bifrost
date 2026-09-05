namespace Bifrost.Core.Models;

/// <summary>
/// A parsed <c>nxm://</c> "Mod Manager Download" link — what Nexus's website
/// hands off to whatever's registered for the scheme (Bifrost, via the
/// Windows registry — see <c>Services.NxmProtocolRegistrar</c>) when a user
/// clicks "Mod Manager Download" on a mod page. Shape:
/// <c>nxm://&lt;game domain&gt;/mods/&lt;modId&gt;/files/&lt;fileId&gt;?key=...&amp;expires=...&amp;user_id=...</c>
///
/// <c>Key</c>/<c>Expires</c> are present only for a free-account "Slow
/// download" click — Nexus's own time-limited, IP-locked signature for that
/// specific download, required as query parameters on
/// <c>download_link.json</c> for a non-premium API key (see
/// <see cref="Services.NexusClient.DownloadLinkAsync"/>). A premium
/// account's link omits them entirely, since a premium key works against
/// that endpoint on its own. Ported from the macOS reference
/// implementation's <c>NxmLink.swift</c>.
/// </summary>
public sealed record NxmLink(string GameDomain, int ModId, int FileId, string? Key, string? Expires)
{
    public abstract class ParseException(string message) : Exception(message)
    {
        public sealed class Malformed() : ParseException("That doesn't look like a valid Nexus Mod Manager Download link");

        public sealed class WrongGame(string game) : ParseException($"That link is for {game}, not Valheim")
        {
            public string Game { get; } = game;
        }
    }

    /// <summary>
    /// Parses <paramref name="url"/>, requiring scheme "nxm" and game domain
    /// "valheim". Any other game's domain throws <see cref="ParseException.WrongGame"/>
    /// (carrying that domain) so the caller can show a friendly, specific
    /// alert rather than a generic parse failure; anything else malformed
    /// (wrong scheme, no host, unexpected path shape, non-numeric ids)
    /// throws <see cref="ParseException.Malformed"/>.
    /// </summary>
    public static NxmLink Parse(string rawUrl)
    {
        Uri url;
        try
        {
            url = new Uri(rawUrl);
        }
        catch
        {
            throw new ParseException.Malformed();
        }

        if (!string.Equals(url.Scheme, "nxm", StringComparison.OrdinalIgnoreCase) || string.IsNullOrEmpty(url.Host))
        {
            throw new ParseException.Malformed();
        }
        if (!string.Equals(url.Host, "valheim", StringComparison.OrdinalIgnoreCase))
        {
            throw new ParseException.WrongGame(url.Host);
        }

        var components = url.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (components.Length != 4
            || components[0] != "mods" || !int.TryParse(components[1], out var modId)
            || components[2] != "files" || !int.TryParse(components[3], out var fileId))
        {
            throw new ParseException.Malformed();
        }

        var query = System.Web.HttpUtility.ParseQueryString(url.Query);
        return new NxmLink(url.Host, modId, fileId, query["key"], query["expires"]);
    }
}
