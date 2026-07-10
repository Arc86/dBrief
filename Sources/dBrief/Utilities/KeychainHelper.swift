import Foundation
import Security

enum KeychainSecretKey: String, CaseIterable, Sendable {
    case notion = "integration.notion.token"
    case evernote = "integration.evernote.token"
    case googleKeep = "integration.googlekeep.token"
    case oneNote = "integration.onenote.token"
    case microsoftAccessToken = "microsoft.accessToken"
    case microsoftRefreshToken = "microsoft.refreshToken"
    case microsoftTokenExpiry = "microsoft.tokenExpiry"
}

enum KeychainHelper {
    static func set(_ value: String, for key: KeychainSecretKey) {
        let data = Data(value.utf8)
        let query = baseQuery(for: key)

        SecItemDelete(query as CFDictionary)

        var insert = query
        insert[kSecValueData as String] = data
        SecItemAdd(insert as CFDictionary, nil)
    }

    static func get(for key: KeychainSecretKey) -> String {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return value
    }

    private static func baseQuery(for key: KeychainSecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppSupportPaths.bundleIdentifier,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
    }
}
