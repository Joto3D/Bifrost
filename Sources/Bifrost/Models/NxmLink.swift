import Foundation

/// A parsed `nxm://` "Mod Manager Download" link — what Nexus's website
/// hands off to whatever's registered for the scheme (Bifrost, via
/// `CFBundleURLTypes` in Info.plist) when a user clicks "Mod Manager
/// Download" on a mod page. Shape:
/// `nxm://<game domain>/mods/<modId>/files/<fileId>?key=...&expires=...&user_id=...`
///
/// `key`/`expires` are present only for a free-account "Slow download"
/// click — Nexus's own time-limited, IP-locked signature for that specific
/// download, required as query parameters on `download_link.json` for a
/// non-premium API key (see `NexusClient.downloadLink`). A premium
/// account's link omits them entirely, since a premium key works against
/// that endpoint on its own.
struct NxmLink: Equatable {
    let gameDomain: String
    let modId: Int
    let fileId: Int
    let key: String?
    let expires: String?

    enum ParseError: Error, CustomStringConvertible, Equatable {
        case malformed
        case wrongGame(String)

        var description: String {
            switch self {
            case .malformed:
                return "That doesn't look like a valid Nexus Mod Manager Download link"
            case .wrongGame(let game):
                return "That link is for \(game), not Valheim"
            }
        }
    }

    /// Parses `url`, requiring scheme `nxm` and game domain `valheim`. Any
    /// other game's domain throws `.wrongGame` (carrying that domain) so
    /// the caller can show a friendly, specific alert rather than a
    /// generic parse failure; anything else malformed (wrong scheme, no
    /// host, unexpected path shape, non-numeric ids) throws `.malformed`.
    static func parse(_ url: URL) throws -> NxmLink {
        guard url.scheme?.lowercased() == "nxm", let host = url.host, !host.isEmpty else {
            throw ParseError.malformed
        }
        guard host.lowercased() == "valheim" else {
            throw ParseError.wrongGame(host)
        }

        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 4,
              components[0] == "mods", let modId = Int(components[1]),
              components[2] == "files", let fileId = Int(components[3]) else {
            throw ParseError.malformed
        }

        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            query.first { $0.name == name }?.value
        }

        return NxmLink(gameDomain: host, modId: modId, fileId: fileId, key: value("key"), expires: value("expires"))
    }
}
