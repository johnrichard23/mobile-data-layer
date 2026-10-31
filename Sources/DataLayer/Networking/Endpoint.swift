//
//  Endpoint.swift
//
//  A request, described as data: method, path, query, headers, body. Build
//  one in an API function, hand it to an `HTTPClient`.
//
//      Endpoint.get("trips", query: ["page": 2, "search": nil])
//      try Endpoint.post("trips", body: NewTrip(name: "Siargao"))
//

import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"

    /// Safe to send again if the first attempt's outcome is unknown.
    public var isIdempotent: Bool {
        switch self {
        case .get, .put, .delete: true
        case .post, .patch: false
        }
    }
}

public struct Endpoint: Sendable {
    /// Relative to the client's base URL, or a full URL.
    public var path: String
    public var method: HTTPMethod
    public var query: [URLQueryItem]
    public var headers: [String: String]
    public var body: Data?
    /// Overrides the client's timeout for this request.
    public var timeout: TimeInterval?

    public init(
        path: String,
        method: HTTPMethod = .get,
        query: [URLQueryItem] = [],
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval? = nil
    ) {
        self.path = path
        self.method = method
        self.query = query
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

// MARK: - Convenience builders

public extension Endpoint {
    /// A GET request. Query values that are `nil` are left out, and the rest
    /// are sorted by name so the URL is the same every time.
    static func get(
        _ path: String,
        query: [String: (any CustomStringConvertible)?] = [:],
        headers: [String: String] = [:],
        timeout: TimeInterval? = nil
    ) -> Endpoint {
        Endpoint(path: path, method: .get, query: queryItems(query), headers: headers, timeout: timeout)
    }

    /// A DELETE request.
    static func delete(
        _ path: String,
        query: [String: (any CustomStringConvertible)?] = [:],
        headers: [String: String] = [:]
    ) -> Endpoint {
        Endpoint(path: path, method: .delete, query: queryItems(query), headers: headers)
    }

    /// A POST request with a JSON body.
    static func post(
        _ path: String,
        body: some Encodable,
        encoder: JSONEncoder = JSONCoding.encoder(),
        headers: [String: String] = [:]
    ) throws -> Endpoint {
        try json(path, .post, body, encoder, headers)
    }

    /// A PUT request with a JSON body.
    static func put(
        _ path: String,
        body: some Encodable,
        encoder: JSONEncoder = JSONCoding.encoder(),
        headers: [String: String] = [:]
    ) throws -> Endpoint {
        try json(path, .put, body, encoder, headers)
    }

    /// A PATCH request with a JSON body.
    static func patch(
        _ path: String,
        body: some Encodable,
        encoder: JSONEncoder = JSONCoding.encoder(),
        headers: [String: String] = [:]
    ) throws -> Endpoint {
        try json(path, .patch, body, encoder, headers)
    }

    private static func json(
        _ path: String,
        _ method: HTTPMethod,
        _ body: some Encodable,
        _ encoder: JSONEncoder,
        _ headers: [String: String]
    ) throws -> Endpoint {
        var headers = headers
        headers["Content-Type"] = headers["Content-Type"] ?? "application/json"
        return try Endpoint(path: path, method: method, headers: headers, body: encoder.encode(body))
    }

    /// Query items from a dictionary: `nil` values dropped, sorted by name.
    static func queryItems(_ values: [String: (any CustomStringConvertible)?]) -> [URLQueryItem] {
        values
            .sorted { $0.key < $1.key }
            .compactMap { key, value in value.map { URLQueryItem(name: key, value: $0.description) } }
    }
}
