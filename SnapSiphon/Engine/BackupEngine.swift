import Foundation
import SwiftUI
import UIKit

/// The brain. Owns configuration, the index, and the run loop; publishes live
/// state for the UI. Everything the dashboard shows flows from here.
@MainActor
final class BackupEngine: ObservableObject {

    enum Phase: Equatable {
        case idle
        case scanning
        case running
        case paused
        case finished
        case failed(String)

        var isActive: Bool { self == .scanning || self == .running }
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let date: Date
        let message: String
        let kind: Kind
        enum Kind { case info, success, warning, error }
    }

    // MARK: Published state
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var counts = BackupIndex.Counts()
    /// Fixed upload "lanes" — one per parallel thread, so the row count stays
    /// static during a run: a finished file's lane is reused by the next file
    /// instead of the row disappearing and a new one popping in (which jittered).
    /// `nil` = that lane is momentarily idle.
    @Published private(set) var uploadLanes: [UploadSlot?] = []

    struct UploadSlot: Identifiable, Equatable {
        let id: String            // localIdentifier
        var filename: String
        var progress: Double
        var byteSize: Int64       // original media size
        var isVideo: Bool
    }
    @Published private(set) var bytesPerSecond: Double = 0
    @Published private(set) var sessionUploaded: Int = 0
    @Published private(set) var sessionBytes: Int64 = 0
    @Published private(set) var bloomFillRatio: Double = 0
    @Published private(set) var bloomFalsePositiveRate: Double = 0
    @Published private(set) var photoAuth: PhotoLibrary.AuthState = PhotoLibrary.currentAuthState()
    @Published private(set) var log: [LogEntry] = []
    /// Number of library assets examined so far during a scan (for live feedback).
    @Published private(set) var scanChecked: Int = 0
    /// Library totals by type (denominator) and uploaded-by-type (numerator) for
    /// the photos/videos ring.
    @Published private(set) var libraryPhotos = 0
    @Published private(set) var libraryVideos = 0
    @Published private(set) var uploadedPhotos = 0
    @Published private(set) var uploadedVideos = 0
    @Published private(set) var storedPhotoBytes: Int64 = 0
    @Published private(set) var storedVideoBytes: Int64 = 0
    /// When the newest object in the bucket was uploaded (for the "last backup" gauge).
    @Published private(set) var lastBackupDate: Date?
    /// When the current backup run began (for throughput / ETA math).
    @Published private(set) var sessionStartedAt: Date?

    /// True while showing seeded demo data (DEBUG screenshot mode); suppresses
    /// the real index from overwriting the fake numbers.
    private var demoMode = false
    /// Non-nil while the run loop is parked on a closed condition gate
    /// (no Wi-Fi, low battery, offline). The dashboard surfaces it.
    @Published private(set) var waitingReason: String?

    // MARK: Configuration (observed by settings screens)
    @Published var settings: BackupSettings { didSet { settings.save() } }
    @Published var s3Config: S3Config { didSet { s3Config.save() } }

    let keyManager = AgeKeyManager.shared
    let conditions = ConditionsMonitor()
    private let photos = PhotoLibrary()
    private var index: BackupIndex?
    private var runTask: Task<Void, Never>?
    private var meter = ThroughputMeter()
    private let tempDir: URL

