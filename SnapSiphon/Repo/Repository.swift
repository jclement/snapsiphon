import Foundation
import CryptoKit

/// The on-bucket repository format:
///
/// ```
/// <prefix>/objects/<random-uuid>                encrypted asset blobs
/// <prefix>/checkpoints/000001/checkpoint.age    encrypted SQLite snapshot
/// <prefix>/checkpoints/000001/journal000001.age encrypted change journal
/// <prefix>/checkpoints/000001/journal000002.age …
/// <prefix>/checkpoints/000002/…                 next self-contained generation
/// ```
///
/// Principles (see docs/design): blobs are immutable and named by random UUID
/// (no content hashes → no confirmation attacks; no extensions → no type leak);
/// metadata is append-only; each generation is restorable alone; the local
/// SQLite is only a cache — checkpoint + journals are the source of truth;
/// blobs upload BEFORE journal commit, so a crash strands only ignorable
/// orphans; journals chain (seq + previous file hash) for tamper evidence.
enum Repo {

    // MARK: Naming

    static func objectKey(uuid: String) -> String { "objects/\(uuid)" }
    static func generationDir(_ gen: Int) -> String { String(format: "checkpoints/%06d", gen) }
    static func checkpointKey(gen: Int) -> String { "\(generationDir(gen))/checkpoint.age" }
    static func journalKey(gen: Int, seq: Int) -> String {
        String(format: "%@/journal%06d.age", generationDir(gen), seq)
    }

    /// Parse "checkpoints/000002/journal000003.age" → (gen 2, seq 3);
    /// "checkpoints/000002/checkpoint.age" → (gen 2, seq 0).
    static func parseMetadataKey(_ relative: String) -> (gen: Int, seq: Int)? {
        let parts = relative.split(separator: "/")
        guard parts.count == 3, parts[0] == "checkpoints", let gen = Int(parts[1]) else { return nil }
        if parts[2] == "checkpoint.age" { return (gen, 0) }
        guard parts[2].hasPrefix("journal"), parts[2].hasSuffix(".age"),
              let seq = Int(parts[2].dropFirst("journal".count).dropLast(".age".count)) else { return nil }
        return (gen, seq)
    }

    // MARK: Journal model

    enum Op: String, Codable {
        case add        // asset uploaded and committed
        case delete     // deleted on device (blob may still exist)
        case restore    // previously-deleted asset reappeared
        case purge      // blob physically removed; drop from restore set
        case update     // metadata correction (filename etc.)
    }

    struct Entry: Codable {
        var op: Op
        var uuid: String
        var localIdentifier: String? = nil
        var filename: String? = nil
        var mediaType: String? = nil
        var size: Int64? = nil              // ciphertext bytes
        var plaintextHash: String? = nil    // sha256 hex of the original file
        var ciphertextHash: String? = nil   // sha256 hex of the stored blob
        var createdAt: String? = nil        // ISO-8601 asset capture date
        var at: String                      // ISO-8601 event time
    }

    struct Journal: Codable {
        var format: Int = 1
        var generation: Int
        var seq: Int
        /// sha256 hex of the previous metadata file's ciphertext — the
        /// checkpoint for seq 1, journal(seq-1) otherwise. Detects rollback,
        /// deletion, and reordering.
        var prevHash: String
        var device: String
        var instance: String
        var createdAt: String
        var entries: [Entry]
    }

    // MARK: Blob naming (salted content addressing)

    /// Blob name for a file: HMAC-SHA256 of the file's sha256, keyed with the
    /// repository's secret salt. Deterministic (same content → same blob →
    /// idempotent uploads and free dedup) yet useless to an outsider: without
    /// the salt, no one can hash a known photo and probe whether you have it.
    /// The salt is minted at repository init and rides inside the encrypted
    /// checkpoint's meta table.
    static func newSaltHex() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func blobName(saltHex: String, plaintextHash: String) -> String {
        let key = SymmetricKey(data: dataFromHex(saltHex))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(plaintextHash.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    static func dataFromHex(_ hex: String) -> Data {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            data.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return data
    }

    // MARK: Hashing

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let done = try autoreleasepool { () -> Bool in
                let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
                if chunk.isEmpty { return true }
                hasher.update(data: chunk)
                return false
            }
            if done { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Encode / decode (journals are small JSON; age-encrypted)

    static func encodeJournal(_ journal: Journal, recipients: [Age.Recipient]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try Age.encrypt(try encoder.encode(journal), to: recipients)
    }

    static func decodeJournal(_ ciphertext: Data, identity: Age.Identity, tempDir: URL) throws -> Journal {
        // Journals are small; still reuse the streaming file decryptor for a
        // single verified code path.
        let src = tempDir.appendingPathComponent("jr-\(UUID().uuidString).age")
        let dst = tempDir.appendingPathComponent("jr-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: dst)
        }
        try ciphertext.write(to: src)
        try Age.decryptFile(at: src, to: dst, identity: identity)
        return try JSONDecoder().decode(Journal.self, from: Data(contentsOf: dst))
    }
}
