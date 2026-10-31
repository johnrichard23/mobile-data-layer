import DataLayer
import XCTest

final class CodingTests: XCTestCase {
    // MARK: - JSONValue

    func testJSONValueRoundTripsEveryKind() throws {
        let source = #"{"a":1,"b":1.5,"c":"text","d":true,"e":null,"f":[1,"x",false],"g":{"h":2}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
        XCTAssertEqual(value["a"], .int(1))
        XCTAssertEqual(value["b"], .double(1.5))
        XCTAssertEqual(value["c"]?.stringValue, "text")
        XCTAssertEqual(value["d"]?.boolValue, true)
        XCTAssertEqual(value["e"], .null)
        XCTAssertEqual(value["f"]?[1], "x")
        XCTAssertEqual(value["g"]?["h"]?.intValue, 2)

        let again = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(again, value)
    }

    func testJSONValueLiterals() {
        let value: JSONValue = ["name": "Dana", "age": 30, "tags": ["a", "b"], "gone": nil]
        XCTAssertEqual(value["name"], .string("Dana"))
        XCTAssertEqual(value["tags"]?[0], .string("a"))
        XCTAssertEqual(value["gone"], .null)
    }

    // MARK: - Dates

    private struct Dated: Codable, Equatable { var at: Date }

    func testDecoderAcceptsIsoWithAndWithoutFractionalSeconds() throws {
        let decoder = JSONCoding.decoder()
        let withFraction = try decoder.decode(Dated.self, from: Data(#"{"at":"2026-10-31T11:00:00.250Z"}"#.utf8))
        let without = try decoder.decode(Dated.self, from: Data(#"{"at":"2026-10-31T11:00:00Z"}"#.utf8))
        XCTAssertEqual(withFraction.at.timeIntervalSince(without.at), 0.25, accuracy: 0.001)
    }

    func testDecoderAcceptsUnixSecondsAndMilliseconds() throws {
        let decoder = JSONCoding.decoder()
        let seconds = try decoder.decode(Dated.self, from: Data(#"{"at":1761908400}"#.utf8))
        let millis = try decoder.decode(Dated.self, from: Data(#"{"at":1761908400000}"#.utf8))
        XCTAssertEqual(seconds.at, millis.at)
        XCTAssertEqual(seconds.at.timeIntervalSince1970, 1_761_908_400)
    }

    func testDecoderRejectsGarbageDates() {
        XCTAssertThrowsError(try JSONCoding.decoder().decode(Dated.self, from: Data(#"{"at":"yesterday"}"#.utf8)))
    }

    func testEncoderWritesIsoDatesAndRoundTrips() throws {
        let date = Date(timeIntervalSince1970: 1_761_908_400.5)
        let data = try JSONCoding.encoder().encode(Dated(at: date))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("2025-10-31T11:00:00.500Z"))
        XCTAssertEqual(try JSONCoding.decoder().decode(Dated.self, from: data).at, date)
    }

    func testSnakeCaseKeysConvertBothWays() throws {
        struct User: Codable, Equatable { var firstName: String }
        let decoded = try JSONCoding.decoder(keys: .snakeCase).decode(User.self, from: Data(#"{"first_name":"Dana"}"#.utf8))
        XCTAssertEqual(decoded.firstName, "Dana")
        let encoded = try JSONCoding.encoder(keys: .snakeCase).encode(decoded)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #"{"first_name":"Dana"}"#)
    }

    // MARK: - WithExtras

    private struct TripDTO: Codable, Equatable, UnknownFieldPreserving {
        var id: String
        var name: String?

        enum CodingKeys: String, CodingKey, CaseIterable { case id, name }
        typealias WireKey = CodingKeys
    }

    func testWithExtrasKeepsFieldsTheDTODoesNotModel() throws {
        let source = #"{"id":"1","name":"Siargao","color":"teal","stats":{"days":7},"future":null}"#
        let trip = try JSONDecoder().decode(WithExtras<TripDTO>.self, from: Data(source.utf8))
        XCTAssertEqual(trip.value, TripDTO(id: "1", name: "Siargao"))
        XCTAssertEqual(trip.extras["color"], "teal")
        XCTAssertEqual(trip.extras["stats"]?["days"]?.intValue, 7)
        XCTAssertEqual(trip.extras["future"], .null)
        XCTAssertNil(trip.extras["id"], "modelled fields are not extras")

        // Saving writes the unknown fields back: nothing is lost.
        let encoded = try JSONEncoder().encode(trip)
        let reread = try JSONDecoder().decode(JSONValue.self, from: encoded)
        XCTAssertEqual(reread["color"], "teal")
        XCTAssertEqual(reread["stats"]?["days"]?.intValue, 7)
        XCTAssertEqual(reread["name"], "Siargao")
    }

    func testWithExtrasChangesToModelledFieldsAreWritten() throws {
        var trip = try JSONDecoder().decode(WithExtras<TripDTO>.self, from: Data(#"{"id":"1","name":"A","x":1}"#.utf8))
        trip.value.name = "B"
        let reread = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(trip))
        XCTAssertEqual(reread["name"], "B")
        XCTAssertEqual(reread["x"], 1)
    }

    func testWithExtrasWithSnakeCaseKeys() throws {
        struct Profile: Codable, UnknownFieldPreserving {
            var firstName: String
            enum CodingKeys: String, CodingKey, CaseIterable { case firstName }
            typealias WireKey = CodingKeys
        }
        let source = #"{"first_name":"Dana","last_seen_at":"2026-01-01"}"#
        let value = try JSONCoding.decoder(keys: .snakeCase).decode(WithExtras<Profile>.self, from: Data(source.utf8))
        XCTAssertEqual(value.value.firstName, "Dana")
        let reread = try JSONDecoder().decode(
            JSONValue.self,
            from: JSONCoding.encoder(keys: .snakeCase).encode(value)
        )
        XCTAssertEqual(reread["last_seen_at"], "2026-01-01", "unknown snake_case key survives the round trip")
        XCTAssertEqual(reread["first_name"], "Dana")
    }

    // MARK: - Mapper

    func testMapperListsFailOnOneBadElementUnlessSkipping() throws {
        let mapper = ClosureMapper<Int, String>(toModel: { number in
            if number < 0 { throw MappingError.invalidValue(field: "n", value: "\(number)") }
            return "#\(number)"
        })
        XCTAssertThrowsError(try mapper.models(from: [1, -2, 3]))
        XCTAssertEqual(try mapper.models(from: [1, -2, 3], skipInvalid: true), ["#1", "#3"])
        XCTAssertThrowsError(try mapper.dto(from: "x")) { error in
            XCTAssertEqual(error as? MappingError, .notSupported)
        }
    }
}
