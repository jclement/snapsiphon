import Foundation
import CryptoKit

/// Takes a single asset from library → encrypted → bucket. Stateless aside from
/// its collaborators, so many can run concurrently. Each step streams through a
/// temp file so a 4K video never has to sit in memory in the clear.
struct AssetProcessor {
    let photos: PhotoLibrary
    let client: S3Client
    let recipients: [Age.Recipient]
    let encryptFilenames: Bool
    let tempDir: URL

    struct Result {
        var encryptedBytes: Int64
        var originalBytes: Int64
        var filename: String
        var remoteKey: String
        var alreadyPresent: Bool
    }

    func process(_ record: AssetRecord,
                 verifyFirst: Bool,
                 bytesPerSecond: Double,
                 onMeta: ((String, Int64) -> Void)? = nil,
                 progress: @escaping (Double) -> Void) async throws -> Result {
        let token = UUID().uuidString
        let originalURL = tempDir.appendingPathComponent("\(token).orig")
        let encryptedURL = tempDir.appendingPathComponent("\(token).age")
        defer {
            try? FileManager.default.removeItem(at: originalURL)
            try? FileManager.default.removeItem(at: encryptedURL)
        }

        // 1. Export the untouched original. This is where we learn the real
        //    filename + extension (both key schemes need the extension, so the
        //    key can only be resolved here, not at scan time).
        let exported = try await photos.exportOriginal(localIdentifier: record.localIdentifier, to: originalURL)
        onMeta?(exported.filename, exported.byteSize)

        let key = client.fullKey(for: Self.remoteKey(
            localIdentifier: record.localIdentifier, filename: exported.filename,
            createdAt: record.createdAt, mediaType: record.mediaType,
            encryptFilenames: encryptFilenames))

        // 2. Optionally skip if already present — this still saves the (large)
        //    encrypt + upload, though the export above already happened.
        if verifyFirst, try await client.headObject(key: key) {
            return Result(encryptedBytes: record.byteSize, originalBytes: exported.byteSize,
                          filename: exported.filename, remoteKey: key, alreadyPresent: true)
        }

        // 3. Encrypt to age, streaming chunk by chunk. We compute the ciphertext's
        //    MD5 in the same pass for the Content-MD5 header (Object-Lock buckets
        //    require it; a free integrity check everywhere else).
        let contentMD5 = try Self.encryptFile(at: originalURL, to: encryptedURL, recipients: recipients)
        let size = (try? FileManager.default.attributesOfItem(atPath: encryptedURL.path)[.size] as? Int64) ?? nil

        // 4. Upload the ciphertext (throttled when a speed limit is set).
        try await client.putObject(fileURL: encryptedURL, key: key,
                                   contentType: "application/age",
                                   contentMD5: contentMD5,
                                   bytesPerSecond: bytesPerSecond,
                                   progress: progress)
        return Result(encryptedBytes: size ?? 0, originalBytes: exported.byteSize,
                      filename: exported.filename, remoteKey: key, alreadyPresent: false)
    }

    /// Stream `source` through the age encryptor into `destination`, returning
    /// the Base64-encoded MD5 of the ciphertext (for the `Content-MD5` header).
    @discardableResult
    static func encryptFile(at source: URL, to destination: URL, recipients: [Age.Recipient]) throws -> String {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var md5 = Insecure.MD5()
        let encryptor = try Age.Encryptor(recipients: recipients)
        while true {
            let chunk = try input.read(upToCount: Age.chunkSize) ?? Data()
            if chunk.isEmpty { break }
            let out = try encryptor.update(chunk)
            if !out.isEmpty { try output.write(contentsOf: out); md5.update(data: out) }
        }
        let tail = try encryptor.finalize()
        if !tail.isEmpty { try output.write(contentsOf: tail); md5.update(data: tail) }
        return Data(md5.finalize()).base64EncodedString()
    }

    /// The object name for an asset. Deterministic from the stable local
    /// identifier, so re-runs overwrite the same object.
    /// - Filenames encrypted (default): `ab/<sha256>.<ext>.age` — the bucket
    ///   never sees the real name, but the extension is kept so you can tell a
    ///   PNG from a JPEG from a MOV at a glance (a small, deliberate leak).
    /// - Filenames plain: `yyyy/MM/<originalName>.age`.
    static func remoteKey(localIdentifier: String, filename: String, createdAt: Date?,
                          mediaType: AssetRecord.MediaType, encryptFilenames: Bool) -> String {
        let ext = fileExtension(filename: filename, mediaType: mediaType)
        if encryptFilenames {
            let digest = SHA256.hash(data: Data(localIdentifier.utf8))
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            return "\(hex.prefix(2))/\(hex).\(ext).age"
        } else {
            let stamp = Self.folderFormatter.string(from: createdAt ?? Date(timeIntervalSince1970: 0))
            let safe = filename.replacingOccurrences(of: "/", with: "_")
            return "\(stamp)/\(safe).age"
        }
    }

    /// Lowercased extension from the filename, falling back to a media-type guess.
    static func fileExtension(filename: String, mediaType: AssetRecord.MediaType) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        if !ext.isEmpty { return ext }
        switch mediaType {
        case .photo: return "jpg"
        case .video: return "mov"
        case .other: return "bin"
        }
    }

    private static let folderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy/MM"
        return f
    }()
}
