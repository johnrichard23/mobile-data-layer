//
//  StubHTTPClient.swift
//
//  A fake `HTTPClient` for your own tests: you decide the reply to each
//  request, and can look at what was sent.
//
//      let client = StubHTTPClient { endpoint in
//          endpoint.path == "trips" ? .json(#"[{"id":"1","name":"Siargao"}]"#) : .json("{}", status: 404)
//      }
//      let repository = Repository<Trip>(remote: RESTRemoteSource(client: client, …), store: InMemoryStore())
//      XCTAssertEqual(client.requests.count, 1)
//

import Foundation

public final class StubHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [Endpoint] = []
    private let handler: @Sendable (Endpoint) async throws -> HTTPResponse

    /// `handler` returns the reply for each request, or throws a `NetworkError`.
    public init(_ handler: @escaping @Sendable (Endpoint) async throws -> HTTPResponse) {
        self.handler = handler
    }

    /// Every request sent so far, in order.
    public var requests: [Endpoint] {
        lock.withLock { sent }
    }

    public func send(_ endpoint: Endpoint) async throws -> HTTPResponse {
        lock.withLock { sent.append(endpoint) }
        let response = try await handler(endpoint)
        guard (200..<300).contains(response.status) else {
            throw NetworkError.from(status: response.status, message: URLSessionHTTPClient.defaultErrorMessage(response.data))
        }
        return response
    }
}

public extension HTTPResponse {
    /// A reply with a JSON body, for `StubHTTPClient`.
    static func json(_ text: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "application/json"], data: Data(text.utf8))
    }
}
