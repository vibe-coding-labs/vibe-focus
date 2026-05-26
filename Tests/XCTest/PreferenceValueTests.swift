import Testing
import Foundation
@testable import VibeFocusKit

@Suite("PreferenceValue")
struct PreferenceValueTests {

    // MARK: - Bool

    @Test("bool Codable roundtrip")
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

    @Test("bool encoding produces expected JSON structure")
    func boolEncoding() throws {
        let pv = PreferenceValue.bool(false)
        let data = try JSONEncoder().encode(pv)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "bool")
        #expect(json["value"] as? Bool == false)
    }

    @Test("bool decoding from raw JSON")
    func boolDecodingRaw() throws {
        let json = """
        {"type":"bool","value":true}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(PreferenceValue.self, from: data)
        if case .bool(let v) = decoded {
            #expect(v == true)
        } else {
            Issue.record("Expected .bool")
        }
    }

    // MARK: - Int

    @Test("int Codable roundtrip")
    func intRoundtrip() throws {
        let original = PreferenceValue.int(42)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PreferenceValue.self, from: data)
        if case .int(let v) = decoded {
            #expect(v == 42)
        } else {
            Issue.record("Expected .int, got \(decoded)")
        }
    }

    @Test("int encoding produces expected JSON structure")
    func intEncoding() throws {
        let pv = PreferenceValue.int(39277)
        let data = try JSONEncoder().encode(pv)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "int")
        #expect(json["value"] as? Int == 39277)
    }

    @Test("int negative value roundtrip")
    func intNegativeRoundtrip() throws {
        let original = PreferenceValue.int(-1)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PreferenceValue.self, from: data)
        if case .int(let v) = decoded {
            #expect(v == -1)
        } else {
            Issue.record("Expected .int")
        }
    }

    @Test("int zero value roundtrip")
    func intZeroRoundtrip() throws {
        let original = PreferenceValue.int(0)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PreferenceValue.self, from: data)
        if case .int(let v) = decoded {
            #expect(v == 0)
        } else {
            Issue.record("Expected .int")
        }
    }

    // MARK: - String

    @Test("string Codable roundtrip")
    func stringRoundtrip() throws {
        let original = PreferenceValue.string("hello world")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PreferenceValue.self, from: data)
        if case .string(let v) = decoded {
            #expect(v == "hello world")
        } else {
            Issue.record("Expected .string, got \(decoded)")
        }
    }

    @Test("string encoding produces expected JSON structure")
    func stringEncoding() throws {
        let pv = PreferenceValue.string("test")
        let data = try JSONEncoder().encode(pv)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "string")
        #expect(json["value"] as? String == "test")
    }

    @Test("string empty value roundtrip")
    func stringEmptyRoundtrip() throws {
        let original = PreferenceValue.string("")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PreferenceValue.self, from: data)
        if case .string(let v) = decoded {
            #expect(v == "")
        } else {
            Issue.record("Expected .string")
        }
    }

    @Test("string with special characters roundtrip")
    func stringSpecialChars() throws {
        let original = PreferenceValue.string("hello\"world\\test\nnewline")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PreferenceValue.self, from: data)
        if case .string(let v) = decoded {
            #expect(v == "hello\"world\\test\nnewline")
        } else {
            Issue.record("Expected .string")
        }
    }

    // MARK: - Data

    @Test("data Codable roundtrip")
    func dataRoundtrip() throws {
        let bytes = Data([0x01, 0x02, 0x03, 0xFF, 0x00])
        let original = PreferenceValue.data(bytes)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PreferenceValue.self, from: data)
        if case .data(let v) = decoded {
            #expect(v == bytes)
        } else {
            Issue.record("Expected .data, got \(decoded)")
        }
    }

    @Test("data encoding uses base64 in value field")
    func dataEncodingBase64() throws {
        let bytes = Data("VibeFocus".utf8)
        let pv = PreferenceValue.data(bytes)
        let data = try JSONEncoder().encode(pv)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "data")
        let base64Str = json["value"] as? String
        #expect(base64Str == bytes.base64EncodedString())
    }

    @Test("data empty bytes roundtrip")
    func dataEmptyRoundtrip() throws {
        let original = PreferenceValue.data(Data())
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PreferenceValue.self, from: data)
        if case .data(let v) = decoded {
            #expect(v == Data())
        } else {
            Issue.record("Expected .data")
        }
    }

    // MARK: - Unknown type rejection

    @Test("decoding rejects unknown type")
    func decodingRejectsUnknownType() {
        let json = """
        {"type":"float","value":3.14}
        """
        let data = Data(json.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PreferenceValue.self, from: data)
        }
    }

    @Test("decoding rejects invalid base64 for data type")
    func decodingRejectsInvalidBase64() {
        let json = """
        {"type":"data","value":"!!!not-base64!!!"}
        """
        let data = Data(json.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PreferenceValue.self, from: data)
        }
    }

    // MARK: - UserDefaults integration

    @Test("writeToUserDefaults and readFromUserDefaults for bool")
    func userDefaultsBool() {
        let key = "test_pref_value_bool"
        PreferenceValue.bool(true).writeToUserDefaults(key: key)
        let read = PreferenceValue.readFromUserDefaults(key: key)
        if case .bool(let v) = read {
            #expect(v == true)
        } else {
            Issue.record("Expected .bool, got \(String(describing: read))")
        }
        UserDefaults.standard.removeObject(forKey: key)
    }

    @Test("writeToUserDefaults and readFromUserDefaults for int")
    func userDefaultsInt() {
        let key = "test_pref_value_int"
        PreferenceValue.int(99).writeToUserDefaults(key: key)
        let read = PreferenceValue.readFromUserDefaults(key: key)
        if case .int(let v) = read {
            #expect(v == 99)
        } else {
            Issue.record("Expected .int, got \(String(describing: read))")
        }
        UserDefaults.standard.removeObject(forKey: key)
    }

    @Test("writeToUserDefaults and readFromUserDefaults for string")
    func userDefaultsString() {
        let key = "test_pref_value_str"
        PreferenceValue.string("abc").writeToUserDefaults(key: key)
        let read = PreferenceValue.readFromUserDefaults(key: key)
        if case .string(let v) = read {
            #expect(v == "abc")
        } else {
            Issue.record("Expected .string, got \(String(describing: read))")
        }
        UserDefaults.standard.removeObject(forKey: key)
    }

    @Test("readFromUserDefaults returns nil for missing key")
    func userDefaultsMissingKey() {
        let key = "test_pref_value_nonexistent_\(UUID().uuidString)"
        let read = PreferenceValue.readFromUserDefaults(key: key)
        #expect(read == nil)
    }

    @Test("writeToUserDefaults and readFromUserDefaults for data")
    func userDefaultsData() {
        let key = "test_pref_value_data"
        let bytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        PreferenceValue.data(bytes).writeToUserDefaults(key: key)
        let read = PreferenceValue.readFromUserDefaults(key: key)
        if case .data(let v) = read {
            #expect(v == bytes)
        } else {
            Issue.record("Expected .data, got \(String(describing: read))")
        }
        UserDefaults.standard.removeObject(forKey: key)
    }
}
