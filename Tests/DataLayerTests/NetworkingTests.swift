@testable import DataLayer
import Foundation
import XCTest

/// Replies to URLSession requests from a closure, so the real client runs
/// without a network.
struct StubReply: Sendable {
    var status: Int
    var body: String = ""
    var headers: [String: String] = [:]
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> StubReply

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var seen: [URLRequest] = []

    static func installReplies(_ handler: @escaping Handler) {
        lock.withLock {
            self.handler = handler
            seen = []
        }
    }

    /// Shorthand for handlers that only return a status and a body.
    static func install(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, String)) {
        installReplies { request in
            let (status, body) = try handler(request)
            return StubReply(status: status, body: body)
        }
    }

    static var requests: [URLRequest] { lock.withLock { seen } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let handler = Self.lock.withLock { () -> Handler? in
            Self.seen.append(request)
            return Self.handler
        }
        do {
            guard let handler else { throw URLError(.unknown) }
            let reply = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: reply.status,
                httpVersion: nil,
                headerFields: reply.headers
            )!
            if (300..<400).contains(reply.status), let location = reply.headers["Location"].flatMap(URL.init(string:)) {
                var redirected = URLRequest(url: location)
                redirected.httpMethod = request.httpMethod
                // What the real URLSession carries to another host: every header
                // except Authorization (measured against a real server pair; it
                // forwards X-Api-Key, Cookie and custom headers).
                var headers = request.allHTTPHeaderFields ?? [:]
                if redirected.url?.host != request.url?.host { headers["Authorization"] = nil }
                redirected.allHTTPHeaderFields = headers
                client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

final class NetworkingTests: XCTestCase {
    private let base = URL(string: "https://api.example.com/v1")!

    private func makeClient(
        interceptors: [any RequestInterceptor] = [],
        retry: RetryPolicy = .none,
        delays: DelayRecorder = DelayRecorder()
    ) -> URLSessionHTTPClient {
        URLSessionHTTPClient(
            baseURL: base,
            session: StubURLProtocol.session(),
            defaultHeaders: ["Accept": "application/json"],
            interceptors: interceptors,
            retry: retry,
            sleep: { await delays.record($0) }
        )
    }

    // MARK: - Endpoint and URL building

    func testQueryDropsNilsAndSortsByName() {
        let endpoint = Endpoint.get("trips", query: ["page": 2, "search": nil, "active": true, "q": "a b"])
        XCTAssertEqual(endpoint.query.map(\.name), ["active", "page", "q"])
        XCTAssertEqual(endpoint.query.map(\.value), ["true", "2", "a b"])
    }

    func testURLJoinsBaseAndPathWithOrWithoutSlashes() throws {
        let client = makeClient()
        XCTAssertEqual(try client.makeRequest(.get("trips")).url?.absoluteString, "https://api.example.com/v1/trips")
        XCTAssertEqual(try client.makeRequest(.get("/trips")).url?.absoluteString, "https://api.example.com/v1/trips")
        XCTAssertEqual(
            try client.makeRequest(.get("trips", query: ["page": 2])).url?.absoluteString,
            "https://api.example.com/v1/trips?page=2"
        )
        XCTAssertEqual(
            try client.makeRequest(.get("https://other.example.com/x")).url?.absoluteString,
            "https://other.example.com/x"
        )
    }

    func testPostBodyIsJSONWithContentType() throws {
        struct Body: Encodable { var name: String }
        let endpoint = try Endpoint.post("trips", body: Body(name: "Siargao"))
        XCTAssertEqual(endpoint.headers["Content-Type"], "application/json")
        XCTAssertEqual(String(decoding: endpoint.body ?? Data(), as: UTF8.self), #"{"name":"Siargao"}"#)
        XCTAssertEqual(endpoint.method, .post)
    }

    // MARK: - Sending

    struct Trip: Codable, Equatable { var id: String; var name: String }

    func testSendDecodesTheReplyAndSendsDefaultHeaders() async throws {
        StubURLProtocol.install { _ in (200, #"[{"id":"1","name":"Siargao"}]"#) }
        let trips: [Trip] = try await makeClient().send(.get("trips"))
        XCTAssertEqual(trips, [Trip(id: "1", name: "Siargao")])
        XCTAssertEqual(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testEmptyBodyDecodesAsEmptyResponse() async throws {
        StubURLProtocol.install { _ in (204, "") }
        let reply: EmptyResponse = try await makeClient().send(.delete("trips/1"))
        _ = reply
    }

    func testStatusCodesMapToTypedErrorsWithServerMessages() async {
        let cases: [(Int, String, NetworkError)] = [
            (401, #"{"message":"Token expired"}"#, .unauthorized(message: "Token expired")),
            (403, #"{"error":"Nope"}"#, .forbidden(message: "Nope")),
            (404, "{}", .notFound(message: nil)),
            (422, #"{"error":{"message":"Name is required"}}"#, .client(status: 422, message: "Name is required")),
            (500, "oops", .server(status: 500, message: nil)),
        ]
        for (status, body, expected) in cases {
            StubURLProtocol.install { _ in (status, body) }
            do {
                _ = try await makeClient().send(.get("trips"))
                XCTFail("\(status) should throw")
            } catch {
                XCTAssertEqual(error as? NetworkError, expected, "status \(status)")
            }
        }
    }

    func testDecodingFailureNamesTheField() async {
        StubURLProtocol.install { _ in (200, #"[{"id":"1"}]"#) }
        do {
            let _: [Trip] = try await makeClient().send(.get("trips"))
            XCTFail("should throw")
        } catch let NetworkError.decoding(text) {
            XCTAssertTrue(text.contains("name"), text)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testOfflineMapsToNoConnection() async {
        StubURLProtocol.install { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await makeClient().send(.get("trips"))
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? NetworkError, .noConnection)
            XCTAssertTrue(error.isOffline)
        }
    }

    // MARK: - Retry

    func testGetRetriesServerFailuresThenSucceeds() async throws {
        let counter = Counter()
        StubURLProtocol.install { _ in counter.next() < 2 ? (503, "{}") : (200, "[]") }
        let delays = DelayRecorder()
        let trips: [Trip] = try await makeClient(retry: .exponential(maxAttempts: 3, baseDelay: 0.5), delays: delays)
            .send(.get("trips"))
        XCTAssertEqual(trips, [])
        XCTAssertEqual(StubURLProtocol.requests.count, 3)
        let waited = await delays.values
        XCTAssertEqual(waited, [0.5, 1.0], "waits double each time")
    }

    func testPostIsNotRetriedByDefault() async throws {
        StubURLProtocol.install { _ in (503, "{}") }
        let endpoint = try Endpoint.post("trips", body: Trip(id: "1", name: "A"))
        do {
            _ = try await makeClient(retry: .exponential()).send(endpoint)
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(StubURLProtocol.requests.count, 1, "a duplicate create must not be possible")
        }
    }

    func testClientErrorsAreNotRetried() async {
        StubURLProtocol.install { _ in (422, "{}") }
        _ = try? await makeClient(retry: .exponential()).send(.get("trips"))
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testStopsAfterMaxAttempts() async {
        StubURLProtocol.install { _ in (503, "{}") }
        _ = try? await makeClient(retry: .exponential(maxAttempts: 3)).send(.get("trips"))
        XCTAssertEqual(StubURLProtocol.requests.count, 3)
    }

    // MARK: - Interceptors

    func testBearerTokenIsAdded() async throws {
        StubURLProtocol.install { _ in (200, "[]") }
        let client = makeClient(interceptors: [BearerTokenInterceptor(token: { "abc" })])
        let _: [Trip] = try await client.send(.get("trips"))
        XCTAssertEqual(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer abc")
    }

    func testNoTokenMeansNoHeader() async throws {
        StubURLProtocol.install { _ in (200, "[]") }
        let client = makeClient(interceptors: [BearerTokenInterceptor(token: { nil })])
        let _: [Trip] = try await client.send(.get("trips"))
        XCTAssertNil(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testUnauthorizedRefreshesTheTokenAndRetriesOnce() async throws {
        let token = TokenBox("old")
        StubURLProtocol.install { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer new" ? (200, "[]") : (401, "{}")
        }
        let client = makeClient(interceptors: [
            BearerTokenInterceptor(token: { await token.value }, refresh: { await token.set("new"); return true }),
        ])
        let _: [Trip] = try await client.send(.get("trips"))
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    func testUnauthorizedIsRefreshedAtMostOnce() async {
        StubURLProtocol.install { _ in (401, "{}") }
        let client = makeClient(interceptors: [BearerTokenInterceptor(token: { "t" }, refresh: { true })])
        do {
            _ = try await client.send(.get("trips"))
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? NetworkError, .unauthorized(message: nil))
            XCTAssertEqual(StubURLProtocol.requests.count, 2, "no refresh loop")
        }
    }

    // MARK: - Credentials stay with the API's own host

    func testCredentialsAreNotCarriedToAnotherHostOnRedirect() async {
        StubURLProtocol.installReplies { request in
            request.url?.host == "api.example.com"
                ? StubReply(status: 302, headers: ["Location": "https://files.example.net/download"])
                : StubReply(status: 200, body: "[]")
        }
        let client = URLSessionHTTPClient(
            baseURL: base,
            session: StubURLProtocol.session(),
            defaultHeaders: ["Accept": "application/json", "X-Api-Key": "key-123", "Cookie": "session=abc"],
            interceptors: [BearerTokenInterceptor(token: { "secret-token" })]
        )
        _ = try? await client.send(.get("trips"))

        let sent = StubURLProtocol.requests
        XCTAssertEqual(sent.first?.value(forHTTPHeaderField: "X-Api-Key"), "key-123", "the API's own host gets them")
        let followed = sent.first { $0.url?.host == "files.example.net" }
        XCTAssertNotNil(followed, "a redirect to another host is followed")
        for header in ["Authorization", "X-Api-Key", "Cookie"] {
            XCTAssertNil(followed?.value(forHTTPHeaderField: header), "\(header) must not go to another host")
        }
        XCTAssertEqual(followed?.value(forHTTPHeaderField: "Accept"), "application/json", "harmless headers do")
    }

    func testRedirectToSameHostKeepsCredentials() async {
        StubURLProtocol.installReplies { request in
            request.url?.path == "/v1/old"
                ? StubReply(status: 302, headers: ["Location": "https://api.example.com/v1/new"])
                : StubReply(status: 200, body: "[]")
        }
        let client = makeClient(interceptors: [BearerTokenInterceptor(token: { "secret-token" })])
        let _: [Trip] = try! await client.send(.get("old"))
        let followed = StubURLProtocol.requests.last
        XCTAssertEqual(followed?.url?.path, "/v1/new")
        XCTAssertEqual(followed?.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
    }

    func testARedirectFromHTTPSToHTTPIsNotFollowed() async {
        StubURLProtocol.installReplies { request in
            request.url?.scheme == "https"
                ? StubReply(status: 302, headers: ["Location": "http://api.example.com/v1/plain"])
                : StubReply(status: 200, body: "[]")
        }
        // The stub can't send the 3xx reply a real network stack returns when a
        // redirect is declined, so the request ends by timing out. What this
        // test checks is that nothing goes out over http.
        let client = URLSessionHTTPClient(
            baseURL: base,
            session: StubURLProtocol.session(),
            interceptors: [BearerTokenInterceptor(token: { "secret-token" })],
            timeout: 0.5
        )
        do {
            let _: [Trip] = try await client.send(.get("trips"))
            XCTFail("should not succeed over http")
        } catch {}
        XCTAssertTrue(StubURLProtocol.requests.allSatisfy { $0.url?.scheme == "https" }, "no request went out over http")
    }

    func testPlainHTTPIsRefusedAndNothingIsSent() async {
        StubURLProtocol.install { _ in (200, "[]") }
        let client = URLSessionHTTPClient(baseURL: URL(string: "http://api.example.com/v1")!, session: StubURLProtocol.session())
        do {
            _ = try await client.send(.get("trips"))
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? NetworkError, .insecureConnection)
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testAFullHTTPURLIsRefusedEvenWithAnHTTPSBase() async {
        StubURLProtocol.install { _ in (200, "[]") }
        do {
            _ = try await makeClient().send(.get("http://api.example.com/v1/trips"))
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? NetworkError, .insecureConnection)
        }
    }

    func testPlainHTTPToLocalhostIsAllowedOnlyWhenTheAppSaysSo() async throws {
        StubURLProtocol.install { _ in (200, "[]") }
        let local = URL(string: "http://localhost:8080")!
        let strict = URLSessionHTTPClient(baseURL: local, session: StubURLProtocol.session())
        do {
            _ = try await strict.send(.get("trips"))
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? NetworkError, .insecureConnection)
        }
        let dev = URLSessionHTTPClient(baseURL: local, session: StubURLProtocol.session(), security: .allowingLocalhost)
        let trips: [Trip] = try await dev.send(.get("trips"))
        XCTAssertEqual(trips, [])
    }

    func testCredentialsGoOnlyToTheAPIsOwnHost() async throws {
        StubURLProtocol.install { _ in (200, "[]") }
        let client = URLSessionHTTPClient(
            baseURL: base,
            session: StubURLProtocol.session(),
            defaultHeaders: ["X-Api-Key": "key-123"],
            interceptors: [BearerTokenInterceptor(token: { "secret-token" })]
        )
        let _: [Trip] = try await client.send(.get("trips"))
        let _: [Trip] = try await client.send(.get("https://cdn.example.net/list.json"))

        let own = StubURLProtocol.requests[0]
        let other = StubURLProtocol.requests[1]
        XCTAssertEqual(own.value(forHTTPHeaderField: "X-Api-Key"), "key-123")
        XCTAssertEqual(own.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        XCTAssertNil(other.value(forHTTPHeaderField: "X-Api-Key"), "a request to another host carries no key")
        XCTAssertNil(other.value(forHTTPHeaderField: "Authorization"), "and no token")
    }

    func testAHostTheAppTrustsDoesGetCredentials() async throws {
        StubURLProtocol.install { _ in (200, "[]") }
        let client = URLSessionHTTPClient(
            baseURL: base,
            session: StubURLProtocol.session(),
            interceptors: [BearerTokenInterceptor(token: { "secret-token" })],
            security: SecurityPolicy(trustedHosts: ["Uploads.Example.com"])
        )
        let _: [Trip] = try await client.send(.get("https://uploads.example.com/list"))
        XCTAssertEqual(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
    }

    func testLogsNeverContainQueryValuesCredentialsOrUserInfo() async throws {
        StubURLProtocol.install { _ in (200, "[]") }
        let lines = LogBox()
        let client = URLSessionHTTPClient(
            baseURL: base,
            session: StubURLProtocol.session(),
            interceptors: [BearerTokenInterceptor(token: { "secret-token" })],
            log: { lines.add($0) }
        )
        let _: [Trip] = try await client.send(.get("trips", query: ["access_token": "abc123", "email": "dana@example.com"]))
        _ = try? await client.send(.get("https://user:hunter2@cdn.example.net/x?sig=zzz"))

        let all = lines.all.joined(separator: "\n")
        XCTAssertFalse(all.isEmpty)
        for secret in ["abc123", "dana@example.com", "secret-token", "hunter2", "zzz"] {
            XCTAssertFalse(all.contains(secret), "\(secret) leaked into the log:\n\(all)")
        }
        XCTAssertTrue(all.contains("access_token"), "names are kept so a log is still useful")
    }

    func testClearSessionRemovesCookiesHeldBySession() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let url = URL(string: "https://api.example.com/v1")!
        session.configuration.httpCookieStorage?.setCookie(
            HTTPCookie(properties: [.name: "session", .value: "abc", .domain: "api.example.com", .path: "/"])!
        )
        XCTAssertEqual(session.configuration.httpCookieStorage?.cookies(for: url)?.count, 1)

        await URLSessionHTTPClient(baseURL: url, session: session).clearSession()
        XCTAssertEqual(session.configuration.httpCookieStorage?.cookies(for: url)?.count ?? 0, 0)
    }

    func testRefreshFailureSurfacesUnauthorized() async {
        StubURLProtocol.install { _ in (401, "{}") }
        let client = makeClient(interceptors: [BearerTokenInterceptor(token: { "t" }, refresh: { false })])
        do {
            _ = try await client.send(.get("trips"))
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(StubURLProtocol.requests.count, 1)
        }
    }
}

// MARK: - Test helpers

actor DelayRecorder {
    private(set) var values: [TimeInterval] = []
    func record(_ delay: TimeInterval) { values.append(delay) }
}

actor TokenBox {
    private(set) var value: String
    init(_ value: String) { self.value = value }
    func set(_ new: String) { value = new }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    /// Returns 0, 1, 2… on successive calls.
    func next() -> Int { lock.withLock { defer { count += 1 }; return count } }
}

final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}
