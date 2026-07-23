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

    private let service = "ca.straybits.snapsiphon.age"
    private let recipientsAccount = "recipients"     // newline-joined bech32 list
    private let legacyRecipientAccount = "recipient" // pre-multi-key single value
    private let identityAccount = "identity"
    /// The identity's *public* half, stored separately so UI checks (badging the
    /// PAIR row, `hasIdentity`) never have to read the secret itself.
    private let identityMarkerAccount = "identityRecipient"

    @Published private(set) var recipients: [String] = []
    @Published private(set) var hasIdentity: Bool = false

    private init() {
        healIdentityIfNeeded()
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

    /// True when the on-device identity's public half is actually in the
    /// recipient list — i.e. a "★ THIS PHONE" row is visible. `hasIdentity`
    /// alone isn't enough: the row can be removed while the secret survives.
    var identityIsActive: Bool {
        guard hasIdentity, let r = identityRecipient ?? derivedIdentityRecipient() else { return false }
        return recipients.contains(r)
    }

    /// Re-add the surviving identity's public half to the recipient list.
    /// Used when the "THIS PHONE" row was removed (or orphaned by an earlier
    /// version) but the secret still exists — re-adding is always safer than
    /// minting a fresh key, which would overwrite a secret that may guard
    /// already-uploaded backups.
    @discardableResult
    func reactivateIdentity() -> Bool {
        guard hasIdentity, let recipient = identityRecipient ?? derivedIdentityRecipient() else { return false }
        try? write(recipient, account: identityMarkerAccount)   // heal a missing marker
        if !recipients.contains(recipient) {
            recipients.append(recipient)
            try? writeRecipients()
        }
        return true
    }

    /// First-run default: if no keys are configured at all, surface this
    /// phone's identity — re-adding a surviving one, else minting fresh.
    @discardableResult
    func ensureDefaultIdentity() -> Bool {
        guard recipients.isEmpty else { return false }
        if hasIdentity { return reactivateIdentity() }
        return (try? generateIdentity()) != nil
    }

    /// Fallback derivation of the identity's public half straight from the
    /// stored secret, for installs that predate the marker.
    private func derivedIdentityRecipient() -> String? {
        guard let secret = readString(account: identityAccount),
              let identity = try? Age.Identity(bech32: secret) else { return nil }
        return identity.recipient.bech32
    }

    /// Secrets generated before the Bech32 checksum fix were stored with an
    /// invalid checksum (computed over the uppercase HRP). The key *bytes* are
    /// fine — re-encode canonically so both this app and the reference age CLI
    /// accept the string.
    private func healIdentityIfNeeded() {
        guard let stored = readString(account: identityAccount) else { return }
        if (try? Bech32.decode(stored, expectedHRP: "AGE-SECRET-KEY-")) != nil { return }  // already canonical
        guard let identity = try? Age.Identity(bech32: stored) else { return }             // unusable — leave it
        try? write(identity.bech32, account: identityAccount)
        try? write(identity.recipient.bech32, account: identityMarkerAccount)
    }

    /// Adopt an existing identity: the pasted secret becomes THIS PHONE's key
    /// and its public half joins the recipient list. Used to carry one key
    /// across installs/devices instead of minting a new one. Any previous
    /// phone secret is overwritten — callers confirm first; the old key's
    /// recipient row survives as public-only so files encrypted to it stay
    /// tracked. Legacy (pre-checksum-fix) secrets are accepted and re-encoded
    /// canonically on the way in.
    @discardableResult
    func importIdentity(_ secretString: String) throws -> String {
        let identity = try Age.Identity(bech32: secretString)
        let recipient = identity.recipient.bech32
        try write(identity.bech32, account: identityAccount)    // canonical form
        try write(recipient, account: identityMarkerAccount)
        if !recipients.contains(recipient) {
            recipients.append(recipient)
            try writeRecipients()
        }
        hasIdentity = true
        return recipient
    }

    /// Nuclear option: discard the existing on-device identity (removing its
    /// recipient row) and mint a fresh pair. Backups encrypted only to the old
    /// key become unrecoverable — the UI confirms hard before calling this.
    @discardableResult
    func replaceIdentity() throws -> (recipient: String, secret: String) {
        if let old = identityRecipient ?? derivedIdentityRecipient() {
            recipients.removeAll { $0 == old }
            try? writeRecipients()
        }
        delete(account: identityAccount)
        delete(account: identityMarkerAccount)
        hasIdentity = false
        return try generateIdentity()
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
        // Use the derived fallback too, so a marker mismatch can't strand an
        // orphaned secret in the Keychain.
        if (identityRecipient ?? derivedIdentityRecipient()) == string {
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

    // MARK: Device-scoped scratch values

    /// A value that lives in the ThisDeviceOnly keychain — it survives app
    /// re-installs on the SAME phone but never migrates to a restored/cloned
    /// one. The engine keeps its writer instance ID here so a device-transfer
    /// clone can't impersonate the original writer.
    func deviceScopedValue(account: String) -> String? { readString(account: account) }
    func setDeviceScopedValue(_ value: String, account: String) {
        try? write(value, account: account)
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
