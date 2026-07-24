import Foundation
import SwiftUI
import UIKit
import CryptoKit
import BackgroundTasks
import UserNotifications

/// The brain. Owns configuration, the index, and the run loop; publishes live
/// state for the UI. Everything the dashboard shows flows from here.
@MainActor
final class BackupEngine: ObservableObject {

    enum Phase: Equatable {
        case idle
        case scanning
        case preparing   // between scan and upload: repo checks, journal work
        case running
        case paused
        case finished
        case failed(String)

        var isActive: Bool { self == .scanning || self == .preparing || self == .running }
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
        var kind: MediaKind       // colors the lane to match the donut
        var phase: AssetProcessor.Phase = .exporting
        var isVideo: Bool { kind.isVideo }
    }
    @Published private(set) var bytesPerSecond: Double = 0
    @Published private(set) var sessionUploaded: Int = 0
    @Published private(set) var sessionBytes: Int64 = 0
    @Published private(set) var photoAuth: PhotoLibrary.AuthState = PhotoLibrary.currentAuthState()
    @Published private(set) var log: [LogEntry] = []
    /// Number of library assets examined so far during a scan (for live feedback).
    @Published private(set) var scanChecked: Int = 0
    /// What the pipeline is doing RIGHT NOW during scan/prepare — keeps the
    /// dashboard honest through the quiet stretches (deletion reconcile,
    /// repository checks) between "scanning" and "uploading".
    @Published private(set) var activityDetail: String?
    /// Result of the last completed scan (shown in Settings → Automation).
    @Published private(set) var scanStatus: String?
    /// Library totals by type (denominator) and uploaded-by-type (numerator) for
    /// the photos/videos ring.
    @Published private(set) var libraryPhotos = 0
    @Published private(set) var libraryVideos = 0
    /// How many items live in the Hidden album — shown on the dashboard so
    /// "what's excluded" (or included) is never invisible.
    @Published private(set) var hiddenItemCount = 0
    @Published private(set) var libraryHiddenPhotos = 0
    @Published private(set) var libraryHiddenVideos = 0
    @Published private(set) var uploadedPhotos = 0
    @Published private(set) var uploadedVideos = 0
    @Published private(set) var storedPhotoBytes: Int64 = 0
    @Published private(set) var storedVideoBytes: Int64 = 0
    /// Fine-grained donut segments: visible/hidden per type + Live clips.
    @Published private(set) var storedSegments = BackupIndex.StoredSegments()
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
    @Published var settings: BackupSettings {
        didSet {
            settings.save()
            // Widening a filter (videos back on, favorites-only off) means older
            // assets the mark already passed become eligible — reset it so the
            // next scan re-checks the whole library for them.
            if (settings.includePhotos && !oldValue.includePhotos) ||
               (settings.includeVideos && !oldValue.includeVideos) ||
               (settings.includeLiveMotion && !oldValue.includeLiveMotion) ||
               (settings.includeHidden && !oldValue.includeHidden) ||
               (!settings.favoritesOnly && oldValue.favoritesOnly) ||
               // Cutoff removed or moved earlier: assets before the old cutoff
               // are behind the mark and would otherwise never be picked up.
               (oldValue.backupCutoff != nil &&
                (settings.backupCutoff == nil || settings.backupCutoff! < oldValue.backupCutoff!)) {
                scanMark = nil
                appendLog("Backup filters widened — next scan re-checks the whole library.", .info)
            }
            if settings.backupCutoff != oldValue.backupCutoff {
                Task { await self.refreshLibraryCounts() }
            }
        }
    }
    @Published var s3Config: S3Config { didSet { s3Config.save() } }

