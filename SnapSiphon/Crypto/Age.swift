import Foundation
import CryptoKit

/// A native Swift implementation of the parts of the `age` encryption format
/// (age-encryption.org/v1) that SnapSiphon needs: X25519 recipients and the
/// STREAM-based payload. Built entirely on CryptoKit so there is no third-party
/// dependency and the crypto is auditable.
///
/// Output is byte-compatible with the reference `age` and `rage` tools, so a
/// user can decrypt their backups on a laptop with `age -d -i key.txt file.age`.
enum Age {

    // MARK: Constants

    /// age uses 64 KiB plaintext chunks in its STREAM construction.
    static let chunkSize = 64 * 1024
    private static let version = "age-encryption.org/v1"
    private static let x25519Info = "age-encryption.org/v1/X25519"
    private static let x25519Label = "X25519"

    enum Error: Swift.Error, LocalizedError {
        case badRecipient
        case encryptionFailed

        var errorDescription: String? {
            switch self {
            case .badRecipient: return "The recipient key is not a valid age X25519 key."
            case .encryptionFailed: return "Encryption failed while sealing a chunk."
            }
        }
    }

    // MARK: Recipient / Identity

    /// An age recipient (public key). Encode is `age1…`.
    struct Recipient {
        let publicKey: Curve25519.KeyAgreement.PublicKey

        init(publicKey: Curve25519.KeyAgreement.PublicKey) {
            self.publicKey = publicKey
        }

        init(bech32 string: String) throws {
            let raw = try Bech32.decode(string.trimmingCharacters(in: .whitespacesAndNewlines),
                                        expectedHRP: "age")
            guard raw.count == 32 else { throw Error.badRecipient }
            self.publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(raw))
        }

