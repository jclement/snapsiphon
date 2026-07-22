import Foundation
import SwiftUI

/// All the knobs. Persisted to `UserDefaults` as JSON. This is the "lots of knobs
/// to tune" surface from the brief — deliberately generous.
struct BackupSettings: Codable, Equatable {
    // What to back up
    var includePhotos: Bool = true
    var includeVideos: Bool = true
    var favoritesOnly: Bool = false

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

    // Encryption
    var encryptFilenames: Bool = true       // hash the object key so names don't leak

    // Housekeeping
    var verifyRemoteBeforeUpload: Bool = false  // HEAD each object before PUT (slower, safer)
    var autoStartOnLaunch: Bool = false
    /// Fast scans only look at photos newer than the last-scanned high-water mark.
    /// Turn off (or run a Deep scan) to always re-check the whole library.
    var incrementalScan: Bool = true

    /// Keep an encrypted `manifest.age` in the bucket (key → original filename
    /// map) so a bucket-only restore can rename everything back. Refreshed after
    /// each run that uploads something.
    var keepBucketManifest: Bool = true

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
