import Foundation

/// The backup state of a single photo/video, as tracked in the local index.
enum AssetState: String, Codable {
    case pending      // discovered, not yet uploaded
    case uploading    // in flight
    case uploaded     // blob confirmed in the bucket
    case failed       // last attempt failed; will retry
    case skipped      // excluded by filters (e.g. media type off)
    case deleted      // removed on-device: journaled tombstone. The blob may
                      // still exist until purged; restores skip it by default.
}

/// One row in the backup index (which is a CACHE — the repository's
/// checkpoint + journals in the bucket are the source of truth).
struct AssetRecord: Identifiable, Codable, Equatable {
    var localIdentifier: String
    /// Random blob name in the bucket (`objects/<uuid>`). Assigned at first
    /// upload; carries no information about the content.
    var uuid: String
    var state: AssetState
    var mediaType: MediaType
    var filename: String
    var byteSize: Int64                // ciphertext size once uploaded
    var createdAt: Date?
    var uploadedAt: Date?
    var lastError: String?
    /// sha256 of the original plaintext file (restore-time verification).
    var plaintextHash: String? = nil
    /// sha256 of the stored ciphertext blob (repository verification).
    var ciphertextHash: String? = nil
    /// False while this row's latest change has not yet been committed to a
    /// journal in the bucket. Uncommitted uploads are re-journaled next flush;
    /// if the cache is lost first, their blobs are ignorable orphans.
    var journaled: Bool = false

    var id: String { localIdentifier }

    enum MediaType: String, Codable {
        case photo, video, other
    }
}

extension AssetRecord {
    /// Suffix marking a Live Photo's paired motion-clip record. The base
    /// (unsuffixed) localIdentifier is the still photo's asset id — library
    /// membership checks must always use the base.
    static let liveMotionSuffix = "#live"

    static func liveMotionIdentifier(for base: String) -> String { base + liveMotionSuffix }

    static func baseIdentifier(_ id: String) -> String {
        id.hasSuffix(liveMotionSuffix) ? String(id.dropLast(liveMotionSuffix.count)) : id
    }

    static func isLiveMotion(_ id: String) -> Bool { id.hasSuffix(liveMotionSuffix) }
}
