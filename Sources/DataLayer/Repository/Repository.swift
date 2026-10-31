//
//  Repository.swift
//
//  The one object a screen's view model talks to for a kind of data: "give
//  me the trips". It decides whether to answer from the store or the server
//  (see `CachePolicy`), keeps the store up to date, and sends changes to the
//  server.
//
//      let trips = Repository<Trip>(
//          remote: RESTRemoteSource(client: client, path: "trips", mapper: TripMapper()),
//          store: FileStore(name: "trips")
//      )
//      let list = try await trips.all()              // cache first, refresh when stale
//      for await list in await trips.updates() { … } // follow changes
//
//  Calls for the same data made at the same time share one request.
//

import Foundation

public actor Repository<Model: Identifiable & Sendable> where Model.ID == String {
    private let remote: any RemoteSource<Model>
    private let writer: (any WritableRemoteSource<Model>)?
    private let store: any Store<Model>
    private let defaultPolicy: CachePolicy
    private let now: @Sendable () -> Date

    /// When the whole list was last fetched, in this run of the app.
    private var lastFullFetch: Date?
    private var listRefresh: Task<[Model], any Error>?
    private var itemRefreshes: [String: Task<Model, any Error>] = [:]

    /// A repository that can also create, update and delete.
    public init(
        remote: any WritableRemoteSource<Model>,
        store: any Store<Model>,
        policy: CachePolicy = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.remote = remote
        writer = remote
        self.store = store
        defaultPolicy = policy
        self.now = now
    }

    /// A read-only repository.
    public init(
        remote: any RemoteSource<Model>,
        store: any Store<Model>,
        policy: CachePolicy = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.remote = remote
        writer = nil
        self.store = store
        defaultPolicy = policy
        self.now = now
    }

    // MARK: - Reading

    /// Every item. `policy` overrides the repository's default for this call.
    public func all(policy: CachePolicy? = nil) async throws -> [Model] {
        switch policy ?? defaultPolicy {
        case .networkOnly:
            return try await remote.fetchAll()

        case .cacheOnly:
            return try await store.all().map(\.item)

        case .networkFirst:
            do {
                return try await refreshAll()
            } catch {
                guard !error.isCancellation else { throw error }
                let cached = try await store.all()
                guard !cached.isEmpty || lastFullFetch != nil else { throw error }
                return cached.map(\.item)
            }

        case let .cacheAndRefresh(staleAfter, expireAfter):
            let cached = try await store.all()
            guard let age = listAge(of: cached) else { return try await refreshAll() }
            if age >= expireAfter {
                try await store.deleteAll()
                lastFullFetch = nil
                return try await refreshAll()
            }
            if age >= staleAfter { refreshAllInBackground() }
            return cached.map(\.item)
        }
    }

    /// One item by id.
    public func item(id: String, policy: CachePolicy? = nil) async throws -> Model {
        switch policy ?? defaultPolicy {
        case .networkOnly:
            return try await remote.fetch(id: id)

        case .cacheOnly:
            guard let cached = try await store.item(id: id) else { throw RepositoryError.notCached }
            return cached.item

        case .networkFirst:
            do {
                return try await refreshItem(id: id)
            } catch {
                guard !error.isCancellation, !error.isNotFound, let cached = try await store.item(id: id) else {
                    throw error
                }
                return cached.item
            }

        case let .cacheAndRefresh(staleAfter, expireAfter):
            guard let cached = try await store.item(id: id) else { return try await refreshItem(id: id) }
            let age = now().timeIntervalSince(cached.fetchedAt)
            if age >= expireAfter {
                try await store.delete(ids: [id])
                return try await refreshItem(id: id)
            }
            if age >= staleAfter { refreshItemInBackground(id: id) }
            return cached.item
        }
    }

    /// Fetches everything from the server now and updates the store.
    @discardableResult
    public func refresh() async throws -> [Model] {
        try await refreshAll()
    }

    /// The stored items now, then again after every change to the store
    /// (including changes made by a refresh).
    public func updates() async -> AsyncStream<[Model]> {
        let source = await store.updates()
        return AsyncStream { continuation in
            let task = Task {
                for await stored in source { continuation.yield(stored.map(\.item)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Empties the store, e.g. on sign-out.
    public func clear() async throws {
        listRefresh?.cancel()
        listRefresh = nil
        for task in itemRefreshes.values { task.cancel() }
        itemRefreshes = [:]
        lastFullFetch = nil
        try await store.deleteAll()
    }

    // MARK: - Writing

    /// Sends a new item to the server and stores what comes back.
    public func create(_ model: Model) async throws -> Model {
        guard let writer else { throw RepositoryError.readOnly }
        let created = try await writer.create(model)
        try await store.save([stored(created)])
        return created
    }

    /// Sends changes to the server and stores what comes back.
    public func update(_ model: Model) async throws -> Model {
        guard let writer else { throw RepositoryError.readOnly }
        let updated = try await writer.update(model)
        try await store.save([stored(updated)])
        return updated
    }

    /// Deletes on the server, then from the store.
    public func delete(id: String) async throws {
        guard let writer else { throw RepositoryError.readOnly }
        try await writer.delete(id: id)
        try await store.delete(ids: [id])
    }

    // MARK: - Refreshing

    private func refreshAll() async throws -> [Model] {
        if let running = listRefresh { return try await running.value }
        let task = Task { try await self.fetchAndStoreAll() }
        listRefresh = task
        defer { listRefresh = nil }
        return try await task.value
    }

    private func fetchAndStoreAll() async throws -> [Model] {
        let models = try await remote.fetchAll()
        let fetchedAt = now()
        try await store.replaceAll(models.map { Stored(id: $0.id, item: $0, fetchedAt: fetchedAt) })
        lastFullFetch = fetchedAt
        return models
    }

    private func refreshAllInBackground() {
        guard listRefresh == nil else { return }
        Task { _ = try? await self.refreshAll() }
    }

    private func refreshItem(id: String) async throws -> Model {
        if let running = itemRefreshes[id] { return try await running.value }
        let task = Task { try await self.fetchAndStoreItem(id: id) }
        itemRefreshes[id] = task
        defer { itemRefreshes[id] = nil }
        return try await task.value
    }

    private func fetchAndStoreItem(id: String) async throws -> Model {
        do {
            let model = try await remote.fetch(id: id)
            try await store.save([stored(model)])
            return model
        } catch {
            // Gone from the server: don't keep showing it.
            if error.isNotFound { try? await store.delete(ids: [id]) }
            throw error
        }
    }

    private func refreshItemInBackground(id: String) {
        guard itemRefreshes[id] == nil else { return }
        Task { _ = try? await self.refreshItem(id: id) }
    }

    // MARK: - Helpers

    private func stored(_ model: Model) -> Stored<Model> {
        Stored(id: model.id, item: model, fetchedAt: now())
    }

    /// How old the stored list is, or `nil` when there is nothing to judge
    /// (nothing stored and no fetch yet in this run).
    private func listAge(of cached: [Stored<Model>]) -> TimeInterval? {
        if let lastFullFetch { return now().timeIntervalSince(lastFullFetch) }
        guard let oldest = cached.map(\.fetchedAt).min() else { return nil }
        return now().timeIntervalSince(oldest)
    }
}

private extension Error {
    var isCancellation: Bool {
        self is CancellationError || (self as? NetworkError) == .cancelled
    }

    var isNotFound: Bool {
        if case .notFound = self as? NetworkError { true } else { false }
    }
}
