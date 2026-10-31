import DataLayer
import XCTest

/// A remote source the test controls: what it returns, how often it was
/// called, whether it fails, and how long it takes.
final class FakeRemote: WritableRemoteSource, @unchecked Sendable {
    typealias Model = Trip

    private let lock = NSLock()
    private var trips: [Trip]
    private var failure: (any Error)?
    private var fetchAllCalls = 0
    private var fetchCalls: [String] = []
    private let delay: Duration

    init(_ trips: [Trip] = [], delay: Duration = .zero) {
        self.trips = trips
        self.delay = delay
    }

    var fetchAllCount: Int { lock.withLock { fetchAllCalls } }
    var fetchedIDs: [String] { lock.withLock { fetchCalls } }
    func setTrips(_ new: [Trip]) { lock.withLock { trips = new } }
    func setFailure(_ error: (any Error)?) { lock.withLock { failure = error } }

    private func check() throws {
        if let failure = lock.withLock({ failure }) { throw failure }
    }

    func fetchAll() async throws -> [Trip] {
        lock.withLock { fetchAllCalls += 1 }
        if delay != .zero { try await Task.sleep(for: delay) }
        try check()
        return lock.withLock { trips }
    }

    func fetch(id: String) async throws -> Trip {
        lock.withLock { fetchCalls.append(id) }
        try check()
        guard let trip = lock.withLock({ trips.first { $0.id == id } }) else {
            throw NetworkError.notFound(message: nil)
        }
        return trip
    }

    func create(_ model: Trip) async throws -> Trip {
        try check()
        let created = Trip(id: "server-\(model.name)", name: model.name)
        lock.withLock { trips.append(created) }
        return created
    }

    func update(_ model: Trip) async throws -> Trip {
        try check()
        let updated = Trip(id: model.id, name: model.name + " (saved)")
        lock.withLock { trips = trips.map { $0.id == model.id ? updated : $0 } }
        return updated
    }

    func delete(id: String) async throws {
        try check()
        lock.withLock { trips.removeAll { $0.id == id } }
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)
    func now() -> Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

final class RepositoryTests: XCTestCase {
    private let a = Trip(id: "a", name: "A")
    private let b = Trip(id: "b", name: "B")
    private let c = Trip(id: "c", name: "C")
    private let policy = CachePolicy.cacheAndRefresh(staleAfter: 60, expireAfter: 3600)

    private func makeRepository(
        _ remote: FakeRemote,
        store: (any Store<Trip>)? = nil,
        clock: TestClock = TestClock(),
        policy: CachePolicy? = nil
    ) -> (Repository<Trip>, any Store<Trip>, TestClock) {
        let store = store ?? InMemoryStore<Trip>()
        let repository = Repository<Trip>(
            remote: remote,
            store: store,
            policy: policy ?? self.policy,
            now: { clock.now() }
        )
        return (repository, store, clock)
    }

    /// Waits for background work (a stale refresh) to show its result. Wait
    /// for the outcome you care about, not for a call to have started.
    private func eventually(
        _ condition: () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<300 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition not met in time", file: file, line: line)
    }

    // MARK: - cacheAndRefresh, the list

    func testFirstCallFetchesAndLaterCallsUseTheStoredCopy() async throws {
        let remote = FakeRemote([a, b])
        let (repository, store, _) = makeRepository(remote)

        let first = try await repository.all()
        let second = try await repository.all()

        XCTAssertEqual(first, [a, b])
        XCTAssertEqual(second, [a, b])
        XCTAssertEqual(remote.fetchAllCount, 1, "fresh data is not fetched again")
        let stored = try await store.all()
        XCTAssertEqual(stored.map(\.item), [a, b])
    }

    func testStaleDataIsReturnedAtOnceAndRefreshedInTheBackground() async throws {
        let remote = FakeRemote([a])
        let (repository, _, clock) = makeRepository(remote)
        _ = try await repository.all()

        remote.setTrips([a, b])
        clock.advance(120) // stale (60) but not expired (3600)
        let result = try await repository.all()

        XCTAssertEqual(result, [a], "the caller doesn't wait for the server")
        await eventually { (try? await repository.all(policy: .cacheOnly)) == [a, b] }
        XCTAssertEqual(remote.fetchAllCount, 2)
    }

