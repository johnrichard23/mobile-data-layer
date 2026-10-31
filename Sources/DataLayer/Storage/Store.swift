//
//  Store.swift
//
//  Where fetched data is kept between screens and launches. The repository
//  talks only to this protocol, so a project picks the storage:
//
//  - `InMemoryStore`: gone when the app quits. Fine for session caches.
//  - `FileStore`: JSON on disk, survives relaunch. No dependencies.
//  - Your own: a SwiftData, Realm or Core Data store. Write the "entity"
//    type inside that adapter and map model <-> entity there, so the rest of
//    the app never sees it.
//

import Foundation

/// A model plus when it was last fetched from the server.
public struct Stored<Item: Sendable>: Sendable {
    public var id: String
    public var item: Item
    /// When this copy came from the server. Cache freshness is judged on it.
    public var fetchedAt: Date

    public init(id: String, item: Item, fetchedAt: Date) {
        self.id = id
        self.item = item
        self.fetchedAt = fetchedAt
    }
}

extension Stored: Codable where Item: Codable {}
extension Stored: Equatable where Item: Equatable {}

public protocol Store<Item>: Sendable {
    associatedtype Item: Sendable

    /// Every item, in the order they were last saved with `replaceAll`.
    func all() async throws -> [Stored<Item>]
    func item(id: String) async throws -> Stored<Item>?
    /// Adds or replaces items by id.
    func save(_ items: [Stored<Item>]) async throws
    func delete(ids: [String]) async throws
    /// Replaces the whole contents, in the order given.
    func replaceAll(_ items: [Stored<Item>]) async throws
    /// The current contents now, then again after every change.
    func updates() async -> AsyncStream<[Stored<Item>]>
}

public extension Store {
    func deleteAll() async throws {
        try await replaceAll([])
    }
}

/// An ordered list with id lookup. The shared logic of the built-in stores.
struct StoredList<Item: Sendable>: Sendable {
    private var order: [String] = []
    private var byID: [String: Stored<Item>] = [:]

    init(_ items: [Stored<Item>] = []) {
        replaceAll(items)
    }

    var all: [Stored<Item>] { order.compactMap { byID[$0] } }

    func item(id: String) -> Stored<Item>? { byID[id] }

    mutating func save(_ items: [Stored<Item>]) {
        for item in items {
            if byID.updateValue(item, forKey: item.id) == nil { order.append(item.id) }
        }
    }

    mutating func delete(ids: [String]) {
        let removed = Set(ids)
        guard !removed.isDisjoint(with: byID.keys) else { return }
        for id in removed { byID[id] = nil }
        order.removeAll { removed.contains($0) }
    }

    mutating func replaceAll(_ items: [Stored<Item>]) {
        order = []
        byID = [:]
        save(items)
    }
}
