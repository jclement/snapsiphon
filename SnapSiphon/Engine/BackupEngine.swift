import Foundation
import SwiftUI
import UIKit
import BackgroundTasks
import UserNotifications

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
        var phase: AssetProcessor.Phase = .exporting
    }
    @Published private(set) var bytesPerSecond: Double = 0
    @Published private(set) var sessionUploaded: Int = 0
    @Published private(set) var sessionBytes: Int64 = 0
    @Published private(set) var photoAuth: PhotoLibrary.AuthState = PhotoLibrary.currentAuthState()
    @Published private(set) var log: [LogEntry] = []
    /// Number of library assets examined so far during a scan (for live feedback).
    @Published private(set) var scanChecked: Int = 0
    /// Result of the last completed scan (shown at the Deep-scan button).
    @Published private(set) var scanStatus: String?
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
    /// Face ID gate for the Settings tab once the app is configured — so nobody
    /// holding the unlocked phone can quietly add a key or redirect the bucket.
    /// Cleared whenever the app goes to the background.
    @Published var settingsUnlocked = false

    // MARK: Configuration (observed by settings screens)
    @Published var settings: BackupSettings { didSet { settings.save() } }
    @Published var s3Config: S3Config { didSet { s3Config.save() } }

    let keyManager = AgeKeyManager.shared
    let conditions = ConditionsMonitor()
    private let photos = PhotoLibrary()
    private var index: BackupIndex?
    private var runTask: Task<Void, Never>?
    /// The previous run while its cancelled tasks finish unwinding.
    private var drainingTask: Task<Void, Never>?
    private var meter = ThroughputMeter()
    private let tempDir: URL

    init() {
        self.settings = BackupSettings.load()
        self.s3Config = S3Config.load()
        self.tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("snapsiphon-work", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // Sweep temp leftovers from a previous crash/kill so they can't
        // accumulate and eat disk (each dead run could strand up to
        // 2×parallelism part-written files here).
        if let leftovers = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
            for f in leftovers { try? FileManager.default.removeItem(at: f) }
        }
        openIndex()
        refreshCounts()
        #if DEBUG
        if let mode = ProcessInfo.processInfo.environment["SNAPSIPHON_DEMO"] { seedDemoState(mode) }
        #endif
        // First run: mint this phone's own key by default so backups can start
        // right away and the restore script is turnkey. Never touches an
        // already-configured key set.
        if !demoMode, keyManager.ensureDefaultIdentity() {
            appendLog("Generated this phone's encryption key. Reveal & back it up in Settings → Encryption key (requires Face ID).", .info)
        }
        registerBackgroundTask()
        rescheduleReminder()
    }

    #if DEBUG
    /// Populate the app with rich fake data for screenshots / design iteration.
    /// Gated behind DEBUG + the SNAPSIPHON_DEMO env var, so it never ships.
    private func seedDemoState(_ mode: String) {
        demoMode = true   // makes isConfigured true without writing to Keychain/UserDefaults
        settingsUnlocked = true

        var c = BackupIndex.Counts()
        c.total = 12_843
        c.uploaded = 8_642
        c.pending = 4_197
        c.failed = mode == "ready" ? 0 : 4
        c.uploadedBytes = 71_400_000_000     // ~71 GB
        c.totalBytes = c.uploadedBytes
        counts = c
        libraryPhotos = 11_040
        libraryVideos = 1_803
        uploadedPhotos = 7_986
        uploadedVideos = 656
        storedPhotoBytes = 27_800_000_000    // ~28 GB photos
        storedVideoBytes = 43_600_000_000    // ~44 GB videos
        lastBackupDate = Date().addingTimeInterval(-42)

        if mode == "uploading" {
            phase = .running
            uploadLanes = [
                UploadSlot(id: "1", filename: "IMG_4821.HEIC", progress: 0.62, byteSize: 4_200_000, isVideo: false, phase: .uploading),
                UploadSlot(id: "2", filename: "IMG_4822.MOV", progress: 0.28, byteSize: 214_000_000, isVideo: true, phase: .encrypting),
                UploadSlot(id: "3", filename: "IMG_4823.HEIC", progress: 0, byteSize: 3_900_000, isVideo: false, phase: .exporting),
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

    /// The clamped parallel-upload setting (read live by the run loop).
    var workerTarget: Int {
        max(1, min(settings.parallelUploads, BackupSettings.parallelRange.upperBound))
    }

    /// Not-yet-uploaded counts per type (library total minus uploaded) — covers
    /// both indexed-pending items AND new photos no scan has seen yet, which is
    /// what the "ready to back up" banner needs at launch.
    var toBackupPhotos: Int { settings.includePhotos ? max(0, libraryPhotos - uploadedPhotos) : 0 }
    var toBackupVideos: Int { settings.includeVideos ? max(0, libraryVideos - uploadedVideos) : 0 }

    // MARK: Background backup (BGProcessingTask)

    static let bgTaskID = "com.snapsiphon.backup"

    /// Must be called before the app finishes launching (we call it from init).
    nonisolated func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.bgTaskID, using: nil) { [weak self] task in
            guard let self, let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleBackgroundTask(task)
        }
    }

    nonisolated private func handleBackgroundTask(_ task: BGProcessingTask) {
        Task { @MainActor in
            self.scheduleBackgroundBackup()   // chain the next window first
            guard self.settings.backgroundBackup, self.isConfigured, self.runTask == nil else {
                task.setTaskCompleted(success: true)
                return
            }
            // On expiry, pause gracefully — the index checkpoints per file, so
            // whatever uploaded stays uploaded and the rest resumes next window.
            task.expirationHandler = { [weak self] in
                Task { @MainActor in self?.pause() }
            }
            self.appendLog("Background window granted — backing up…", .info)
            await self.scan()
            self.start()
            await self.runTask?.value
            self.rescheduleReminder()
            task.setTaskCompleted(success: true)
        }
    }

    /// Ask iOS for a future processing window (requires power + network, at
    /// least 30 min out). iOS decides when — typically overnight on charge.
    func scheduleBackgroundBackup() {
        guard settings.backgroundBackup, isConfigured else { return }
        let request = BGProcessingTaskRequest(identifier: Self.bgTaskID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: Reminder notifications

    /// (Re)schedule the "no backup for N days" local notification. Called after
    /// every completed run and whenever the setting changes, so the countdown
    /// always measures from the last backup.
    func rescheduleReminder() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["com.snapsiphon.reminder"])
        let days = settings.reminderDays
        guard days > 0 else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Photos waiting to be backed up"
            content.body = "It's been \(days) day\(days == 1 ? "" : "s") since your last SnapSiphon backup. Tap to protect what's new."
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: TimeInterval(days) * 86_400, repeats: true)
            center.add(UNNotificationRequest(identifier: "com.snapsiphon.reminder",
                                             content: content, trigger: trigger))
        }
    }

    // MARK: Auto backup

    private static let lastRunKey = "SnapSiphon.lastRunCompletedAt"

    /// If enabled, kick off a backup when the app opens/foregrounds — but only
    /// when the last completed run is more than 30 minutes old, so quick app
    /// switches don't thrash scans.
    func autoBackupIfDue() {
        guard settings.autoStartOnLaunch, isConfigured, runTask == nil,
              phase != .scanning, !verifying else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastRunKey)
        if last > 0, Date().timeIntervalSince1970 - last < 30 * 60 { return }
        appendLog("Auto backup — last run more than 30 minutes ago.", .info)
        backUpNow()
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
        // Re-scan a 48h overlap behind the mark: an iCloud photo taken earlier
        // on another device can sync in with a creationDate BEHIND the mark and
        // would otherwise be skipped forever. The known-set dedups the overlap,
        // so this costs almost nothing. (Imports older than 48h → Deep scan.)
        let since: Date? = (deep || !settings.incrementalScan)
            ? nil : scanMark?.addingTimeInterval(-48 * 3600)
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
        let outcome: (added: Int, newest: Date?, checked: Int) = await Task.detached(priority: .utility) {
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
            return (added, newest, infos.count)
        }.value

        let added = outcome.added
        // Advance the mark so the next fast scan starts where this one ended.
        if settings.incrementalScan, let newest = outcome.newest { scanMark = newest }
        scanChecked = 0

        refreshCounts()
        await refreshLibraryCounts()
        // An explicit result — especially for deep scans, where "found nothing
        // new" is the common case and used to be indistinguishable from a no-op.
        scanStatus = added == 0
            ? "✓ \(deep ? "Deep scan" : "Scan") checked \(Format.count(outcome.checked)) item\(outcome.checked == 1 ? "" : "s") — nothing new, everything already indexed"
            : "✓ \(deep ? "Deep scan" : "Scan") checked \(Format.count(outcome.checked)) — \(Format.count(added)) new queued"
        appendLog("Scan complete — \(added) new item\(added == 1 ? "" : "s") queued.", .success)

        // Deletions are ALWAYS reconciled into the manifest (tombstones +
        // resurrections) so restores reflect reality; the toggle only governs
        // whether blobs are physically purged.
        await reconcileDeletes()
        phase = .idle
    }

    // MARK: Fast-scan high-water mark

    /// True whenever the archive's contents have changed since the last
    /// *successful* manifest write. Persisted, so a failed write (or a kill
    /// mid-run) is retried at the end of the next run even if that run
    /// uploads nothing.
    private var manifestDirty: Bool {
        get { UserDefaults.standard.bool(forKey: "SnapSiphon.manifestDirty") }
        set { UserDefaults.standard.set(newValue, forKey: "SnapSiphon.manifestDirty") }
    }

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

    /// Reconcile on-device deletions — runs on EVERY scan:
    ///
    /// - Photos removed on-device become **tombstones**, stamped with the time,
    ///   and are immediately marked deleted in the manifest (restores skip them
    ///   by default; `restore.py --all` can still recover un-purged ones).
    /// - Tombstoned photos that have **reappeared** in the library are
    ///   resurrected — the accidental-erase recovery.
    /// - Only when "Purge deleted backups" is on does `purgeTombstones` then
    ///   physically free blobs past the grace period (Object Lock permitting).
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
            appendLog("\(orphans.count) photo\(orphans.count == 1 ? "" : "s") deleted on device — marked deleted in the manifest.", .warning)
        }

        if resurrected > 0 || !orphans.isEmpty {
            manifestDirty = true
            refreshCounts()
            if settings.keepBucketManifest { await writeManifest() }
        }

        // Physical space reclamation is opt-in; marking above is unconditional.
        if settings.propagateDeletes { await purgeTombstones() }
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
            manifestDirty = true
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
    func writeManifest() async -> Result<(count: Int, bytes: Int64), Error> {
        guard let index, let client = makeClient() else { return .failure(S3Error.badConfig) }
        let recipients = keyManager.recipientObjects
        guard !recipients.isEmpty else { return .failure(Age.Error.badRecipient) }

        let iso = ISO8601DateFormatter()
        func item(_ r: AssetRecord) -> Manifest.Item {
            Manifest.Item(key: r.remoteKey, filename: r.filename, mediaType: r.mediaType.rawValue,
                          storedBytes: r.byteSize,
                          createdAt: r.createdAt.map { iso.string(from: $0) },
                          uploadedAt: r.uploadedAt.map { iso.string(from: $0) })
        }
        let items = index.allUploaded().map(item)
        let deletedItems = index.deletedRecords().map(item)
        let manifest = Manifest(version: 2, generatedAt: iso.string(from: Date()),
                                bucket: s3Config.bucket, prefix: s3Config.prefix,
                                count: items.count, items: items,
                                deletedKeys: deletedItems.map(\.key),
                                deleted: deletedItems)

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
                .base64EncodedString()
            // Unique, write-once key: never overwrites (Object-Lock safe), and old
            // manifests expire under the same lifecycle rule while the newest stays
            // fresh. Restore lists `manifests/` and takes the last one.
            let stamp = Self.manifestStampFormatter.string(from: Date())
            let key = client.fullKey(for: "manifests/manifest-\(stamp).age")
            let encBytes = (try? FileManager.default.attributesOfItem(atPath: encURL.path)[.size] as? Int64) ?? nil
            try await S3Client.withRetries {
                try await client.putObject(fileURL: encURL, key: key,
                                           contentType: "application/age", contentMD5: md5)
            }
            manifestDirty = false
            appendLog("Wrote encrypted manifest — \(items.count) item\(items.count == 1 ? "" : "s"), \(Format.bytes(encBytes ?? 0)) → \(key).", .success)
            return .success((items.count, encBytes ?? 0))
        } catch {
            appendLog("Manifest write failed: \(error.localizedDescription)", .error)
            return .failure(error)
        }
    }

    /// Build the break-glass restore script (bucket creds + age secret baked in),
    /// gated behind Face ID / passcode. Nil if storage isn't configured or auth
    /// fails. Without an on-device identity, the script carries a placeholder
    /// the user must fill with a secret key.
    func buildRestoreScript() async -> String? {
        guard s3Config.isComplete, let creds = S3CredentialStore.load() else { return nil }
        let what = keyManager.hasIdentity ? "bucket credentials and encryption secret key" : "bucket credentials"
        guard await DeviceAuth.authenticate(reason: "Export a restore script containing your \(what)") else {
            return nil
        }
        return RestoreScript.build(config: s3Config, credentials: creds,
                                   ageSecret: keyManager.exportSecret())
    }

    // MARK: Verification

    @Published private(set) var verifying = false
    @Published private(set) var verifyStatus: String?

    /// Egress-free backup verification: pages ListObjectsV2 over the prefix
    /// (~10 requests per 10k objects, zero downloads) and checks every uploaded
    /// record exists remotely with the expected size and — because B2's ETag for
    /// single-part uploads IS the object's MD5, which we store at upload — the
    /// expected checksum. Missing/mismatched files are re-queued for upload.
    func verifyBackups() async {
        guard !verifying, !phase.isActive else { return }
        guard let index, let client = makeClient() else {
            verifyStatus = "✗ Storage not configured"
            return
        }
        verifying = true
        defer { verifying = false }
        do {
            var remote: [String: (size: Int64, etag: String)] = [:]
            var token: String? = nil
            repeat {
                let page = try await client.listObjects(continuationToken: token)
                for o in page.objects { remote[o.key] = (o.size, o.etag) }
                token = page.next
                verifyStatus = "Listing bucket… \(Format.count(remote.count)) objects"
            } while token != nil

            let uploaded = index.allUploaded()
            var ok = 0, missing = 0, mismatched = 0
            var matchedKeys = Set<String>()
            for r in uploaded where !r.remoteKey.isEmpty {
                guard let obj = remote[r.remoteKey] else {
                    missing += 1
                    index.requeue(r.localIdentifier, reason: "Verify: missing from bucket")
                    continue
                }
                matchedKeys.insert(r.remoteKey)
                if r.byteSize > 0 && obj.size != r.byteSize {
                    mismatched += 1
                    index.requeue(r.localIdentifier, reason: "Verify: size mismatch")
                } else if let md5 = r.md5, !obj.etag.isEmpty, obj.etag != md5 {
                    mismatched += 1
                    index.requeue(r.localIdentifier, reason: "Verify: checksum mismatch")
                } else {
                    ok += 1
                }
            }
            let manifestPrefix = client.fullKey(for: "manifests/")
            let orphans = remote.keys.filter { !matchedKeys.contains($0) && !$0.hasPrefix(manifestPrefix) }.count

            refreshCounts()
            if missing > 0 || mismatched > 0 { manifestDirty = true }   // uploaded set changed
            if missing == 0 && mismatched == 0 {
                verifyStatus = "✓ \(Format.count(ok)) backups verified — all present, sizes & checksums match"
                appendLog("Verify: all \(Format.count(ok)) backups check out.", .success)
            } else {
                verifyStatus = "⚠ \(Format.count(ok)) ok · \(missing) missing · \(mismatched) mismatched — re-queued"
                appendLog("Verify: \(missing) missing, \(mismatched) mismatched — re-queued for upload.", .warning)
            }
            if orphans > 0 {
                appendLog("Verify: \(orphans) untracked object\(orphans == 1 ? "" : "s") in the bucket (tombstoned, older key scheme, or another device).", .info)
            }
        } catch {
            verifyStatus = "✗ \(error.localizedDescription)"
            appendLog("Verify failed: \(error.localizedDescription)", .error)
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

        let draining = drainingTask
        drainingTask = nil
        runTask = Task { [weak self] in
            // Let a just-paused run finish unwinding before touching the same
            // records, so a stale cancellation can't stamp over fresh state.
            await draining?.value
            await self?.runLoop(processor: processor)
            await MainActor.run { [weak self] in
                self?.finishRun()
            }
        }
    }

    func pause() {
        runTask?.cancel()
        drainingTask = runTask   // cancellation is cooperative; remember it so a
        runTask = nil            // quick Resume waits for the old run to unwind
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
        uploadLanes.removeAll()
        bytesPerSecond = 0
        if phase == .running {
            phase = .finished
            appendLog("Backup finished — \(sessionUploaded) uploaded this session.", .success)
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastRunKey)
        rescheduleReminder()   // reset the "no backup for N days" countdown
        // Refresh the bucket manifest whenever the archive has changed since the
        // last successful write — covering uploads from THIS run, but also a
        // previous run whose manifest write failed or was cut short.
        if settings.keepBucketManifest && manifestDirty {
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

    private func updateSlot(_ id: String, filename: String? = nil, byteSize: Int64? = nil,
                            phase: AssetProcessor.Phase? = nil, progress: Double? = nil) {
        guard let i = uploadLanes.firstIndex(where: { $0?.id == id }) else { return }
        if let filename { uploadLanes[i]?.filename = filename }
        if let byteSize { uploadLanes[i]?.byteSize = byteSize }
        if let phase { uploadLanes[i]?.phase = phase }
        if let progress, let slot = uploadLanes[i] {
            // Feed the throughput meter from byte-level progress, not file
            // completions — a single long video used to starve the 5s window
            // for minutes and the speed gauge read "—".
            let delta = (progress - slot.progress) * Double(slot.byteSize)
            if delta > 0 {
                meter.record(bytes: Int64(delta))
                bytesPerSecond = meter.bytesPerSecond()
            }
            uploadLanes[i]?.progress = progress
        }
    }

    private func endSlot(_ id: String) {
        // Free the lane (keep the row) so the next file reuses this position.
        if let i = uploadLanes.firstIndex(where: { $0?.id == id }) { uploadLanes[i] = nil }
        // If the worker slider was lowered mid-run, let excess lanes drain away:
        // trailing idle rows disappear as their files finish (never mid-upload).
        let target = max(1, min(settings.parallelUploads, BackupSettings.parallelRange.upperBound))
        while uploadLanes.count > target, let last = uploadLanes.last, last == nil {
            uploadLanes.removeLast()
        }
    }

    private func runLoop(processor: AssetProcessor) async {
        guard let index else { return }
        // Convert the MB/s knob to bytes/s once per run (0 = unlimited).
        let bytesPerSecond = settings.speedLimitMBps * 1_000_000
        let verifyFirst = settings.verifyRemoteBeforeUpload
        // Live worker count: refreshed at every refill, so moving the slider
        // mid-run takes effect as files finish — more lanes spawn up to the new
        // target, or excess lanes drain away.
        let initialTarget = workerTarget

        if await !waitForFavorableConditions() { return }

        // Continuous refill — one new file starts the moment any lane frees up.
        // The old design processed fixed batches of 200 with a barrier at the
        // end of each: a multi-GB video in flight at a batch boundary idled
        // every other lane until it finished. No batches, no barrier, no stall.
        var inFlight = Set<String>()
        var attempted = Set<String>()   // one try per record per run; failures wait for the next run

        await withTaskGroup(of: String.self) { group in
            var target = initialTarget

            @discardableResult
            func spawnNext() -> Bool {
                let candidates = index.pendingRecords(limit: target * 2 + attempted.count)
                guard let record = candidates.first(where: {
                    !inFlight.contains($0.localIdentifier) && !attempted.contains($0.localIdentifier)
                }) else { return false }
                inFlight.insert(record.localIdentifier)
                attempted.insert(record.localIdentifier)
                group.addTask { [weak self] in
                    await self?.processOne(record, processor: processor,
                                           verifyFirst: verifyFirst, bytesPerSecond: bytesPerSecond)
                    return record.localIdentifier
                }
                return true
            }

            while inFlight.count < target, spawnNext() {}
            while let finished = await group.next() {
                inFlight.remove(finished)
                if Task.isCancelled { continue }                      // drain without refilling
                if await !waitForFavorableConditions() { continue }   // park refills; in-flight uploads run on
                // Top up to the (possibly changed) worker target.
                target = await self.workerTarget
                while inFlight.count < target, spawnNext() {}
            }
        }
        refreshCounts()
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
                onPhase: { phase in
                    Task { @MainActor in self.updateSlot(rid, phase: phase) }
                },
                onRetry: { attempt, error in
                    Task { @MainActor in
                        let name = record.filename.isEmpty ? "Upload" : record.filename
                        self.appendLog("\(name): transient storage error — retry \(attempt + 1)/3…", .warning)
                    }
                },
                progress: { p in
                    Task { @MainActor in self.updateSlot(rid, progress: p) }
                })

            // Persist the metadata we learned at upload time (filename/size/key/md5).
            uploaded.state = .uploaded
            uploaded.filename = result.filename
            uploaded.remoteKey = result.remoteKey
            uploaded.byteSize = result.encryptedBytes
            uploaded.uploadedAt = Date()
            uploaded.md5 = result.md5Hex
            index.upsert(uploaded)
            manifestDirty = true

            endSlot(rid)
            sessionUploaded += 1
            if !result.alreadyPresent {
                // Session totals only — the speed meter is fed by byte-level
                // progress in updateSlot, so recording here would double-count.
                sessionBytes += result.encryptedBytes
            }
            refreshCounts()
        } catch {
            // URLSession surfaces task cancellation as URLError.cancelled, not
            // CancellationError — treat both as a quiet pause, not a failure.
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            index.markFailed(rid, error: cancelled ? "Cancelled" : error.localizedDescription)
            endSlot(rid)
            if !cancelled {
                appendLog("Failed \(record.filename): \(error.localizedDescription)", .error)
            }
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