    init() {
        self.settings = BackupSettings.load()
        self.s3Config = S3Config.load()
        self.tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("snapsiphon-work", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        openIndex()
        refreshCounts()
        #if DEBUG
        if let mode = ProcessInfo.processInfo.environment["SNAPSIPHON_DEMO"] { seedDemoState(mode) }
        #endif
    }

    #if DEBUG
    /// Populate the app with rich fake data for screenshots / design iteration.
    /// Gated behind DEBUG + the SNAPSIPHON_DEMO env var, so it never ships.
    private func seedDemoState(_ mode: String) {
        demoMode = true   // makes isConfigured true without writing to Keychain/UserDefaults

        var c = BackupIndex.Counts()
        c.total = 12_843
        c.uploaded = 8_642
        c.pending = 4_197
        c.failed = 4
        c.uploadedBytes = 71_400_000_000     // ~71 GB
        c.totalBytes = c.uploadedBytes
        counts = c
        libraryPhotos = 11_040
        libraryVideos = 1_803
        uploadedPhotos = 7_986
        uploadedVideos = 656
        storedPhotoBytes = 27_800_000_000    // ~28 GB photos
        storedVideoBytes = 43_600_000_000    // ~44 GB videos
        bloomFillRatio = 0.34
        bloomFalsePositiveRate = 0.0008
        lastBackupDate = Date().addingTimeInterval(-42)

        if mode == "uploading" {
            phase = .running
            uploadLanes = [
                UploadSlot(id: "1", filename: "IMG_4821.HEIC", progress: 0.62, byteSize: 4_200_000, isVideo: false),
                UploadSlot(id: "2", filename: "IMG_4822.MOV", progress: 0.28, byteSize: 214_000_000, isVideo: true),
                UploadSlot(id: "3", filename: "IMG_4823.HEIC", progress: 0.91, byteSize: 3_900_000, isVideo: false),
            ]
            sessionUploaded = 143
            sessionBytes = 2_410_000_000
            bytesPerSecond = 8_600_000
            sessionStartedAt = Date().addingTimeInterval(-612)
        } else {
            phase = .idle
        }
    }
    #endif

    var isConfigured: Bool {
        if demoMode { return true }
        return keyManager.isConfigured && s3Config.isComplete && S3CredentialStore.hasCredentials
    }

    /// Rough estimate of seconds remaining for the current run, from the average
    /// per-file time so far. Nil until we have a completion to extrapolate from.
    func estimatedSecondsRemaining(now: Date = Date()) -> Double? {
        guard phase == .running, sessionUploaded > 0, counts.pending > 0,
              let start = sessionStartedAt else { return nil }
        let elapsed = now.timeIntervalSince(start)
        guard elapsed > 0 else { return nil }
        let perFile = elapsed / Double(sessionUploaded)
        return perFile * Double(counts.pending)
    }

    /// Average encrypted size across everything uploaded so far.
    var averageObjectBytes: Int64 {
        guard counts.uploaded > 0 else { return 0 }
        return counts.uploadedBytes / Int64(counts.uploaded)
    }

    // MARK: Index

    private func openIndex() {
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask, appropriateFor: nil, create: true)
            let dir = support.appendingPathComponent("SnapSiphon", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            index = try BackupIndex(directory: dir)
        } catch {
            appendLog("Could not open index: \(error.localizedDescription)", .error)
        }
    }

    func refreshCounts() {
        guard let index else { return }
        if demoMode { return }
        counts = index.counts()
        let byType = index.uploadedByType()
        uploadedPhotos = byType.photos
        uploadedVideos = byType.videos
        storedPhotoBytes = byType.photoBytes
        storedVideoBytes = byType.videoBytes
        lastBackupDate = index.recentUploads(limit: 1).first?.uploadedAt
        let bloom = index.bloomSnapshot
        bloomFillRatio = bloom.fillRatio
        bloomFalsePositiveRate = bloom.estimatedFalsePositiveRate
    }

    /// Refresh the library totals by type (cheap PhotoKit counts). Runs off-main
    /// and only when we have read access. Called on dashboard appear and scans.
    func refreshLibraryCounts() async {
        if demoMode || !photoAuth.canRead { return }
        let photos = self.photos
        let counts = await Task.detached(priority: .utility) { photos.libraryCounts() }.value
        libraryPhotos = counts.photos
        libraryVideos = counts.videos
    }

    // MARK: Permissions

    func requestPhotoAccess() async {
        photoAuth = await PhotoLibrary.requestAccess()
    }

    // MARK: Credentials

    func saveCredentials(accessKeyID: String, secret: String) {
        S3CredentialStore.save(S3Credentials(accessKeyID: accessKeyID, secretAccessKey: secret))
    }

    func makeClient() -> S3Client? {
        guard s3Config.isComplete, let creds = S3CredentialStore.load() else { return nil }
        return S3Client(config: s3Config, credentials: creds)
    }

    func testConnection() async -> Result<Void, Error> {
        guard let client = makeClient() else {
            return .failure(S3Error.badConfig)
        }
        do {
            try await client.testConnection()
            appendLog("Connection to \(s3Config.bucket) OK.", .success)
            return .success(())
        } catch {
            appendLog("Connection failed: \(error.localizedDescription)", .error)
            return .failure(error)
        }
    }

