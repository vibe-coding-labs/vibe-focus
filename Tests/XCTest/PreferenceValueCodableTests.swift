import Testing
import Foundation
@testable import VibeFocusKit

@Suite("PreferenceValue Codable")
struct PreferenceValueCodableTests {

    @Test("bool encode/decode roundtrip")
    func boolRoundtrip() throws {
        let original = PreferenceValue.bool(true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PreferenceValue.self, from: data)
        if case .bool(let v) = decoded {
            #expect(v == true)
        } else {
            Issue.record("Expected .bool, got \(decoded)")
        }
    }

    @Test("bool false roundtrip")
    func boolFalseRoundtrip() throws {
        let original = PreferenceValue.bool(false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PreferenceValue.self, from: data)
        if case .bool(let v) = decoded {
            #expect(v == false)
        } else {
            Issue.record("Expected .bool(false)")
        }
    }

    @Test("int roundtrip")
    func intRoundtrip() throws {
        let original = PreferenceValue.int(12345)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PreferenceValue.self, from: data)
        if case .int(let v) = decoded {
            #expect(v == 12345)
        } else {
            Issue.record("Expected .int")
        }
    }

    @Test("string roundtrip")
    func stringRoundtrip() throws {
        let original = PreferenceValue.string("hello world")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PreferenceValue.self, from: data)
        if case .string(let v) = decoded {
            #expect(v == "hello world")
        } else {
            Issue.record("Expected .string")
        }
    }

    @Test("data roundtrip via base64")
    func dataRoundtrip() throws {
        let originalData = Data("test binary data".utf8)
        let original = PreferenceValue.data(originalData)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PreferenceValue.self, from: encoded)
        if case .data(let v) = decoded {
            #expect(v == originalData)
        } else {
            Issue.record("Expected .data")
        }
    }

    @Test("empty data roundtrip")
    func emptyDataRoundtrip() throws {
        let original = PreferenceValue.data(Data())
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PreferenceValue.self, from: encoded)
        if case .data(let v) = decoded {
            #expect(v.isEmpty)
        } else {
            Issue.record("Expected .data")
        }
    }

    @Test("encode produces expected JSON structure for bool")
    func encodeStructureBool() throws {
        let encoded = try JSONEncoder().encode(PreferenceValue.bool(true))
        let json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect(json?["type"] as? String == "bool")
        #expect(json?["value"] as? Bool == true)
    }

    @Test("encode produces expected JSON structure for int")
    func encodeStructureInt() throws {
        let encoded = try JSONEncoder().encode(PreferenceValue.int(42))
        let json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect(json?["type"] as? String == "int")
        #expect(json?["value"] as? Int == 42)
    }

    @Test("encode produces expected JSON structure for string")
    func encodeStructureString() throws {
        let encoded = try JSONEncoder().encode(PreferenceValue.string("test"))
        let json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect(json?["type"] as? String == "string")
        #expect(json?["value"] as? String == "test")
    }

    @Test("decode throws for unknown type")
    func decodeUnknownType() {
        let json = """
        {"type": "unknown", "value": 42}
        """
        let data = Data(json.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(PreferenceValue.self, from: data)
        }
    }

    @Test("decode throws for invalid base64 in data type")
    func decodeInvalidBase64() {
        let json = """
        {"type": "data", "value": "!!!not-base64!!!"}
        """
        let data = Data(json.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(PreferenceValue.self, from: data)
        }
    }

    @Test("data writeToUserDefaults/readFromUserDefaults roundtrip")
    func dataUserDefaultsRoundtrip() {
        let key = "test_pref_data_roundtrip_\(UUID().uuidString)"
        UserDefaults.standard.removeObject(forKey: key)
        let originalData = Data("binary content".utf8)
        PreferenceValue.data(originalData).writeToUserDefaults(key: key)
        let read = PreferenceValue.readFromUserDefaults(key: key)
        if case .data(let v) = read {
            #expect(v == originalData)
        } else {
            Issue.record("Expected .data, got \(String(describing: read))")
        }
        UserDefaults.standard.removeObject(forKey: key)
    }
}
