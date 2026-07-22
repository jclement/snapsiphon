import Foundation

/// The backup state of a single photo/video, as tracked in the local index.
enum AssetState: String, Codable {
    case pending      // discovered, not yet uploaded
    case uploading    // in flight
    case uploaded     // confirmed in the bucket
    case failed       // last attempt failed; will retry
    case skipped      // excluded by filters (e.g. media type off)
    case deleted      // removed on-device: a logical tombstone. The object may
                      // still exist in the bucket (Object Lock) until the
                      // lifecycle rule expires it; the manifest marks it gone.
}

/// One row in the backup index. `localIdentifier` is PhotoKit's stable asset id;
/// `remoteKey` is the object key we (will) store it under in the bucket.
struct AssetRecord: Identifiable, Codable, Equatable {
    var localIdentifier: String
    var remoteKey: String
    var state: AssetState
    var mediaType: MediaType
    var filename: String
    var byteSize: Int64
    var createdAt: Date?
    var uploadedAt: Date?
    var lastError: String?

    var id: String { localIdentifier }

    enum MediaType: String, Codable {
        case photo, video, other
    }
}
