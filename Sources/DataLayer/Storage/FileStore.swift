//
//  FileStore.swift
//
//  Keeps items as one JSON file, so they survive relaunch. Meant for cached
//  server data (hundreds to a few thousand items), not for a database. If
//  the file can't be read (the model changed shape, the file is damaged) it
//  is discarded and the store starts empty, since the server still has the
//  data.
//

import Foundation

public actor FileStore<Item: Codable & Sendable>: Store {
    private let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var list = StoredList<Item>()
    private var isLoaded = false
    private var continuations: [UUID: AsyncStream<[Stored<Item>]>.Continuation] = [:]

    /// - Parameters:
    ///   - name: the file name (without extension). One per kind of data.
    ///   - directory: where to keep it. The default is the app's Caches
    ///     folder, which iOS may clear when space is low; pass
    ///     `.applicationSupportDirectory` for data that must stay.
    public init(name: String, directory: URL? = nil) {
        let folder = directory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DataLayer", isDirectory: true)
        url = folder.appendingPathComponent("\(name).json")
        encoder = JSONCoding.encoder()
        decoder = JSONCoding.decoder()
    }

    public func all() throws -> [Stored<Item>] {
        load()
        return list.all
    }

    public func item(id: String) throws -> Stored<Item>? {
        load()
        return list.item(id: id)
    }

    public func save(_ items: [Stored<Item>]) throws {
        load()
        list.save(items)
        try persist()
    }

    public func delete(ids: [String]) throws {
        load()
        list.delete(ids: ids)
        try persist()
    }

    public func replaceAll(_ items: [Stored<Item>]) throws {
        load()
        list.replaceAll(items)
        try persist()
    }

    public func updates() -> AsyncStream<[Stored<Item>]> {
        load()
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

    private func load() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let data = try? Data(contentsOf: url) else { return }
        if let items = try? decoder.decode([Stored<Item>].self, from: data) {
            list = StoredList(items)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(list.all).write(to: url, options: .atomic)
        let snapshot = list.all
        for continuation in continuations.values { continuation.yield(snapshot) }
    }
}
