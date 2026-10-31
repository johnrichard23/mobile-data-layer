//
//  JSONCoding.swift
//
//  One place to create the JSON decoder and encoder the whole app uses, so
//  every API agrees on dates and key style. Dates are ISO 8601 with or
//  without fractional seconds, or a Unix timestamp in seconds or
//  milliseconds, because real APIs mix them.
//

import Foundation

public enum JSONCoding {
    /// How property names map to JSON keys.
    public enum KeyStyle: Sendable {
        /// Keys match property names (or your `CodingKeys`).
        case asIs
        /// `user_name` in JSON is `userName` in Swift.
        case snakeCase
    }

    /// A decoder with tolerant date handling.
    public static func decoder(keys: KeyStyle = .asIs) -> JSONDecoder {
        let decoder = JSONDecoder()
        if keys == .snakeCase { decoder.keyDecodingStrategy = .convertFromSnakeCase }
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                if let date = parseISO8601(text) { return date }
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Not an ISO 8601 date: \(text)"
                )
            }
            if let number = try? container.decode(Double.self) {
                // Milliseconds since 1970 are above 1e11 (year 5138 in seconds).
                return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number)
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported date value")
        }
        return decoder
    }

    /// An encoder that writes dates as ISO 8601 with fractional seconds (UTC).
    public static func encoder(keys: KeyStyle = .asIs, sortedKeys: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        if keys == .snakeCase { encoder.keyEncodingStrategy = .convertToSnakeCase }
        if sortedKeys { encoder.outputFormatting.insert(.sortedKeys) }
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatISO8601(date))
        }
        return encoder
    }

    /// Parses an ISO 8601 date, with or without fractional seconds.
    public static func parseISO8601(_ text: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(text)
    }

    /// Formats a date as ISO 8601 with fractional seconds, in UTC.
    public static func formatISO8601(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}
