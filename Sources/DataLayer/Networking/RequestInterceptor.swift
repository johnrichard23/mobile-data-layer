//
//  RequestInterceptor.swift
//
//  Changes every request before it is sent (add the auth header, a locale
//  header, an app version) and reacts when the server says "unauthorized".
//  Interceptors run in order.
//
//      BearerTokenInterceptor(token: { await session.accessToken() },
//                             refresh: { await session.refreshTokens() })
//

import Foundation

public protocol RequestInterceptor: Sendable {
    /// Returns the request to send.
    func adapt(_ request: URLRequest) async throws -> URLRequest

    /// Called after a 401. Return `true` if credentials were renewed, and the
    /// client will send the request once more.
    func refreshAfterUnauthorized() async -> Bool
}

public extension RequestInterceptor {
    func adapt(_ request: URLRequest) async throws -> URLRequest { request }
    func refreshAfterUnauthorized() async -> Bool { false }
}

/// Adds fixed headers to every request.
public struct HeaderInterceptor: RequestInterceptor {
    private let headers: [String: String]

    public init(_ headers: [String: String]) {
        self.headers = headers
    }

    public func adapt(_ request: URLRequest) async throws -> URLRequest {
        var request = request
        for (name, value) in headers where request.value(forHTTPHeaderField: name) == nil {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }
}

/// Adds `Authorization: Bearer <token>`, and renews the token once after a 401.
public struct BearerTokenInterceptor: RequestInterceptor {
    private let token: @Sendable () async throws -> String?
    private let refresh: (@Sendable () async -> Bool)?

    /// - Parameters:
    ///   - token: the current access token, or `nil` when signed out (no
    ///     header is added).
    ///   - refresh: renews the token; return `true` on success.
    public init(
        token: @escaping @Sendable () async throws -> String?,
        refresh: (@Sendable () async -> Bool)? = nil
    ) {
        self.token = token
        self.refresh = refresh
    }

    public func adapt(_ request: URLRequest) async throws -> URLRequest {
        guard let token = try await token(), !token.isEmpty else { return request }
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    public func refreshAfterUnauthorized() async -> Bool {
        await refresh?() ?? false
    }
}
