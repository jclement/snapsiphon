import Foundation

/// The local cache of repository state: a SQLite table of `AssetRecord`s plus
/// a small meta table tracking the journal chain position. NOT the source of
/// truth — the bucket's checkpoint + journals are; this database can be
/// rebuilt from them at any time (`importSnapshot` + `apply(journal:)`).
/// All access is serialized on a private queue.
final class BackupIndex {
    private let db: SQLiteDatabase
    private let dbURL: URL
    private let queue = DispatchQueue(label: "ca.straybits.snapsiphon.index")

    init(directory: URL) throws {
        self.dbURL = directory.appendingPathComponent("index.sqlite")
        self.db = try SQLiteDatabase(path: dbURL.path)
        // Clean up files from earlier formats.
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("bloom.filter"))

        // Format v2 (checkpoint/journal repo). Pre-repo caches are dropped —
        // the schema changed shape and the cache is rebuildable.
        let legacy = db.scalarInt(
            "SELECT COUNT(*) FROM pragma_table_info('assets') WHERE name='remoteKey';")
        if legacy > 0 { db.exec("DROP TABLE assets;") }

        db.exec("""
            CREATE TABLE IF NOT EXISTS assets (
                localIdentifier TEXT PRIMARY KEY,
                uuid TEXT NOT NULL,
                state TEXT NOT NULL,
                mediaType TEXT NOT NULL,
                filename TEXT NOT NULL,
                byteSize INTEGER NOT NULL,
                createdAt REAL,
                uploadedAt REAL,
                lastError TEXT,
                plaintextHash TEXT,
                ciphertextHash TEXT,
                journaled INTEGER NOT NULL DEFAULT 0,
                deletedAt REAL
            );
        """)
        db.exec("CREATE INDEX IF NOT EXISTS idx_state ON assets(state);")
        db.exec("CREATE INDEX IF NOT EXISTS idx_journaled ON assets(journaled);")
        db.exec("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);")
        // Crash recovery: mid-flight rows go back to pending (blobs from a PUT
        // that finished without being recorded are ignorable orphans).
        db.exec("UPDATE assets SET state='pending' WHERE state='uploading';")
    }

    // MARK: Meta (journal chain position)

    func metaValue(_ key: String) -> String? {
        queue.sync {
            (try? db.query("SELECT value FROM meta WHERE key=?;", [.text(key)]) { $0.text(0) })?.first
        }
    }

    func setMeta(_ key: String, _ value: String?) {
        queue.sync {
            if let value {
                db.exec("INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
                        [.text(key), .text(value)])
            } else {
                db.exec("DELETE FROM meta WHERE key=?;", [.text(key)])
            }
        }
    }

    // MARK: Upserts

    func upsert(_ record: AssetRecord) {
        queue.sync {
            db.exec("""
                INSERT INTO assets
                    (localIdentifier, uuid, state, mediaType, filename, byteSize, createdAt, uploadedAt, lastError, plaintextHash, ciphertextHash, journaled)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(localIdentifier) DO UPDATE SET
                    uuid=excluded.uuid, state=excluded.state, mediaType=excluded.mediaType,
                    filename=excluded.filename, byteSize=excluded.byteSize, createdAt=excluded.createdAt,
                    uploadedAt=excluded.uploadedAt, lastError=excluded.lastError,
                    plaintextHash=excluded.plaintextHash, ciphertextHash=excluded.ciphertextHash,
                    journaled=excluded.journaled;
                """,
                [
                    .text(record.localIdentifier),
                    .text(record.uuid),
                    .text(record.state.rawValue),
                    .text(record.mediaType.rawValue),
                    .text(record.filename),
                    .int(record.byteSize),
                    .date(record.createdAt),
                    .date(record.uploadedAt),
                    .optText(record.lastError),
                    .optText(record.plaintextHash),
                    .optText(record.ciphertextHash),
                    .int(record.journaled ? 1 : 0),
                ])
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

    // MARK: Journal bookkeeping

    /// Rows whose latest change hasn't been committed to a bucket journal yet.
    func unjournaledRecords() -> [AssetRecord] {
        queue.sync {
            (try? db.query(
                "SELECT * FROM assets WHERE journaled=0 AND state IN ('uploaded','deleted') ORDER BY uploadedAt;",
                [], Self.mapRow)) ?? []
        }
    }

    func markJournaled(_ localIdentifiers: [String]) {
        queue.sync {
            for id in localIdentifiers {
                db.exec("UPDATE assets SET journaled=1 WHERE localIdentifier=?;", [.text(id)])
            }
        }
    }

    func unjournaledCount() -> Int {
        queue.sync {
            Int(db.scalarInt("SELECT COUNT(*) FROM assets WHERE journaled=0 AND state IN ('uploaded','deleted');"))
        }
    }

    /// Every blob UUID any row still references (uploaded, deleted-but-
    /// unpurged, or in flight) — the complement of "orphan" for Verify.
    func referencedUUIDs() -> Set<String> {
        queue.sync {
            Set((try? db.query("SELECT uuid FROM assets WHERE uuid != '';", []) { $0.text(0) }) ?? [])
        }
    }

    /// True when any OTHER live (non-deleted) row points at this blob —
    /// with content addressing, identical files share one blob, so a purge
    /// must not delete a blob a surviving twin still needs.
    func blobSharedByLive(_ uuid: String, excluding localIdentifier: String) -> Bool {
        queue.sync {
            db.scalarInt("SELECT COUNT(*) FROM assets WHERE uuid=? AND localIdentifier != ? AND state != 'deleted';",
                         [.text(uuid), .text(localIdentifier)]) > 0
        }
    }

    // MARK: State transitions

    func markDeleted(_ localIdentifier: String, at date: Date) {
        queue.sync {
            db.exec("UPDATE assets SET state='deleted', deletedAt=?, journaled=0 WHERE localIdentifier=? AND state != 'deleted';",
                    [.date(date), .text(localIdentifier)])
        }
    }

    func resurrect(_ localIdentifier: String) {
        queue.sync {
            db.exec("UPDATE assets SET state='uploaded', deletedAt=NULL, journaled=0 WHERE localIdentifier=? AND state='deleted';",
                    [.text(localIdentifier)])
        }
    }

    func tombstonedIdentifiers() -> Set<String> {
        queue.sync {
            Set((try? db.query("SELECT localIdentifier FROM assets WHERE state='deleted';", []) { $0.text(0) }) ?? [])
        }
    }

    /// Tombstones past the grace cutoff, eligible for physical purge.
    func purgeableRecords(before cutoff: Date) -> [AssetRecord] {
        queue.sync {
            (try? db.query(
                "SELECT * FROM assets WHERE state='deleted' AND deletedAt IS NOT NULL AND deletedAt <= ?;",
                [.date(cutoff)], Self.mapRow)) ?? []
        }
    }

    /// Drop a record entirely (purged blob, or pending item whose asset vanished).
    func hardDeleteRecord(_ localIdentifier: String) {
        queue.sync {
            db.exec("DELETE FROM assets WHERE localIdentifier=?;", [.text(localIdentifier)])
        }
    }

    func requeue(_ localIdentifier: String, reason: String) {
        queue.sync {
            db.exec("UPDATE assets SET state='pending', lastError=? WHERE localIdentifier=?;",
                    [.text(reason), .text(localIdentifier)])
        }
    }

    // MARK: Aggregates & queries (cache reads)

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

    func allUploaded() -> [AssetRecord] {
        queue.sync {
            (try? db.query("SELECT * FROM assets WHERE state='uploaded' ORDER BY uploadedAt;", [], Self.mapRow)) ?? []
        }
    }

    func uploadedKeyPairs() -> [(id: String, uuid: String)] {
        queue.sync {
            (try? db.query("SELECT localIdentifier, uuid FROM assets WHERE state='uploaded';", []) {
                (id: $0.text(0), uuid: $0.text(1))
            }) ?? []
        }
    }

    func recentUploads(limit: Int) -> [AssetRecord] {
        queue.sync {
            (try? db.query(
                "SELECT * FROM assets WHERE state='uploaded' ORDER BY uploadedAt DESC LIMIT ?;",
                [.int(Int64(limit))], Self.mapRow)) ?? []
        }
    }

    func allIdentifiers() -> Set<String> {
        queue.sync {
            Set((try? db.query("SELECT localIdentifier FROM assets;", []) { $0.text(0) }) ?? [])
        }
    }

    func reset() {
        queue.sync {
            db.exec("DELETE FROM assets;")
            db.exec("DELETE FROM meta;")
        }
    }

    // MARK: Snapshot (checkpoint) export / import

    /// Write a consistent snapshot of this database to `url` (VACUUM INTO).
    /// The encrypted result IS the checkpoint — local cache and checkpoint
    /// share one schema by construction.
    func snapshot(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try queue.sync {
            try db.execThrowing("VACUUM INTO '\(url.path.replacingOccurrences(of: "'", with: "''"))';")
        }
    }

    /// Replace this database's contents with a decrypted checkpoint snapshot.
    func importSnapshot(from url: URL) throws {
        let snap = try SQLiteDatabase(path: url.path)
        let rows = try snap.query("SELECT * FROM assets;", [], Self.mapRow)
        let metaRows: [(String, String)] = (try? snap.query("SELECT key, value FROM meta;", []) {
            ($0.text(0), $0.text(1))
        }) ?? []
        queue.sync {
            db.exec("DELETE FROM assets;")
            db.exec("DELETE FROM meta;")
        }
        for r in rows { upsert(r) }
        for (k, v) in metaRows { setMeta(k, v) }
    }

    /// Apply one journal's entries on top of current state (repo replay).
    func apply(journal: Repo.Journal) {
        let iso = ISO8601DateFormatter()
        for e in journal.entries {
            switch e.op {
            case .add, .update, .restore:
                let rec = AssetRecord(
                    localIdentifier: e.localIdentifier ?? "remote-\(e.uuid)",
                    uuid: e.uuid,
                    state: .uploaded,
                    mediaType: AssetRecord.MediaType(rawValue: e.mediaType ?? "") ?? .other,
                    filename: e.filename ?? "",
                    byteSize: e.size ?? 0,
                    createdAt: e.createdAt.flatMap { iso.date(from: $0) },
                    uploadedAt: iso.date(from: e.at),
                    lastError: nil,
                    plaintextHash: e.plaintextHash,
                    ciphertextHash: e.ciphertextHash,
                    journaled: true)
                upsert(rec)
            case .delete:
                if let id = e.localIdentifier {
                    markDeleted(id, at: iso.date(from: e.at) ?? Date())
                    markJournaled([id])
                }
            case .purge:
                if let id = e.localIdentifier { hardDeleteRecord(id) }
            }
        }
    }

    // MARK: Row mapping

    private static func mapRow(_ r: SQLiteDatabase.Row) -> AssetRecord {
        AssetRecord(
            localIdentifier: r.text(0),
            uuid: r.text(1),
            state: AssetState(rawValue: r.text(2)) ?? .pending,
            mediaType: AssetRecord.MediaType(rawValue: r.text(3)) ?? .other,
            filename: r.text(4),
            byteSize: r.int64(5),
            createdAt: r.dateOrNil(6),
            uploadedAt: r.dateOrNil(7),
            lastError: r.textOrNil(8),
            plaintextHash: r.textOrNil(9),
            ciphertextHash: r.textOrNil(10),
            journaled: r.int(11) == 1)
    }
}
