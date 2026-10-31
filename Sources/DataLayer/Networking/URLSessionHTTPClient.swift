//
//  URLSessionHTTPClient.swift
//
//  The real client, on `URLSession` with async/await.
//
//      let client = URLSessionHTTPClient(
//          baseURL: URL(string: "https://api.example.com/v1")!,
//          defaultHeaders: ["Accept": "application/json"],
//          interceptors: [BearerTokenInterceptor(token: { await auth.token() },
//                                                refresh: { await auth.refresh() })],
//          retry: .exponential()
//      )
//
//  Request and response bodies and headers are never logged: they hold
//  tokens and personal data. The optional `log` receives one line per
//  request ("GET https://host/path?page=… → 200 (143 ms)"): query values are
//  never written, only their names.
//
//  See `SecurityPolicy` for what the client refuses and where it sends
//  credentials. `clearSession()` signs the client out of URLSession.
//

import Foundation

public final class URLSessionHTTPClient: HTTPClient {
    private let baseURL: URL
    private let session: URLSession
    private let defaultHeaders: [String: String]
    private let interceptors: [any RequestInterceptor]
    private let retryPolicy: RetryPolicy
    private let security: SecurityPolicy
    private let timeout: TimeInterval
    private let cachePolicy: URLRequest.CachePolicy
    private let errorMessage: @Sendable (Data) -> String?
    private let log: (@Sendable (String) -> Void)?
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    /// - Parameters:
    ///   - baseURL: where relative endpoint paths start.
    ///   - session: use a configured session (certificate pinning, an
    ///     ephemeral one for tests).
    ///   - security: HTTPS-only and credential scoping; see `SecurityPolicy`.
    ///   - cachePolicy: the HTTP cache. A repository does its own caching, so
    ///     apps that use one usually pass `.reloadIgnoringLocalCacheData`.
    ///   - errorMessage: pulls a message out of an error reply's body. The
    ///     default reads `message`, `error` or `detail`.
    ///   - sleep: how retries wait. Tests pass one that returns at once.
    public init(
        baseURL: URL,
        session: URLSession = .shared,
        defaultHeaders: [String: String] = [:],
        interceptors: [any RequestInterceptor] = [],
        retry: RetryPolicy = .none,
        security: SecurityPolicy = .standard,
        timeout: TimeInterval = 30,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        errorMessage: @escaping @Sendable (Data) -> String? = URLSessionHTTPClient.defaultErrorMessage,
        log: (@Sendable (String) -> Void)? = nil,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.baseURL = baseURL
        self.session = session
        self.defaultHeaders = defaultHeaders
        self.interceptors = interceptors
        retryPolicy = retry
        self.security = security
        self.timeout = timeout
        self.cachePolicy = cachePolicy
        self.errorMessage = errorMessage
        self.log = log
        self.sleep = sleep
    }

    public func send(_ endpoint: Endpoint) async throws -> HTTPResponse {
        var attempt = 1
        var refreshedCredentials = false
        while true {
            do {
                return try await perform(endpoint)
            } catch let error as NetworkError {
                if case .unauthorized = error, !refreshedCredentials, await refreshCredentials() {
                    refreshedCredentials = true
                    continue
                }
                guard retryPolicy.shouldRetry(error, method: endpoint.method, attempt: attempt) else {
                    throw error
                }
                do {
                    try await sleep(retryPolicy.delay(afterAttempt: attempt))
                } catch {
                    throw NetworkError.cancelled
                }
                attempt += 1
            }
        }
    }

    // MARK: - One attempt

    private func perform(_ endpoint: Endpoint) async throws -> HTTPResponse {
        var request = try makeRequest(endpoint)
        if isTrusted(request.url) {
            for interceptor in interceptors {
                request = try await interceptor.adapt(request)
            }
        }

        let started = Date()
        let data: Data
        let response: URLResponse
        let redirectGuard = RedirectGuard(trustedHosts: trustedHosts)
        do {
            (data, response) = try await session.data(for: request, delegate: redirectGuard)
        } catch let error as URLError {
            log?("\(endpoint.method.rawValue) \(LogRedaction.describe(request.url)) → \(error.code.rawValue)")
            throw NetworkError.from(error)
        } catch is CancellationError {
            throw NetworkError.cancelled
        } catch {
            throw NetworkError.unknown(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw NetworkError.invalidResponse }
        let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        log?("\(endpoint.method.rawValue) \(LogRedaction.describe(request.url)) → \(http.statusCode) (\(milliseconds) ms)")

        guard (200..<300).contains(http.statusCode) else {
            throw NetworkError.from(status: http.statusCode, message: errorMessage(data))
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, data: data)
    }

    private func refreshCredentials() async -> Bool {
        for interceptor in interceptors where await interceptor.refreshAfterUnauthorized() {
            return true
        }
        return false
    }

    func makeRequest(_ endpoint: Endpoint) throws -> URLRequest {
        let url: URL
        if endpoint.path.contains("://") {
            guard let absolute = URL(string: endpoint.path) else { throw NetworkError.invalidURL }
            url = absolute
        } else {
            guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
                throw NetworkError.invalidURL
            }
            let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
            let path = endpoint.path.hasPrefix("/") ? String(endpoint.path.dropFirst()) : endpoint.path
            components.path = path.isEmpty ? basePath : basePath + "/" + path
            guard let built = components.url else { throw NetworkError.invalidURL }
            url = built
        }

        guard var withQuery = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw NetworkError.invalidURL
        }
        if !endpoint.query.isEmpty {
            let existing = withQuery.queryItems ?? []
            withQuery.queryItems = existing + endpoint.query
        }
        guard let finalURL = withQuery.url else { throw NetworkError.invalidURL }

        guard isAllowedScheme(finalURL) else { throw NetworkError.insecureConnection }

        var request = URLRequest(url: finalURL, cachePolicy: cachePolicy, timeoutInterval: endpoint.timeout ?? timeout)
        request.httpMethod = endpoint.method.rawValue
        if isTrusted(finalURL) {
            for (name, value) in defaultHeaders { request.setValue(value, forHTTPHeaderField: name) }
        }
        for (name, value) in endpoint.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = endpoint.body
        return request
    }

    /// HTTPS, or HTTP to a host the policy allows.
    private func isAllowedScheme(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": true
        case "http": url.host.map { security.insecureHosts.contains($0.lowercased()) } ?? false
        default: false
        }
    }

    private var trustedHosts: Set<String> {
        var hosts = security.trustedHosts
        if let host = baseURL.host?.lowercased() { hosts.insert(host) }
        return hosts
    }

    /// The API's own host, or one the policy trusts: the only places
    /// credentials go.
    private func isTrusted(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return trustedHosts.contains(host)
    }

    /// Signs out at the URLSession level: cookies, cached replies and
    /// credentials held by the session are removed. Call it on sign-out,
    /// together with clearing repositories and your own tokens.
    public func clearSession() async {
        await session.reset()
    }

    /// Reads `message`, `error` (text or `{message}`), `error_description` or
    /// `detail` from a JSON error body.
    public static let defaultErrorMessage: @Sendable (Data) -> String? = { data in
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        for key in ["message", "error_description", "detail", "error"] {
            if let text = json[key]?.stringValue, !text.isEmpty { return text }
            if let text = json[key]?["message"]?.stringValue, !text.isEmpty { return text }
        }
        return nil
    }
}
