import Foundation
import Photos

/// Wraps PhotoKit: authorization, enumeration, and exporting an asset's original
/// file to a temp URL for encryption + upload. Uses the *original* resource so
/// backups are untouched masters, not re-encoded derivatives. One resource per
/// asset: a Live Photo's motion clip and a RAW+JPEG's secondary file are NOT
/// yet included (disclosed in Help).
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
        let isLivePhoto: Bool
        let isHidden: Bool
    }

    /// Enumerate the WHOLE library — every photo and video, Hidden album
    /// included (as far as iOS lets us see it), oldest-first — as cheap
    /// `AssetInfo` values. Deliberately unfiltered: one pass feeds everything a
    /// scan needs (eligibility under the current settings is decided by the
    /// caller, per asset), the Hidden-album flags, AND the liveness set for
    /// deletion reconciliation. There is no incremental mark to fall behind.
    /// No `PHAssetResource` lookups happen here, which is what made scanning a
    /// large library slow; those are deferred to the moment we actually upload.
    func enumerateAll() -> [AssetInfo] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue),
            NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue),
        ])

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
                isFavorite: asset.isFavorite,
                isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
                isHidden: asset.isHidden))
        }
        return infos
    }

    /// Cheap library totals by media type — PhotoKit keeps these counts, so no
    /// enumeration or resource lookups are needed. This is our denominator for
    /// "% of photos / videos backed up" (we can't cheaply know total *bytes*).
    /// `since` mirrors the backup-cutoff setting and `favoritesOnly` the
    /// favorites filter, so the ring/banner denominator matches what the
    /// backup will actually cover. These predicates MUST agree with the
    /// per-asset eligibility test in the engine's scan (`>=` on the cutoff),
    /// or the dashboard counts things no scan will ever queue.
    func libraryCounts(since: Date? = nil, includeHidden: Bool = false,
                       favoritesOnly: Bool = false) -> (photos: Int, videos: Int) {
        func count(_ type: PHAssetMediaType) -> Int {
            let o = PHFetchOptions()
            o.includeHiddenAssets = includeHidden
            var predicates = [NSPredicate(format: "mediaType == %d", type.rawValue)]
            if let since {
                predicates.append(NSPredicate(format: "creationDate >= %@", since as NSDate))
            }
            if favoritesOnly {
                predicates.append(NSPredicate(format: "isFavorite == YES"))
            }
            o.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            return PHAsset.fetchAssets(with: o).count
        }
        return (count(.image), count(.video))
    }

    /// Enumerate lightweight identity metadata for repository attachment
    /// checks. This reads PhotoKit's resource metadata but never downloads or
    /// hashes an original, so even an iCloud-backed library stays inexpensive.
    /// Live Photo motion resources are represented separately because the
    /// repository stores them as separate backup records.
    func comparisonRecords() -> [LibraryComparisonRecord] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        let result = PHAsset.fetchAssets(with: options)
        var records: [LibraryComparisonRecord] = []
        records.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            let mediaType: AssetRecord.MediaType
            let preferred: PHAssetResourceType
            switch asset.mediaType {
            case .image:
                mediaType = .photo
                preferred = .photo
            case .video:
                mediaType = .video
                preferred = .video
            default:
                return
            }
            let resources = PHAssetResource.assetResources(for: asset)
            let original = resources.first { $0.type == preferred }
                ?? resources.first { $0.type == .fullSizePhoto || $0.type == .fullSizeVideo }
                ?? resources.first
            records.append(LibraryComparisonRecord(
                localIdentifier: asset.localIdentifier,
                mediaType: mediaType,
                filename: original?.originalFilename ?? "",
                createdAt: asset.creationDate))

            if asset.mediaSubtypes.contains(.photoLive),
               let motion = resources.first(where: { $0.type == .fullSizePairedVideo })
                    ?? resources.first(where: { $0.type == .pairedVideo }) {
                records.append(LibraryComparisonRecord(
                    localIdentifier: AssetRecord.liveMotionIdentifier(for: asset.localIdentifier),
                    mediaType: .other,
                    filename: motion.originalFilename,
                    createdAt: asset.creationDate))
            }
        }
        return records
    }

    enum ExportError: Error, LocalizedError {
        case notFound
        case noResource
        case hiddenExcluded
        case exportFailed(String)
        var errorDescription: String? {
            switch self {
            case .notFound: return "The photo is no longer in the library."
            case .noResource: return "No original file could be found for this item."
            case .hiddenExcluded: return "This photo is in the Hidden album, which is excluded by settings."
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
    /// `allowHidden` gates Hidden-album assets EXPLICITLY: the identifier
    /// fetch must always include hidden assets (a default fetch silently
    /// returns nothing for a hidden photo — indistinguishable from deleted),
    /// then we decide, so "hidden" can never masquerade as "not found".
    func exportOriginal(localIdentifier: String, to destination: URL,
                        allowHidden: Bool = true) async throws -> Exported {
        let asset = try fetchAsset(localIdentifier, allowHidden: allowHidden)

        let resources = PHAssetResource.assetResources(for: asset)
        // Prefer the true original (photo/video) resource.
        let preferred: PHAssetResourceType = asset.mediaType == .video ? .video : .photo
        let resource = resources.first { $0.type == preferred }
            ?? resources.first { $0.type == .fullSizePhoto || $0.type == .fullSizeVideo }
            ?? resources.first
        guard let resource else { throw ExportError.noResource }
        return try await writeResource(resource, to: destination)
    }

    /// Export a Live Photo's paired motion clip (the ~3 s video that plays on
    /// press). Throws `.noResource` for assets without one.
    func exportLiveMotion(localIdentifier: String, to destination: URL,
                          allowHidden: Bool = true) async throws -> Exported {
        let asset = try fetchAsset(localIdentifier, allowHidden: allowHidden)
        let resources = PHAssetResource.assetResources(for: asset)
        let resource = resources.first { $0.type == .fullSizePairedVideo }
            ?? resources.first { $0.type == .pairedVideo }
        guard let resource else { throw ExportError.noResource }
        return try await writeResource(resource, to: destination)
    }

    private func fetchAsset(_ localIdentifier: String, allowHidden: Bool) throws -> PHAsset {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: options)
        guard let asset = fetch.firstObject else { throw ExportError.notFound }
        if asset.isHidden && !allowHidden { throw ExportError.hiddenExcluded }
        return asset
    }

    private func writeResource(_ resource: PHAssetResource, to destination: URL) async throws -> Exported {
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
