//
//  SecretStore.swift
//
//  Where small secrets live: access tokens, refresh tokens, the key that
//  encrypts a `FileStore`. On iOS the answer is the Keychain, never
//  UserDefaults and never a file: the Keychain is encrypted by the system,
//  isn't included in plain backups, and can be tied to this device.
//
//      let secrets = KeychainSecretStore(service: "com.example.app")
//      try await secrets.setSecret(Data(token.utf8), for: "refresh-token")
//
//      // An encrypted cache:
//      let key = try await secrets.encryptionKey(named: "trips-cache")
//      let store = FileStore<Trip>(name: "trips", encryptionKey: key)
//
//  If your sign-in SDK already keeps tokens in the Keychain, leave them
//  there; use this for what your own code stores.
//

import CryptoKit
import Foundation
import Security

public protocol SecretStore: Sendable {
    func secret(for key: String) async throws -> Data?
    /// Stores the secret, or deletes it when `secret` is `nil`.
    func setSecret(_ secret: Data?, for key: String) async throws
}

public enum SecretStoreError: Error, Equatable, Sendable {
    /// A Keychain call failed. The number is the `OSStatus`.
    case keychain(Int32)
    /// A stored key wasn't the expected size.
    case corrupted
}

public extension SecretStore {
    /// A random 256-bit key stored under `name`. Created the first time and
    /// returned unchanged after that.
    func encryptionKey(named name: String = "data-layer.file-store-key") async throws -> SymmetricKey {
        if let existing = try await secret(for: name) {
            guard existing.count == 32 else { throw SecretStoreError.corrupted }
            return SymmetricKey(data: existing)
        }
        let key = SymmetricKey(size: .bits256)
        try await setSecret(key.withUnsafeBytes { Data($0) }, for: name)
        return key
    }
}

/// Keeps secrets in memory only. For tests, and for secrets that should not
/// outlive the app run.
public actor InMemorySecretStore: SecretStore {
    private var values: [String: Data] = [:]

    public init() {}

    public func secret(for key: String) -> Data? { values[key] }

    public func setSecret(_ secret: Data?, for key: String) {
        values[key] = secret
    }
}

/// Keeps secrets in the Keychain, as generic passwords under one service name.
public struct KeychainSecretStore: SecretStore {
    /// When the secret can be read.
    public enum Accessibility: Sendable {
        /// After the first unlock since boot, on this device only. The right
        /// choice for tokens that background refreshes need.
        case afterFirstUnlockThisDeviceOnly
        /// Only while the device is unlocked, on this device only. For
        /// secrets used only while the user is in the app.
        case whenUnlockedThisDeviceOnly

        var attribute: CFString {
            switch self {
            case .afterFirstUnlockThisDeviceOnly: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            case .whenUnlockedThisDeviceOnly: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            }
        }
    }

    private let service: String
    private let accessGroup: String?
    private let accessibility: Accessibility

    /// - Parameters:
    ///   - service: groups this app's items, e.g. the bundle identifier.
    ///   - accessGroup: share items between apps of one team; `nil` keeps
    ///     them private to this app.
    public init(
        service: String,
        accessGroup: String? = nil,
        accessibility: Accessibility = .afterFirstUnlockThisDeviceOnly
    ) {
        self.service = service
        self.accessGroup = accessGroup
        self.accessibility = accessibility
    }

    public func secret(for key: String) async throws -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw SecretStoreError.keychain(status)
        }
    }

    public func setSecret(_ secret: Data?, for key: String) async throws {
        let query = baseQuery(for: key)
        guard let secret else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SecretStoreError.keychain(status)
            }
            return
        }

        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: secret] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SecretStoreError.keychain(update) }

        var attributes = query
        attributes[kSecValueData as String] = secret
        attributes[kSecAttrAccessible as String] = accessibility.attribute
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
    }

    private func baseQuery(for key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}
