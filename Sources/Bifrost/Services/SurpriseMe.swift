import Foundation

/// Backs Browse's "Surprise Me" dice button: picks a random well-rated mod
/// from the cached Thunderstore index for the user to look at, so browsing
/// thousands of mods has a low-effort "just show me something good" option.
enum SurpriseMe {
    /// Minimum `ratingScore` for a package to be considered "well-rated"
    /// enough to surprise someone with.
    static let minimumRating = 20

    /// Filters `index` down to eligible candidates: rated at least
    /// `minimumRating`, not deprecated, not already installed (per
    /// `manifest`), and never the BepInEx loader pack itself
    /// (`ModManager.loaderFullName`) — surprising someone with the mod
    /// loader isn't a fun surprise, it's a setup step. (In practice
    /// `ThunderstoreClient.fetchIndex` already excludes deprecated packages
    /// and the loader from its returned index, but this filters defensively
    /// so the logic is correct against any index handed to it — including
    /// the raw fixtures `DebugCheck`'s "fun" section exercises it with.)
    static func eligible(index: [ThunderstorePackage], manifest: InstalledManifest) -> [ThunderstorePackage] {
        let installedFullNames = Set(manifest.mods.map(\.fullName))
        return index.filter { package in
            package.ratingScore >= minimumRating
                && !package.isDeprecated
                && package.fullName != ModManager.loaderFullName
                && !installedFullNames.contains(package.fullName)
        }
    }

    /// Picks one eligible package at random, or `nil` if none qualify.
    /// Deliberately uses the system RNG (unlike `Flavor.quip`'s seeded one)
    /// — every press of the dice should feel like a fresh roll, not a
    /// reproducible one.
    static func pick(index: [ThunderstorePackage], manifest: InstalledManifest) -> ThunderstorePackage? {
        eligible(index: index, manifest: manifest).randomElement()
    }
}
