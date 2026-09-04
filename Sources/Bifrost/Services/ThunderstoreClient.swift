import Foundation

/// Fetches and caches the Thunderstore package index for the Valheim
/// community. The index is tens of MB, so it's cached to disk with a
/// validator sidecar and only re-downloaded in full when it has actually
/// changed.
///
/// Note: Thunderstore's package index endpoint does not send an `ETag`
/// header in practice (verified against the live API) — it only sends
/// `Last-Modified`, which it does honor via `If-Modified-Since` for a real
/// 304 response. The sidecar stores whichever validator(s) the server
/// provides and sends both back on the next request, so this keeps working
/// unchanged if Thunderstore starts sending an ETag too.
actor ThunderstoreClient {
    enum ClientError: Error {
        case badResponse
        case noCacheAvailable
    }

    private struct Validators: Codable {
        var etag: String?
        var lastModified: String?
    }

    private static let indexURL = URL(string: "https://thunderstore.io/c/valheim/api/v1/package/")!
    private static let loaderPackageFullName = "denikson-BepInExPack_Valheim"

    private let session: URLSession
    private let cacheFileURL: URL
    private let validatorsFileURL: URL

    init(session: URLSession = .shared) {
        self.session = session

        let supportDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Bifrost")
        self.cacheFileURL = supportDir.appendingPathComponent("package-index.json")
        self.validatorsFileURL = supportDir.appendingPathComponent("package-index.etag")

        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    }

    /// Fetches the current package index, using the on-disk cache where
    /// possible.
    ///
    /// - `force: false` sends a conditional request using the last known
    ///   validators (`ETag`/`Last-Modified`, whichever the server gave us);
    ///   a 304 response means the cache is still fresh and is loaded from
    ///   disk.
    /// - `force: true` skips the validators and always requests a full,
    ///   fresh copy from the server.
    /// - If the network request fails outright (e.g. offline) and a disk
    ///   cache exists, that cache is returned rather than throwing.
    func fetchIndex(force: Bool = false) async throws -> [ThunderstorePackage] {
        var request = URLRequest(url: Self.indexURL)
        if !force, let validators = loadValidators() {
            if let etag = validators.etag {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }
            if let lastModified = validators.lastModified {
                request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if let cached = try? loadCachedPackages() {
                return cached
            }
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.badResponse
        }

        switch httpResponse.statusCode {
        case 304:
            if let cached = try? loadCachedPackages() {
                return cached
            }
            // Shouldn't happen (server wouldn't 304 without a validator we
            // sent), but fall back to a fresh fetch just in case the cache
            // went missing.
            return try await fetchIndex(force: true)

        case 200:
            let packages = try decode(data)
            try? data.write(to: cacheFileURL, options: .atomic)
            let validators = Validators(
                etag: httpResponse.value(forHTTPHeaderField: "ETag"),
                lastModified: httpResponse.value(forHTTPHeaderField: "Last-Modified")
            )
            saveValidators(validators)
            return filter(packages)

        default:
            if let cached = try? loadCachedPackages() {
                return cached
            }
            throw ClientError.badResponse
        }
    }

    /// The icon URL for a package's latest version, if it has one.
    nonisolated func iconURL(for package: ThunderstorePackage) -> URL? {
        guard let icon = package.latestVersion?.icon, !icon.isEmpty else { return nil }
        return URL(string: icon)
    }

    private func loadValidators() -> Validators? {
        guard let data = try? Data(contentsOf: validatorsFileURL) else { return nil }
        return try? JSONDecoder().decode(Validators.self, from: data)
    }

    private func saveValidators(_ validators: Validators) {
        guard validators.etag != nil || validators.lastModified != nil else { return }
        guard let data = try? JSONEncoder().encode(validators) else { return }
        try? data.write(to: validatorsFileURL, options: .atomic)
    }

    private func loadCachedPackages() throws -> [ThunderstorePackage] {
        guard FileManager.default.fileExists(atPath: cacheFileURL.path) else {
            throw ClientError.noCacheAvailable
        }
        let data = try Data(contentsOf: cacheFileURL)
        return filter(try decode(data))
    }

    private func decode(_ data: Data) throws -> [ThunderstorePackage] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = Self.iso8601WithFractional.date(from: string) {
                return date
            }
            if let date = Self.iso8601Plain.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized date format: \(string)"
            )
        }
        return try decoder.decode([ThunderstorePackage].self, from: data)
    }

    private func filter(_ packages: [ThunderstorePackage]) -> [ThunderstorePackage] {
        packages.filter { !$0.isDeprecated && $0.fullName != Self.loaderPackageFullName }
    }

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