    func testExpiredDataIsDiscardedAndFetchedAgain() async throws {
        let remote = FakeRemote([a])
        let (repository, _, clock) = makeRepository(remote)
        _ = try await repository.all()

        remote.setTrips([b])
        clock.advance(7200)
        let result = try await repository.all()

        XCTAssertEqual(result, [b], "the caller waits for fresh data")
        XCTAssertEqual(remote.fetchAllCount, 2)
    }

    func testExpiredDataIsNotShownWhenTheServerFails() async throws {
        let remote = FakeRemote([a])
        let (repository, _, clock) = makeRepository(remote)
        _ = try await repository.all()

        clock.advance(7200)
        remote.setFailure(NetworkError.noConnection)
        do {
            _ = try await repository.all()
            XCTFail("should throw")
        } catch {
            XCTAssertTrue(error.isOffline)
        }
    }

    func testRefreshRemovesItemsDeletedOnTheServerAndKeepsServerOrder() async throws {
        let remote = FakeRemote([a, b, c])
        let (repository, store, _) = makeRepository(remote)
        _ = try await repository.all()

        remote.setTrips([c, a])
        _ = try await repository.refresh()

        let stored = try await store.all()
        XCTAssertEqual(stored.map(\.id), ["c", "a"])
    }

    func testAnEmptyListFromTheServerIsCachedAsEmptyNotRefetchedEveryTime() async throws {
        let remote = FakeRemote([])
        let (repository, _, _) = makeRepository(remote)
        _ = try await repository.all()
        _ = try await repository.all()
        XCTAssertEqual(remote.fetchAllCount, 1)
    }

    func testCallsMadeAtTheSameTimeShareOneRequest() async throws {
        let remote = FakeRemote([a], delay: .milliseconds(80))
        let (repository, _, _) = makeRepository(remote)

        async let one = repository.all()
        async let two = repository.all()
        async let three = repository.all()
        let results = try await [one, two, three]

        XCTAssertEqual(results, [[a], [a], [a]])
        XCTAssertEqual(remote.fetchAllCount, 1)
    }

    // MARK: - Other policies

    func testNetworkFirstFallsBackToTheStoredCopyWhenOffline() async throws {
        let remote = FakeRemote([a])
        let (repository, _, _) = makeRepository(remote)
        _ = try await repository.all()

        remote.setFailure(NetworkError.noConnection)
        let result = try await repository.all(policy: .networkFirst)
        XCTAssertEqual(result, [a])
    }

    func testNetworkFirstThrowsWhenNothingIsStored() async {
        let remote = FakeRemote([a])
        remote.setFailure(NetworkError.noConnection)
        let (repository, _, _) = makeRepository(remote)
        do {
            _ = try await repository.all(policy: .networkFirst)
            XCTFail("should throw")
        } catch {
            XCTAssertTrue(error.isOffline)
        }
    }

    func testNetworkOnlyNeverTouchesTheStore() async throws {
        let remote = FakeRemote([a])
        let (repository, store, _) = makeRepository(remote)
        _ = try await repository.all(policy: .networkOnly)
        let stored = try await store.all()
        XCTAssertTrue(stored.isEmpty)
    }

    func testCacheOnlyNeverContactsTheServer() async throws {
        let remote = FakeRemote([a])
        let (repository, _, _) = makeRepository(remote)
        let list = try await repository.all(policy: .cacheOnly)
        XCTAssertEqual(list, [])
        do {
            _ = try await repository.item(id: "a", policy: .cacheOnly)
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .notCached)
        }
        XCTAssertEqual(remote.fetchAllCount, 0)
        XCTAssertEqual(remote.fetchedIDs, [])
    }

    // MARK: - Single items

    func testItemFetchesOnceThenUsesTheStoredCopy() async throws {
        let remote = FakeRemote([a, b])
        let (repository, _, _) = makeRepository(remote)
        let first = try await repository.item(id: "b")
        let second = try await repository.item(id: "b")
        XCTAssertEqual(first, b)
        XCTAssertEqual(second, b)
        XCTAssertEqual(remote.fetchedIDs, ["b"])
    }

    func testStaleItemRefreshesInTheBackground() async throws {
        let remote = FakeRemote([a])
        let (repository, _, clock) = makeRepository(remote)
        _ = try await repository.item(id: "a")

        remote.setTrips([Trip(id: "a", name: "A new")])
        clock.advance(120)
        let result = try await repository.item(id: "a")
        XCTAssertEqual(result.name, "A")
        await eventually { (try? await repository.item(id: "a", policy: .cacheOnly))?.name == "A new" }
        XCTAssertEqual(remote.fetchedIDs.count, 2)
    }

