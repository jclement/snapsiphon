import Foundation

/// The local source of truth for what has been backed up: a SQLite table of
/// `AssetRecord`s. Scans load the full identifier set into memory in one query
/// (cheap even at 100k assets), so no probabilistic pre-filter is needed. All
/// access is serialized on a private queue so callers can hit it from any
/// actor/task.
final class BackupIndex {
    private let db: SQLiteDatabase
    private let queue = DispatchQueue(label: "com.snapsiphon.index")

    init(directory: URL) throws {
        let dbURL = directory.appendingPathComponent("index.sqlite")
        self.db = try SQLiteDatabase(path: dbURL.path)
        // Clean up the bloom filter file from earlier versions.
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("bloom.filter"))
        db.exec("""
            CREATE TABLE IF NOT EXISTS assets (
                localIdentifier TEXT PRIMARY KEY,
                remoteKey TEXT NOT NULL,
                state TEXT NOT NULL,
                mediaType TEXT NOT NULL,
                filename TEXT NOT NULL,
                byteSize INTEGER NOT NULL,
                createdAt REAL,
                uploadedAt REAL,
                lastError TEXT
            );
        """)
        db.exec("CREATE INDEX IF NOT EXISTS idx_state ON assets(state);")
        // Migration: tombstone timestamp for delete grace-period logic. Harmless
        // duplicate-column error on already-migrated DBs (exec ignores it).
        db.exec("ALTER TABLE assets ADD COLUMN deletedAt REAL;")
        db.exec("ALTER TABLE assets ADD COLUMN md5 TEXT;")
        // Crash recovery: anything mid-flight when the process died goes back to
        // pending, so the next run retries it (deterministic keys mean a re-upload
        // just overwrites the same object — no duplicates).
        db.exec("UPDATE assets SET state='pending' WHERE state='uploading';")
    }

    // MARK: Upserts

    func upsert(_ record: AssetRecord) {
        queue.sync {
            db.exec("""
                INSERT INTO assets
                    (localIdentifier, remoteKey, state, mediaType, filename, byteSize, createdAt, uploadedAt, lastError, md5)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(localIdentifier) DO UPDATE SET
                    remoteKey=excluded.remoteKey, state=excluded.state, mediaType=excluded.mediaType,
                    filename=excluded.filename, byteSize=excluded.byteSize, createdAt=excluded.createdAt,
                    uploadedAt=excluded.uploadedAt, lastError=excluded.lastError, md5=excluded.md5;
                """,
                [
                    .text(record.localIdentifier),
                    .text(record.remoteKey),
                    .text(record.state.rawValue),
                    .text(record.mediaType.rawValue),
                    .text(record.filename),
                    .int(record.byteSize),
                    .date(record.createdAt),
                    .date(record.uploadedAt),
                    .optText(record.lastError),
                    .optText(record.md5),
                ])
        }
    }

    func markUploaded(_ localIdentifier: String, uploadedAt: Date) {
        queue.sync {
            db.exec("UPDATE assets SET state='uploaded', uploadedAt=?, lastError=NULL WHERE localIdentifier=?;",
                    [.date(uploadedAt), .text(localIdentifier)])
        }
    }

    func markFailed(_ localIdentifier: String, error: String) {
        queue.sync {
            db.exec("UPDATE assets SET state='failed', lastError=? WHERE localIdentifier=?;",
                    [.text(error), .text(localIdentifier)])
        }
    }

    func record(for localIdentifier: String) -> AssetRecord? {
        queue.sync {
            (try? db.query("SELECT * FROM assets WHERE localIdentifier = ?;", [.text(localIdentifier)], Self.mapRow))?.first
        }
    }

    // MARK: Aggregate stats

    struct Counts {
        var total = 0
        var uploaded = 0
        var pending = 0
        var failed = 0
        var uploadedBytes: Int64 = 0
        var totalBytes: Int64 = 0
    }

    func counts() -> Counts {
        queue.sync {
            var c = Counts()
            c.total = Int(db.scalarInt("SELECT COUNT(*) FROM assets WHERE state != 'deleted';"))
            c.uploaded = Int(db.scalarInt("SELECT COUNT(*) FROM assets WHERE state='uploaded';"))
            c.pending = Int(db.scalarInt("SELECT COUNT(*) FROM assets WHERE state IN ('pending','uploading');"))
            c.failed = Int(db.scalarInt("SELECT COUNT(*) FROM assets WHERE state='failed';"))
            c.uploadedBytes = db.scalarInt("SELECT COALESCE(SUM(byteSize),0) FROM assets WHERE state='uploaded';")
            c.totalBytes = db.scalarInt("SELECT COALESCE(SUM(byteSize),0) FROM assets WHERE state != 'deleted';")
            return c
        }
    }

    /// Uploaded counts and stored bytes split by media type, for the ring.
    func uploadedByType() -> (photos: Int, videos: Int, photoBytes: Int64, videoBytes: Int64) {
        queue.sync {
            let p = db.scalarInt("SELECT COUNT(*) FROM assets WHERE state='uploaded' AND mediaType='photo';")
            let v = db.scalarInt("SELECT COUNT(*) FROM assets WHERE state='uploaded' AND mediaType='video';")
            let pb = db.scalarInt("SELECT COALESCE(SUM(byteSize),0) FROM assets WHERE state='uploaded' AND mediaType='photo';")
            let vb = db.scalarInt("SELECT COALESCE(SUM(byteSize),0) FROM assets WHERE state='uploaded' AND mediaType='video';")
            return (Int(p), Int(v), pb, vb)
        }
    }

    func pendingRecords(limit: Int) -> [AssetRecord] {
        queue.sync {
            (try? db.query(
                "SELECT * FROM assets WHERE state IN ('pending','failed') ORDER BY createdAt DESC LIMIT ?;",
                [.int(Int64(limit))], Self.mapRow)) ?? []
        }
    }

    /// Every uploaded record, for building the restore manifest.
    func allUploaded() -> [AssetRecord] {
        queue.sync {
            (try? db.query("SELECT * FROM assets WHERE state='uploaded' ORDER BY uploadedAt;", [], Self.mapRow)) ?? []
        }
    }

    /// A random sample of uploaded records, for spot-check verification.
    func randomUploaded(limit: Int) -> [AssetRecord] {
        queue.sync {
            (try? db.query(
                "SELECT * FROM assets WHERE state='uploaded' ORDER BY RANDOM() LIMIT ?;",
                [.int(Int64(limit))], Self.mapRow)) ?? []
        }
    }

    /// Send a record back to the upload queue (verification found it missing or
    /// mismatched in the bucket — a re-upload heals it).
    func requeue(_ localIdentifier: String, reason: String) {
        queue.sync {
            db.exec("UPDATE assets SET state='pending', lastError=? WHERE localIdentifier=?;",
                    [.text(reason), .text(localIdentifier)])
        }
    }

    func recentUploads(limit: Int) -> [AssetRecord] {
        queue.sync {
            (try? db.query(
                "SELECT * FROM assets WHERE state='uploaded' ORDER BY uploadedAt DESC LIMIT ?;",
                [.int(Int64(limit))], Self.mapRow)) ?? []
        }
    }

    /// Every indexed local identifier, loaded in one query. The scan holds this
    /// in memory so it can skip already-known assets without a per-asset DB hit.
    func allIdentifiers() -> Set<String> {
        queue.sync {
            let rows = (try? db.query("SELECT localIdentifier FROM assets;", []) { $0.text(0) }) ?? []
            return Set(rows)
        }
    }

    /// (id, remoteKey) for every uploaded object — used to reconcile against the
    /// live library when propagating deletes.
    func uploadedKeyPairs() -> [(id: String, remoteKey: String)] {
        queue.sync {
            (try? db.query("SELECT localIdentifier, remoteKey FROM assets WHERE state='uploaded';", []) {
                (id: $0.text(0), remoteKey: $0.text(1))
            }) ?? []
        }
    }

    /// Logically delete: keep the row as a tombstone (state='deleted') stamped
    /// with the deletion time, so the manifest records it and the grace period
    /// can be enforced before any physical purge.
    func markDeleted(_ localIdentifier: String, at date: Date) {
        queue.sync {
            db.exec("UPDATE assets SET state='deleted', deletedAt=? WHERE localIdentifier=? AND state != 'deleted';",
                    [.date(date), .text(localIdentifier)])
        }
    }

    /// Bring a tombstoned asset back to life — used when a deleted photo
    /// reappears in the library (e.g. iCloud restored after an accidental erase).
    func resurrect(_ localIdentifier: String) {
        queue.sync {
            db.exec("UPDATE assets SET state='uploaded', deletedAt=NULL WHERE localIdentifier=? AND state='deleted';",
                    [.text(localIdentifier)])
        }
    }

    /// Local identifiers currently tombstoned (to detect resurrections).
    func tombstonedIdentifiers() -> Set<String> {
        queue.sync {
            let rows = (try? db.query("SELECT localIdentifier FROM assets WHERE state='deleted';", []) { $0.text(0) }) ?? []
            return Set(rows)
        }
    }

    /// Object keys of everything logically deleted — the manifest's tombstone list.
    func deletedKeys() -> [String] {
        queue.sync {
            (try? db.query("SELECT remoteKey FROM assets WHERE state='deleted';", []) { $0.text(0) }) ?? []
        }
    }

    /// Full records for tombstoned assets, so the manifest can carry their
    /// metadata for disaster (`--all`) restores until the blob is purged.
    func deletedRecords() -> [AssetRecord] {
        queue.sync {
            (try? db.query("SELECT * FROM assets WHERE state='deleted' ORDER BY uploadedAt;", [], Self.mapRow)) ?? []
        }
    }

    /// Tombstones whose grace period has elapsed and are eligible for physical
    /// purge (returns their object keys).
    func purgeableKeys(before cutoff: Date) -> [String] {
        queue.sync {
            (try? db.query(
                "SELECT remoteKey FROM assets WHERE state='deleted' AND deletedAt IS NOT NULL AND deletedAt <= ?;",
                [.date(cutoff)]) { $0.text(0) }) ?? []
        }
    }

    /// Permanently drop a tombstone once its object is confirmed gone from the bucket.
    func hardDelete(remoteKey: String) {
        queue.sync {
            db.exec("DELETE FROM assets WHERE remoteKey=? AND state='deleted';", [.text(remoteKey)])
        }
    }

    func reset() {
        queue.sync {
            db.exec("DELETE FROM assets;")
        }
    }

    // MARK: Row mapping

    private static func mapRow(_ r: SQLiteDatabase.Row) -> AssetRecord {
        AssetRecord(
            localIdentifier: r.text(0),
            remoteKey: r.text(1),
            state: AssetState(rawValue: r.text(2)) ?? .pending,
            mediaType: AssetRecord.MediaType(rawValue: r.text(3)) ?? .other,
            filename: r.text(4),
            byteSize: r.int64(5),
            createdAt: r.dateOrNil(6),
            uploadedAt: r.dateOrNil(7),
            lastError: r.textOrNil(8),
            md5: r.textOrNil(10))   // col 9 = deletedAt, col 10 = md5 (migration order)
    }
}
