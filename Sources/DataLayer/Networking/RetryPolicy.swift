//
//  RetryPolicy.swift
//
//  When and how often to send a failed request again. By default only
//  requests that are safe to repeat (GET, PUT, DELETE) are retried, and only
//  for failures that may pass: no connection, a timeout, 500/502/503/504.
//  A POST isn't retried unless you opt in, because the first attempt may
//  have worked and a second would create a duplicate.
//

import Foundation

public struct RetryPolicy: Sendable, Equatable {
    /// Total tries, including the first.
    public var maxAttempts: Int
    /// Wait before the first retry; doubles for each one after.
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    /// Also retry POST and PATCH. Only for endpoints the server de-duplicates.
    public var retriesNonIdempotent: Bool

    public init(
        maxAttempts: Int,
        baseDelay: TimeInterval = 0.5,
        maxDelay: TimeInterval = 8,
        retriesNonIdempotent: Bool = false
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.retriesNonIdempotent = retriesNonIdempotent
    }

    /// Never retry.
    public static let none = RetryPolicy(maxAttempts: 1)

    /// Retry up to `maxAttempts` times in total, waiting longer each time.
    public static func exponential(maxAttempts: Int = 3, baseDelay: TimeInterval = 0.5) -> RetryPolicy {
        RetryPolicy(maxAttempts: maxAttempts, baseDelay: baseDelay)
    }

    func delay(afterAttempt attempt: Int) -> TimeInterval {
        min(maxDelay, baseDelay * pow(2, Double(attempt - 1)))
    }

    func shouldRetry(_ error: NetworkError, method: HTTPMethod, attempt: Int) -> Bool {
        guard attempt < maxAttempts, error.isRetryable else { return false }
        return method.isIdempotent || retriesNonIdempotent
    }
}
