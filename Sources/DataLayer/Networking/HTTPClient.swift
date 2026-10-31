//
//  HTTPClient.swift
//
//  Sends an `Endpoint` and gives back the reply, or throws a `NetworkError`.
//  `URLSessionHTTPClient` is the real one; `StubHTTPClient` (in this package)
//  is for tests. Depend on `any HTTPClient`, never on the concrete type.
//

import Foundation

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var data: Data

    public init(status: Int, headers: [String: String] = [:], data: Data = Data()) {
        self.status = status
        self.headers = headers
        self.data = data
    }

    /// Decodes the body. An empty body decodes only to `EmptyResponse`.
    public func decode<Value: Decodable>(
        _: Value.Type = Value.self,
        decoder: JSONDecoder = JSONCoding.decoder()
    ) throws -> Value {
        if data.isEmpty, let empty = EmptyResponse() as? Value { return empty }
        do {
            return try decoder.decode(Value.self, from: data)
        } catch let error as DecodingError {
            throw NetworkError.decoding(error.readable)
        } catch {
            throw NetworkError.decoding(error.localizedDescription)
        }
    }
}

/// For calls whose reply body doesn't matter (or is empty, like a 204).
public struct EmptyResponse: Decodable, Sendable {
    public init() {}
    public init(from _: any Decoder) throws {}
}

public protocol HTTPClient: Sendable {
    /// Sends the request. Throws `NetworkError` for anything but a 2xx reply.
    func send(_ endpoint: Endpoint) async throws -> HTTPResponse
}

public extension HTTPClient {
    /// Sends the request and decodes the reply.
    func send<Response: Decodable>(
        _ endpoint: Endpoint,
        as type: Response.Type = Response.self,
        decoder: JSONDecoder = JSONCoding.decoder()
    ) async throws -> Response {
        try await send(endpoint).decode(type, decoder: decoder)
    }
}
