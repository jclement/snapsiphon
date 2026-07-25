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
    /// Hidden-album membership (read-only mirror; the scan refreshes the
    /// underlying column in batches — upserts never write it).
    var hidden: Bool = false

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

/// Cheap, read-only PhotoKit metadata used to answer whether a repository
/// appears to have come from the Photos library currently visible to the app.
/// No originals are downloaded or hashed for this comparison.
struct LibraryComparisonRecord: Equatable {
    var localIdentifier: String
    var mediaType: AssetRecord.MediaType
    var filename: String
    var createdAt: Date?
}

struct RepositoryLibraryMatch: Equatable {
    var repositoryCount: Int
    var libraryCount: Int
    var exactIdentifierMatches: Int
    var metadataMatches: Int

    var matchedCount: Int { exactIdentifierMatches + metadataMatches }
    var repositoryNotFound: Int { repositoryCount - matchedCount }
}

enum RepositoryLibraryMatcher {
    /// Match exact PhotoKit identifiers first. If identifiers changed during a
    /// reinstall/device migration, accept only a one-to-one metadata match:
    /// original filename + media kind + capture second. Ambiguous bursts or
    /// missing metadata stay unmatched rather than producing false confidence.
    static func compare(repository: [AssetRecord],
                        library: [LibraryComparisonRecord]) -> RepositoryLibraryMatch {
        var remainingRepo = Dictionary(uniqueKeysWithValues:
            repository.enumerated().map { ($0.offset, $0.element) })
        var remainingLibrary = Dictionary(uniqueKeysWithValues:
            library.enumerated().map { ($0.offset, $0.element) })

        var libraryByIdentifier: [String: [Int]] = [:]
        for (index, item) in remainingLibrary {
            libraryByIdentifier[item.localIdentifier, default: []].append(index)
        }

        var exact = 0
        for repoIndex in Array(remainingRepo.keys) {
            guard let record = remainingRepo[repoIndex] else { continue }
            guard var candidates = libraryByIdentifier[record.localIdentifier],
                  let libraryIndex = candidates.popLast(),
                  remainingLibrary[libraryIndex] != nil else { continue }
            libraryByIdentifier[record.localIdentifier] = candidates
            remainingRepo.removeValue(forKey: repoIndex)
            remainingLibrary.removeValue(forKey: libraryIndex)
            exact += 1
        }

        struct MetadataKey: Hashable {
            let mediaType: AssetRecord.MediaType
            let filename: String
            let captureSecond: Int64
        }
        func key(mediaType: AssetRecord.MediaType, filename: String,
                 createdAt: Date?) -> MetadataKey? {
            let normalized = filename
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !normalized.isEmpty, let createdAt else { return nil }
            return MetadataKey(mediaType: mediaType, filename: normalized,
                               captureSecond: Int64(createdAt.timeIntervalSince1970))
        }

        var repoByMetadata: [MetadataKey: [Int]] = [:]
        for (index, record) in remainingRepo {
            if let k = key(mediaType: record.mediaType, filename: record.filename,
                           createdAt: record.createdAt) {
                repoByMetadata[k, default: []].append(index)
            }
        }
        var libraryByMetadata: [MetadataKey: [Int]] = [:]
        for (index, item) in remainingLibrary {
            if let k = key(mediaType: item.mediaType, filename: item.filename,
                           createdAt: item.createdAt) {
                libraryByMetadata[k, default: []].append(index)
            }
        }

        var metadata = 0
        for (key, repoIndexes) in repoByMetadata where repoIndexes.count == 1 {
            guard libraryByMetadata[key]?.count == 1 else { continue }
            metadata += 1
        }

        return RepositoryLibraryMatch(
            repositoryCount: repository.count,
            libraryCount: library.count,
            exactIdentifierMatches: exact,
            metadataMatches: metadata)
    }
}
