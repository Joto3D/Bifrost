import Foundation

/// A single mod package as returned by Thunderstore's v1 package index for
/// the Valheim community. Only the fields Bifrost actually uses are
/// decoded; everything else in the response is ignored.
struct ThunderstorePackage: Codable, Identifiable, Sendable, Hashable {
    let name: String
    let fullName: String
    let owner: String
    let packageURL: URL
    let dateUpdated: Date
    let ratingScore: Int
    let isDeprecated: Bool
    let categories: [String]
    let versions: [Version]

    var id: String { fullName }

    /// The most recent version, which the index always lists first.
    var latestVersion: Version? { versions.first }

    enum CodingKeys: String, CodingKey {
        case name
        case fullName = "full_name"
        case owner
        case packageURL = "package_url"
        case dateUpdated = "date_updated"
        case ratingScore = "rating_score"
        case isDeprecated = "is_deprecated"
        case categories
        case versions
    }

    struct Version: Codable, Sendable, Hashable {
        let name: String
        let fullName: String
        let description: String
        let icon: String?
        let versionNumber: String
        /// Dependency identifiers in "Author-Name-Version" form.
        let dependencies: [String]
        let downloadURL: URL
        let downloads: Int
        let fileSize: Int

        enum CodingKeys: String, CodingKey {
            case name
            case fullName = "full_name"
            case description
            case icon
            case versionNumber = "version_number"
            case dependencies
            case downloadURL = "download_url"
            case downloads
            case fileSize = "file_size"
        }
    }
}

extension ThunderstorePackage {
    /// Total downloads across all versions — what the Thunderstore site
    /// itself shows as the package's download count.
    var totalDownloads: Int {
        versions.reduce(0) { $0 + $1.downloads }
    }
}
