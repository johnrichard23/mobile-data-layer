//
//  NetworkError.swift
//
//  Everything that can go wrong with a request, as one type, so screens
//  handle "offline", "signed out" and "server said no" the same way for every
//  API. Server messages are kept so the app can show them.
//

import Foundation

public enum NetworkError: Error, Equatable, Sendable {
    /// The URL couldn't be built.
    case invalidURL
    /// No connection to the internet or the server.
    case noConnection
    /// The server took too long.
    case timeout
    /// The request was cancelled (the screen left, the task was cancelled).
    case cancelled
    /// 401: not signed in, or the session expired.
    case unauthorized(message: String?)
    /// 403: signed in but not allowed.
    case forbidden(message: String?)
    /// 404.
    case notFound(message: String?)
    /// Any other 4xx: the request was wrong.
    case client(status: Int, message: String?)
    /// 5xx: the server failed.
    case server(status: Int, message: String?)
    /// The reply wasn't an HTTP response.
    case invalidResponse
    /// The reply didn't match the DTO. The text says which field.
    case decoding(String)
    /// Anything else.
    case unknown(String)
}

public extension NetworkError {
    var statusCode: Int? {
        switch self {
        case .unauthorized: 401
        case .forbidden: 403
        case .notFound: 404
        case let .client(status, _), let .server(status, _): status
        default: nil
        }
    }

    /// The message the server sent, if any. Safe to show to people only if
    /// your server writes user-facing messages.
    var serverMessage: String? {
        switch self {
        case let .unauthorized(message), let .forbidden(message), let .notFound(message): message
        case let .client(_, message), let .server(_, message): message
        default: nil
        }
    }

    /// True when the device has no connection. Show an offline state.
    var isOffline: Bool {
        self == .noConnection
    }

    /// True when sending the same request again might work.
    var isRetryable: Bool {
        switch self {
        case .noConnection, .timeout: true
        case let .server(status, _): [500, 502, 503, 504].contains(status)
        default: false
        }
    }
}

extension NetworkError: LocalizedError {
    /// English text for developers and fallbacks. Show your own localised
    /// copy for each case in the UI.
    public var errorDescription: String? {
        if let message = serverMessage, !message.isEmpty { return message }
        switch self {
        case .invalidURL: return "The address is not valid."
        case .noConnection: return "No internet connection."
        case .timeout: return "The server took too long to respond."
        case .cancelled: return "The request was cancelled."
        case .unauthorized: return "You need to sign in again."
        case .forbidden: return "You don't have access to this."
        case .notFound: return "That wasn't found."
        case let .client(status, _): return "The request was rejected (\(status))."
        case let .server(status, _): return "The server had a problem (\(status))."
        case .invalidResponse: return "The server's reply wasn't understood."
        case .decoding: return "The server's reply wasn't in the expected format."
        case let .unknown(text): return text
        }
    }
}

public extension Error {
    /// True when this error means the device is offline.
    var isOffline: Bool {
        if let error = self as? NetworkError { return error.isOffline }
        if let error = self as? URLError { return error.code == .notConnectedToInternet }
        return false
    }
}

extension NetworkError {
    /// Maps a URLSession failure.
    static func from(_ error: URLError) -> NetworkError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
             .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            .noConnection
        case .timedOut: .timeout
        case .cancelled: .cancelled
        case .badURL, .unsupportedURL: .invalidURL
        default: .unknown(error.localizedDescription)
        }
    }

    /// Maps an HTTP status outside 200–299.
    static func from(status: Int, message: String?) -> NetworkError {
        switch status {
        case 401: .unauthorized(message: message)
        case 403: .forbidden(message: message)
        case 404: .notFound(message: message)
        case 400..<500: .client(status: status, message: message)
        case 500...: .server(status: status, message: message)
        default: .invalidResponse
        }
    }
}

extension DecodingError {
    /// A short description with the path to the failing field.
    var readable: String {
        func path(_ context: Context) -> String {
            let text = context.codingPath.map(\.stringValue).joined(separator: ".")
            return text.isEmpty ? "(root)" : text
        }
        switch self {
        case let .keyNotFound(key, context): return "Missing \"\(key.stringValue)\" at \(path(context))"
        case let .valueNotFound(_, context): return "Missing value at \(path(context))"
        case let .typeMismatch(type, context): return "Expected \(type) at \(path(context))"
        case let .dataCorrupted(context): return "Invalid data at \(path(context)): \(context.debugDescription)"
        @unknown default: return localizedDescription
        }
    }
}
