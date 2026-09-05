import Foundation

/// On app open, if the cached Thunderstore package index is missing or
/// older than a day, kicks off a quiet background refresh via
/// `ThunderstoreClient`'s existing force-fetch path — no modal, no blocking
/// of startup. `InstalledModsView` already does its own conditional
/// (cheap, 304-friendly) fetch on open; this is purely about not letting the
/// cache go stale for days at a time if Bifrost is left running or is
/// reopened frequently without ever visiting Installed/Browse.
///
/// Reads the cache file's own modification date directly, rather than
/// adding a new accessor to `ThunderstoreClient` — the cache path is a
/// fixed, already-relied-upon convention (see `ThunderstoreClient.init` and
/// `DebugCheck.checkThunderstoreIndex`).
enum IndexAutoRefresher {
    static let staleAfter: TimeInterval = 24 * 60 * 60

    static var cacheFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Bifrost/package-index.json")
    }

    /// True when the cache file is missing entirely, or its modification
    /// date is more than `staleAfter` seconds before `now`.
    static func isStale(now: Date = Date()) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: cacheFileURL.path),
              let modified = attributes[.modificationDate] as? Date else {
            return true
        }
        return now.timeIntervalSince(modified) > staleAfter
    }

    /// If the cache is stale, kicks off a background force-refresh and
    /// returns the `Task` driving it (so a caller can await it if it wants
    /// to, e.g. to know when to clear a status note); returns `nil` without
    /// calling `onStatus` at all if the cache is already fresh. `onStatus`
    /// is called exactly once, with a short human-readable note, once the
    /// refresh finishes (successfully or not).
    @discardableResult
    static func refreshIfStale(
        client: ThunderstoreClient,
        onStatus: @escaping @Sendable (String) -> Void = { _ in }
    ) -> Task<Void, Never>? {
        guard isStale() else { return nil }
        return Task {
            do {
                let packages = try await client.fetchIndex(force: true)
                onStatus("Thunderstore index refreshed in the background (\(packages.count) packages)")
            } catch {
                onStatus("Background index refresh failed: \(error.localizedDescription)")
            }
        }
    }
}
