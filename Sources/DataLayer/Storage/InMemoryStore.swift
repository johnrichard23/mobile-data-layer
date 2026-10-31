//
//  InMemoryStore.swift
//

import Foundation

/// Keeps items in memory only; they're gone when the app quits.
public actor InMemoryStore<Item: Sendable>: Store {
    private var list = StoredList<Item>()
    private var continuations: [UUID: AsyncStream<[Stored<Item>]>.Continuation] = [:]

    public init() {}

    public func all() -> [Stored<Item>] { list.all }

    public func item(id: String) -> Stored<Item>? { list.item(id: id) }

    public func save(_ items: [Stored<Item>]) {
        list.save(items)
        broadcast()
    }

    public func delete(ids: [String]) {
        list.delete(ids: ids)
        broadcast()
    }

    public func replaceAll(_ items: [Stored<Item>]) {
        list.replaceAll(items)
        broadcast()
    }

    public func updates() -> AsyncStream<[Stored<Item>]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: [Stored<Item>].self,
            bufferingPolicy: .bufferingNewest(1)
        )
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        continuation.yield(list.all)
        return stream
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func broadcast() {
        let snapshot = list.all
        for continuation in continuations.values { continuation.yield(snapshot) }
    }
}
