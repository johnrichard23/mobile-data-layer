//
//  FileStore.swift
//
//  Keeps items as one JSON file, so they survive relaunch. Meant for cached
//  server data (hundreds to a few thousand items), not for a database. If
//  the file can't be read (the model changed shape, the file is damaged) it
//  is discarded and the store starts empty, since the server still has the
//  data.
//
//  What's on disk is protected in three ways:
//  - a file-protection class, so the system encrypts it while the device is
//    locked (the default, "until first user authentication", still lets a
//    background refresh run after the first unlock; use `.complete` to
//    lock it whenever the screen is locked);
//  - it's excluded from backups (the server is the backup);
//  - optionally, you can encrypt the contents yourself with a key you keep
//    in the Keychain (see `SecretStore.encryptionKey(named:)`). Do this when
//    the cache holds personal data you wouldn't want readable from a device
//    backup, a forensic copy or a jailbroken device.
//

import CryptoKit
import Foundation

public actor FileStore<Item: Codable & Sendable>: Store {
    private let url: URL
    private let protection: FileProtectionType
    private let excludeFromBackup: Bool
    private let encryptionKey: SymmetricKey?
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
    ///   - protection: the file-protection class (iOS and other device
    ///     platforms; ignored on macOS).
    ///   - excludeFromBackup: keep the file out of device backups.
    ///   - encryptionKey: encrypt the contents (AES-GCM). A file written
    ///     with a different key, or without one, is discarded.
    public init(
        name: String,
        directory: URL? = nil,
        protection: FileProtectionType = .completeUntilFirstUserAuthentication,
        excludeFromBackup: Bool = true,
        encryptionKey: SymmetricKey? = nil
    ) {
        let folder = directory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DataLayer", isDirectory: true)
        url = folder.appendingPathComponent("\(name).json")
        self.protection = protection
        self.excludeFromBackup = excludeFromBackup
        self.encryptionKey = encryptionKey
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

    /// Marks a file as encrypted by this store.
    private static var header: Data { Data("DL1".utf8) }

    private func load() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let data = try? Data(contentsOf: url) else { return }
        if let json = open(data), let items = try? decoder.decode([Stored<Item>].self, from: json) {
            list = StoredList(items)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The JSON inside a file, or `nil` if it doesn't match how this store is
    /// configured (wrong key, tampered, encrypted vs plain).
    private func open(_ data: Data) -> Data? {
        let isEncrypted = data.starts(with: Self.header)
        guard let encryptionKey else { return isEncrypted ? nil : data }
        guard isEncrypted,
              let box = try? AES.GCM.SealedBox(combined: data.dropFirst(Self.header.count)),
              let json = try? AES.GCM.open(box, using: encryptionKey)
        else { return nil }
        return json
    }

    private func seal(_ json: Data) throws -> Data {
        guard let encryptionKey else { return json }
        guard let combined = try AES.GCM.seal(json, using: encryptionKey).combined else {
            throw CocoaError(.coderInvalidValue)
        }
        return Self.header + combined
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            switch protection {
            case .complete: options.insert(.completeFileProtection)
            case .completeUnlessOpen: options.insert(.completeFileProtectionUnlessOpen)
            case .none: options.insert(.noFileProtection)
            default: options.insert(.completeFileProtectionUntilFirstUserAuthentication)
            }
        #endif
        try seal(encoder.encode(list.all)).write(to: url, options: options)

        var values = URLResourceValues()
        values.isExcludedFromBackup = excludeFromBackup
        var file = url
        try file.setResourceValues(values)

        let snapshot = list.all
        for continuation in continuations.values { continuation.yield(snapshot) }
    }
}