    let keyManager = AgeKeyManager.shared
    let conditions = ConditionsMonitor()
    private let photos = PhotoLibrary()
    private var index: BackupIndex?
    private var runTask: Task<Void, Never>?
    /// Whole-pipeline task (scan → adopt → run) for reentrancy + BG expiry cancel.
    private var pipelineTask: Task<Void, Never>?
    /// Monotonic run counter so a stale (paused, still-draining) run's cleanup
    /// can never clobber the state of a newer run.
    private var runGeneration = 0
    /// Consecutive transport-class upload failures; trips the circuit breaker
    /// so a dead endpoint doesn't churn the whole queue (export+encrypt+fail
    /// for every pending file).
    private var consecutiveTransportFailures = 0
    /// Set when a run is aborted early (endpoint unreachable); finishRun turns
    /// it into a visible failed state instead of "finished".
    private var runAbortReason: String?
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
            if s3Config.isComplete {
                // Storage is configured but there was NO key: this phone was
                // migrated/restored (keys live only in the old phone's secure
                // keychain and never transfer). A silently-minted key would
                // write new backups the user thinks are protected by the OLD
                // key — say so, loudly.
                appendLog("This looks like a migrated or restored phone: storage is configured but the encryption key did not transfer (keys never leave a device's keychain). A NEW key was generated — to reconnect to your existing backups, import your saved AGE-SECRET-KEY in Settings → Encryption key BEFORE backing up.", .error)
            } else {
                appendLog("Generated this phone's encryption key. Reveal & back it up in Settings → Encryption key (requires Face ID).", .info)
            }
        }
        registerBackgroundTask()
        rescheduleReminder(force: false)
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
        storedSegments = {
            var s = BackupIndex.StoredSegments()
            s.photoBytes = 24_100_000_000;  s.photoCount = 7_612
            s.hiddenPhotoBytes = 2_400_000_000; s.hiddenPhotoCount = 374
            s.videoBytes = 40_200_000_000;  s.videoCount = 611
            s.hiddenVideoBytes = 3_400_000_000; s.hiddenVideoCount = 45
            s.clipBytes = 1_300_000_000;    s.clipCount = 902
            s.remainingPhotos = 3_054; s.remainingVideos = 1_147
            s.remainingHiddenPhotos = 138; s.remainingClips = 764
            return s
        }()
        libraryHiddenPhotos = 512
        libraryHiddenVideos = 61
        hiddenItemCount = 573
        lastBackupDate = Date().addingTimeInterval(-42)

        if mode == "uploading" {
            phase = .running
            uploadLanes = [
                UploadSlot(id: "1", filename: "IMG_4821.HEIC", progress: 0.62, byteSize: 4_200_000, kind: .photo, phase: .uploading),
                UploadSlot(id: "2", filename: "IMG_4822.MOV", progress: 0.28, byteSize: 214_000_000, kind: .video, phase: .encrypting),
                UploadSlot(id: "3", filename: "IMG_4823.MOV", progress: 0.11, byteSize: 2_100_000, kind: .clip, phase: .uploading),
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

    /// True while any pipeline/run is active — settings that change the
    /// destination must not commit mid-run.
    var isRunActive: Bool { phase.isActive || runTask != nil || pipelineTask != nil }

    /// Tombstones already past the grace period — what enabling automatic
    /// purge (or Clean up now) would free next.
    func purgeEligibleCount() -> Int {
        guard let index else { return 0 }
        let cutoff = Calendar.current.date(byAdding: .day, value: -settings.deleteGraceDays, to: Date()) ?? Date()
        return index.purgeableRecords(before: cutoff).count
    }

    /// Called after the recipient list changes with an attached repository:
    /// journals/checkpoints written so far aren't readable by the new key, so
    /// compact immediately — from the next generation on, the new key can
    /// read the index. (Existing photo BLOBS are not re-encrypted; the new
    /// key covers metadata and future uploads.)
    func noteRecipientsChanged() {
        guard repoGeneration != nil else { return }
        appendLog("Recipient list changed — writing a fresh checkpoint so the new key can read the repository index. Existing photo blobs stay encrypted to the old key set; new uploads use the new one.", .info)
        Task { await compactNow() }
    }

    /// Not-yet-uploaded counts per type (library total minus uploaded) — covers
    /// both indexed-pending items AND new photos no scan has seen yet, which is
    /// what the "ready to back up" banner needs at launch.
    var toBackupPhotos: Int { settings.includePhotos ? max(0, libraryPhotos - uploadedPhotos) : 0 }
    var toBackupVideos: Int { settings.includeVideos ? max(0, libraryVideos - uploadedVideos) : 0 }

    // MARK: Background backup (BGProcessingTask)

    static let bgTaskID = "ca.straybits.snapsiphon.backup"

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
            guard self.settings.backgroundBackup, PremiumStore.shared.isUnlocked,
                  self.isConfigured, self.runTask == nil, self.pipelineTask == nil,
                  !self.verifying else {
                task.setTaskCompleted(success: true)
                return
            }
            // On expiry, pause gracefully — the index checkpoints per file, so
            // whatever uploaded stays uploaded and the rest resumes next window.
            task.expirationHandler = { [weak self] in
                Task { @MainActor in
                    self?.pipelineTask?.cancel()
                    self?.pause()
                }
            }
            self.appendLog("Background window granted — backing up…", .info)
            await self.scan()
            // Same gate as Back Up Now: never upload into an unattached or
            // conflicted repository. An attach prompt can't be answered from
            // the background — leave it for the next foreground launch.
            guard await self.prepareRepository() else {
                task.setTaskCompleted(success: true)
                return
            }
            self.start()
            await self.runTask?.value
            self.rescheduleReminder()
            task.setTaskCompleted(success: true)
        }
    }

    /// Ask iOS for a future processing window (requires power + network, at
    /// least 30 min out). iOS decides when — typically overnight on charge.
    func scheduleBackgroundBackup() {
        guard settings.backgroundBackup, PremiumStore.shared.isUnlocked, isConfigured else { return }
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
    func rescheduleReminder(force: Bool = true) {
        let center = UNUserNotificationCenter.current()
        let days = settings.reminderDays
        guard days > 0 else {
            center.removePendingNotificationRequests(withIdentifiers: ["ca.straybits.snapsiphon.reminder"])
            return
        }
        if !force {
            // Launch path: keep an existing countdown (it measures from the last
            // backup); only create one if none is pending yet.
            center.getPendingNotificationRequests { pending in
                if !pending.contains(where: { $0.identifier == "ca.straybits.snapsiphon.reminder" }) {
                    Task { @MainActor in self.rescheduleReminder(force: true) }
                }
            }
            return
        }
        center.removePendingNotificationRequests(withIdentifiers: ["ca.straybits.snapsiphon.reminder"])
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Photos waiting to be backed up"
            content.body = "It's been \(days) day\(days == 1 ? "" : "s") since your last SnapSiphon backup. Tap to protect what's new."
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: TimeInterval(days) * 86_400, repeats: true)
            center.add(UNNotificationRequest(identifier: "ca.straybits.snapsiphon.reminder",
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
        storedSegments = index.storedSegments()
        lastBackupDate = index.recentUploads(limit: 1).first?.uploadedAt
    }

    /// Called when the storage destination (bucket/endpoint) changes while an
    /// index exists: the index describes the OLD bucket, so surface it loudly
    /// and point at the healing paths instead of quietly lying.
    func noteDestinationChanged() {
        // Our position in the OLD repository's journal chain means nothing in
        // the new location — drop it so the next backup re-inspects the folder
        // (initializing it, or raising the attach prompt if a repo lives there).
        setRepoPosition(generation: nil, nextSeq: 1, lastHash: "")
        repoConflict = nil
        pendingAttach = nil
        appendLog("Storage destination changed — the local index still describes the old repository. The next backup inspects the new folder; run Verify afterwards to re-queue anything the new bucket is missing, or Reset local index for a fresh start.", .warning)
    }

    /// Refresh the library totals by type (cheap PhotoKit counts). Runs off-main
    /// and only when we have read access. Called on dashboard appear and scans.
    func refreshLibraryCounts() async {
        if demoMode || !photoAuth.canRead { return }
        let photos = self.photos
        let cutoff = settings.backupCutoff
        let includeHidden = settings.includeHidden
        let (counts, hiddenP, hiddenV) = await Task.detached(priority: .utility) { () -> ((photos: Int, videos: Int), Int, Int) in
            let with = photos.libraryCounts(since: cutoff, includeHidden: true)
            let without = photos.libraryCounts(since: cutoff, includeHidden: false)
            return (includeHidden ? with : without,
                    max(0, with.photos - without.photos),
                    max(0, with.videos - without.videos))
        }.value
        libraryPhotos = counts.photos
        libraryVideos = counts.videos
        libraryHiddenPhotos = hiddenP
        libraryHiddenVideos = hiddenV
        hiddenItemCount = hiddenP + hiddenV
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

    /// A full scan: ignores the high-water mark and re-checks the whole
    /// library. Not user-facing — scans self-heal: a fast scan that finds the
    /// library holding more eligible items than the index triggers this
    /// automatically.
    private func fullScan() async { await runScan(deep: true) }

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
        let includeLiveMotion = settings.includeLiveMotion
        let includeHidden = settings.includeHidden
        let favoritesOnly = settings.favoritesOnly
        let photos = self.photos
        // Fast-scan mark: only enumerate assets created after it (unless deep or
        // incremental scanning is disabled). Assets are enumerated oldest-first
        // so the mark only ever moves forward.
        // Re-scan a 48h overlap behind the mark: an iCloud photo taken earlier
        // on another device can sync in with a creationDate BEHIND the mark and
        // would otherwise be skipped forever. The known-set dedups the overlap,
        // so this costs almost nothing. (Imports older than 48h → Deep scan.)
        // The cutoff setting bounds every scan (even full ones): content older
        // than it is out of scope by user choice, not covered-and-skipped.
        let cutoff = settings.backupCutoff
        let markSince: Date? = deep ? nil : scanMark?.addingTimeInterval(-48 * 3600)
        let since: Date? = [markSince, cutoff].compactMap { $0 }.max()
        appendLog(deep ? "Full scan — re-checking the whole library…"
                       : (since == nil ? "Scanning library…" : "Checking for new photos…"), .info)

        // One query for everything we already know, then in-memory membership
        // checks — no per-asset database round-trips.
        let known = index.allIdentifiers()
        // Rows skipped for provably-recheckable reasons: an enumeration that
        // includes the asset proves it exists and is eligible again (unhidden,
        // or the Hidden setting flipped on) — requeue on sight.
        let recheckable = index.skippedIdentifiers(reasons: [Self.skipReasonHidden, Self.skipReasonGone])
        let idx = index
        let startMark = scanMark
        scanChecked = 0

        // Enumerate AND index off the main actor so the UI stays live and we can
        // report progress as we go.
        let outcome: (added: Int, newest: Date?, checked: Int) = await Task.detached(priority: .utility) {
            let infos = photos.enumerate(includePhotos: includePhotos, includeVideos: includeVideos,
                                         since: since, includeHidden: includeHidden)
            var added = 0
            var newest = startMark
            for (i, info) in infos.enumerated() {
                if i % 250 == 0 {
                    let checked = i
                    await MainActor.run { self.scanChecked = checked }
                }
                // Skip BEFORE advancing the mark: a filtered-out asset is not
                // covered, so the mark must not move past it (favoriting it
                // later has to be picked up by a fast scan).
                if favoritesOnly && !info.isFavorite { continue }
                if let d = info.creationDate, newest == nil || d > newest! { newest = d }
                // Live Photo motion clips get their own suffixed record —
                // checked independently of the still, so enabling the toggle
                // later back-fills clips for already-uploaded stills.
                if recheckable.contains(info.localIdentifier) {
                    idx.requeue(info.localIdentifier, reason: "Eligible again")
                    added += 1
                }
                if includeLiveMotion, info.isLivePhoto {
                    let clipID = AssetRecord.liveMotionIdentifier(for: info.localIdentifier)
                    if recheckable.contains(clipID) {
                        idx.requeue(clipID, reason: "Eligible again")
                        added += 1
                    }
                    if !known.contains(clipID) {
                        idx.upsert(AssetRecord(
                            localIdentifier: clipID,
                            uuid: "",
                            state: .pending,
                            mediaType: .other,   // not counted in the photo/video ring
                            filename: "",
                            byteSize: 0,
                            createdAt: info.creationDate,
                            uploadedAt: nil,
                            lastError: nil))
                        added += 1
                    }
                }
                if known.contains(info.localIdentifier) { continue }
                idx.upsert(AssetRecord(
                    localIdentifier: info.localIdentifier,
                    // Blob name is a salted content address, computed at
                    // upload time once the bytes have been hashed.
                    uuid: "",
                    state: .pending,
                    mediaType: info.mediaType,
                    filename: "",             // filled in at upload (deferred PHAssetResource lookup)
                    byteSize: 0,
                    createdAt: info.creationDate,
                    uploadedAt: nil,
                    lastError: nil))
                added += 1
            }
            // Everything enumerated is by definition present in THIS phone's
            // library — the precondition for ever tombstoning it later.
            // (Clip records ride on their still's presence.)
            var seenIDs = infos.map(\.localIdentifier)
            if includeLiveMotion {
                seenIDs += infos.filter(\.isLivePhoto)
                    .map { AssetRecord.liveMotionIdentifier(for: $0.localIdentifier) }
            }
            idx.markLocalSeen(seenIDs)
            // Refresh Hidden-album membership (it changes over time; clips
            // follow their still) — feeds the dashboard's segment donut.
            var hiddenIDs: [String] = []
            var visibleIDs: [String] = []
            for info in infos {
                if info.isHidden {
                    hiddenIDs.append(info.localIdentifier)
                    if info.isLivePhoto { hiddenIDs.append(AssetRecord.liveMotionIdentifier(for: info.localIdentifier)) }
                } else {
                    visibleIDs.append(info.localIdentifier)
                    if info.isLivePhoto { visibleIDs.append(AssetRecord.liveMotionIdentifier(for: info.localIdentifier)) }
                }
            }
            idx.setHiddenFlags(hidden: hiddenIDs, visible: visibleIDs)
            return (added, newest, infos.count)
        }.value

        let added = outcome.added
        // Advance the mark so the next fast scan starts where this one ended.
        // Clamp to now: one future-dated asset (bad camera clock) must not
        // blind every future fast scan.
        if let newest = outcome.newest { scanMark = min(newest, Date()) }
        scanChecked = 0

        refreshCounts()
        await refreshLibraryCounts()

        // Self-healing full check: if the library holds more eligible items
        // than the index knows about, something slipped behind the incremental
        // mark (an old import, iCloud backfill) — silently re-check everything.
        // This replaces the old user-facing "Deep scan" button.
        if !deep, !favoritesOnly {
            let expected = (includePhotos ? libraryPhotos : 0) + (includeVideos ? libraryVideos : 0)
            let indexed = index.counts().total
            if expected > indexed {
                appendLog("Library has \(Format.count(expected)) eligible items but the index only knows \(Format.count(indexed)) — running a full re-check.", .info)
                return await runScan(deep: true)
            }
        }

        // An explicit result — "found nothing new" is the common case and used
        // to be indistinguishable from a no-op.
        scanStatus = added == 0
            ? "✓ \(deep ? "Full scan" : "Scan") checked \(Format.count(outcome.checked)) item\(outcome.checked == 1 ? "" : "s") — nothing new, everything already indexed"
            : "✓ \(deep ? "Full scan" : "Scan") checked \(Format.count(outcome.checked)) — \(Format.count(added)) new queued"
        appendLog("Scan complete — \(added) new item\(added == 1 ? "" : "s") queued.", .success)

        // Deletions are ALWAYS reconciled (tombstones + resurrections) so
        // restores reflect reality; the toggle only governs whether blobs are
        // physically purged.
        activityDetail = "Checking for deleted photos…"
        await reconcileDeletes()
        activityDetail = nil
        phase = .idle
    }

    // MARK: Repository chain state

    /// Index-meta keys tracking where this instance believes the bucket's
    /// journal chain head is. The bucket is the source of truth — these are
    /// only our cached position in it.
    private enum RepoMeta {
        static let generation = "repo.generation"
        static let nextSeq = "repo.nextSeq"
        static let lastHash = "repo.lastHash"
        static let salt = "repo.salt"      // blob-naming HMAC salt (hex)
        static let layout = "repo.layout"  // blob key layout (absent = flat)
    }

    /// The repository's blob-naming salt. Minted once at repo init; travels
    /// inside the encrypted checkpoint (the meta table is part of the
    /// snapshot), so an attach/reload recovers it automatically.
    private var repoSalt: String? { index?.metaValue(RepoMeta.salt) }

    /// Whether this repository uses the sharded blob layout (objects/ab/…).
    /// Recorded at init; old repositories stay flat forever — the layout is a
    /// repository property, never a per-device choice.
    var repoSharded: Bool { index?.metaValue(RepoMeta.layout) == Repo.shardedLayout }

    @discardableResult
    private func ensureRepoSalt() -> String {
        if let salt = repoSalt { return salt }
        let salt = Repo.newSaltHex()
        index?.setMeta(RepoMeta.salt, salt)
        return salt
    }

    /// Stable random ID for THIS device's install. Journals carry it, which is
    /// how a second device writing to the same folder becomes detectable — and
    /// how an interrupted flush recognizes its own head journal. Stored in the
    /// ThisDeviceOnly keychain, NOT UserDefaults: a device-transfer/iCloud
    /// restore clones UserDefaults, and two phones sharing one instance ID
    /// would sail straight past every two-writer check.
    static var instanceID: String {
        let account = "engineInstanceID"
        if let v = AgeKeyManager.shared.deviceScopedValue(account: account) { return v }
        let v = UUID().uuidString.lowercased()
        AgeKeyManager.shared.setDeviceScopedValue(v, account: account)
        UserDefaults.standard.removeObject(forKey: "SnapSiphon.instanceID")   // retire the migratable copy
        return v
    }

    private var repoGeneration: Int? {
        index?.metaValue(RepoMeta.generation).flatMap(Int.init)
    }
    private var repoNextSeq: Int {
        index?.metaValue(RepoMeta.nextSeq).flatMap(Int.init) ?? 1
    }
    private var repoLastHash: String {
        index?.metaValue(RepoMeta.lastHash) ?? ""
    }
    private func setRepoPosition(generation: Int?, nextSeq: Int, lastHash: String) {
        index?.setMeta(RepoMeta.generation, generation.map(String.init))
        index?.setMeta(RepoMeta.nextSeq, String(nextSeq))
        index?.setMeta(RepoMeta.lastHash, lastHash)
    }

    private static let repoISO = ISO8601DateFormatter()

    // MARK: Fast-scan high-water mark

    /// Skip reasons that scans can prove wrong later (the asset shows up in an
    /// enumeration) — such rows are re-queued automatically.
    static let skipReasonHidden = "In Hidden album (excluded)"
    static let skipReasonGone = "Asset no longer in library"

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
        // Absence-from-library only means "deleted" under FULL photo access.
        // Under .limited, unselected photos vanish from fetches while still
        // existing on the phone — tombstoning them would mark valid backups
        // deleted (and purge could destroy them).
        guard photoAuth == .authorized else { return }
        let photos = self.photos
        let liveIDs = await Task.detached(priority: .utility) { photos.allLocalIdentifiers() }.value

        // Resurrect tombstones whose asset is back in the library. Motion-clip
        // records (#live suffix) follow their still's presence.
        var resurrected = 0
        for id in index.tombstonedIdentifiers() where liveIDs.contains(AssetRecord.baseIdentifier(id)) {
            index.resurrect(id); resurrected += 1
        }
        if resurrected > 0 {
            appendLog("\(resurrected) previously-deleted photo\(resurrected == 1 ? "" : "s") reappeared — kept.", .success)
        }

        // Tombstone assets THIS PHONE has seen and uploaded that are no longer
        // anywhere in the library. Rows imported from another install's
        // repository (never seen here) are excluded — a photo this phone never
        // had is not a deletion, and after a take-over on a new device the old
        // rows would otherwise all read as "deleted" and trip the fuse forever.
        let uploadedPairs = index.locallySeenUploadedPairs()
        let orphans = uploadedPairs.filter { !liveIDs.contains(AssetRecord.baseIdentifier($0.id)) }
        // Mass-deletion fuse: if a huge fraction of the archive suddenly reads
        // as deleted, it's far more likely an access/App-state anomaly than a
        // real intent — refuse to tombstone and tell the user.
        if orphans.count > 50 && orphans.count * 4 > uploadedPairs.count {
            appendLog("\(orphans.count) of \(uploadedPairs.count) backed-up photos are missing from the library — refusing to mark them deleted (safety fuse). If this is intentional, delete in smaller batches or reset the index.", .warning)
            return
        }
        // Rows whose asset is gone and that never made it into the repository:
        // drop them so they don't retry (and fail) forever. Anything that WAS
        // journaled or uploaded gets a proper tombstone instead — silently
        // hard-deleting it would leave the repository claiming an asset that
        // this cache no longer tracks.
        let liveSet = liveIDs
        let now = Date()
        for rec in index.pendingRecords(limit: 100_000)
        where !liveSet.contains(AssetRecord.baseIdentifier(rec.localIdentifier)) {
            if !rec.uuid.isEmpty && (rec.journaled || rec.uploadedAt != nil) {
                index.markDeleted(rec.localIdentifier, at: now)
            } else {
                index.hardDeleteRecord(rec.localIdentifier)
            }
        }
        for orphan in orphans { index.markDeleted(orphan.id, at: now) }
        if !orphans.isEmpty {
            // Name names (up to a few) — "3 photos deleted" is unactionable.
            let names = orphans.prefix(4).compactMap { index.record(for: $0.id)?.filename }
                .filter { !$0.isEmpty }
            let sample = names.isEmpty ? "" :
                " (\(names.joined(separator: ", "))\(orphans.count > names.count ? ", …" : ""))"
            // Gentle wording: under the iOS 16+ Face ID lock, a photo moved to
            // the Hidden album is indistinguishable from a deleted one — don't
            // claim "deleted" when we can't know.
            appendLog("\(orphans.count) photo\(orphans.count == 1 ? "" : "s") no longer visible in the library\(sample) — deleted, or moved to the locked Hidden album. Marked deleted in the journal; the backup stays until purged, and anything that reappears is restored automatically.", .warning)
        }

        if resurrected > 0 || !orphans.isEmpty {
            refreshCounts()
            await flushJournal()   // tombstones/resurrections are journal ops
        }

        // Physical space reclamation is opt-in; marking above is unconditional.
        if settings.propagateDeletes {
            activityDetail = "Cleaning up deleted backups…"
            await purgeTombstones()
        }
    }

    /// Physically remove tombstones past the grace period, freeing bucket bytes.
    /// Each is version-deleted; Object Lock rejects any still under retention, so
    /// those stay tombstoned and are retried on a later scan — nothing recent can
    /// be wiped by a bulk mistake.
    /// Manual "Clean up now" status (garbage-collection box in Settings).
    @Published private(set) var gcStatus: String?

    /// Run garbage collection on demand — even when automatic purging is off.
    /// Same grace-period rules as the automatic path: recent deletions are the
    /// accident window and are never touched.
    func garbageCollectNow() async {
        guard !phase.isActive, runTask == nil, pipelineTask == nil, !verifying else {
            gcStatus = "✗ Wait for the current run to finish"
            return
        }
        guard let index else { return }
        gcStatus = "Cleaning up…"
        let tombstones = index.tombstonedIdentifiers().count
        let stats = await purgeTombstones()
        let waiting = tombstones - stats.freed
        if tombstones == 0 {
            gcStatus = "✓ Nothing to clean up — no deleted backups"
        } else {
            var parts: [String] = []
            if stats.freed > 0 { parts.append("freed \(Format.count(stats.freed)) (\(Format.bytes(stats.freedBytes)))") }
            if stats.blocked > 0 { parts.append("\(stats.blocked) blocked by Object Lock") }
            let inGrace = waiting - stats.blocked
            if inGrace > 0 { parts.append("\(inGrace) still inside the grace period") }
            gcStatus = (stats.freed > 0 ? "✓ " : "") + parts.joined(separator: " · ")
        }
    }

    @discardableResult
    private func purgeTombstones() async -> (freed: Int, freedBytes: Int64, blocked: Int) {
        guard let index, let client = makeClient() else { return (0, 0, 0) }
        let cutoff = Calendar.current.date(byAdding: .day, value: -settings.deleteGraceDays, to: Date()) ?? Date()
        let records = index.purgeableRecords(before: cutoff)
        guard !records.isEmpty else { return (0, 0, 0) }

        var freed: [AssetRecord] = []
        var blocked = 0
        // Dedup guard: identical content shares one blob. The blob may only be
        // deleted when NOTHING outside this purge batch references it — a live
        // twin, or a tombstoned twin still inside its grace window (both are
        // restorable and both need the blob). References inside the batch are
        // fine: the blob is deleted once, all batch rows are purged together.
        let batchIDs = Set(records.map(\.localIdentifier))
        var blobHandled = Set<String>()
        for record in records where !record.uuid.isEmpty {
            if Task.isCancelled { break }
            if blobHandled.contains(record.uuid) {
                freed.append(record)                    // twin's blob already freed
                continue
            }
            if index.blobReferencedOutside(record.uuid, excluding: batchIDs) {
                freed.append(record)                    // drop the row, keep the blob
                continue
            }
            let key = client.fullKey(for: Repo.objectKey(uuid: record.uuid, sharded: repoSharded))
            do {
                let versions = try await client.listVersions(forKey: key)
                var allGone = true
                for v in versions {
                    do { try await client.deleteObjectVersion(key: key, versionId: v.versionId) }
                    catch { allGone = false }          // locked / retention — retry later
                }
                if allGone { freed.append(record); blobHandled.insert(record.uuid) }
                else { blocked += 1 }
            } catch {
                blocked += 1                            // listing failed — retry later
            }
        }
        if !freed.isEmpty {
            // Journal the purges FIRST (so a restore knows the blob is gone),
            // then drop the cache rows. If the flush fails, rows stay
            // tombstoned and the purge op is retried next scan — the version
            // listing comes back empty, which is fine and idempotent.
            let at = Self.repoISO.string(from: Date())
            let purgeEntries = freed.map { r in
                Repo.Entry(op: .purge, uuid: r.uuid, localIdentifier: r.localIdentifier, at: at)
            }
            // Rollover is deferred so a checkpoint can never snapshot rows we
            // are about to hard-delete (it would immortalize tombstones whose
            // blobs are already gone).
            if await flushJournal(extra: purgeEntries, deferRollover: true) {
                for r in freed { index.hardDeleteRecord(r.localIdentifier) }
                await rolloverIfDue()
            }
            let names = freed.prefix(4).map(\.filename).filter { !$0.isEmpty }
            let sample = names.isEmpty ? "" :
                " (\(names.joined(separator: ", "))\(freed.count > names.count ? ", …" : ""))"
            appendLog("Freed \(freed.count) deleted backup\(freed.count == 1 ? "" : "s") from the bucket\(sample).", .info)
        }
        if blocked > 0 {
            appendLog("\(blocked) deletion\(blocked == 1 ? "" : "s") still locked — will retry once Object Lock retention expires.", .info)
        }
        refreshCounts()
        return (freed.count, freed.reduce(0) { $0 + $1.byteSize }, blocked)
    }

    // MARK: Journal & checkpoint (the bucket IS the source of truth)

    /// Set when journaling detects another writer (or a chain anomaly) in the
    /// repository. Journaling stops until the user resolves it — two devices
    /// interleaving journals WILL corrupt both backups.
    @Published private(set) var repoConflict: String?
    /// Set when Back Up Now finds an existing repository this install has never
    /// attached to. Upload is blocked until the user picks an option (sheet).
    @Published var pendingAttach: ExistingRepoInfo?
    @Published private(set) var attachStatus: String?
    @Published private(set) var checkpointStatus: String?

    struct ExistingRepoInfo: Identifiable, Equatable {
        let id = UUID()
        var generations: Int
        var journalFiles: Int
    }

    /// Raised when Back Up Now points at an EMPTY folder while the cache still
    /// lists uploads from a previous destination.
    @Published var pendingFreshInit: FreshInitInfo?
    struct FreshInitInfo: Identifiable, Equatable {
        let id = UUID()
        var staleUploads: Int
    }
    private var allowInitWithStaleCache = false

    /// User confirmed the fresh-init prompt: requeue every "uploaded" row (the
    /// blobs live elsewhere), then let the next Back Up Now initialize here
    /// and re-establish everything by re-uploading.
    func confirmFreshInitRequeueAll() {
        guard let index else { return }
        let n = index.requeueAllUploaded()
        allowInitWithStaleCache = true
        pendingFreshInit = nil
        refreshCounts()
        appendLog("Re-queued \(Format.count(n)) item\(n == 1 ? "" : "s") for upload to the new destination.", .info)
    }

    /// Uncommitted changes before a mid-run journal write (also always flushed
    /// at the end of every run). User-tunable.
    private var journalFlushThreshold: Int { settings.journalFlushEvery }
    /// Journals per generation before compacting into a fresh checkpoint.
    /// User-tunable.
    private var journalsPerGeneration: Int { settings.checkpointEveryJournals }

    /// List every metadata key under checkpoints/, parsed to (gen, seq).
    private func listMetadata(client: S3Client) async throws -> [(gen: Int, seq: Int)] {
        var parsed: [(gen: Int, seq: Int)] = []
        var token: String? = nil
        let pfx = client.fullKey(for: "")
        repeat {
            let page = try await client.listObjects(subPrefix: "checkpoints/", continuationToken: token)
            for o in page.objects {
                let rel = o.key.hasPrefix(pfx) ? String(o.key.dropFirst(pfx.count)) : o.key
                if let p = Repo.parseMetadataKey(rel) { parsed.append(p) }
            }
            token = page.next
        } while token != nil
        return parsed
    }

    /// Serialization for journal flushes: overlapping calls WAIT for the
    /// in-flight one, then run their own (its outcome doesn't cover their
    /// entries). Never skip-and-report-success — purge relies on the result.
    private var flushTask: Task<Bool, Never>?

    /// Commit every un-journaled cache change (uploads, tombstones,
    /// resurrections) plus any `extra` entries (purges) to the next journal
    /// file in the chain. Returns true when there was nothing to do or the
    /// write succeeded. Blobs are already uploaded by the time their entries
    /// are journaled — the upload-before-commit rule.
    @discardableResult
    func flushJournal(extra: [Repo.Entry] = [], deferRollover: Bool = false) async -> Bool {
        while let inflight = flushTask { _ = await inflight.value }
        let task = Task { await self.performFlush(extra: extra, deferRollover: deferRollover) }
        flushTask = task
        let result = await task.value
        flushTask = nil
        return result
    }

    /// Confirm the bucket agrees this device holds the chain head for
    /// `generation`, expecting to write `seq` next. Self-heals the
    /// "PUT landed but the position update was lost" case by recognizing our
    /// own instance ID inside the head journal and advancing past it.
    private func verifyChainHead(client: S3Client, generation: Int, seq: Int) async -> Bool {
        do {
            let entries = try await listMetadata(client: client)
            if let newest = entries.map(\.gen).max(), newest > generation {
                repoConflict = "The repository has moved on to generation \(newest) while this device is still at \(generation) — another install compacted or took it over. Use Settings → Reload index from repository to catch up (nothing is lost), or give this device its own folder."
                appendLog(repoConflict!, .error)
                return false
            }
            let maxSeq = entries.filter { $0.gen == generation }.map(\.seq).max() ?? -1
            if maxSeq < seq {
                if maxSeq >= 0 && maxSeq != seq - 1 {
                    appendLog("Repository chain gap: last journal in the bucket is \(maxSeq) but this device expected \(seq - 1). Journals may have been deleted remotely.", .warning)
                }
                return true
            }
            // Head at/ahead of our write point. If it's OUR journal (a PUT that
            // landed while the position update was lost to a crash/timeout),
            // adopt it and continue — not a conflict.
            if maxSeq == seq,
               let secret = keyManager.exportSecret(),
               let identity = try? Age.Identity(bech32: secret) {
                let jURL = tempDir.appendingPathComponent("head-\(UUID().uuidString).age")
                defer { try? FileManager.default.removeItem(at: jURL) }
                try await client.getObject(key: client.fullKey(for: Repo.journalKey(gen: generation, seq: seq)), to: jURL)
                let data = try Data(contentsOf: jURL)
                if let journal = try? Repo.decodeJournal(data, identity: identity, tempDir: tempDir),
                   journal.instance == Self.instanceID {
                    setRepoPosition(generation: generation, nextSeq: seq + 1, lastHash: Repo.sha256Hex(data))
                    appendLog("Recovered from an interrupted journal write — journal \(generation)/\(seq) was already committed by this device.", .info)
                    return true
                }
            }
            repoConflict = "Another device appears to be writing to this repository (found journal \(maxSeq) in generation \(generation), expected to write \(seq)). Two writers in one folder WILL corrupt both backups — each device needs its own folder. Change the folder in Storage settings, or use 'Take over repository' if the other device is retired."
            appendLog(repoConflict!, .error)
            return false
        } catch {
            appendLog("Could not check the repository head: \(error.localizedDescription)", .warning)
            return false
        }
    }

    private func performFlush(extra: [Repo.Entry], deferRollover: Bool) async -> Bool {
        guard let index, let client = makeClient() else { return false }
        guard repoConflict == nil else { return false }
        guard let generation = repoGeneration else { return false }   // repo not attached yet

        let dirty = index.unjournaledRecords()
        if dirty.isEmpty && extra.isEmpty { return true }
        let recipients = keyManager.recipientObjects
        guard !recipients.isEmpty else { return false }

        guard await verifyChainHead(client: client, generation: generation, seq: repoNextSeq) else {
            return false
        }
        let seq = repoNextSeq   // may have advanced via self-heal

        let iso = Self.repoISO
        let at = iso.string(from: Date())
        var entries = dirty.map { r in
            Repo.Entry(op: r.state == .deleted ? .delete : .add,
                       uuid: r.uuid,
                       localIdentifier: r.localIdentifier,
                       filename: r.filename.isEmpty ? nil : r.filename,
                       mediaType: r.mediaType.rawValue,
                       size: r.byteSize > 0 ? r.byteSize : nil,
                       plaintextHash: r.plaintextHash,
                       ciphertextHash: r.ciphertextHash,
                       createdAt: r.createdAt.map { iso.string(from: $0) },
                       at: at)
        }
        entries.append(contentsOf: extra)
        let journal = Repo.Journal(generation: generation, seq: seq, prevHash: repoLastHash,
                                   device: UIDevice.current.name, instance: Self.instanceID,
                                   createdAt: at, entries: entries)

        let encURL = tempDir.appendingPathComponent("journal-\(UUID().uuidString).age")
        defer { try? FileManager.default.removeItem(at: encURL) }
        do {
            let data = try Repo.encodeJournal(journal, recipients: recipients)
            try data.write(to: encURL)
            let md5 = Data(Insecure.MD5.hash(data: data)).base64EncodedString()
            let key = client.fullKey(for: Repo.journalKey(gen: generation, seq: seq))
            do {
                try await putJournalObject(client: client, fileURL: encURL, key: key, md5: md5)
            } catch S3Error.http(412, _) {
                // Someone wrote this seq between our check and PUT — possibly
                // our own earlier timed-out attempt. Next flush's head check
                // sorts out whose it is; nothing is marked journaled.
                appendLog("Journal \(generation)/\(seq) already exists — will reconcile on the next flush.", .warning)
                return false
            }
            index.markJournaled(records: dirty)
            setRepoPosition(generation: generation, nextSeq: seq + 1, lastHash: Repo.sha256Hex(data))
            // Break the commit down by operation so deletions are visible in
            // the activity feed, not buried inside "N changes".
            var parts: [String] = []
            let adds = entries.filter { $0.op == .add }.count
            let deletes = entries.filter { $0.op == .delete }.count
            let purges = entries.filter { $0.op == .purge }.count
            if adds > 0 { parts.append("\(adds) added") }
            if deletes > 0 { parts.append("\(deletes) deleted") }
            if purges > 0 { parts.append("\(purges) purged") }
            appendLog("Journal \(generation)/\(seq) committed — \(parts.isEmpty ? "\(entries.count) changes" : parts.joined(separator: " · ")).", .info)
            // Compaction: enough journals → roll a fresh self-contained
            // generation (checkpoint carries the whole state). Deferred during
            // a purge flush so the snapshot never captures rows the caller is
            // about to hard-delete.
            if !deferRollover && seq + 1 > journalsPerGeneration {
                await writeCheckpoint(generation: generation + 1)
            }
            return true
        } catch {
            appendLog("Journal write failed (changes stay queued): \(error.localizedDescription)", .error)
            return false
        }
    }

    /// Providers that answered 501 NotImplemented to a conditional PUT — B2
    /// does this ("a header you provided implies functionality that is not
    /// implemented") rather than ignoring the header. Remembered per endpoint
    /// so we only pay one failed request, ever.
    private func conditionalPutUnsupportedKey() -> String {
        "SnapSiphon.noConditionalPut.\(s3Config.endpoint)"
    }

    /// PUT a journal file, preferring a conditional (If-None-Match: *) write
    /// where the provider supports it — that makes the LIST→PUT ownership race
    /// atomic. On 501 the capability is remembered as absent and the write
    /// retries plain (the pre-write head check still guards ownership).
    private func putJournalObject(client: S3Client, fileURL: URL, key: String, md5: String) async throws {
        let conditional = !UserDefaults.standard.bool(forKey: conditionalPutUnsupportedKey())
        do {
            try await S3Client.withRetries {
                try await client.putObject(fileURL: fileURL, key: key,
                                           contentType: "application/age", contentMD5: md5,
                                           ifNoneMatch: conditional)
            }
        } catch S3Error.http(501, _) where conditional {
            UserDefaults.standard.set(true, forKey: conditionalPutUnsupportedKey())
            appendLog("This provider doesn't support conditional writes — using plain journal writes from now on (the pre-write ownership check still applies).", .info)
            try await S3Client.withRetries {
                try await client.putObject(fileURL: fileURL, key: key,
                                           contentType: "application/age", contentMD5: md5,
                                           ifNoneMatch: false)
            }
        }
    }

    /// Roll into a fresh generation if the current one is past the journal
    /// threshold (used after purge flushes that deferred their rollover).
    private func rolloverIfDue() async {
        guard repoConflict == nil, let generation = repoGeneration else { return }
        if repoNextSeq > journalsPerGeneration {
            await writeCheckpoint(generation: generation + 1)
        }
    }

    /// Snapshot the entire cache into an encrypted SQLite checkpoint and start
    /// generation `generation` with it. The previous generation stays on disk,
    /// fully self-contained (append-only friendly).
    @discardableResult
    private func writeCheckpoint(generation: Int) async -> Bool {
        guard let index, let client = makeClient() else { return false }
        let recipients = keyManager.recipientObjects
        guard !recipients.isEmpty else { return false }
        let token = UUID().uuidString
        let dbURL = tempDir.appendingPathComponent("\(token).ckpt.sqlite")
        let encURL = tempDir.appendingPathComponent("\(token).ckpt.age")
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: encURL)
        }
        do {
            try index.snapshot(to: dbURL)
            let digests = try AssetProcessor.encryptFile(at: dbURL, to: encURL, recipients: recipients)
            let key = client.fullKey(for: Repo.checkpointKey(gen: generation))
            try await S3Client.withRetries {
                try await client.putObject(fileURL: encURL, key: key,
                                           contentType: "application/age",
                                           contentMD5: digests.ciphertextMD5Base64)
            }
            setRepoPosition(generation: generation, nextSeq: 1, lastHash: digests.ciphertextSHA256)
            appendLog("Checkpoint written — generation \(generation) begins.", .success)
            return true
        } catch {
            appendLog("Checkpoint write failed: \(error.localizedDescription)", .error)
            return false
        }
    }

    /// "Write checkpoint now" — flush pending changes, then compact into a new
    /// generation regardless of the rollover threshold.
    func compactNow() async {
        guard repoConflict == nil else { checkpointStatus = "✗ Resolve the repository conflict first"; return }
        guard let generation = repoGeneration, let client = makeClient() else {
            checkpointStatus = "✗ No repository yet — run a backup first"; return
        }
        checkpointStatus = "Writing checkpoint…"
        guard await flushJournal() else { checkpointStatus = "✗ Could not commit pending changes"; return }
        // A clean cache skips the flush's head check entirely — verify
        // ownership explicitly so a retired-and-revived device can't clobber
        // the new writer's checkpoint.
        guard await verifyChainHead(client: client, generation: repoGeneration ?? generation, seq: repoNextSeq) else {
            checkpointStatus = "✗ Repository head has moved — see the conflict message"; return
        }
        checkpointStatus = await writeCheckpoint(generation: (repoGeneration ?? generation) + 1)
            ? "✓ Checkpoint written — repository compacted"
            : "✗ Checkpoint write failed (see activity log)"
    }

    /// Called before the first upload of a pipeline. Returns true when the
    /// repository is ready to receive journals. On a fresh cache pointed at a
    /// bucket that ALREADY contains a repository, this refuses to proceed and
    /// raises the attach sheet — silently taking over someone else's chain (or
    /// double-writing it) is the one unrecoverable mistake this design has.
    func prepareRepository() async -> Bool {
        guard index != nil, let client = makeClient() else { return false }
        if repoConflict != nil {
            appendLog("Backup blocked — resolve the repository conflict first.", .error)
            return false
        }
        if repoGeneration != nil { return true }   // already attached
        do {
            let entries = try await listMetadata(client: client)
            if entries.isEmpty {
                // Virgin bucket/folder. If the cache still lists uploads, they
                // came from a DIFFERENT destination — a checkpoint written now
                // would claim backups this bucket doesn't hold. Requeue them
                // first (content addressing makes re-upload skip nothing that
                // is actually present) so the repository never lies.
                let stale = index?.counts().uploaded ?? 0
                if stale > 0, !allowInitWithStaleCache {
                    pendingFreshInit = FreshInitInfo(staleUploads: stale)
                    appendLog("This folder is empty, but the index lists \(Format.count(stale)) backups from a previous destination. Choose how to proceed — see the prompt.", .warning)
                    return false
                }
                allowInitWithStaleCache = false
                appendLog("Initializing repository…", .info)
                // Salt and layout must exist BEFORE the checkpoint so the
                // snapshot carries them (readers learn both from it).
                ensureRepoSalt()
                index?.setMeta(RepoMeta.layout, Repo.shardedLayout)
                return await writeCheckpoint(generation: 1)
            }
            // Existing repository, and this install has no position in it.
            let gens = Set(entries.map(\.gen))
            pendingAttach = ExistingRepoInfo(generations: gens.count,
                                             journalFiles: entries.filter { $0.seq > 0 }.count)
            appendLog("This folder already contains a SnapSiphon repository (\(gens.count) generation\(gens.count == 1 ? "" : "s")). Backup is paused until you choose how to attach — see the prompt.", .warning)
            return false
        } catch {
            appendLog("Could not inspect the repository: \(error.localizedDescription)", .error)
            return false
        }
    }

    /// Rebuild the local cache from the bucket: newest complete checkpoint,
    /// then every journal after it, verifying the tamper-evidence chain. On
    /// success this device owns the chain head (it may append next).
    @discardableResult
    func restoreIndexFromRepo() async -> Bool {
        guard let index, let client = makeClient() else {
            attachStatus = "✗ Storage not configured"; return false
        }
        guard let secret = keyManager.exportSecret(), let identity = try? Age.Identity(bech32: secret) else {
            attachStatus = "✗ This phone has no private key that can decrypt the repository"
            return false
        }
        attachStatus = "Reading repository…"
        do {
            let entries = try await listMetadata(client: client)
            let byGen = Dictionary(grouping: entries, by: \.gen)
            guard let gen = byGen.filter({ $0.value.contains(where: { $0.seq == 0 }) }).keys.max() else {
                attachStatus = "✗ No complete checkpoint found in this folder"
                return false
            }
            let token = UUID().uuidString
            let encURL = tempDir.appendingPathComponent("\(token).ckpt.age")
            let dbURL = tempDir.appendingPathComponent("\(token).ckpt.sqlite")
            defer {
                try? FileManager.default.removeItem(at: encURL)
                try? FileManager.default.removeItem(at: dbURL)
            }
            try await client.getObject(key: client.fullKey(for: Repo.checkpointKey(gen: gen)), to: encURL)
            var lastHash = try Repo.sha256Hex(fileAt: encURL)
            try Age.decryptFile(at: encURL, to: dbURL, identity: identity)
            // Detach BEFORE importing: if the replay dies mid-way (network),
            // the index must hold NO chain position — a stale one would let
            // the next backup silently fork an abandoned generation. The
            // attach prompt simply re-raises and the reload is retried.
            setRepoPosition(generation: nil, nextSeq: 1, lastHash: "")
            try index.importSnapshot(from: dbURL)

            let seqs = byGen[gen]!.map(\.seq).filter { $0 > 0 }.sorted()
            var applied = 0
            for seq in seqs {
                attachStatus = "Replaying journal \(seq) of \(seqs.count)…"
                let jURL = tempDir.appendingPathComponent("\(token)-j\(seq).age")
                defer { try? FileManager.default.removeItem(at: jURL) }
                try await client.getObject(key: client.fullKey(for: Repo.journalKey(gen: gen, seq: seq)), to: jURL)
                let data = try Data(contentsOf: jURL)
                let journal = try Repo.decodeJournal(data, identity: identity, tempDir: tempDir)
                if journal.prevHash != lastHash {
                    appendLog("Tamper evidence: journal \(gen)/\(seq) does not chain to its predecessor (expected \(lastHash.prefix(12))…, recorded \(journal.prevHash.prefix(12))…). Applying anyway, but the repository history has been altered.", .error)
                }
                index.apply(journal: journal)
                lastHash = Repo.sha256Hex(data)
                applied += 1
            }
            setRepoPosition(generation: gen, nextSeq: (seqs.max() ?? 0) + 1, lastHash: lastHash)
            ensureRepoSalt()   // pre-salt repos: mint one now (rides the next checkpoint)
            repoConflict = nil
            pendingAttach = nil
            refreshCounts()
            let c = index.counts()
            attachStatus = "✓ Loaded \(Format.count(c.uploaded)) backed-up item\(c.uploaded == 1 ? "" : "s") (generation \(gen), \(applied) journal\(applied == 1 ? "" : "s")). This device now owns the journal chain."
            appendLog(attachStatus!, .success)
            return true
        } catch {
            attachStatus = "✗ \(error.localizedDescription)"
            appendLog("Restore index from repository failed: \(error.localizedDescription)", .error)
            return false
        }
    }

    /// "Verify match" for the attach sheet: read the repository's metadata into
    /// a throwaway index (never touching the real cache), then compare it with
    /// the local cache and with the blobs actually present under objects/.
    /// Catches missing blobs and local/repo divergence — not silent remote
    /// corruption (self-stored hashes + Verify cover sizes; full corruption
    /// checks would mean downloading everything).
    func compareWithRepo() async {
        guard let index, let client = makeClient() else {
            attachStatus = "✗ Storage not configured"; return
        }
        guard let secret = keyManager.exportSecret(), let identity = try? Age.Identity(bech32: secret) else {
            attachStatus = "✗ This phone has no private key that can decrypt the repository"; return
        }
        attachStatus = "Comparing with repository…"
        let scratchDir = tempDir.appendingPathComponent("compare-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratchDir) }
        do {
            try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
            let scratch = try BackupIndex(directory: scratchDir)
            let entries = try await listMetadata(client: client)
            let byGen = Dictionary(grouping: entries, by: \.gen)
            guard let gen = byGen.filter({ $0.value.contains(where: { $0.seq == 0 }) }).keys.max() else {
                attachStatus = "✗ No complete checkpoint found in this folder"; return
            }
            let encURL = scratchDir.appendingPathComponent("ckpt.age")
            let dbURL = scratchDir.appendingPathComponent("ckpt.sqlite")
            try await client.getObject(key: client.fullKey(for: Repo.checkpointKey(gen: gen)), to: encURL)
            try Age.decryptFile(at: encURL, to: dbURL, identity: identity)
            try scratch.importSnapshot(from: dbURL)
            for seq in byGen[gen]!.map(\.seq).filter({ $0 > 0 }).sorted() {
                let jURL = scratchDir.appendingPathComponent("j\(seq).age")
                try await client.getObject(key: client.fullKey(for: Repo.journalKey(gen: gen, seq: seq)), to: jURL)
                scratch.apply(journal: try Repo.decodeJournal(try Data(contentsOf: jURL),
                                                              identity: identity, tempDir: scratchDir))
            }

            // Blob existence under objects/ (sizes come free with the LIST).
            var blobs = Set<String>()
            var token: String? = nil
            let objPfx = client.fullKey(for: "objects/")
            repeat {
                let page = try await client.listObjects(subPrefix: "objects/", continuationToken: token)
                for o in page.objects where o.key.hasPrefix(objPfx) {
                    // Last path component = the blob address, in both the
                    // flat and sharded (objects/ab/…) layouts.
                    if let addr = o.key.split(separator: "/").last { blobs.insert(String(addr)) }
                }
                token = page.next
            } while token != nil

            let repoUUIDs = Set(scratch.uploadedKeyPairs().map(\.uuid))
            let localUUIDs = Set(index.uploadedKeyPairs().map(\.uuid))
            let matching = repoUUIDs.intersection(localUUIDs).count
            let repoOnly = repoUUIDs.subtracting(localUUIDs).count
            let localOnly = localUUIDs.subtracting(repoUUIDs).count
            let missingBlobs = repoUUIDs.subtracting(blobs).count
            if repoOnly == 0 && localOnly == 0 && missingBlobs == 0 {
                // The unambiguous good outcome deserves an unambiguous headline.
                attachStatus = "✓ Perfect match\nThis phone and the repository agree on all \(Format.count(matching)) backed-up item\(matching == 1 ? "" : "s"), and every blob is present in the bucket. Taking over this repository is safe."
            } else {
                var lines = ["⚠ Differences found",
                             "Repository: \(Format.count(repoUUIDs.count)) items · This phone: \(Format.count(localUUIDs.count)) · Matching: \(Format.count(matching))"]
                if repoOnly > 0 { lines.append("• \(Format.count(repoOnly)) only in the repository (from another install, or before a reset)") }
                if localOnly > 0 { lines.append("• \(Format.count(localOnly)) only on this phone (not yet in the repository)") }
                if missingBlobs > 0 { lines.append("• \(Format.count(missingBlobs)) repository item\(missingBlobs == 1 ? "" : "s") missing their blob from the bucket") }
                lines.append("Differences aren't necessarily bad — taking over merges the repository's view; anything only on this phone re-queues on the next scan.")
                attachStatus = lines.joined(separator: "\n")
            }
        } catch {
            attachStatus = "✗ \(error.localizedDescription)"
        }
    }

    /// Build the break-glass restore script (bucket creds + age secret baked in),
    /// gated behind Face ID / passcode. Nil if storage isn't configured or auth
    /// fails. Without an on-device identity, the script carries a placeholder
    /// the user must fill with a secret key.
    /// `includeSecrets: false` builds the prompting variant — no SECRET_KEY or
    /// AGE_SECRET in the file, the script asks at run time — and therefore
    /// needs no biometric gate (the remaining contents identify the bucket but
    /// can't read it).
    func buildRestoreScript(includeSecrets: Bool = true) async -> String? {
        guard s3Config.isComplete, let creds = S3CredentialStore.load() else { return nil }
        guard includeSecrets else {
            return RestoreScript.build(config: s3Config, credentials: creds,
                                       ageSecret: nil, includeSecrets: false)
        }
        let what = keyManager.hasIdentity ? "bucket credentials and encryption secret key" : "bucket credentials"
        guard await DeviceAuth.authenticate(reason: "Export a restore script containing your \(what)") else {
            return nil
        }
        return RestoreScript.build(config: s3Config, credentials: creds,
                                   ageSecret: keyManager.exportSecret(), includeSecrets: true)
    }

    // MARK: Verification

    @Published private(set) var verifying = false
    @Published private(set) var verifyStatus: String?

    /// Egress-free backup verification: pages ListObjectsV2 over `objects/`
    /// (~10 requests per 10k blobs, zero downloads) and checks every uploaded
    /// record's blob exists remotely with the expected size. Missing or
    /// wrong-size blobs are re-queued for upload (same UUID, so the repair is
    /// an overwrite-in-place on versioned buckets, a fresh version on locked
    /// ones). ETags are ignored — the repository stores its own hashes.
    func verifyBackups() async {
        guard !verifying, !phase.isActive, runTask == nil, pipelineTask == nil else { return }
        guard let index, let client = makeClient() else {
            verifyStatus = "✗ Storage not configured"
            return
        }
        verifying = true
        defer { verifying = false }
        do {
            var remote: [String: Int64] = [:]   // uuid → ciphertext size
            var token: String? = nil
            let objPfx = client.fullKey(for: "objects/")
            repeat {
                let page = try await client.listObjects(subPrefix: "objects/", continuationToken: token)
                for o in page.objects where o.key.hasPrefix(objPfx) {
                    // Last path component = blob address (flat or sharded layout).
                    if let addr = o.key.split(separator: "/").last { remote[String(addr)] = o.size }
                }
                token = page.next
                verifyStatus = "Listing bucket… \(Format.count(remote.count)) blobs"
            } while token != nil

            let uploaded = index.allUploaded()
            var ok = 0, missing = 0, mismatched = 0
            for r in uploaded where !r.uuid.isEmpty {
                guard let size = remote[r.uuid] else {
                    missing += 1
                    index.requeue(r.localIdentifier, reason: "Verify: missing from bucket")
                    continue
                }
                if r.byteSize > 0 && size != r.byteSize {
                    mismatched += 1
                    index.requeue(r.localIdentifier, reason: "Verify: size mismatch")
                } else {
                    ok += 1
                }
            }
            // Tombstoned (deleted-but-unpurged) records are still restorable
            // via --all, so their blobs are part of "verified" too. Missing
            // ones are reported, not re-queued — the asset is gone locally.
            var missingTombstones = 0
            for r in index.deletedRecords() where !r.uuid.isEmpty && remote[r.uuid] == nil {
                missingTombstones += 1
            }

            // Blobs no cache row references: tombstones already purged from the
            // cache, another install's uploads, or a crash between blob upload
            // and journal commit (harmless by design — never auto-deleted).
            let referenced = index.referencedUUIDs()
            let orphans = remote.keys.filter { !referenced.contains($0) }.count

            refreshCounts()
            if missing == 0 && mismatched == 0 {
                verifyStatus = "✓ \(Format.count(ok)) backups verified — every blob present with the expected size"
                appendLog("Verify: all \(Format.count(ok)) backups check out.", .success)
            } else {
                verifyStatus = "⚠ \(Format.count(ok)) ok · \(missing) missing · \(mismatched) wrong size — re-queued"
                appendLog("Verify: \(missing) missing, \(mismatched) wrong size — re-queued for upload.", .warning)
            }
            if missingTombstones > 0 {
                appendLog("Verify: \(missingTombstones) deleted-but-unpurged item\(missingTombstones == 1 ? "" : "s") no longer have a blob (removed outside the app?) — a --all restore would skip them.", .warning)
            }
            if orphans > 0 {
                appendLog("Verify: \(orphans) unreferenced blob\(orphans == 1 ? "" : "s") in the bucket (purged tombstones, another install, or an interrupted upload). Harmless.", .info)
            }
        } catch {
            verifyStatus = "✗ \(error.localizedDescription)"
            appendLog("Verify failed: \(error.localizedDescription)", .error)
        }
    }

    // MARK: Backup run

    /// One-tap entry point for the dashboard: scan for new photos, make sure
    /// the repository is attached (initializing a virgin folder, or raising the
    /// attach prompt when the folder already holds a repository), then upload.
    func backUpNow() {
        guard runTask == nil, pipelineTask == nil, phase != .scanning, !verifying else { return }
        pipelineTask = Task { [weak self] in
            await self?.scan()
            // The repository checks are real network work (LIST + possibly a
            // checkpoint) — show them, don't dead-air on "READY".
            await MainActor.run { [weak self] in
                self?.phase = .preparing
                self?.activityDetail = "Checking the repository…"
            }
            let ready = await self?.prepareRepository() ?? false
            await MainActor.run { [weak self] in
                self?.activityDetail = nil
                if ready { self?.start() }
                else if self?.phase == .scanning || self?.phase == .preparing { self?.phase = .idle }
                self?.pipelineTask = nil
            }
        }
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
        consecutiveTransportFailures = 0
        runAbortReason = nil
        sessionStartedAt = Date()
        // One fixed lane per parallel thread — the row count stays put all run.
        let concurrency = max(1, min(settings.parallelUploads, BackupSettings.parallelRange.upperBound))
        uploadLanes = Array(repeating: nil, count: concurrency)
        meter.reset()
        appendLog("Backup started.", .info)

        let processor = AssetProcessor(photos: photos, client: client, recipients: recipients,
                                       tempDir: tempDir, saltHex: ensureRepoSalt(),
                                       shardedLayout: repoSharded,
                                       allowHidden: settings.includeHidden)

        let draining = drainingTask
        drainingTask = nil
        runGeneration += 1
        let generation = runGeneration
        runTask = Task { [weak self] in
            // Let a just-paused run finish unwinding before touching the same
            // records, so a stale cancellation can't stamp over fresh state.
            await draining?.value
            await self?.runLoop(processor: processor)
            await MainActor.run { [weak self] in
                self?.finishRun(generation: generation)
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

    private func finishRun(generation: Int) {
        // A paused run drains asynchronously; if the user already resumed, this
        // cleanup belongs to the OLD run and must not touch the new one.
        guard generation == runGeneration else { return }
        runTask = nil
        waitingReason = nil
        UIApplication.shared.isIdleTimerDisabled = false
        refreshCounts()
        uploadLanes.removeAll()
        bytesPerSecond = 0
        if let reason = runAbortReason {
            runAbortReason = nil
            phase = .failed(reason)
            appendLog(reason, .error)
        } else if phase == .running {
            phase = .finished
            appendLog(sessionUploaded == 0
                      ? "Backup finished — everything was already backed up."
                      : "Backup finished — \(sessionUploaded) uploaded this session.", .success)
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastRunKey)
        rescheduleReminder()   // reset the "no backup for N days" countdown
        // Commit whatever this run changed to the journal chain — including
        // changes a PREVIOUS run failed to commit (they stay flagged in the
        // cache until a flush succeeds).
        Task { await flushJournal() }
    }

    // MARK: Per-stream upload slots

    private func beginSlot(_ record: AssetRecord) {
        let slot = UploadSlot(id: record.localIdentifier,
                              filename: record.filename.isEmpty ? "Preparing…" : record.filename,
                              progress: 0,
                              byteSize: record.byteSize,
                              kind: MediaKind.of(record: record))
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
        // Convert the MB/s knob to bytes/s once per run (0 = unlimited). The
        // limit is TOTAL: divided across lanes so N parallel uploads can't
        // multiply it.
        let totalBudget = settings.speedLimitMBps * 1_000_000
        let bytesPerSecond = totalBudget > 0 ? totalBudget / Double(workerTarget) : 0
        let includePhotos = settings.includePhotos
        let includeVideos = settings.includeVideos
        let includeLiveMotion = settings.includeLiveMotion
        // Live worker count: refreshed at every refill, so moving the slider
        // mid-run takes effect as files finish — more lanes spawn up to the new
        // target, or excess lanes drain away.
        let initialTarget = workerTarget

        if await !waitForFavorableConditions() { return }

        // Preflight: one cheap LIST against the endpoint before exporting and
        // encrypting anything. A self-hosted node that's offline (or a tailnet
        // the phone isn't on) should fail in seconds with a clear message, not
        // churn the entire queue through export→encrypt→retry→fail.
        do {
            try await S3Client.withRetries(attempts: 2) { try await processor.client.testConnection() }
        } catch {
            runAbortReason = "Storage endpoint unreachable — server offline, or this network can't reach it (Tailscale/VPN off?). Nothing was uploaded; backup will retry next run."
            return
        }

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
                        // Honour type filters for items queued before a toggle changed.
                        && !($0.mediaType == .photo && !includePhotos)
                        && !($0.mediaType == .video && !includeVideos)
                        && !(AssetRecord.isLiveMotion($0.localIdentifier) && !includeLiveMotion)
                }) else { return false }
                inFlight.insert(record.localIdentifier)
                attempted.insert(record.localIdentifier)
                group.addTask { [weak self] in
                    await self?.processOne(record, processor: processor, bytesPerSecond: bytesPerSecond)
                    return record.localIdentifier
                }
                return true
            }

            while inFlight.count < target, spawnNext() {}
            while let finished = await group.next() {
                inFlight.remove(finished)
                if Task.isCancelled { continue }                      // drain without refilling
                // Circuit breaker: several consecutive transport failures means
                // the endpoint died mid-run — stop cleanly instead of failing
                // every remaining file one by one.
                if consecutiveTransportFailures >= 3 {
                    runAbortReason = "Storage endpoint became unreachable mid-backup — pausing the run. Uploaded files are safe; the rest retry next run."
                    group.cancelAll()
                    continue
                }
                if await !waitForFavorableConditions() { continue }   // park refills; in-flight uploads run on
                // Journal every ~25 uploads so a mid-run crash loses at most a
                // small tail of uncommitted (but re-flushable) changes.
                let unjournaled = await self.pendingJournalCount()
                if unjournaled >= journalFlushThreshold {
                    await self.flushJournal()
                }
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
                            bytesPerSecond: Double) async {
        guard let index else { return }
        let rid = record.localIdentifier
        beginSlot(record)
        do {
            var uploaded = record
            uploaded.state = .uploading
            uploaded.uploadedAt = nil
            uploaded.lastError = nil
            index.upsert(uploaded)

            // A record requeued by Verify has a size mismatch — the HEAD-skip
            // would just re-mark the bad blob as fine, so force the upload.
            let forceUpload = record.lastError?.hasPrefix("Verify:") ?? false
            let result = try await processor.process(
                record, forceUpload: forceUpload, bytesPerSecond: bytesPerSecond,
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

            // Persist what upload time taught us (filename/size/hashes). The
            // row is NOT yet journaled — the blob is safely in the bucket, and
            // the journal entry follows at the next flush (upload-before-
            // commit; a crash in between strands only an ignorable orphan).
            uploaded.state = .uploaded
            uploaded.uuid = result.uuid          // salted content address
            uploaded.filename = result.filename
            uploaded.byteSize = result.encryptedBytes
            uploaded.uploadedAt = Date()
            uploaded.plaintextHash = result.plaintextHash
            uploaded.ciphertextHash = result.ciphertextHash.isEmpty ? nil : result.ciphertextHash
            uploaded.journaled = false
            index.upsert(uploaded)
            index.markLocalSeen([rid])   // uploaded from this phone = seen here
            if forceUpload, !result.alreadyPresent {
                // A verify-repair re-uploaded a (possibly shared) blob: keep
                // every twin's stored hashes/size in step with the new bytes.
                index.updateTwinHashes(uuid: result.uuid,
                                       plaintextHash: result.plaintextHash,
                                       ciphertextHash: result.ciphertextHash,
                                       byteSize: result.encryptedBytes,
                                       excluding: rid)
            }

            endSlot(rid)
            consecutiveTransportFailures = 0
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
            if !cancelled, S3Client.isTransient(error) { consecutiveTransportFailures += 1 }
            // Permanent conditions must not retry forever: an asset with no
            // exportable resource (an edited Live Photo whose motion clip was
            // stripped, or an asset that vanished) is SKIPPED, not failed.
            if case PhotoLibrary.ExportError.noResource = error {
                let what = AssetRecord.isLiveMotion(rid)
                    ? "Live Photo has no motion clip (edited?)"
                    : "asset has no exportable file"
                index.markSkipped(rid, reason: "No exportable resource")
                endSlot(rid)
                appendLog("Skipped \(record.filename.isEmpty ? "an item" : record.filename) — \(what). It won't be retried.", .warning)
                refreshCounts()
                return
            }
            if case PhotoLibrary.ExportError.notFound = error {
                // Asset is gone from the library; the next scan's cleanup
                // tombstones or drops the row properly.
                index.markSkipped(rid, reason: Self.skipReasonGone)
                endSlot(rid)
                refreshCounts()
                return
            }
            if case PhotoLibrary.ExportError.hiddenExcluded = error {
                // Hidden after being queued, with the Hidden-album setting
                // off. Skipped for now; scans requeue it the moment it turns
                // eligible again (unhidden, or the setting turned on).
                index.markSkipped(rid, reason: Self.skipReasonHidden)
                endSlot(rid)
                appendLog("Skipped \(record.filename.isEmpty ? "a photo" : record.filename) — it's in the Hidden album, which isn't backed up (Settings → What to back up → Hidden album).", .info)
                refreshCounts()
                return
            }
            // A verify-requeued record keeps its "Verify:" marker across failed
            // attempts — losing it would let the next attempt's HEAD-skip
            // re-mark the bad blob as healthy without re-uploading.
            let reason = cancelled ? "Cancelled" : error.localizedDescription
            let hadVerify = record.lastError?.hasPrefix("Verify:") ?? false
            index.markFailed(rid, error: hadVerify ? "Verify: retry — \(reason)" : reason)
            endSlot(rid)
            if !cancelled {
                appendLog("Failed \(record.filename): \(error.localizedDescription)", .error)
            }
        }
    }

    // MARK: Maintenance

    private func pendingJournalCount() -> Int {
        index?.unjournaledCount() ?? 0
    }

    func resetIndex() {
        index?.reset()
        scanMark = nil
        repoConflict = nil
        pendingAttach = nil
        refreshCounts()
        appendLog("Local index cleared (repository untouched). The next backup re-inspects the folder — use the attach prompt to reload from the repository, or a fresh folder to start over.", .warning)
    }

    // MARK: Logging

    private func appendLog(_ message: String, _ kind: LogEntry.Kind) {
        log.insert(LogEntry(date: Date(), message: message, kind: kind), at: 0)
        if log.count > 200 { log.removeLast(log.count - 200) }
    }
}
