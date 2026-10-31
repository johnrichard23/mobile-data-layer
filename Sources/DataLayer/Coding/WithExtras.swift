//
//  WithExtras.swift
//
//  Keeps the fields an API sends that your DTO doesn't list, so they survive
//  a round trip. Without this, an app built against today's API silently
//  deletes tomorrow's new fields every time it saves a record it only
//  partly understands.
//
//      struct TripDTO: Codable, UnknownFieldPreserving {
//          var id: String
//          var name: String
//
//          enum CodingKeys: String, CodingKey, CaseIterable { case id, name }
//          typealias WireKey = CodingKeys
//      }
//
//      let trip = try decoder.decode(WithExtras<TripDTO>.self, from: data)
//      trip.value.name          // the fields you modelled
//      trip.extras["color"]     // everything else the server sent
//      // encoding trip writes both back
//

import Foundation

/// A DTO that can say which JSON keys it models.
public protocol UnknownFieldPreserving {
    /// The DTO's own coding keys. Usually `typealias WireKey = CodingKeys`
    /// with `CodingKeys` also conforming to `CaseIterable`.
    associatedtype WireKey: CodingKey & CaseIterable
}

/// A DTO plus the JSON fields it doesn't model.
public struct WithExtras<DTO: Codable & UnknownFieldPreserving>: Codable {
    public var value: DTO
    public var extras: [String: JSONValue]

    public init(_ value: DTO, extras: [String: JSONValue] = [:]) {
        self.value = value
        self.extras = extras
    }

    public init(from decoder: any Decoder) throws {
        value = try DTO(from: decoder)
        let known = Set(DTO.WireKey.allCases.map(\.stringValue))
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        var extras: [String: JSONValue] = [:]
        for key in container.allKeys where !known.contains(key.stringValue) {
            extras[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        self.extras = extras
    }

    public func encode(to encoder: any Encoder) throws {
        try value.encode(to: encoder)
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        for (key, extra) in extras.sorted(by: { $0.key < $1.key }) {
            try container.encode(extra, forKey: AnyCodingKey(key))
        }
    }
}

extension WithExtras: Sendable where DTO: Sendable {}
extension WithExtras: Equatable where DTO: Equatable {}

/// A coding key made from any string.
struct AnyCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue _: Int) { nil }
}