    func testAnItemGoneFromTheServerIsRemovedFromTheStore() async throws {
        let remote = FakeRemote([a])
        let (repository, store, _) = makeRepository(remote)
        _ = try await repository.item(id: "a")

        remote.setTrips([])
        do {
            _ = try await repository.item(id: "a", policy: .networkFirst)
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? NetworkError, .notFound(message: nil))
        }
        let stored = try await store.item(id: "a")
        XCTAssertNil(stored, "not shown again after the server says it's gone")
    }

    // MARK: - Writing

    func testCreateUpdateDeleteGoThroughToTheServerAndTheStore() async throws {
        let remote = FakeRemote([a])
        let (repository, store, _) = makeRepository(remote)
        _ = try await repository.all()

        let created = try await repository.create(Trip(id: "", name: "New"))
        XCTAssertEqual(created.id, "server-New")
        var ids = try await store.all().map(\.id)
        XCTAssertEqual(ids, ["a", "server-New"])

        let updated = try await repository.update(Trip(id: "a", name: "A!"))
        XCTAssertEqual(updated.name, "A! (saved)", "the server's version is what's stored")
        let stored = try await store.item(id: "a")
        XCTAssertEqual(stored?.item.name, "A! (saved)")

        try await repository.delete(id: "a")
        ids = try await store.all().map(\.id)
        XCTAssertEqual(ids, ["server-New"])
    }

    func testAFailedWriteLeavesTheStoreUntouched() async throws {
        let remote = FakeRemote([a])
        let (repository, store, _) = makeRepository(remote)
        _ = try await repository.all()

        remote.setFailure(NetworkError.server(status: 500, message: nil))
        do {
            try await repository.delete(id: "a")
            XCTFail("should throw")
        } catch {}
        let ids = try await store.all().map(\.id)
        XCTAssertEqual(ids, ["a"])
    }

    func testReadOnlyRepositoryRefusesToWrite() async throws {
        struct ReadOnly: RemoteSource {
            func fetch(id _: String) async throws -> Trip { Trip(id: "x", name: "X") }
            func fetchAll() async throws -> [Trip] { [] }
        }
        let repository = Repository<Trip>(remote: ReadOnly(), store: InMemoryStore())
        do {
            _ = try await repository.create(Trip(id: "", name: "N"))
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? RepositoryError, .readOnly)
        }
    }

    // MARK: - Observing and relaunch

    func testUpdatesFollowsRefreshes() async throws {
        let remote = FakeRemote([a])
        let (repository, _, _) = makeRepository(remote)
        var iterator = await repository.updates().makeAsyncIterator()

        var next = await iterator.next()
        XCTAssertEqual(next, [], "starts with what is stored")

        _ = try await repository.all()
        next = await iterator.next()
        XCTAssertEqual(next, [a])

        remote.setTrips([a, b])
        _ = try await repository.refresh()
        next = await iterator.next()
        XCTAssertEqual(next, [a, b])
    }

    func testClearEmptiesTheStoreAndForgetsFreshness() async throws {
        let remote = FakeRemote([a])
        let (repository, store, _) = makeRepository(remote)
        _ = try await repository.all()
        try await repository.clear()

        let stored = try await store.all()
        XCTAssertTrue(stored.isEmpty)
        _ = try await repository.all()
        XCTAssertEqual(remote.fetchAllCount, 2, "fetches again after a clear")
    }

    func testAfterRelaunchTheStoredFetchTimeDecidesFreshness() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()

        let firstRun = FakeRemote([a])
        let (before, _, _) = makeRepository(
            firstRun,
            store: FileStore<Trip>(name: "trips", directory: directory),
            clock: clock
        )
        _ = try await before.all()

        // The app is relaunched: a new repository over the same file, 2 minutes later.
        clock.advance(120)
        let secondRun = FakeRemote([a, b])
        let (after, _, _) = makeRepository(
            secondRun,
            store: FileStore<Trip>(name: "trips", directory: directory),
            clock: clock
        )
        let shown = try await after.all()

        XCTAssertEqual(shown, [a], "shows what was stored straight away")
        await eventually { (try? await after.all(policy: .cacheOnly)) == [a, b] }
        XCTAssertEqual(secondRun.fetchAllCount, 1, "refreshed once, because the stored copy was stale")
    }
}
