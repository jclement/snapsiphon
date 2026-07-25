import XCTest
@testable import SnapSiphon

final class CryptoAndRepositoryTests: XCTestCase {
    func testAgeRoundTripsChunkBoundariesAndRejectsTampering() throws {
        let identity = Age.Identity()
        let sizes = [0, 1, 65_535, 65_536, 65_537, 131_072]
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("age-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for size in sizes {
            let plaintext = Data((0..<size).map { UInt8(truncatingIfNeeded: $0) })
            let ciphertext = try Age.encrypt(plaintext, to: [identity.recipient])
            let encryptedURL = directory.appendingPathComponent("\(size).age")
            let restoredURL = directory.appendingPathComponent("\(size).out")
            try ciphertext.write(to: encryptedURL)
            try Age.decryptFile(at: encryptedURL, to: restoredURL, identity: identity)
            XCTAssertEqual(try Data(contentsOf: restoredURL), plaintext, "size \(size)")
        }

        var tampered = try Age.encrypt(Data("important".utf8), to: [identity.recipient])
        tampered[tampered.index(before: tampered.endIndex)] ^= 1
        let badURL = directory.appendingPathComponent("tampered.age")
        let badOutput = directory.appendingPathComponent("tampered.out")
        try tampered.write(to: badURL)
        XCTAssertThrowsError(try Age.decryptFile(at: badURL, to: badOutput, identity: identity))
        XCTAssertFalse(FileManager.default.fileExists(atPath: badOutput.path))
    }

    func testAgeEncryptsToEveryRecipient() throws {
        let first = Age.Identity()
        let second = Age.Identity()
        let plaintext = Data("two recipients".utf8)
        let ciphertext = try Age.encrypt(plaintext, to: [first.recipient, second.recipient])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("recipient-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.age")
        try ciphertext.write(to: source)
        for (index, identity) in [first, second].enumerated() {
            let output = directory.appendingPathComponent("\(index).out")
            try Age.decryptFile(at: source, to: output, identity: identity)
            XCTAssertEqual(try Data(contentsOf: output), plaintext)
        }
    }

    func testRepositoryNamingAndGraceTwinSafety() throws {
        let salt = try Repo.newSaltHex()
        XCTAssertEqual(salt.count, 64)
        XCTAssertEqual(Repo.blobName(saltHex: salt, plaintextHash: "abc"),
                       Repo.blobName(saltHex: salt, plaintextHash: "abc"))
        XCTAssertEqual(Repo.parseMetadataKey("checkpoints/000002/journal000003.age")?.gen, 2)
        XCTAssertEqual(Repo.parseMetadataKey("checkpoints/000002/journal000003.age")?.seq, 3)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("index-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try BackupIndex(directory: directory)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func record(_ id: String) -> AssetRecord {
            AssetRecord(localIdentifier: id, uuid: "shared", state: .uploaded,
                        mediaType: .photo, filename: "\(id).jpg", byteSize: 100,
                        createdAt: now, uploadedAt: now, lastError: nil,
                        plaintextHash: "plain", ciphertextHash: "cipher", journaled: true)
        }
        index.upsert(record("old"))
        index.upsert(record("recent"))
        index.markDeleted("old", at: now.addingTimeInterval(-31 * 86_400))
        index.markDeleted("recent", at: now.addingTimeInterval(-5 * 86_400))
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        XCTAssertEqual(index.purgeableRecords(before: cutoff).map(\.localIdentifier), ["old"])
        XCTAssertTrue(index.blobReferencedOutside("shared", excluding: ["old"]))
        index.resurrect("old")
        XCTAssertEqual(index.record(for: "old")?.state, .uploaded)
        XCTAssertFalse(index.record(for: "old")?.journaled ?? true)
        XCTAssertNil(index.databaseError)

        try index.reset()
        XCTAssertTrue(index.allIdentifiers().isEmpty)
        XCTAssertNil(index.databaseError)
    }

    func testSQLiteFailureIsStickyAndSettingsGraceIsClamped() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        database.exec("THIS IS NOT SQL")
        XCTAssertNotNil(database.lastError)

        var invalid = BackupSettings()
        invalid.deleteGraceDays = -90
        invalid.parallelUploads = 999
        let key = "SnapSiphon.settings.v1"
        let previous = UserDefaults.standard.data(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.set(try JSONEncoder().encode(invalid), forKey: key)
        let loaded = BackupSettings.load()
        XCTAssertEqual(loaded.deleteGraceDays, BackupSettings.graceRange.lowerBound)
        XCTAssertEqual(loaded.parallelUploads, BackupSettings.parallelRange.upperBound)
    }

    func testRepositoryLibraryMatcherUsesPhotosNotTheClearedCache() {
        let captured = Date(timeIntervalSince1970: 1_700_000_000)
        let repository = [
            AssetRecord(localIdentifier: "photo-1", uuid: "blob-1", state: .uploaded,
                        mediaType: .photo, filename: "IMG_0001.HEIC", byteSize: 123,
                        createdAt: captured, uploadedAt: captured, lastError: nil),
            AssetRecord(localIdentifier: "old-device-id", uuid: "blob-2", state: .uploaded,
                        mediaType: .video, filename: "IMG_0002.MOV", byteSize: 456,
                        createdAt: captured.addingTimeInterval(20), uploadedAt: captured,
                        lastError: nil),
        ]
        let photos = [
            LibraryComparisonRecord(localIdentifier: "photo-1", mediaType: .photo,
                                    filename: "IMG_0001.HEIC", createdAt: captured),
            // Different identifier, as can happen after a device migration;
            // the unique original metadata still provides a strong match.
            LibraryComparisonRecord(localIdentifier: "new-device-id", mediaType: .video,
                                    filename: "img_0002.mov",
                                    createdAt: captured.addingTimeInterval(20.4)),
        ]

        let result = RepositoryLibraryMatcher.compare(repository: repository, library: photos)
        XCTAssertEqual(result.repositoryCount, 2)
        XCTAssertEqual(result.libraryCount, 2)
        XCTAssertEqual(result.exactIdentifierMatches, 1)
        XCTAssertEqual(result.metadataMatches, 1)
        XCTAssertEqual(result.repositoryNotFound, 0)
    }

    func testRepositoryLibraryMatcherRefusesAmbiguousMetadata() {
        let captured = Date(timeIntervalSince1970: 1_700_000_000)
        let repository = [
            AssetRecord(localIdentifier: "old-1", uuid: "blob-1", state: .uploaded,
                        mediaType: .photo, filename: "BURST.HEIC", byteSize: 123,
                        createdAt: captured, uploadedAt: captured, lastError: nil),
            AssetRecord(localIdentifier: "old-2", uuid: "blob-2", state: .uploaded,
                        mediaType: .photo, filename: "BURST.HEIC", byteSize: 123,
                        createdAt: captured, uploadedAt: captured, lastError: nil),
        ]
        let photos = [
            LibraryComparisonRecord(localIdentifier: "new-1", mediaType: .photo,
                                    filename: "BURST.HEIC", createdAt: captured),
            LibraryComparisonRecord(localIdentifier: "new-2", mediaType: .photo,
                                    filename: "BURST.HEIC", createdAt: captured),
        ]

        let result = RepositoryLibraryMatcher.compare(repository: repository, library: photos)
        XCTAssertEqual(result.matchedCount, 0)
        XCTAssertEqual(result.repositoryNotFound, 2)
    }
}
