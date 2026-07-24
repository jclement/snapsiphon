import Foundation
import SwiftUI

/// All the knobs. Persisted to `UserDefaults` as JSON. This is the "lots of knobs
/// to tune" surface from the brief — deliberately generous.
struct BackupSettings: Codable, Equatable {
    // What to back up
    var includePhotos: Bool = true
    var includeVideos: Bool = true
    var favoritesOnly: Bool = false
    /// Also back up each Live Photo's paired ~3 s motion clip (a second,
    /// separate encrypted blob per Live Photo). Off = stills only.
    var backupLivePhotoMovies: Bool? = nil
    var includeLiveMotion: Bool { backupLivePhotoMovies ?? false }
    /// Also back up the Hidden album. Off by default: hidden photos are often
    /// the most sensitive, so leaving them out is the conservative default.
    /// (Hiding a photo AFTER backup never deletes its backup either way.)
    var backupHiddenPhotos: Bool? = nil
    var includeHidden: Bool { backupHiddenPhotos ?? false }
    /// Only back up content captured on/after this date (nil = everything).
    /// For testing against a slice of a huge library, or when older content is
    /// already safe in a pre-existing backup.
    var backupCutoff: Date? = nil

    // Concurrency & throughput
    var parallelUploads: Int = 3            // 1…8
    var speedLimitMBps: Double = 0          // 0 = unlimited
    var chunkRetryLimit: Int = 3

    // Network conditions
    var wifiOnly: Bool = true
    var pauseOnLowBattery: Bool = true
    var lowBatteryThreshold: Double = 0.2   // 20%

    // Device behaviour
    var keepScreenOnWhileUploading: Bool = true
    var runInLowPowerMode: Bool = false
    /// Pew pew mode: synthesized sound effects for every pipeline event.
    /// A full-parallel backup becomes a tiny arcade. Off by default.
    var pewPewMode: Bool? = nil
    var pewPew: Bool { pewPewMode ?? false }

    // Housekeeping
    var autoStartOnLaunch: Bool = false

    /// Opportunistic background backups via BGProcessingTask — iOS grants short
    /// windows (typically overnight, charging, on Wi-Fi). Best-effort by design.
    var backgroundBackup: Bool = true

    /// Local-notification reminder when no backup has run for N days (0 = off).
    var reminderDays: Int = 0

    // Repository cadence (nerd knobs; the defaults are sensible)
    /// Commit a journal after this many uncommitted changes mid-run (one is
    /// always written at the end of a run regardless).
    var journalEvery: Int? = nil
    var journalFlushEvery: Int { journalEvery ?? 25 }
    /// Compact into a fresh checkpoint generation after this many journals.
    var checkpointEvery: Int? = nil
    var checkpointEveryJournals: Int { checkpointEvery ?? 20 }

    static let journalEveryRange = 5.0...200.0
    static let checkpointEveryRange = 5.0...100.0

    /// Whether to physically purge deleted photos' blobs (best-effort, after
    /// the grace period, Object Lock permitting). Deletions are ALWAYS marked
    /// in the manifest regardless — this knob only reclaims storage.
    var propagateDeletes: Bool = false

    /// How long a deleted photo must stay tombstoned before the app tries to
    /// physically remove it. This is the accident window: if you erase iCloud by
    /// mistake and the photos come back within this many days, nothing is purged.
    var deleteGraceDays: Int = 30

    static let parallelRange = 1...8
    static let speedRange = 0.0...50.0

    // MARK: Persistence

    private static let key = "SnapSiphon.settings.v1"

    static func load() -> BackupSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(BackupSettings.self, from: data) else {
            return BackupSettings()
        }
        return decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

/// Non-secret S3 config persistence (the secret parts live in `S3CredentialStore`).
extension S3Config {
    private static let key = "SnapSiphon.s3config.v1"

    static func load() -> S3Config {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(S3Config.self, from: data) else {
            return S3Config()
        }
        return decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
