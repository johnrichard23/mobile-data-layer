import CryptoKit
import DataLayer
import XCTest

final class StorageSecurityTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func record(_ name: String) -> Stored<Trip> {
        Stored(id: name, item: Trip(id: name, name: name), fetchedAt: t0)
    }

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func fileBytes(_ directory: URL, _ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent("\(name).json"))
    }

    // MARK: - Encrypted file store

    func testEncryptedFileHoldsNoReadableData() async throws {
        let directory = tempDirectory()
        let key = SymmetricKey(size: .bits256)
        let store = FileStore<Trip>(name: "trips", directory: directory, encryptionKey: key)
        try await store.save([record("Siargao honeymoon"), record("Dana Cruz")])

        let bytes = try fileBytes(directory, "trips")
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(text.contains("Siargao"), "trip names must not be readable on disk")
        XCTAssertFalse(text.contains("Dana"))
        XCTAssertFalse(text.contains("fetchedAt"), "not even the JSON structure")
    }

    func testEncryptedStoreReadsItsDataBackWithTheRightKey() async throws {
        let directory = tempDirectory()
        let key = SymmetricKey(size: .bits256)
        try await FileStore<Trip>(name: "trips", directory: directory, encryptionKey: key)
            .save([record("A"), record("B")])

        let again = try await FileStore<Trip>(name: "trips", directory: directory, encryptionKey: key).all()
        XCTAssertEqual(again.map(\.id), ["A", "B"])
    }

    func testAWrongKeyReadsNothingAndTheFileIsDiscarded() async throws {
        let directory = tempDirectory()
        try await FileStore<Trip>(name: "trips", directory: directory, encryptionKey: SymmetricKey(size: .bits256))
            .save([record("A")])

        let other = FileStore<Trip>(name: "trips", directory: directory, encryptionKey: SymmetricKey(size: .bits256))
        let items = try await other.all()
        XCTAssertTrue(items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("trips.json").path))
    }

    func testATamperedFileIsRejected() async throws {
        let directory = tempDirectory()
        let key = SymmetricKey(size: .bits256)
        try await FileStore<Trip>(name: "trips", directory: directory, encryptionKey: key).save([record("A")])

        var bytes = try fileBytes(directory, "trips")
        bytes[bytes.count - 5] ^= 0xFF // flip bits inside the ciphertext/tag
        try bytes.write(to: directory.appendingPathComponent("trips.json"))

        let items = try await FileStore<Trip>(name: "trips", directory: directory, encryptionKey: key).all()
        XCTAssertTrue(items.isEmpty, "authenticated encryption notices the change")
    }

    func testPlainAndEncryptedFilesAreNeverMixedUp() async throws {
        // A plain file read by an encrypted store, and the reverse, are both discarded.
        let directory = tempDirectory()
        try await FileStore<Trip>(name: "plain", directory: directory).save([record("A")])
        let encryptedReader = FileStore<Trip>(name: "plain", directory: directory, encryptionKey: SymmetricKey(size: .bits256))
        let fromPlain = try await encryptedReader.all()
        XCTAssertTrue(fromPlain.isEmpty)

        let key = SymmetricKey(size: .bits256)
        try await FileStore<Trip>(name: "secret", directory: directory, encryptionKey: key).save([record("A")])
        let plainReader = FileStore<Trip>(name: "secret", directory: directory)
        let fromEncrypted = try await plainReader.all()
        XCTAssertTrue(fromEncrypted.isEmpty)
    }

    // MARK: - File attributes

    func testFilesAreExcludedFromBackupUnlessAppOptsOut() async throws {
        let directory = tempDirectory()
        try await FileStore<Trip>(name: "default", directory: directory).save([record("A")])
        try await FileStore<Trip>(name: "kept", directory: directory, excludeFromBackup: false).save([record("A")])

        let excluded = try directory.appendingPathComponent("default.json").resourceValues(forKeys: [.isExcludedFromBackupKey])
        let included = try directory.appendingPathComponent("kept.json").resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(excluded.isExcludedFromBackup, true)
        XCTAssertEqual(included.isExcludedFromBackup, false)
    }

    func testFileProtectionClassIsApplied() async throws {
        #if os(iOS)
            let directory = tempDirectory()
            try await FileStore<Trip>(name: "default", directory: directory).save([record("A")])
            try await FileStore<Trip>(name: "locked", directory: directory, protection: .complete).save([record("A")])
            func protection(_ name: String) throws -> FileProtectionType? {
                try FileManager.default.attributesOfItem(
                    atPath: directory.appendingPathComponent("\(name).json").path
                )[.protectionKey] as? FileProtectionType
            }
            // The simulator has no data protection and reports no class at all.
            // The check is only meaningful on a device.
            let reported = try protection("default")
            try XCTSkipIf(reported == nil, "This platform doesn't report file protection (the simulator doesn't implement it)")
            XCTAssertEqual(reported, .completeUntilFirstUserAuthentication)
            XCTAssertEqual(try protection("locked"), .complete)
        #else
            throw XCTSkip("File protection classes exist on iOS only")
        #endif
    }

    // MARK: - Secret stores

    func testEncryptionKeyIsCreatedOnceAndThenReused() async throws {
        let secrets = InMemorySecretStore()
        let first = try await secrets.encryptionKey(named: "cache")
        let second = try await secrets.encryptionKey(named: "cache")
        let other = try await secrets.encryptionKey(named: "other")
        XCTAssertEqual(first.withUnsafeBytes { Data($0) }, second.withUnsafeBytes { Data($0) })
        XCTAssertNotEqual(first.withUnsafeBytes { Data($0) }, other.withUnsafeBytes { Data($0) })
        XCTAssertEqual(first.bitCount, 256)
    }

    func testAStoredKeyOfTheWrongSizeIsReportedNotUsed() async throws {
        let secrets = InMemorySecretStore()
        await secrets.setSecret(Data([1, 2, 3]), for: "cache")
        do {
            _ = try await secrets.encryptionKey(named: "cache")
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? SecretStoreError, .corrupted)
        }
    }

    func testKeychainStoresUpdatesAndDeletesSecrets() async throws {
        let store = KeychainSecretStore(service: "datalayer.tests.\(UUID().uuidString)")
        do {
            try await store.setSecret(Data("one".utf8), for: "token")
        } catch let SecretStoreError.keychain(status) where [-34018, -25308, -25293].contains(status) {
            throw XCTSkip("The Keychain isn't available to this test runner (status \(status))")
        }
        addTeardownBlock { try? await store.setSecret(nil, for: "token") }

        let stored = try await store.secret(for: "token")
        XCTAssertEqual(stored, Data("one".utf8))
        try await store.setSecret(Data("two".utf8), for: "token")
        let updated = try await store.secret(for: "token")
        XCTAssertEqual(updated, Data("two".utf8))

        try await store.setSecret(nil, for: "token")
        let removed = try await store.secret(for: "token")
        XCTAssertNil(removed)
        let missing = try await store.secret(for: "never-set")
        XCTAssertNil(missing)
    }
}
