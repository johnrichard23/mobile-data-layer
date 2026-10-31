//
//  ConflictResolver.swift
//
//  When the same record was changed on the device and on the server, which
//  copy wins? These are the rules a shipping offline-first app uses: the most
//  recent change wins, and a deletion wins over an older edit but loses to a
//  newer one.
//
//  Pure logic, no storage or network, so it can be tested and reused by any
//  sync design.
//

import Foundation

/// A record with the dates sync needs.
public protocol Syncable {
    /// When it was last changed, on whichever side it lives.
    var modifiedDate: Date? { get }
    /// When it was (softly) deleted, or `nil` if it still exists.
    var deletionDate: Date? { get }
}

public enum ConflictResolution: Sendable, Equatable {
    /// Keep the device's copy (and send it to the server).
    case keepLocal
    /// Replace the device's copy with the server's.
    case takeRemote
    /// They agree. Do nothing.
    case noChange
}

public enum ConflictResolver {
    public static func resolve(local: some Syncable, remote: some Syncable) -> ConflictResolution {
        if local.deletionDate != nil || remote.deletionDate != nil {
            return resolveDeletion(local: local, remote: remote)
        }
        return resolveModification(local: local.modifiedDate, remote: remote.modifiedDate)
    }

    private static func resolveDeletion(local: some Syncable, remote: some Syncable) -> ConflictResolution {
        // Only the server deleted it.
        guard let localDeletion = local.deletionDate else { return .takeRemote }
        // Only the device deleted it.
        guard let remoteDeletion = remote.deletionDate else { return .keepLocal }
        // Both deleted it: needs the dates to compare.
        guard let localModified = local.modifiedDate, let remoteModified = remote.modifiedDate else {
            return .noChange
        }
        // The device deleted it after the server's last change: the deletion stands.
        if localDeletion >= remoteModified { return .keepLocal }
        // The server's deletion is newer than the device's last change.
        if remoteDeletion > localModified { return .takeRemote }
        return .keepLocal
    }

    private static func resolveModification(local: Date?, remote: Date?) -> ConflictResolution {
        guard let local else { return .takeRemote }
        guard let remote else { return .keepLocal }
        if remote == local { return .noChange }
        return remote > local ? .takeRemote : .keepLocal
    }
}