    // MARK: Scan

    /// Enumerate the library and register any not-yet-seen assets as pending.
    /// A normal (fast) scan: only looks at photos newer than the high-water mark.
    func scan() async { await runScan(deep: false) }

    /// A deep scan: ignores the high-water mark and re-checks the whole library.
    /// Use after importing older photos or changing filters.
    func deepScan() async { await runScan(deep: true) }

    private func runScan(deep: Bool) async {
        guard let index else { return }
        if !photoAuth.canRead {
            await requestPhotoAccess()
            guard photoAuth.canRead else {
                appendLog("Photo access is required to scan.", .warning)
                return
            }
        }
        phase = .scanning

        let includePhotos = settings.includePhotos
        let includeVideos = settings.includeVideos
        let favoritesOnly = settings.favoritesOnly
        let photos = self.photos
        // Fast-scan mark: only enumerate assets created after it (unless deep or
        // incremental scanning is disabled). Assets are enumerated oldest-first
        // so the mark only ever moves forward.
        let since: Date? = (deep || !settings.incrementalScan) ? nil : scanMark
        appendLog(deep ? "Deep scan — re-checking the whole library…"
                       : (since == nil ? "Scanning library…" : "Fast scan — checking new photos…"), .info)

        // One query for everything we already know, then in-memory membership
        // checks — no per-asset database round-trips.
        let known = index.allIdentifiers()
        let idx = index
        let startMark = scanMark
        scanChecked = 0

        // Enumerate AND index off the main actor so the UI stays live and we can
        // report progress as we go.
        let outcome: (added: Int, newest: Date?) = await Task.detached(priority: .utility) {
            let infos = photos.enumerate(includePhotos: includePhotos, includeVideos: includeVideos, since: since)
            var added = 0
            var newest = startMark
            for (i, info) in infos.enumerated() {
                if i % 250 == 0 {
                    let checked = i
                    await MainActor.run { self.scanChecked = checked }
                }
                if let d = info.creationDate, newest == nil || d > newest! { newest = d }
                if favoritesOnly && !info.isFavorite { continue }
                if known.contains(info.localIdentifier) { continue }
                idx.upsert(AssetRecord(
                    localIdentifier: info.localIdentifier,
                    remoteKey: "",             // resolved at upload (needs the file extension)
                    state: .pending,
                    mediaType: info.mediaType,
                    filename: "",             // filled in at upload (deferred PHAssetResource lookup)
                    byteSize: 0,
                    createdAt: info.creationDate,
                    uploadedAt: nil,
                    lastError: nil))
                added += 1
            }
            return (added, newest)
        }.value

        let added = outcome.added
        // Advance the mark so the next fast scan starts where this one ended.
        if settings.incrementalScan, let newest = outcome.newest { scanMark = newest }
        scanChecked = 0

        refreshCounts()
        await refreshLibraryCounts()
        appendLog("Scan complete — \(added) new item\(added == 1 ? "" : "s") queued.", .success)

        if settings.propagateDeletes {
            await reconcileDeletes()
        }
        phase = .idle
    }

    // MARK: Fast-scan high-water mark

