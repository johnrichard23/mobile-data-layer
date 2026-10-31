//
//  SecurityPolicy.swift
//
//  The rules that keep credentials and traffic where they belong. The
//  defaults are the safe ones; loosen them deliberately.
//
//  - Everything goes over HTTPS. Plain HTTP is refused, except for hosts you
//    list in `insecureHosts` (your own machine during development).
//  - Credentials (default headers such as an API key, and whatever the
//    interceptors add, such as a token) are only sent to the API's own host
//    and the hosts in `trustedHosts`. A request to any other host, for
//    example a full URL for a file on a CDN, goes out without them.
//  - A redirect to another host keeps only harmless headers, so a token or
//    key can't be handed to a server it wasn't meant for. A redirect from
//    HTTPS to HTTP isn't followed.
//

import Foundation

public struct SecurityPolicy: Sendable, Equatable {
    /// Hosts that may be used over plain HTTP. Empty by default.
    public var insecureHosts: Set<String>
    /// Hosts, besides the base URL's, that may receive credentials.
    public var trustedHosts: Set<String>

    public init(insecureHosts: Set<String> = [], trustedHosts: Set<String> = []) {
        self.insecureHosts = Set(insecureHosts.map { $0.lowercased() })
        self.trustedHosts = Set(trustedHosts.map { $0.lowercased() })
    }

    /// HTTPS only; credentials go to the API's own host only.
    public static let standard = SecurityPolicy()

    /// Like `standard`, but allows plain HTTP to this machine, for a local
    /// development server. Don't ship it enabled.
    public static let allowingLocalhost = SecurityPolicy(insecureHosts: ["localhost", "127.0.0.1", "::1"])
}

/// Applied to each request's redirects, so credentials can't be forwarded to
/// a host that wasn't meant to have them.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// Headers that carry no secret and may follow a redirect to any host.
    static let harmlessHeaders: Set<String> = [
        "accept", "accept-encoding", "accept-language", "content-type", "content-length",
        "user-agent", "range", "if-none-match", "if-modified-since",
    ]

    private let trustedHosts: Set<String>

    init(trustedHosts: Set<String>) {
        self.trustedHosts = trustedHosts
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // Never follow a redirect from HTTPS down to HTTP.
        if task.originalRequest?.url?.scheme?.lowercased() == "https",
           request.url?.scheme?.lowercased() != "https"
        {
            completionHandler(nil)
            return
        }
        // Same host, or one the app trusts: nothing changes.
        if let host = request.url?.host?.lowercased(), trustedHosts.contains(host) {
            completionHandler(request)
            return
        }
        // Another host: keep only headers that carry no secret.
        var safe = request
        for name in (request.allHTTPHeaderFields ?? [:]).keys
            where !Self.harmlessHeaders.contains(name.lowercased())
        {
            safe.setValue(nil, forHTTPHeaderField: name)
        }
        completionHandler(safe)
    }
}

/// A URL as it is safe to write in a log: no user name or password, no
/// fragment, and query *names* but never values (values are where tokens,
/// emails and search terms live).
enum LogRedaction {
    static func describe(_ url: URL?) -> String {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "?" }
        components.user = nil
        components.password = nil
        components.fragment = nil
        let names = (components.queryItems ?? []).map(\.name)
        components.query = nil
        var text = components.string ?? "?"
        if !names.isEmpty { text += "?" + names.joined(separator: "&") + "=…" }
        return text
    }
}
