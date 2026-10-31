//
//  Mapper.swift
//
//  Converts between what the server sends (the DTO) and what the app uses
//  (the model). Two directions, written once per feature. The stored form
//  (an "entity") belongs inside a `Store` adapter and is mapped there, so a
//  feature never needs more than this one mapper.
//
//      struct TripMapper: Mapper {
//          func model(from dto: TripDTO) throws -> Trip {
//              guard let id = dto.id else { throw MappingError.missingField("id") }
//              return Trip(id: id, name: dto.name ?? "Untitled")
//          }
//          func dto(from model: Trip) throws -> TripDTO {
//              TripDTO(id: model.id, name: model.name)
//          }
//      }
//
//  For a read-only feature, use `ClosureMapper(toModel:)`.
//

import Foundation

/// Why a DTO or model couldn't be converted.
public enum MappingError: Error, Equatable, Sendable {
    /// A field the model requires is missing.
    case missingField(String)
    /// A field has a value the model can't represent.
    case invalidValue(field: String, value: String)
    /// This mapper doesn't convert in that direction.
    case notSupported
}

/// Converts a DTO to a model and back.
public protocol Mapper: Sendable {
    associatedtype DTO: Sendable
    associatedtype Model: Sendable

    func model(from dto: DTO) throws -> Model
    func dto(from model: Model) throws -> DTO
}

public extension Mapper {
    /// Converts a list. By default one bad element fails the whole list, so
    /// bad data is noticed. Pass `skipInvalid: true` to drop bad elements
    /// instead (the number dropped isn't reported).
    func models(from dtos: [DTO], skipInvalid: Bool = false) throws -> [Model] {
        if skipInvalid { return dtos.compactMap { try? model(from: $0) } }
        return try dtos.map { try model(from: $0) }
    }
}

/// A mapper made from closures.
public struct ClosureMapper<DTO: Sendable, Model: Sendable>: Mapper {
    private let toModel: @Sendable (DTO) throws -> Model
    private let toDTO: @Sendable (Model) throws -> DTO

    /// A two-way mapper.
    public init(
        toModel: @escaping @Sendable (DTO) throws -> Model,
        toDTO: @escaping @Sendable (Model) throws -> DTO
    ) {
        self.toModel = toModel
        self.toDTO = toDTO
    }

    /// A read-only mapper: converting a model to a DTO throws `.notSupported`.
    public init(toModel: @escaping @Sendable (DTO) throws -> Model) {
        self.toModel = toModel
        toDTO = { _ in throw MappingError.notSupported }
    }

    public func model(from dto: DTO) throws -> Model { try toModel(dto) }
    public func dto(from model: Model) throws -> DTO { try toDTO(model) }
}

/// For when the DTO and the model are the same type (the server's shape is
/// what the app wants). Prefer a real model once the app needs computed
/// properties or renames.
public struct IdentityMapper<Value: Sendable>: Mapper {
    public init() {}
    public func model(from dto: Value) throws -> Value { dto }
    public func dto(from model: Value) throws -> Value { model }
}