    private static let manifestStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss'Z'"
        return f
    }()

    private static let scanMarkKey = "SnapSiphon.scanMark.v1"

    private var scanMark: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: Self.scanMarkKey)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: Self.scanMarkKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.scanMarkKey)
            }
        }
    }

    /// Reconcile on-device deletions (only when "Mirror deletions" is on).
    ///
    /// - Photos removed on-device become **tombstones**, stamped with the time so
    ///   the grace period can run. They're immediately recorded in the manifest.
    /// - Tombstoned photos that have **reappeared** in the library are resurrected
    ///   — this is the accidental-erase recovery: restore iCloud within the grace
    ///   window and nothing is lost.
    /// - Then `purgeTombstones` physically frees any that are past the grace
    ///   period (Object Lock permitting).
    private func reconcileDeletes() async {
        guard let index else { return }
        let photos = self.photos
        let liveIDs = await Task.detached(priority: .utility) { photos.allLocalIdentifiers() }.value

        // Resurrect tombstones whose asset is back in the library.
        var resurrected = 0
        for id in index.tombstonedIdentifiers() where liveIDs.contains(id) {
            index.resurrect(id); resurrected += 1
        }
        if resurrected > 0 {
            appendLog("\(resurrected) previously-deleted photo\(resurrected == 1 ? "" : "s") reappeared — kept.", .success)
        }

        // Tombstone assets we uploaded that are no longer anywhere in the library.
        let orphans = index.uploadedKeyPairs().filter { !liveIDs.contains($0.id) }
        let now = Date()
        for orphan in orphans { index.markDeleted(orphan.id, at: now) }
        if !orphans.isEmpty {
            appendLog("\(orphans.count) photo\(orphans.count == 1 ? "" : "s") deleted on device — tombstoned (grace \(settings.deleteGraceDays)d).", .warning)
        }

        if resurrected > 0 || !orphans.isEmpty {
            refreshCounts()
            if settings.keepBucketManifest { await writeManifest() }
        }

        await purgeTombstones()
    }

    /// Physically remove tombstones past the grace period, freeing bucket bytes.
    /// Each is version-deleted; Object Lock rejects any still under retention, so
    /// those stay tombstoned and are retried on a later scan — nothing recent can
    /// be wiped by a bulk mistake.
    private func purgeTombstones() async {
        guard let index, let client = makeClient() else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -settings.deleteGraceDays, to: Date()) ?? Date()
        let keys = index.purgeableKeys(before: cutoff)
        guard !keys.isEmpty else { return }

        var freed = 0, blocked = 0
        for key in keys {
            if Task.isCancelled { break }
            do {
                let versions = try await client.listVersions(forKey: key)
                var allGone = true
                for v in versions {
                    do { try await client.deleteObjectVersion(key: key, versionId: v.versionId) }
                    catch { allGone = false }          // locked / retention — retry later
                }
                if allGone { index.hardDelete(remoteKey: key); freed += 1 } else { blocked += 1 }
            } catch {
                blocked += 1                            // listing failed — retry later
            }
        }
        if freed > 0 {
            appendLog("Freed \(freed) deleted backup\(freed == 1 ? "" : "s") from the bucket.", .info)
            if settings.keepBucketManifest { await writeManifest() }
        }
        if blocked > 0 {
            appendLog("\(blocked) deletion\(blocked == 1 ? "" : "s") still locked — will retry once Object Lock retention expires.", .info)
        }
        refreshCounts()
    }

    /// Build the encrypted restore manifest and upload it to the bucket as
    /// `manifest.age`. Encrypted to the same recipients, so the provider still
    /// sees only ciphertext, but you can `age -d` it to recover every filename.
    @discardableResult
    func writeManifest() async -> Result<Int, Error> {
        guard let index, let client = makeClient() else { return .failure(S3Error.badConfig) }
        let recipients = keyManager.recipientObjects
        guard !recipients.isEmpty else { return .failure(Age.Error.badRecipient) }

        let iso = ISO8601DateFormatter()
        let records = index.allUploaded()
        let items = records.map { r in
            Manifest.Item(key: r.remoteKey, filename: r.filename, mediaType: r.mediaType.rawValue,
                          storedBytes: r.byteSize,
                          createdAt: r.createdAt.map { iso.string(from: $0) },
                          uploadedAt: r.uploadedAt.map { iso.string(from: $0) })
        }
        let manifest = Manifest(version: 1, generatedAt: iso.string(from: Date()),
                                bucket: s3Config.bucket, prefix: s3Config.prefix,
                                count: items.count, items: items,
                                deletedKeys: index.deletedKeys())

        let token = UUID().uuidString
        let jsonURL = tempDir.appendingPathComponent("\(token).json")
        let encURL = tempDir.appendingPathComponent("\(token).manifest.age")
        defer {
            try? FileManager.default.removeItem(at: jsonURL)
            try? FileManager.default.removeItem(at: encURL)
        }
        do {
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: jsonURL)
            let md5 = try AssetProcessor.encryptFile(at: jsonURL, to: encURL, recipients: recipients)
            // Unique, write-once key: never overwrites (Object-Lock safe), and old
            // manifests expire under the same lifecycle rule while the newest stays
            // fresh. Restore lists `manifests/` and takes the last one.
            let stamp = Self.manifestStampFormatter.string(from: Date())
            let key = client.fullKey(for: "manifests/manifest-\(stamp).age")
            try await client.putObject(fileURL: encURL, key: key,
                                       contentType: "application/age", contentMD5: md5)
            appendLog("Wrote encrypted manifest (\(items.count) item\(items.count == 1 ? "" : "s")) → \(key).", .success)
            return .success(items.count)
        } catch {
            appendLog("Manifest write failed: \(error.localizedDescription)", .error)
            return .failure(error)
        }
    }

    // MARK: Backup run

    /// One-tap entry point for the dashboard: scan for new photos, then upload.
    func backUpNow() {
        guard runTask == nil, phase != .scanning else { return }
        Task { await scan(); start() }
    }

    func start() {
        guard runTask == nil else { return }
        guard isConfigured else {
            appendLog("Finish setup (key + storage) before backing up.", .warning)
            return
        }
        let recipients = keyManager.recipientObjects
        guard !recipients.isEmpty, let client = makeClient() else {
            phase = .failed("Missing key or storage configuration.")
            return
        }
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOnWhileUploading

        phase = .running
        sessionUploaded = 0
        sessionBytes = 0
        sessionStartedAt = Date()
        // One fixed lane per parallel thread — the row count stays put all run.
        let concurrency = max(1, min(settings.parallelUploads, BackupSettings.parallelRange.upperBound))
        uploadLanes = Array(repeating: nil, count: concurrency)
        meter.reset()
        appendLog("Backup started.", .info)

        let processor = AssetProcessor(photos: photos, client: client, recipients: recipients,
                                       encryptFilenames: settings.encryptFilenames, tempDir: tempDir)

        runTask = Task { [weak self] in
            await self?.runLoop(processor: processor)
            await MainActor.run { [weak self] in
                self?.finishRun()
            }
        }
    }

    func pause() {
        runTask?.cancel()
        runTask = nil
        phase = .paused
        waitingReason = nil
        uploadLanes.removeAll()
        UIApplication.shared.isIdleTimerDisabled = false
        appendLog("Paused.", .warning)
    }

    private func finishRun() {
        runTask = nil
        waitingReason = nil
        UIApplication.shared.isIdleTimerDisabled = false
        refreshCounts()
        index?.persistBloom()
        uploadLanes.removeAll()
        bytesPerSecond = 0
        if phase == .running {
            phase = .finished
            appendLog("Backup finished — \(sessionUploaded) uploaded this session.", .success)
        }
        // Refresh the bucket manifest if this run actually uploaded anything.
        if settings.keepBucketManifest && sessionUploaded > 0 {
            Task { await writeManifest() }
        }
    }

    // MARK: Per-stream upload slots

    private func beginSlot(_ record: AssetRecord) {
        let slot = UploadSlot(id: record.localIdentifier,
                              filename: record.filename.isEmpty ? "Preparing…" : record.filename,
                              progress: 0,
                              byteSize: record.byteSize,
                              isVideo: record.mediaType == .video)
        // Claim the first idle lane; grow only if somehow all are busy.
        if let i = uploadLanes.firstIndex(where: { $0 == nil }) {
            uploadLanes[i] = slot
        } else {
            uploadLanes.append(slot)
        }
    }

    private func updateSlot(_ id: String, filename: String? = nil, byteSize: Int64? = nil, progress: Double? = nil) {
        guard let i = uploadLanes.firstIndex(where: { $0?.id == id }) else { return }
        if let filename { uploadLanes[i]?.filename = filename }
        if let byteSize { uploadLanes[i]?.byteSize = byteSize }
        if let progress { uploadLanes[i]?.progress = progress }
    }

    private func endSlot(_ id: String) {
        // Free the lane (keep the row) so the next file reuses this position.
        if let i = uploadLanes.firstIndex(where: { $0?.id == id }) { uploadLanes[i] = nil }
    }

    private func runLoop(processor: AssetProcessor) async {
        guard let index else { return }
        let batchSize = 200
        // Convert the MB/s knob to bytes/s once per run (0 = unlimited).
        let bytesPerSecond = settings.speedLimitMBps * 1_000_000
        let verifyFirst = settings.verifyRemoteBeforeUpload

        while !Task.isCancelled {
            // Park here while a condition gate (Wi-Fi / battery / offline) is closed.
            if await !waitForFavorableConditions() { break }

            let pending = index.pendingRecords(limit: batchSize)
            if pending.isEmpty { break }

            let concurrency = max(1, min(settings.parallelUploads, BackupSettings.parallelRange.upperBound))

            await withTaskGroup(of: Void.self) { group in
                var iterator = pending.makeIterator()
                var inFlight = 0

                @Sendable func spawn(_ record: AssetRecord) {
                    group.addTask { [weak self] in
                        await self?.processOne(record, processor: processor,
                                               verifyFirst: verifyFirst, bytesPerSecond: bytesPerSecond)
                    }
                }

                // Prime the group up to the concurrency limit.
                while inFlight < concurrency, let next = iterator.next() {
                    spawn(next); inFlight += 1
                }
                // As each finishes, start the next.
                while await group.next() != nil {
                    inFlight -= 1
                    if Task.isCancelled { break }
                    if let next = iterator.next() { spawn(next); inFlight += 1 }
                }
            }
            refreshCounts()
            if Task.isCancelled { break }
        }
    }

    /// Blocks until the user's network/battery gates all open, or the task is
    /// cancelled. Returns false if cancelled while waiting.
    private func waitForFavorableConditions() async -> Bool {
        while !Task.isCancelled {
            let reason = conditions.blockReason(for: settings)
            if reason == nil {
                if waitingReason != nil { waitingReason = nil }
                return true
            }
            if waitingReason != reason {
                waitingReason = reason
                appendLog(reason!, .warning)
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)  // re-check every 3s
        }
        return false
    }

    private func processOne(_ record: AssetRecord, processor: AssetProcessor,
                            verifyFirst: Bool, bytesPerSecond: Double) async {
        guard let index else { return }
        let rid = record.localIdentifier
        beginSlot(record)
        do {
            var uploaded = AssetRecord(localIdentifier: rid, remoteKey: record.remoteKey,
                                       state: .uploading, mediaType: record.mediaType, filename: record.filename,
                                       byteSize: record.byteSize, createdAt: record.createdAt,
                                       uploadedAt: nil, lastError: nil)
            index.upsert(uploaded)

            let result = try await processor.process(
                record, verifyFirst: verifyFirst, bytesPerSecond: bytesPerSecond,
                onMeta: { filename, size in
                    Task { @MainActor in self.updateSlot(rid, filename: filename, byteSize: size) }
                },
                progress: { p in
                    Task { @MainActor in self.updateSlot(rid, progress: p) }
                })

            // Persist the metadata we learned at upload time (filename/size/key).
            uploaded.state = .uploaded
            uploaded.filename = result.filename
            uploaded.remoteKey = result.remoteKey
            uploaded.byteSize = result.encryptedBytes
            uploaded.uploadedAt = Date()
            index.upsert(uploaded)

            endSlot(rid)
            sessionUploaded += 1
            if !result.alreadyPresent {
                sessionBytes += result.encryptedBytes
                meter.record(bytes: result.encryptedBytes)
                self.bytesPerSecond = meter.bytesPerSecond()
            }
            refreshCounts()
        } catch is CancellationError {
            index.markFailed(rid, error: "Cancelled")
            endSlot(rid)
        } catch {
            index.markFailed(rid, error: error.localizedDescription)
            endSlot(rid)
            appendLog("Failed \(record.filename): \(error.localizedDescription)", .error)
        }
    }

    // MARK: Maintenance

    func resetIndex() {
        index?.reset()
        scanMark = nil
        refreshCounts()
        appendLog("Local index cleared. Next scan re-checks everything.", .warning)
    }

    // MARK: Logging

    private func appendLog(_ message: String, _ kind: LogEntry.Kind) {
        log.insert(LogEntry(date: Date(), message: message, kind: kind), at: 0)
        if log.count > 200 { log.removeLast(log.count - 200) }
    }
}
