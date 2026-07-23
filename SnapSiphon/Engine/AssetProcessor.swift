import Foundation
import CryptoKit

/// Takes a single asset from library → encrypted → bucket. Stateless aside from
/// its collaborators, so many can run concurrently. Each step streams through a
/// temp file so a 4K video never has to sit in memory in the clear.
struct AssetProcessor {
    let photos: PhotoLibrary
    let client: S3Client
    let recipients: [Age.Recipient]
    let tempDir: URL
    /// The repository's blob-naming salt (hex). Blob names are
    /// HMAC(salt, sha256(content)) — deterministic per repo, opaque outside it.
    let saltHex: String

    /// Where a file currently is in its lane's pipeline (drives the lane UI).
    enum Phase: Equatable, Sendable {
        case exporting      // pulling the original (possibly from iCloud)
        case encrypting
        case uploading
    }

    struct Result {
        var uuid: String              // blob name actually used
        var encryptedBytes: Int64
        var originalBytes: Int64
        var filename: String
        var plaintextHash: String
        var ciphertextHash: String
        var alreadyPresent: Bool
    }

    /// Hashes produced in the single encrypt pass: sha256 of the source (for
    /// restore-time verification), sha256 of the ciphertext (for repository
    /// verification), and MD5 of the ciphertext (Content-MD5 upload integrity).
    struct EncryptDigests {
        var plaintextSHA256: String
        var ciphertextSHA256: String
        var ciphertextMD5Base64: String
    }

    func process(_ record: AssetRecord,
                 forceUpload: Bool,
                 bytesPerSecond: Double,
                 onMeta: ((String, Int64) -> Void)? = nil,
                 onPhase: ((Phase) -> Void)? = nil,
                 onRetry: ((Int, Swift.Error) -> Void)? = nil,
                 progress: @escaping (Double) -> Void) async throws -> Result {
        let token = UUID().uuidString
        let originalURL = tempDir.appendingPathComponent("\(token).orig")
        let encryptedURL = tempDir.appendingPathComponent("\(token).age")
        defer {
            try? FileManager.default.removeItem(at: originalURL)
            try? FileManager.default.removeItem(at: encryptedURL)
        }

        // 1. Export the untouched original (learns the real filename/size,
        //    deferred from scan time). A "#live"-suffixed record means this
        //    row is a Live Photo's paired motion clip.
        onPhase?(.exporting)
        let exported: PhotoLibrary.Exported
        if AssetRecord.isLiveMotion(record.localIdentifier) {
            exported = try await photos.exportLiveMotion(
                localIdentifier: AssetRecord.baseIdentifier(record.localIdentifier), to: originalURL)
        } else {
            exported = try await photos.exportOriginal(
                localIdentifier: record.localIdentifier, to: originalURL)
        }
        onMeta?(exported.filename, exported.byteSize)

        // 2. Hash the plaintext (fast local read) — its salted HMAC IS the
        //    blob name, so identical content always maps to the same key.
        //    Records that already carry a name keep it (stability).
        let plainHash = try Repo.sha256Hex(fileAt: originalURL)
        let uuid = record.uuid.isEmpty ? Repo.blobName(saltHex: saltHex, plaintextHash: plainHash)
                                       : record.uuid
        let key = client.fullKey(for: Repo.objectKey(uuid: uuid))

        // 3. Skip if the blob is already there: a crashed previous attempt, or
        //    a different asset with identical bytes (dedup). One cheap HEAD.
        //    `forceUpload` (verify found a bad blob) bypasses the shortcut so
        //    the repair actually re-uploads.
        if !forceUpload,
           let remoteSize = try await S3Client.withRetries(onRetry: onRetry, { try await client.headObject(key: key) }) {
            return Result(uuid: uuid, encryptedBytes: remoteSize, originalBytes: exported.byteSize,
                          filename: exported.filename,
                          plaintextHash: plainHash,
                          ciphertextHash: record.ciphertextHash ?? "",
                          alreadyPresent: true)
        }

        // 4. Encrypt to age, streaming chunk by chunk, computing the remaining
        //    digests in the same pass.
        onPhase?(.encrypting)
        let digests = try Self.encryptFile(at: originalURL, to: encryptedURL, recipients: recipients)
        let size = (try? FileManager.default.attributesOfItem(atPath: encryptedURL.path)[.size] as? Int64) ?? nil

        // 5. Upload the ciphertext (throttled when a speed limit is set;
        //    retried on transient errors — the encrypted temp is on disk, so a
        //    retry costs no re-export or re-encrypt).
        onPhase?(.uploading)
        try await S3Client.withRetries(onRetry: onRetry) {
            try await client.putObject(fileURL: encryptedURL, key: key,
                                       contentType: "application/age",
                                       contentMD5: digests.ciphertextMD5Base64,
                                       bytesPerSecond: bytesPerSecond,
                                       progress: progress)
        }
        return Result(uuid: uuid, encryptedBytes: size ?? 0, originalBytes: exported.byteSize,
                      filename: exported.filename,
                      plaintextHash: digests.plaintextSHA256,
                      ciphertextHash: digests.ciphertextSHA256,
                      alreadyPresent: false)
    }

    /// Stream `source` through the age encryptor into `destination`.
    @discardableResult
    static func encryptFile(at source: URL, to destination: URL,
                            recipients: [Age.Recipient]) throws -> EncryptDigests {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var plainSHA = SHA256()
        var cipherSHA = SHA256()
        var md5 = Insecure.MD5()
        let encryptor = try Age.Encryptor(recipients: recipients)
        while true {
            // autoreleasepool is essential: FileHandle.read returns autoreleased
            // buffers that otherwise pile up for the whole file — on a multi-GB
            // video that ballooned resident memory until iOS jetsam-killed us.
            let done = try autoreleasepool { () -> Bool in
                let chunk = try input.read(upToCount: Age.chunkSize) ?? Data()
                if chunk.isEmpty { return true }
                plainSHA.update(data: chunk)
                let out = try encryptor.update(chunk)
                if !out.isEmpty {
                    try output.write(contentsOf: out)
                    cipherSHA.update(data: out)
                    md5.update(data: out)
                }
                return false
            }
            if done { break }
        }
        let tail = try encryptor.finalize()
        if !tail.isEmpty {
            try output.write(contentsOf: tail)
            cipherSHA.update(data: tail)
            md5.update(data: tail)
        }
        return EncryptDigests(
            plaintextSHA256: plainSHA.finalize().map { String(format: "%02x", $0) }.joined(),
            ciphertextSHA256: cipherSHA.finalize().map { String(format: "%02x", $0) }.joined(),
            ciphertextMD5Base64: Data(md5.finalize()).base64EncodedString())
    }
}
