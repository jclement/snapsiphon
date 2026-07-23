import Foundation
import Photos

/// Wraps PhotoKit: authorization, enumeration, and exporting an asset's original
/// file to a temp URL for encryption + upload. Uses the *original* resource so
/// backups are the untouched masters (including RAW/Live Photo components where
/// available), not re-encoded derivatives.
final class PhotoLibrary {

    enum AuthState {
        case notDetermined, authorized, limited, denied, restricted

        init(_ status: PHAuthorizationStatus) {
            switch status {
            case .authorized: self = .authorized
            case .limited: self = .limited
            case .denied: self = .denied
            case .restricted: self = .restricted
            default: self = .notDetermined
            }
        }

        var canRead: Bool { self == .authorized || self == .limited }
    }

    static func currentAuthState() -> AuthState {
        AuthState(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    static func requestAccess() async -> AuthState {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: AuthState(status))
            }
        }
    }

    /// A lightweight description of an asset for enumeration/filtering, so we
    /// don't hold `PHAsset` objects across async boundaries. Deliberately carries
    /// only cheap PHAsset properties — the filename/byte size (which require the
    /// expensive `PHAssetResource` lookup) are filled in lazily at upload time.
    struct AssetInfo {
        let localIdentifier: String
        let mediaType: AssetRecord.MediaType
        let creationDate: Date?
        let isFavorite: Bool
    }

    /// Enumerate the library honouring the media-type filters, oldest-first.
    ///
    /// `since` implements the fast-scan high-water mark: pass the newest
    /// creation date already indexed and PhotoKit only returns assets created
    /// after it — so after the first pass a scan touches just the new photos.
    /// No `PHAssetResource` lookups happen here, which is what made scanning a
    /// large library slow; those are deferred to the moment we actually upload.
    func enumerate(includePhotos: Bool, includeVideos: Bool, since: Date? = nil) -> [AssetInfo] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        var predicates: [NSPredicate] = []
        var typePredicates: [NSPredicate] = []
        if includePhotos {
            typePredicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue))
        }
        if includeVideos {
            typePredicates.append(NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue))
        }
        if !typePredicates.isEmpty {
            predicates.append(NSCompoundPredicate(orPredicateWithSubpredicates: typePredicates))
        }
        if let since {
            predicates.append(NSPredicate(format: "creationDate > %@", since as NSDate))
        }
        if !predicates.isEmpty {
            options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }

        let result = PHAsset.fetchAssets(with: options)
        var infos: [AssetInfo] = []
        infos.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            let mediaType: AssetRecord.MediaType
            switch asset.mediaType {
            case .image: mediaType = .photo
            case .video: mediaType = .video
            default: mediaType = .other
            }
            infos.append(AssetInfo(
                localIdentifier: asset.localIdentifier,
                mediaType: mediaType,
                creationDate: asset.creationDate,
                isFavorite: asset.isFavorite))
        }
        return infos
    }

    /// Cheap library totals by media type — PhotoKit keeps these counts, so no
    /// enumeration or resource lookups are needed. This is our denominator for
    /// "% of photos / videos backed up" (we can't cheaply know total *bytes*).
    /// `since` mirrors the backup-cutoff setting so the ring/banner denominator
    /// matches what the backup will actually cover.
    func libraryCounts(since: Date? = nil) -> (photos: Int, videos: Int) {
        func count(_ type: PHAssetMediaType) -> Int {
            let o = PHFetchOptions()
            var predicates = [NSPredicate(format: "mediaType == %d", type.rawValue)]
            if let since {
                predicates.append(NSPredicate(format: "creationDate >= %@", since as NSDate))
            }
            o.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            return PHAsset.fetchAssets(with: o).count
        }
        return (count(.image), count(.video))
    }

    /// Every asset identifier currently in the library (any media type). Used to
    /// detect on-device deletions for delete propagation — membership only, so
    /// it stays cheap even for large libraries.
    func allLocalIdentifiers() -> Set<String> {
        let options = PHFetchOptions()
        // MUST include hidden assets: this set defines "still exists on device"
        // for delete-tombstoning. Excluding hidden photos made Hiding a photo
        // indistinguishable from deleting it.
        options.includeHiddenAssets = true
        let result = PHAsset.fetchAssets(with: options)
        var ids = Set<String>()
        ids.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
        return ids
    }

    enum ExportError: Error, LocalizedError {
        case notFound
        case noResource
        case exportFailed(String)
        var errorDescription: String? {
            switch self {
            case .notFound: return "The photo is no longer in the library."
            case .noResource: return "No original file could be found for this item."
            case .exportFailed(let m): return "Could not export the original: \(m)"
            }
        }
    }

    /// The result of exporting an asset's original file: where it landed plus the
    /// metadata we deferred at scan time (original filename, byte size, type).
    struct Exported {
        let uti: String
        let filename: String
        let byteSize: Int64
    }

    /// Write the asset's original resource to `destination`, returning its
    /// filename/size/type. This is where the `PHAssetResource` lookup we skipped
    /// during scanning finally happens — but only for items we actually upload.
    func exportOriginal(localIdentifier: String, to destination: URL) async throws -> Exported {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = fetch.firstObject else { throw ExportError.notFound }

        let resources = PHAssetResource.assetResources(for: asset)
        // Prefer the true original (photo/video) resource.
        let preferred: PHAssetResourceType = asset.mediaType == .video ? .video : .photo
        let resource = resources.first { $0.type == preferred }
            ?? resources.first { $0.type == .fullSizePhoto || $0.type == .fullSizeVideo }
            ?? resources.first
        guard let resource else { throw ExportError.noResource }

        try? FileManager.default.removeItem(at: destination)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true  // fetch from iCloud if needed

        let filename = resource.originalFilename
        let uti = resource.uniformTypeIdentifier
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options) { error in
                if let error {
                    continuation.resume(throwing: ExportError.exportFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? nil
        return Exported(uti: uti, filename: filename, byteSize: size ?? 0)
    }
}