        var bech32: String {
            Bech32.encode(hrp: "age", data: Array(publicKey.rawRepresentation))
        }
    }

    /// An age identity (secret key). Encode is `AGE-SECRET-KEY-1…` (uppercase).
    struct Identity {
        let privateKey: Curve25519.KeyAgreement.PrivateKey

        init() { self.privateKey = Curve25519.KeyAgreement.PrivateKey() }
        init(privateKey: Curve25519.KeyAgreement.PrivateKey) { self.privateKey = privateKey }

        init(bech32 string: String) throws {
            let raw = try Bech32.decode(string.trimmingCharacters(in: .whitespacesAndNewlines),
                                        expectedHRP: "AGE-SECRET-KEY-")
            guard raw.count == 32 else { throw Error.badRecipient }
            self.privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(raw))
        }

        var recipient: Recipient { Recipient(publicKey: privateKey.publicKey) }

        /// AGE-SECRET-KEY-1… (uppercase, as the age tools emit).
        var bech32: String {
            Bech32.encode(hrp: "AGE-SECRET-KEY-", data: Array(privateKey.rawRepresentation)).uppercased()
        }
    }

    // MARK: Header building

    /// Builds the age header for a set of recipients, returning the ASCII header
    /// bytes (including the terminating `--- <mac>\n`) and the random file key.
    private static func makeHeader(fileKey: SymmetricKey, recipients: [Recipient]) throws -> Data {
        var stanzas = ""
        for recipient in recipients {
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            let ephemeralShare = ephemeral.publicKey.rawRepresentation
            let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient.publicKey)

            var salt = Data()
            salt.append(ephemeralShare)
            salt.append(recipient.publicKey.rawRepresentation)

            let wrapKey = shared.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: salt,
                sharedInfo: Data(x25519Info.utf8),
                outputByteCount: 32)

            // Wrap the file key: ChaCha20-Poly1305 with a 12-byte zero nonce.
            let nonce = try ChaChaPoly.Nonce(data: Data(repeating: 0, count: 12))
            let sealed = try ChaChaPoly.seal(fileKey.rawData, using: wrapKey, nonce: nonce)
            let body = sealed.ciphertext + sealed.tag  // 16 + 16 = 32 bytes

            stanzas += "-> \(x25519Label) \(b64(ephemeralShare))\n"
            stanzas += wrapBase64(body) + "\n"
        }

        let headerNoMac = "\(version)\n\(stanzas)---"
        // HMAC key = HKDF(fileKey, salt: "", info: "header")
        let macKey = SymmetricKey(data: HKDF<SHA256>.deriveKey(
            inputKeyMaterial: fileKey,
            salt: Data(),
            info: Data("header".utf8),
            outputByteCount: 32))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(headerNoMac.utf8), using: macKey)
        let header = "\(headerNoMac) \(b64(Data(mac)))\n"
        return Data(header.utf8)
    }

    // MARK: Streaming encryptor

    /// Incremental age encryptor. Feed plaintext with `update(_:)` and finish
    /// with `finalize()`; the first `update` return also carries the header.
    /// Designed so a large photo/video never needs to be fully resident.
    final class Encryptor {
        private let streamKeyBytes: [UInt8]
        private var counter: UInt64 = 0
        private var buffer = Data()
        private var headerEmitted = false
        private let header: Data
        private let nonce: Data

        init(recipients: [Recipient]) throws {
            let fileKey = SymmetricKey(size: .init(bitCount: 128))  // age file key is 16 bytes
            self.header = try Age.makeHeader(fileKey: fileKey, recipients: recipients)
            // Payload key = HKDF(fileKey, salt: nonce(16 random), info: "payload")
            var n = Data(count: 16)
            n.withUnsafeMutableBytes { ptr in
                _ = SecRandomCopyBytes(kSecRandomDefault, 16, ptr.baseAddress!)
            }
            self.nonce = n
            let key = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: fileKey,
                salt: n,
                info: Data("payload".utf8),
                outputByteCount: 32)
            self.streamKeyBytes = Array(key.withUnsafeBytes { Array($0) })
        }

        /// Feed more plaintext. Returns any ciphertext ready to be written.
        func update(_ data: Data) throws -> Data {
            var out = Data()
            if !headerEmitted {
                out.append(header)
                out.append(nonce)
                headerEmitted = true
            }
            buffer.append(data)
            while buffer.count > Age.chunkSize {
                let chunk = buffer.prefix(Age.chunkSize)
                buffer.removeFirst(Age.chunkSize)
                out.append(try seal(Data(chunk), last: false))
            }
            return out
        }

        /// Finish the stream, sealing the final (possibly empty) chunk.
        func finalize() throws -> Data {
            var out = Data()
            if !headerEmitted {
                out.append(header)
                out.append(nonce)
                headerEmitted = true
            }
            out.append(try seal(buffer, last: true))
            buffer.removeAll()
            return out
        }

        private func seal(_ plaintext: Data, last: Bool) throws -> Data {
            let nonce = try ChaChaPoly.Nonce(data: streamNonce(counter: counter, last: last))
            let key = SymmetricKey(data: Data(streamKeyBytes))
            let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce)
            counter &+= 1
            return sealed.ciphertext + sealed.tag
        }

        /// STREAM nonce: 11-byte big-endian counter + 1-byte last-chunk flag.
        private func streamNonce(counter: UInt64, last: Bool) -> Data {
            var nonce = Data(count: 12)
            var c = counter
            // Fill the low 8 bytes of the 11-byte counter field (index 3..<11).
            for i in stride(from: 10, through: 3, by: -1) {
                nonce[i] = UInt8(c & 0xff)
                c >>= 8
            }
            nonce[11] = last ? 0x01 : 0x00
            return nonce
        }
    }

    // MARK: One-shot helpers

    /// Encrypt a whole `Data` blob in memory (used for small payloads / tests).
    static func encrypt(_ plaintext: Data, to recipients: [Recipient]) throws -> Data {
        let enc = try Encryptor(recipients: recipients)
        var out = try enc.update(plaintext)
        out.append(try enc.finalize())
        return out
    }

    // MARK: Base64 helpers (age uses RFC 4648 std base64 with no padding)

    private static func b64(_ data: Data) -> String {
        var s = data.base64EncodedString()
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }

    /// age wraps stanza bodies at 64 columns.
    private static func wrapBase64(_ data: Data) -> String {
        let full = b64(data)
        var lines: [String] = []
        var idx = full.startIndex
        while idx < full.endIndex {
            let end = full.index(idx, offsetBy: 64, limitedBy: full.endIndex) ?? full.endIndex
            lines.append(String(full[idx..<end]))
            idx = end
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n")
    }
}

private extension SymmetricKey {
    var rawData: Data { withUnsafeBytes { Data($0) } }
}
