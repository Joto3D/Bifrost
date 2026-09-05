import Foundation

/// Client for the Nexus Mods API (`https://api.nexusmods.com/v1/`) — the
/// "Mod Manager Download" (`nxm://`) flow's only network dependency:
/// validating a user's personal API key, fetching a mod's display metadata
/// for install progress, and resolving a CDN download link for a specific
/// mod/file pair.
///
/// Every request carries the key as the `apikey` header, exactly as
/// Nexus's own docs specify. The key itself never lives here — callers read
/// it from `Keychain` (service `Keychain.nexusAPIKeyService`) and pass it
/// in per call, so `NexusClient` stays a stateless, ephemeral actor with
/// nothing sensitive to leak.
actor NexusClient {
    enum NexusError: Error, CustomStringConvertible, Equatable {
        case badResponse
        case httpError(status: Int, body: String)
        case freeAccountNeedsManagerDownload
        case decodingFailed

        var description: String {
            switch self {
            case .badResponse:
                return "Nexus returned an unrecognized response"
            case .httpError(let status, let body):
                return "Nexus API error \(status)\(body.isEmpty ? "" : ": \(body)")"
            case .freeAccountNeedsManagerDownload:
                return "Free Nexus accounts must use the \u{201c}Mod Manager Download\u{201d} button on the website (Slow download tab)"
            case .decodingFailed:
                return "Couldn't parse Nexus's response"
            }
        }
    }

    struct ValidationResult: Sendable, Equatable {
        let name: String
        let isPremium: Bool
    }

    struct ModInfo: Sendable, Equatable {
        let name: String
        let version: String
        let author: String
        let summary: String
    }

    private static let baseURL = URL(string: "https://api.nexusmods.com/v1/")!
    private static let game = "valheim"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// GET `/users/validate.json` — confirms the key works and reports the
    /// account's display name and premium status.
    func validateKey(_ key: String) async throws -> ValidationResult {
        struct Response: Decodable {
            let name: String
            let isPremium: Bool
            enum CodingKeys: String, CodingKey { case name, isPremium = "is_premium" }
        }
        let url = Self.baseURL.appendingPathComponent("users/validate.json")
        let response: Response = try await get(url, key: key)
        return ValidationResult(name: response.name, isPremium: response.isPremium)
    }

    /// GET `/games/valheim/mods/{id}.json` — a mod's name, latest version,
    /// author, and summary, used both for the nxm-install progress line
    /// and (via `ModManager.updatesAvailable`) for checking a `source ==
    /// "nexus"` entry's installed version against Nexus's current one.
    func modInfo(modId: Int, key: String) async throws -> ModInfo {
        struct Response: Decodable {
            let name: String
            let version: String
            let author: String
            let summary: String?
        }
        let url = Self.baseURL.appendingPathComponent("games/\(Self.game)/mods/\(modId).json")
        let response: Response = try await get(url, key: key)
        return ModInfo(name: response.name, version: response.version, author: response.author, summary: response.summary ?? "")
    }

    /// GET `/games/valheim/mods/{mod_id}/files/{file_id}/download_link.json`
    /// — resolves the CDN mirror(s) for a specific file and returns the
    /// first one's URI. `nxmKey`/`expires` come straight off the `nxm://`
    /// link for a free account's "Slow download" click and are appended as
    /// query parameters exactly as Nexus's own Vortex/r2modman clients do
    /// — required for a non-premium key (Nexus 403s the endpoint outright
    /// without them); a premium key works with neither.
    func downloadLink(modId: Int, fileId: Int, apiKey: String, nxmKey: String?, expires: String?) async throws -> URL {
        struct Mirror: Decodable { let URI: String }

        guard var components = URLComponents(
            url: Self.baseURL.appendingPathComponent("games/\(Self.game)/mods/\(modId)/files/\(fileId)/download_link.json"),
            resolvingAgainstBaseURL: false
        ) else {
            throw NexusError.badResponse
        }
        var query: [URLQueryItem] = []
        if let nxmKey { query.append(URLQueryItem(name: "key", value: nxmKey)) }
        if let expires { query.append(URLQueryItem(name: "expires", value: expires)) }
        if !query.isEmpty { components.queryItems = query }

        guard let url = components.url else { throw NexusError.badResponse }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "apikey")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NexusError.badResponse }

        if http.statusCode == 403, nxmKey == nil, expires == nil {
            throw NexusError.freeAccountNeedsManagerDownload
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NexusError.httpError(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }

        let mirrors = try decode([Mirror].self, from: data)
        guard let first = mirrors.first, let uri = URL(string: first.URI) else { throw NexusError.badResponse }
        return uri
    }

    private func get<T: Decodable>(_ url: URL, key: String) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "apikey")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NexusError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw NexusError.httpError(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return try decode(T.self, from: data)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw NexusError.decodingFailed
        }
    }
}
