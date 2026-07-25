import Foundation
import Security

/// Stores the S3 access key / secret in the Keychain, separate from the
/// non-secret `S3Config` (which lives in UserDefaults). Keeping them apart means
/// the secret never lands in a plist or a settings export.
enum S3CredentialStore {
    private static let service = "ca.straybits.snapsiphon.s3"
    private static let accessAccount = "accessKeyID"
    private static let secretAccount = "secretAccessKey"
    private static let credentialsAccount = "credentials.v2"

    private struct StoredCredentials: Codable {
        let accessKeyID: String
        let secretAccessKey: String
        let sessionToken: String?
    }

    /// One Keychain item makes credential replacement atomic and lets errors
    /// reach the UI instead of displaying a false "saved" state.
    static func save(_ credentials: S3Credentials) throws {
        let stored = StoredCredentials(accessKeyID: credentials.accessKeyID,
                                       secretAccessKey: credentials.secretAccessKey,
                                       sessionToken: credentials.sessionToken)
        try write(try JSONEncoder().encode(stored), account: credentialsAccount)
    }

    static func load() -> S3Credentials? {
        if let data = readData(account: credentialsAccount),
           let stored = try? JSONDecoder().decode(StoredCredentials.self, from: data),
           !stored.accessKeyID.isEmpty, !stored.secretAccessKey.isEmpty {
            return S3Credentials(accessKeyID: stored.accessKeyID,
                                 secretAccessKey: stored.secretAccessKey,
                                 sessionToken: stored.sessionToken)
        }
        // Migrate the original two-item format on its next successful save.
        guard let id = read(account: accessAccount),
              let secret = read(account: secretAccount),
              !id.isEmpty, !secret.isEmpty else { return nil }
        return S3Credentials(accessKeyID: id, secretAccessKey: secret)
    }

    static var hasCredentials: Bool { load() != nil }

    static func clear() {
        delete(account: credentialsAccount)
        delete(account: accessAccount)
        delete(account: secretAccount)
    }

    // MARK: Keychain

    private static func write(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialError.keychain(status)
        }
    }

    private static func read(account: String) -> String? {
        guard let data = readData(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func readData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return data
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    enum CredentialError: Error, LocalizedError {
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .keychain(let status):
                return "Credentials could not be stored securely (Keychain error \(status))."
            }
        }
    }
}
