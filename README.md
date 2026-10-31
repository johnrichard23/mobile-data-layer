# DataLayer

The same way to get data from an API into your screens, in every app: send
requests, turn the server's data into your own types, keep a copy for
offline and speed, and decide when to trust the copy. Swift 6, iOS 17+, no
dependencies, async/await.

**Read this first.** There are five small pieces, one job each:

```
 Screen / ViewModel
        │  "give me the trips"
        ▼
   Repository ───────── decides: stored copy or server?  (CachePolicy)
     │       │
     │       └── Store          keeps the copy   (InMemoryStore, FileStore, or yours)
     ▼
   RemoteSource ──────── fetches models from the server (RESTRemoteSource, or yours)
     │
     ├── HTTPClient       sends requests, retries, adds auth   (URLSessionHTTPClient)
     └── Mapper           server shape (DTO)  ⇄  app shape (Model)
```

You don't have to use all five. An online-only screen needs just
`HTTPClient` + `Mapper`. Add the `Repository` and a `Store` when a screen
should open instantly, work offline, or avoid asking the server every time.

- [Quick start](#quick-start)
- [The shapes: DTO, Model, Entity](#the-shapes-dto-model-entity)
- [Cookbook](#cookbook)
- [Reference](#reference)
- [Rules](#rules)
- [Troubleshooting](#troubleshooting)
- [Not included yet](#not-included-yet)
- [Versions](#versions)

---

## Quick start

**1. Add the package.** In Xcode: File › Add Package Dependencies › paste the
repository URL › "Up to Next Major Version" from the latest tag. Or in
`Package.swift`:

```swift
.package(url: "<repository URL>", from: "0.1.0")
// in your target:
.product(name: "DataLayer", package: "mobile-data-layer")
```

Before the repository is hosted, use a path: `.package(path: "../mobile-data-layer")`.

**2. Write the two shapes and the mapper for one feature.**

```swift
/// What the app uses: clean names, real types, computed properties.
struct Trip: Identifiable, Sendable, Codable, Equatable {
    let id: String
    var name: String
    var startDate: Date?
    var travelers: [String]

    var travelerCount: Int { travelers.count }
}

/// What the server sends: every field optional that the server may leave out.
struct TripDTO: Codable, Sendable {
    var id: String?
    var name: String?
    var startDate: Date?
    var travelers: [String]?
}

/// The only place the two shapes meet.
struct TripMapper: Mapper {
    func model(from dto: TripDTO) throws -> Trip {
        guard let id = dto.id else { throw MappingError.missingField("id") }
        return Trip(id: id, name: dto.name ?? "Untitled", startDate: dto.startDate,
                    travelers: dto.travelers ?? [])
    }

    func dto(from model: Trip) throws -> TripDTO {
        TripDTO(id: model.id, name: model.name, startDate: model.startDate, travelers: model.travelers)
    }
}
```

**3. Create one client for the app.** Create it once at launch and pass it in
(through initialisers, not a global). `auth` is whatever holds your tokens.

```swift
func makeClient(auth: any AuthSession) -> any HTTPClient {
    URLSessionHTTPClient(
        baseURL: URL(string: "https://api.example.com/v1")!,
        defaultHeaders: ["Accept": "application/json"],
        interceptors: [
            BearerTokenInterceptor(token: { await auth.accessToken() },
                                   refresh: { await auth.refreshTokens() }),
        ],
        retry: .exponential(),
        cachePolicy: .reloadIgnoringLocalCacheData   // the repository does the caching
    )
}
```

**4a. Online-only?** Write a small API type, one function per endpoint, and
call it from the view model:

```swift
struct TripsAPI {
    let client: any HTTPClient

    /// `GET /trips` — the signed-in user's trips, newest first.
    func trips(page: Int = 1) async throws -> [Trip] {
        let dtos: [TripDTO] = try await client.send(.get("trips", query: ["page": page]))
        return try TripMapper().models(from: dtos)
    }

    /// `POST /trips` — creates a trip and returns it with its server id.
    func createTrip(name: String) async throws -> Trip {
        let dto: TripDTO = try await client.send(.post("trips", body: ["name": name]))
        return try TripMapper().model(from: dto)
    }
}
```

**4b. Want offline and speed?** Put a `Repository` in front instead:

```swift
extension Repository where Model == Trip {
    static func trips(client: any HTTPClient) -> Repository<Trip> {
        Repository(
            remote: RESTRemoteSource(client: client, path: "trips", mapper: TripMapper()),
            store: FileStore<Trip>(name: "trips"),
            policy: .cacheAndRefresh(staleAfter: 5 * 60, expireAfter: 24 * 60 * 60)
        )
    }
}
```

**5. Use it from a view model.** The repository returns models, throws a
`NetworkError` for anything to do with the connection or the server, and can
be followed for changes:

```swift
@MainActor @Observable
final class TripsViewModel {
    enum State {
        case loading
        case loaded([Trip])
        case offline
        case failed(String)
    }

    private(set) var state = State.loading
    private let repository: Repository<Trip>

    init(repository: Repository<Trip>) {
        self.repository = repository
    }

    /// Cached trips at once; fresh ones when the cache is stale.
    func load() async {
        do {
            state = .loaded(try await repository.all())
        } catch {
            state = error.isOffline ? .offline : .failed(error.localizedDescription)
        }
    }

    /// Pull to refresh: ask the server now.
    func refresh() async {
        do {
            state = .loaded(try await repository.refresh())
        } catch {
            state = error.isOffline ? .offline : .failed(error.localizedDescription)
        }
    }

    /// Keeps the screen in step with the store, including background refreshes.
    func follow() async {
        for await trips in await repository.updates() {
            state = .loaded(trips)
        }
    }

    func rename(_ trip: Trip, to name: String) async {
        var changed = trip
        changed.name = name
        _ = try? await repository.update(changed)   // the store, and so the screen, follow
    }
}
```

`error.isOffline` is true for "no connection": show your offline state (with
the design system, `DSStateView.offline`). Every other `NetworkError` case is
in [Reference](#reference).

---

## The shapes: DTO, Model, Entity

| | What it is | Lives | Rule |
|---|---|---|---|
| **DTO** | Exactly what the server sends and accepts. Optional where the server may omit a field. | next to the API | Never used by screens. |
| **Model** | What the app uses: clean names, real types, computed properties. | the whole app | Never knows about JSON. |
| **Entity** | How a database stores it (SwiftData, Realm, Core Data). | inside a `Store` adapter | Never leaves the adapter. |

The `Mapper` is the only code that knows both the DTO and the Model, so a
server change touches the DTO and the mapper, and nothing else.

**Do I need both a DTO and a Model?** Not always. If the server's shape is
exactly what the app wants and the API is stable, use one type and
`IdentityMapper`. Split them as soon as you want a computed property, a
rename, or protection from the server changing.

**Do I need an Entity?** Only if a database must store the model. The built-in
`FileStore` stores the model itself as JSON, which suits cached server data.
A database-backed `Store` of your own keeps its entity type private and
maps model ⇄ entity inside, so repositories and screens never see it.

---

## Cookbook

### Choosing when to use the stored copy

Each repository has a default `CachePolicy`; any call can override it:

```swift
func policyExamples(trips: Repository<Trip>) async throws {
    _ = try await trips.all()                              // the repository's default
    _ = try await trips.all(policy: .networkFirst)         // fresh if possible, else what's stored
    _ = try await trips.all(policy: .cacheOnly)            // never contacts the server
    _ = try await trips.item(id: "42", policy: .networkOnly) // ignores the store entirely
}
```

| Policy | What happens |
|---|---|
| `.cacheAndRefresh(staleAfter:expireAfter:)` | **Default.** Younger than `staleAfter`: use the copy, don't ask the server. Older: use it now and refresh in the background. Older than `expireAfter`: discard it and wait for the server. |
| `.networkFirst` | Ask the server; if that fails and something is stored, use the stored copy. |
| `.networkOnly` | Ask the server, never touch the store. |
| `.cacheOnly` | Never ask the server. |

Calls made at the same time for the same data share one request. A refresh
removes items the server no longer has and keeps the server's order.

### Keeping fields you don't model

A server adds a field; your app version doesn't know it; the user edits
something and the app saves the record back, deleting the new field. To avoid
that, wrap the DTO in `WithExtras`: it keeps every field the DTO doesn't list
and writes them back.

```swift
struct PlaceDTO: Codable, Sendable, UnknownFieldPreserving {
    var id: String
    var name: String?

    enum CodingKeys: String, CodingKey, CaseIterable { case id, name }
    typealias WireKey = CodingKeys
}

/// Rename a place without deleting the fields this app version doesn't know.
func rename(placeJSON: Data, to name: String) throws -> Data {
    var place = try JSONCoding.decoder().decode(WithExtras<PlaceDTO>.self, from: placeJSON)
    place.value.name = name
    return try JSONCoding.encoder().encode(place)
}
```

### Replies wrapped in an envelope, PATCH updates, fixed query items

```swift
let wrapped = RESTRemoteSource(
    client: StubHTTPClient { _ in .json("{}") },
    path: "trips",
    mapper: TripMapper(),
    envelope: .key("data"),            // replies look like { "data": [ … ] }
    listQuery: [URLQueryItem(name: "limit", value: "100")],
    updateMethod: .patch               // the server updates with PATCH, not PUT
)
```

### A remote source that isn't REST

Anything that can fetch models fits: a GraphQL call, an SDK, a Supabase query.

```swift
/// A remote source that isn't REST: wrap whatever SDK or protocol you have.
struct SDKTripSource: RemoteSource {
    let sdk: TripSDK

    func fetchAll() async throws -> [Trip] {
        try await sdk.listTrips().map { Trip(id: $0.id, name: $0.title, startDate: nil, travelers: []) }
    }

    func fetch(id: String) async throws -> Trip {
        let record = try await sdk.trip(id: id)
        return Trip(id: record.id, name: record.title, startDate: nil, travelers: [])
    }
}
```

Add `create`, `update` and `delete` by conforming to `WritableRemoteSource`
instead. Repositories built on a read-only source throw
`RepositoryError.readOnly` for writes.

### Sign-in, token refresh, extra headers

`BearerTokenInterceptor` adds the token and, after a 401, calls your `refresh`
once and retries the request. `HeaderInterceptor` adds fixed headers. For
anything else, conform to `RequestInterceptor`:

```swift
struct LocaleInterceptor: RequestInterceptor {
    func adapt(_ request: URLRequest) async throws -> URLRequest {
        var request = request
        request.setValue(Locale.current.identifier, forHTTPHeaderField: "Accept-Language")
        return request
    }
}
```

### Retrying

`retry: .exponential()` tries a request up to 3 times in all, waiting 0.5 s
before the second try and 1 s before the third. It
only retries things that can pass (no connection, a timeout, 500/502/503/504)
and only requests that are safe to repeat (GET, PUT, DELETE). A POST is never
retried unless you set `retriesNonIdempotent: true`, because a retried
create can make a duplicate.

### Sign-out

`try await repository.clear()` empties the store and forgets freshness. Call
it for every repository when the user signs out.

### Deciding which copy wins after offline edits

`ConflictResolver` holds the rules a shipping offline-first app uses: the most
recent change wins, a deletion wins over an older edit but not over a newer
one. It is pure logic (no storage, no network), so it fits any sync design.

```swift
struct Note: Syncable {
    var text: String
    var modifiedDate: Date?
    var deletionDate: Date?
}

func merge(local: Note, remote: Note) -> Note {
    switch ConflictResolver.resolve(local: local, remote: remote) {
    case .takeRemote: remote
    case .keepLocal: local     // and send it to the server
    case .noChange: local
    }
}
```

### Testing

`StubHTTPClient` replies to requests from a closure and records what was
sent, so view-model and repository tests need no network:

```swift
func makeTestRepository() -> (Repository<Trip>, StubHTTPClient) {
    let client = StubHTTPClient { endpoint in
        switch endpoint.path {
        case "trips": .json(#"[{"id":"1","name":"Siargao","travelers":["Dana"]}]"#)
        default: .json(#"{"message":"Not found"}"#, status: 404)
        }
    }
    let repository = Repository<Trip>(
        remote: RESTRemoteSource(client: client, path: "trips", mapper: TripMapper()),
        store: InMemoryStore()
    )
    return (repository, client)
}
// In a test: let trips = try await repository.all()
//            XCTAssertEqual(client.requests.count, 1)
```

---

## Reference

### Types

| Need | Use |
|---|---|
| Describe a request | `Endpoint.get(…)`, `.post(…)`, `.put(…)`, `.patch(…)`, `.delete(…)` |
| Send it | `HTTPClient.send(_:)` (returns `HTTPResponse`) or `send(_:as:)` (decodes) |
| The real client | `URLSessionHTTPClient` |
| A client for tests | `StubHTTPClient` |
| Add headers or tokens | `HeaderInterceptor`, `BearerTokenInterceptor`, or your own `RequestInterceptor` |
| JSON decoder or encoder | `JSONCoding.decoder()` / `.encoder()` (ISO dates; `keys: .snakeCase`) |
| Any JSON value | `JSONValue` |
| Keep unknown fields | `WithExtras<DTO>` + `UnknownFieldPreserving` |
| Convert server ⇄ app | `Mapper`, `ClosureMapper`, `IdentityMapper` |
| Fetch models | `RemoteSource`, `WritableRemoteSource`, `RESTRemoteSource` |
| Keep models | `Store`, `InMemoryStore`, `FileStore` |
| The one object for a screen | `Repository<Model>` + `CachePolicy` |
| Resolve conflicts | `ConflictResolver` + `Syncable` |

### Errors: `NetworkError`

| Case | Meaning | Usual screen response |
|---|---|---|
| `.noConnection` | Device offline or server unreachable | Offline state; `error.isOffline` is true |
| `.timeout` | Server too slow | Try again |
| `.unauthorized` | 401: signed out or expired | Send to sign-in |
| `.forbidden` | 403 | "You don't have access" |
| `.notFound` | 404 | "That's gone" |
| `.client(status:message:)` | Other 4xx (e.g. 422 validation) | Show `serverMessage` near the form |
| `.server(status:message:)` | 5xx | "Something went wrong", with retry |
| `.decoding(String)` | The reply didn't match the DTO; the text names the field | Log it; it's a bug |
| `.cancelled` | The task was cancelled | Ignore |
| `.invalidURL`, `.invalidResponse`, `.unknown` | Rare | Generic error |

`error.localizedDescription` gives English text; show your own copy for each
case in the UI. `RepositoryError` has `.readOnly` and `.notCached`.

---

## Rules

Do:
- Create the `HTTPClient` and repositories once, and pass them in through
  initialisers. Depend on `any HTTPClient` and `Repository<Model>`, so tests
  can swap them.
- Make DTO fields optional wherever the server may leave them out; decide the
  default in the mapper.
- Keep DTOs private to the API and mapper. Screens only see models.
- Give a repository to one kind of data, with one store name (`FileStore(name:)`).
- Clear every repository on sign-out.

Don't:
- Don't decode DTOs in a view model, or put `URLSession` in one.
- Don't share a store name between two kinds of data.
- Don't retry POSTs unless the server de-duplicates them.
- Don't log request bodies or headers. The client doesn't; keep it that way.
- Don't put an entity (database type) outside its store adapter.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `.decoding("Missing "name" at …")` | The DTO field isn't optional but the server omitted it. Make it optional. |
| Dates fail to decode | `JSONCoding.decoder()` accepts ISO 8601 (with or without fractions) and Unix seconds/milliseconds. Other formats need a custom `dateDecodingStrategy` on your own decoder, passed to `RESTRemoteSource(decoder:)`. |
| Keys are `snake_case` | Use `JSONCoding.decoder(keys: .snakeCase)` and `.encoder(keys: .snakeCase)` and pass both to `RESTRemoteSource`. |
| Always shows old data | The policy's `staleAfter` is long. Lower it, call `refresh()` on pull-to-refresh, or use `.networkFirst` for that screen. |
| Always hits the server | `.networkFirst`/`.networkOnly` was used, or `staleAfter` is tiny. The default is 5 minutes. |
| Cached data vanished after an app update | `FileStore` throws away a file it can't read (the model changed). That's intended: the server still has the data. |
| Data cleared by iOS | The default folder is Caches, which the system may empty. Pass `directory:` with Application Support for data that must stay. |
| 401 loops | A refresh is attempted once per request. If your refresh returns `true` without really renewing the token, the second 401 is returned as `.unauthorized`. |
| `RESTRemoteSource` won't compile for my model | It needs `Identifiable` with `String` ids. Convert non-string ids in the mapper. |

---

## Not included yet

These are real needs in some apps; they're left out until a project needs
them, so they get designed against a real case:

- **An offline write queue and sync engine** (pending changes, pushing them
  when back online, retry triggers). `ConflictResolver` is the part that
  doesn't depend on how you design it.
- **Pagination helper** (`page`/`cursor` loops). Today: pass `query:` to an
  `Endpoint` and merge in the API function.
- **Database stores** (SwiftData, Realm, Core Data). Write one as a `Store`
  adapter in your app; if two projects want the same one, it becomes an
  optional add-on package so this one stays dependency-free.
- **Network reachability monitoring.** `error.isOffline` tells you after the
  fact; add `NWPathMonitor` in your app if you need to know beforehand.

If your app already has a DTO → Entity → Model stack with Combine and a
database, the equivalents are: a base remote data source → `RESTRemoteSource`;
a six-function mapper → `Mapper` (two functions; the entity mapping moves into
the store adapter); a cache-and-refresh repository → `Repository` with
`CachePolicy`; a conflict manager → `ConflictResolver`; Combine publishers →
async functions and `AsyncStream`; unknown-property DTOs → `WithExtras`.

---

## Versions

One shared repository, so a fix made here reaches every app when it updates.
Apps pin a version and update on purpose.

- Versions are `MAJOR.MINOR.PATCH` git tags.
  - **Patch:** a fix; the public API doesn't change.
  - **Minor:** something new, backwards compatible.
  - **Major:** something an app has to change.
- Every release is listed in [CHANGELOG.md](CHANGELOG.md).
- Before tagging: `swift test` passes (it runs on macOS), the tests also pass
  on an iOS simulator, and the package builds for iOS.
- The repository stays project-neutral: no project names, domains or sample
  data from a real project in code, comments or tests.
