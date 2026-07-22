import Foundation

/// A restore manifest: the mapping from opaque object keys back to original
/// filenames + metadata. Written to the bucket as `manifest.age` (itself
/// age-encrypted to your recipients), so a bucket-only disaster recovery can
/// decrypt it and rename every `<hash>.<ext>.age` blob back to its real name.
///
/// Portable JSON on purpose — restore doesn't need SnapSiphon:
///   age -d -i key.txt manifest.age | jq .
struct Manifest: Codable {
    let version: Int
    let generatedAt: String        // ISO-8601
    let bucket: String
    let prefix: String
    let count: Int
    let items: [Item]
    /// Object keys logically deleted on-device (blobs may still exist until
    /// purged). Restores skip these by default.
    let deletedKeys: [String]
    /// Full metadata for the deleted objects, so a disaster restore can still
    /// recover them (`restore.py --all`) — e.g. after an accidental library
    /// wipe marked everything deleted. Entries disappear once a blob is
    /// actually purged from the bucket.
    let deleted: [Item]

    struct Item: Codable {
        let key: String            // full object key in the bucket
        let filename: String       // original filename
        let mediaType: String
        let storedBytes: Int64     // size of the encrypted object
        let createdAt: String?     // ISO-8601, original capture date
        let uploadedAt: String?    // ISO-8601
    }
}
