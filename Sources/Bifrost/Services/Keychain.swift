import Foundation
import Security

/// Minimal Keychain read/write/delete wrapper for a single generic-password
/// item per service name. Used to store the user's personal Nexus Mods API
/// key (`nexusAPIKeyService`, "Bifrost-NexusAPIKey") — deliberately never
/// UserDefaults or any other plist-backed store, since those can end up in
/// a Time Machine backup or a stray `defaults read` in cleartext.
///
/// Each `service` string is its own single-item slot: `save` replaces
/// whatever's already there for that service rather than erroring on
/// "already exists", so callers don't need a separate update path.
enum Keychain {
    enum KeychainError: Error, CustomStringConvertible {
        case unexpectedStatus(OSStatus)

        var description: String {
            switch self {
            case .unexpectedStatus(let status):
                return "Keychain error \(status)"
            }
        }
    }

    /// The real service name the app's Nexus Mods integration reads/writes
    /// in normal use. `--check`'s Keychain-round-trip section deliberately
    /// uses its own `"Bifrost-NexusAPIKey-check"` service instead, so it
    /// never touches whatever real key this developer has configured.
    static let nexusAPIKeyService = "Bifrost-NexusAPIKey"

    static func save(_ value: String, service: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        // Single-item-per-service store: clear whatever's already there
        // first so this always behaves like an upsert.
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    static func read(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Returns `true` if an item existed and was removed, or if none
    /// existed to begin with (both are a successful "not there anymore").
    @discardableResult
    static func delete(service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
