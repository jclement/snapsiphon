import Foundation
import Security

/// Stores the S3 access key / secret in the Keychain, separate from the
/// non-secret `S3Config` (which lives in UserDefaults). Keeping them apart means
/// the secret never lands in a plist or a settings export.
enum S3CredentialStore {
    private static let service = "ca.straybits.snapsiphon.s3"
    private static let accessAccount = "accessKeyID"
    private static let secretAccount = "secretAccessKey"

    static func save(_ credentials: S3Credentials) {
        write(credentials.accessKeyID, account: accessAccount)
        write(credentials.secretAccessKey, account: secretAccount)
    }

    static func load() -> S3Credentials? {
        guard let id = read(account: accessAccount),
              let secret = read(account: secretAccount),
              !id.isEmpty, !secret.isEmpty else { return nil }
        return S3Credentials(accessKeyID: id, secretAccessKey: secret)
    }

    static var hasCredentials: Bool { load() != nil }

    static func clear() {
        delete(account: accessAccount)
        delete(account: secretAccount)
    }

    // MARK: Keychain

    private static func write(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func read(account: String) -> String? {
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
        return String(data: data, encoding: .utf8)
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
