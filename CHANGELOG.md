# Changelog

Versions follow `MAJOR.MINOR.PATCH`. See "Versions" in the README.

## 0.1.0

First release.

- **Networking:** `HTTPClient` and `URLSessionHTTPClient` (async/await), `Endpoint`
  builders, typed `NetworkError`, `RequestInterceptor` with bearer-token and
  refresh-after-401, `RetryPolicy` (idempotent requests only by default).
- **Coding:** `JSONCoding` (tolerant ISO 8601 and Unix dates, snake_case option),
  `JSONValue`, `WithExtras` to keep unknown server fields across a round trip.
- **Mapping:** `Mapper`, `ClosureMapper`, `IdentityMapper`, `MappingError`.
- **Storage:** `Store`, `InMemoryStore`, `FileStore`.
- **Repository:** `Repository` with `CachePolicy` (cache-and-refresh with stale and
  expiry times, network-first, network-only, cache-only), shared in-flight
  requests, write-through create/update/delete, `updates()` stream.
- **Remote sources:** `RemoteSource`, `WritableRemoteSource`, `RESTRemoteSource`.
- **Sync rules:** `ConflictResolver` and `Syncable`.
- **Testing:** `StubHTTPClient`.
- 63 tests, run on macOS and on an iOS simulator.
