import Foundation
import Security

/// Persists the age recipients/identity in the Keychain and exposes an
/// observable surface for the UI.
///
/// SnapSiphon encrypts every file to **all** configured recipients (age wraps
/// the file key once per recipient), so any one of the matching secret keys can
/// decrypt it. That lets you back up to, say, your phone's own generated key
/// *and* your laptop's public key *and* an offline paper key at once.
///
/// - **Public-key only:** paste `age1…` recipients. SnapSiphon can encrypt but
///   never decrypt — the secrets live elsewhere. Safest default.
/// - **Generated pair:** SnapSiphon mints an identity, shows the secret once,
///   and keeps it in the Keychain; its public half joins the recipient list.
@MainActor
final class AgeKeyManager: ObservableObject {
    static let shared = AgeKeyManager()

    private let service = "com.snapsiphon.age"
    private let recipientsAccount = "recipients"     // newline-joined bech32 list
    private let legacyRecipientAccount = "recipient" // pre-multi-key single value
    private let identityAccount = "identity"
    /// The identity's *public* half, stored separately so UI checks (badging the
    /// PAIR row, `hasIdentity`) never have to read the secret itself.
    private let identityMarkerAccount = "identityRecipient"

    @Published private(set) var recipients: [String] = []
    @Published private(set) var hasIdentity: Bool = false

    private init() {
        // Migrate a pre-multi-key single recipient into the list.
        if let joined = readString(account: recipientsAccount) {
            recipients = Self.split(joined)
        } else if let legacy = readString(account: legacyRecipientAccount) {
            recipients = [legacy]
            try? writeRecipients()
        }
        hasIdentity = readString(account: identityAccount) != nil
        // Legacy migration: derive + store the public marker once.
        if hasIdentity, readString(account: identityMarkerAccount) == nil,
           let secret = readString(account: identityAccount),
           let identity = try? Age.Identity(bech32: secret) {
            try? write(identity.recipient.bech32, account: identityMarkerAccount)
        }
    }

    /// First-run default: if no keys are configured at all, mint this phone's
    /// own identity so backups can start immediately and the restore script is
    /// fully self-contained. Never touches an already-configured setup.
    @discardableResult
    func ensureDefaultIdentity() -> Bool {
        guard recipients.isEmpty && !hasIdentity else { return false }
        return (try? generateIdentity()) != nil
    }

    var isConfigured: Bool { !recipients.isEmpty }

    /// Parsed recipients, skipping any that no longer decode.
    var recipientObjects: [Age.Recipient] {
        recipients.compactMap { try? Age.Recipient(bech32: $0) }
    }

    /// The recipient string that corresponds to the on-device identity (if any),
    /// so the UI can badge which entry we hold the secret for. Reads the public
    /// marker, never the secret.
    var identityRecipient: String? { readString(account: identityMarkerAccount) }

    // MARK: Mutations

    /// Add an `age1…` recipient to the set. Validates and de-duplicates.
    func addRecipient(_ string: String) throws {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let recipient = try Age.Recipient(bech32: trimmed)  // throws if invalid
        let canonical = recipient.bech32                    // normalise casing/format
        guard !recipients.contains(canonical) else { return }
        recipients.append(canonical)
        try writeRecipients()
    }

    /// Remove a recipient. If it's the one matching our stored identity, the
    /// identity secret is dropped too.
    func removeRecipient(_ string: String) {
        recipients.removeAll { $0 == string }
        try? writeRecipients()
        if identityRecipient == string {
            delete(account: identityAccount)
            delete(account: identityMarkerAccount)
            hasIdentity = false
        }
    }

    /// Generate a fresh identity, add its public half to the recipient set, and
    /// return the secret so the UI can present it exactly once.
    @discardableResult
    func generateIdentity() throws -> (recipient: String, secret: String) {
        let identity = Age.Identity()
        let recipient = identity.recipient.bech32
        try write(identity.bech32, account: identityAccount)
        try write(recipient, account: identityMarkerAccount)
        if !recipients.contains(recipient) {
            recipients.append(recipient)
            try writeRecipients()
        }
        hasIdentity = true
        return (recipient, identity.bech32)
    }

    /// Retrieve the stored secret. ⚠️ Returns it raw — call ONLY from behind a
    /// `DeviceAuth.authenticate` gate (secret reveal, restore-script export).
    func exportSecret() -> String? { readString(account: identityAccount) }

    func reset() {
        delete(account: recipientsAccount)
        delete(account: legacyRecipientAccount)
        delete(account: identityAccount)
        delete(account: identityMarkerAccount)
        recipients = []
        hasIdentity = false
    }

    // MARK: Keychain plumbing

    private static func split(_ joined: String) -> [String] {
        joined.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }

    private func writeRecipients() throws {
        try write(recipients.joined(separator: "\n"), account: recipientsAccount)
    }

    private func write(_ value: String, account: String) throws {
        let data = Data(value.utf8)
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
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    private func readString(account: String) -> String? {
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

    private func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    enum KeychainError: Swift.Error, LocalizedError {
        case status(OSStatus)
        var errorDescription: String? {
            switch self {
            case .status(let s): return "Keychain error (\(s)). Your key could not be stored securely."
            }
        }
    }
}
