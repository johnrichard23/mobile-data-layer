import DataLayer
import XCTest

struct Trip: Identifiable, Sendable, Codable, Equatable {
    let id: String
    var name: String
}

final class StoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func stored(_ id: String, _ name: String, at date: Date? = nil) -> Stored<Trip> {
        Stored(id: id, item: Trip(id: id, name: name), fetchedAt: date ?? t0)
    }

    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // The same behaviour for both built-in stores.
    private func exerciseStore(_ store: any Store<Trip>) async throws {
        try await store.save([stored("a", "A"), stored("b", "B")])
        var ids = try await store.all().map(\.id)
        XCTAssertEqual(ids, ["a", "b"])

        try await store.save([stored("a", "A2"), stored("c", "C")])
        let all = try await store.all()
        XCTAssertEqual(all.map(\.id), ["a", "b", "c"], "saving an existing id keeps its place")
        XCTAssertEqual(all.first?.item.name, "A2")

        let found = try await store.item(id: "b")
        XCTAssertEqual(found?.item.name, "B")
        let missing = try await store.item(id: "zzz")
        XCTAssertNil(missing)

        try await store.delete(ids: ["b", "unknown"])
        ids = try await store.all().map(\.id)
        XCTAssertEqual(ids, ["a", "c"])

        try await store.replaceAll([stored("z", "Z"), stored("y", "Y")])
        ids = try await store.all().map(\.id)
        XCTAssertEqual(ids, ["z", "y"], "replaceAll takes the given order")

        try await store.deleteAll()
        let remaining = try await store.all()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testInMemoryStoreBehaviour() async throws {
        try await exerciseStore(InMemoryStore<Trip>())
    }

    func testFileStoreBehaviour() async throws {
        try await exerciseStore(FileStore<Trip>(name: "trips", directory: tempDirectory()))
    }

    func testFileStoreSurvivesRelaunch() async throws {
        let directory = tempDirectory()
        let first = FileStore<Trip>(name: "trips", directory: directory)
        try await first.replaceAll([stored("a", "A"), stored("b", "B")])

        let second = FileStore<Trip>(name: "trips", directory: directory)
        let all = try await second.all()
        XCTAssertEqual(all.map(\.item), [Trip(id: "a", name: "A"), Trip(id: "b", name: "B")])
        XCTAssertEqual(all.first?.fetchedAt, t0, "fetch times survive too")
    }

    func testFileStoreDiscardsAnUnreadableFileAndStartsEmpty() async throws {
        let directory = tempDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("trips.json"))

        let store = FileStore<Trip>(name: "trips", directory: directory)
        let all = try await store.all()
        XCTAssertTrue(all.isEmpty)
        try await store.save([stored("a", "A")])
        let again = try await FileStore<Trip>(name: "trips", directory: directory).all()
        XCTAssertEqual(again.count, 1, "and works normally afterwards")
    }

    func testDifferentNamesDoNotShareData() async throws {
        let directory = tempDirectory()
        try await FileStore<Trip>(name: "trips", directory: directory).save([stored("a", "A")])
        let other = try await FileStore<Trip>(name: "places", directory: directory).all()
        XCTAssertTrue(other.isEmpty)
    }

    func testUpdatesEmitsCurrentThenEveryChange() async throws {
        let store = InMemoryStore<Trip>()
        await store.save([stored("a", "A")])
        var iterator = await store.updates().makeAsyncIterator()

        var next = await iterator.next()
        XCTAssertEqual(next?.map(\.id), ["a"], "current contents first")

        await store.save([stored("b", "B")])
        next = await iterator.next()
        XCTAssertEqual(next?.map(\.id), ["a", "b"])

        await store.delete(ids: ["a"])
        next = await iterator.next()
        XCTAssertEqual(next?.map(\.id), ["b"])
    }
}
