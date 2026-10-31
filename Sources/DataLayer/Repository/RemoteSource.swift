//
//  RemoteSource.swift
//
//  Where a `Repository` gets models from (and sends changes to). Returns
//  models, not DTOs: the mapping happens inside the source. `RESTRemoteSource`
//  covers the usual JSON-over-REST resource; write your own for anything else
//  (GraphQL, RPC, a Supabase call).
//

import Foundation

public protocol RemoteSource<Model>: Sendable {
    associatedtype Model: Sendable

    func fetch(id: String) async throws -> Model
    func fetchAll() async throws -> [Model]
}

public protocol WritableRemoteSource<Model>: RemoteSource {
    /// Sends a new model. Returns what the server created (with its id).
    func create(_ model: Model) async throws -> Model
    /// Sends changes. Returns the server's version.
    func update(_ model: Model) async throws -> Model
    func delete(id: String) async throws
}

/// A REST resource: `GET /trips`, `GET /trips/{id}`, `POST /trips`,
/// `PUT /trips/{id}`, `DELETE /trips/{id}`.
public struct RESTRemoteSource<DTO: Codable & Sendable, MapperType: Mapper>: WritableRemoteSource
    where MapperType.DTO == DTO, MapperType.Model: Identifiable, MapperType.Model.ID == String
{
    public typealias Model = MapperType.Model

    /// Where the DTO sits inside a reply.
    public enum Envelope: Sendable, Equatable {
        /// The reply is the DTO (or an array of them).
        case none
        /// The reply is `{ "<key>": … }`, e.g. `{ "data": [...] }`.
        case key(String)
    }

    private let client: any HTTPClient
    private let path: String
    private let mapper: MapperType
    private let envelope: Envelope
    private let listQuery: [URLQueryItem]
    private let updateMethod: HTTPMethod
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    /// - Parameters:
    ///   - path: the collection's path, e.g. `"trips"`.
    ///   - envelope: how replies are wrapped.
    ///   - listQuery: fixed query items for the list call (a page size, a filter).
    ///   - updateMethod: `.put` (default) or `.patch`.
    public init(
        client: any HTTPClient,
        path: String,
        mapper: MapperType,
        envelope: Envelope = .none,
        listQuery: [URLQueryItem] = [],
        updateMethod: HTTPMethod = .put,
        decoder: JSONDecoder = JSONCoding.decoder(),
        encoder: JSONEncoder = JSONCoding.encoder()
    ) {
        self.client = client
        self.path = path
        self.mapper = mapper
        self.envelope = envelope
        self.listQuery = listQuery
        self.updateMethod = updateMethod
        self.decoder = decoder
        self.encoder = encoder
    }

    public func fetch(id: String) async throws -> Model {
        let response = try await client.send(Endpoint(path: itemPath(id)))
        return try mapper.model(from: unwrap(DTO.self, from: response))
    }

    public func fetchAll() async throws -> [Model] {
        let response = try await client.send(Endpoint(path: path, query: listQuery))
        return try mapper.models(from: unwrap([DTO].self, from: response))
    }

    public func create(_ model: Model) async throws -> Model {
        let endpoint = try Endpoint.post(path, body: mapper.dto(from: model), encoder: encoder)
        let response = try await client.send(endpoint)
        return try mapper.model(from: unwrap(DTO.self, from: response))
    }

    public func update(_ model: Model) async throws -> Model {
        let dto = try mapper.dto(from: model)
        var endpoint = try Endpoint.put(itemPath(model.id), body: dto, encoder: encoder)
        endpoint.method = updateMethod
        let response = try await client.send(endpoint)
        return try mapper.model(from: unwrap(DTO.self, from: response))
    }

    public func delete(id: String) async throws {
        _ = try await client.send(Endpoint.delete(itemPath(id)))
    }

    // MARK: - Helpers

    private func itemPath(_ id: String) -> String {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return path.hasSuffix("/") ? path + encoded : path + "/" + encoded
    }

    private func unwrap<Value: Decodable>(_: Value.Type, from response: HTTPResponse) throws -> Value {
        switch envelope {
        case .none:
            return try response.decode(Value.self, decoder: decoder)
        case let .key(key):
            do {
                let container = try decoder.decode(KeyedReply.self, from: response.data)
                return try container.value(Value.self, forKey: key, decoder: decoder)
            } catch let error as NetworkError {
                throw error
            } catch let error as DecodingError {
                throw NetworkError.decoding(error.readable)
            } catch {
                throw NetworkError.decoding(error.localizedDescription)
            }
        }
    }

    private struct KeyedReply: Decodable {
        let raw: [String: JSONValue]

        init(from decoder: any Decoder) throws {
            raw = try [String: JSONValue](from: decoder)
        }

        func value<Value: Decodable>(_: Value.Type, forKey key: String, decoder: JSONDecoder) throws -> Value {
            guard let inner = raw[key] else { throw NetworkError.decoding("Missing \"\(key)\" in reply") }
            return try decoder.decode(Value.self, from: JSONEncoder().encode(inner))
        }
    }
}
