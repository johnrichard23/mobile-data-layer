# Changelog

Versions follow `MAJOR.MINOR.PATCH`. See "Versions" in the README.

## 0.2.0

Security release.

- **HTTPS only** by default. A plain HTTP request is refused with the new
  `NetworkError.insecureConnection` (a new case: exhaustive `switch`es over
  `NetworkError` need it). `SecurityPolicy.allowingLocalhost` for development.
- **Credentials stay with the API's host.** Default headers and interceptors
  (tokens, API keys) are no longer sent to other hosts, such as a full URL for
  a CDN file. `SecurityPolicy(trustedHosts:)` lists extra hosts.
- **Redirects:** a redirect to another host keeps only harmless headers
  (URLSession forwards `X-Api-Key`, cookies and custom headers there; only
  `Authorization` is dropped), and a redirect from HTTPS to HTTP isn't followed.
- **Logs** show URLs without query values or user info.
- `FileStore`: file-protection class, excluded from backups by default, and
  optional AES-GCM encryption (`encryptionKey:`). Files that don't match the
  store's configuration are discarded.
- New `SecretStore`, `KeychainSecretStore`, `InMemorySecretStore`, and
  `SecretStore.encryptionKey(named:)`.
- `URLSessionHTTPClient.clearSession()` for sign-out.
- README "Security" section.

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
