import Foundation
import Security

/// Thin wrapper over the macOS Keychain for generic password items
/// scoped to `dev.carafe.Carafe`. Used to store the SteamGridDB API
/// key without committing it to disk in plaintext.
///
/// FRAGILITY: Keychain access on a non-codesigned debug build can
/// behave differently from a notarized release — the keychain
/// occasionally re-prompts after a rebuild because the binary
/// signature changes. In production builds (signed with a stable
/// developer certificate) this is a one-time auth. For dev builds,
/// "Always Allow" makes the prompts go away.
enum CarafeKeychain {
    private static let service = "dev.carafe.Carafe"

    enum Account: String {
        case steamGridDBAPIKey = "steamgriddb-api-key"
    }

    enum Failure: LocalizedError {
        case osStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .osStatus(let status):
                let msg = SecCopyErrorMessageString(status, nil) as String?
                return "Keychain error \(status): \(msg ?? "unknown")"
            }
        }
    }

    /// Store (or overwrite) a string for the given account.
    static func setString(_ value: String, account: Account) throws {
        guard let data = value.data(using: .utf8) else {
            throw Failure.osStatus(errSecParam)
        }
        let baseQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
        // Delete any existing item — SecItemAdd refuses on duplicates.
        SecItemDelete(baseQuery as CFDictionary)
        var insert = baseQuery
        insert[kSecValueData as String] = data
        let status = SecItemAdd(insert as CFDictionary, nil)
        if status != errSecSuccess {
            throw Failure.osStatus(status)
        }
    }

    /// Read the stored string, or nil if the item doesn't exist.
    static func getString(account: Account) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Remove the item. No-op when absent.
    static func delete(account: Account) throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw Failure.osStatus(status)
        }
    }
}
