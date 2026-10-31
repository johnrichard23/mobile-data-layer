//
//  CachePolicy.swift
//
//  How a `Repository` chooses between its stored copy and the server.
//

import Foundation

public enum CachePolicy: Sendable, Equatable {
    /// The default for most screens. Show what's stored at once:
    /// - younger than `staleAfter`: use it, don't contact the server;
    /// - older than that but younger than `expireAfter`: use it now and
    ///   refresh in the background;
    /// - older than `expireAfter` (or nothing stored): throw it away and
    ///   fetch, waiting for the server.
    case cacheAndRefresh(staleAfter: TimeInterval, expireAfter: TimeInterval)

    /// Always ask the server first; if that fails and something is stored,
    /// use the stored copy. For screens where fresh data matters but a
    /// stale one beats an error.
    case networkFirst

    /// Always ask the server and don't touch the store.
    case networkOnly

    /// Never contact the server.
    case cacheOnly

    /// Stale after 5 minutes, expired after a day.
    public static let standard = CachePolicy.cacheAndRefresh(staleAfter: 5 * 60, expireAfter: 24 * 60 * 60)
}

/// Why a repository call couldn't be done.
public enum RepositoryError: Error, Equatable, Sendable {
    /// The repository was built with a read-only remote source.
    case readOnly
    /// `cacheOnly` and the item isn't stored.
    case notCached
}
