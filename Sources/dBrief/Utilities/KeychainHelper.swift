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
    case tickTickAccessToken = "integration.ticktick.accessToken"
    case todoist = "integration.todoist.token"
}

enum KeychainError: LocalizedError, Sendable {
    case unexpectedStatus(OSStatus)
    case invalidStoredValue
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
            return "Keychain operation failed (\(status)): \(message)"
        case .invalidStoredValue:
            return "The Keychain item could not be decoded as text."
        case .verificationFailed:
            return "The Keychain write could not be verified."
        }
    }
}

/// Secrets for a test run, which must never read or write the user's real Keychain
/// items (reading them prompts for the login password on every run).
private final class InMemorySecrets: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    subscript(account: String) -> String? {
        get { lock.withLock { values[account] } }
        set { lock.withLock { values[account] = newValue } }
    }
}

enum KeychainHelper {
    /// A test host: XCTest or Swift Testing is loaded, a test bundle is, or the process
    /// is a test runner. Hosts differ between toolchains, so check all of them; the app
    /// itself links none of these.
    private static let testStore: InMemorySecrets? = isTestHost ? InMemorySecrets() : nil

    private static var isTestHost: Bool {
        if NSClassFromString("XCTestCase") != nil { return true }
        if Bundle.allBundles.contains(where: { $0.bundleURL.pathExtension == "xctest" }) { return true }
        if Bundle.allFrameworks.contains(where: { ["XCTest", "Testing"].contains($0.bundleURL.deletingPathExtension().lastPathComponent) }) {
            return true
        }
        let process = ProcessInfo.processInfo.processName
        return process == "xctest" || process.hasPrefix("swiftpm-testing-helper") || process.hasSuffix("PackageTests")
    }

    static var usesInMemoryStore: Bool { testStore != nil }

    static func set(_ value: String, for key: KeychainSecretKey) throws {
        try set(value, account: key.rawValue)
    }

    static func get(for key: KeychainSecretKey) throws -> String {
        try get(account: key.rawValue)
    }

    static func setEndpointAPIKey(_ value: String, endpointID: UUID) throws {
        try set(value, account: endpointAccount(for: endpointID))
    }

    static func endpointAPIKey(endpointID: UUID) throws -> String {
        try get(account: endpointAccount(for: endpointID))
    }

    static func setWebhookCredentials(_ value: String, credentialID: UUID) throws {
        try set(value, account: "integration.webhook.\(credentialID.uuidString.lowercased()).credentials")
    }

    static func webhookCredentials(credentialID: UUID) throws -> String {
        try get(account: "integration.webhook.\(credentialID.uuidString.lowercased()).credentials")
    }

    private static func set(_ value: String, account: String) throws {
        if let testStore {
            testStore[account] = value.isEmpty ? nil : value
            return
        }
        if value.isEmpty {
            try delete(account: account)
            return
        }

        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        guard try get(account: account) == value else {
            throw KeychainError.verificationFailed
        }
    }

    private static func get(account: String) throws -> String {
        if let testStore { return testStore[account] ?? "" }
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return ""
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            throw KeychainError.invalidStoredValue
        }
        return value
    }

    private static func delete(account: String) throws {
        if let testStore {
            testStore[account] = nil
            return
        }
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private static func endpointAccount(for endpointID: UUID) -> String {
        "endpoint.\(endpointID.uuidString.lowercased()).apiKey"
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppSupportPaths.bundleIdentifier,
            kSecAttrAccount as String: account,
        ]
    }
}
