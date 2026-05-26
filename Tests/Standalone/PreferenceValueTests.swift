// Tests/Standalone/PreferenceValueTests.swift
// Verification: PreferenceValue Codable roundtrip
// Mirrors: Sources/Support/PreferencesSync.swift:164-211
// Run: swift Tests/Standalone/PreferenceValueTests.swift

import Foundation

// MARK: - PreferenceValue (mirrors PreferencesSync.swift:164-211)

enum PreferenceValue: Codable, Equatable {
    case bool(Bool)
    case int(Int)
    case string(String)
    case data(Data)

    private enum CodingKeys: String, CodingKey { case type, value }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bool(let v):
            try container.encode("bool", forKey: .type)
            try container.encode(v, forKey: .value)
        case .int(let v):
            try container.encode("int", forKey: .type)
            try container.encode(v, forKey: .value)
        case .string(let v):
            try container.encode("string", forKey: .type)
            try container.encode(v, forKey: .value)
        case .data(let v):
            try container.encode("data", forKey: .type)
            try container.encode(v.base64EncodedString(), forKey: .value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "bool":
            self = .bool(try container.decode(Bool.self, forKey: .value))
        case "int":
            self = .int(try container.decode(Int.self, forKey: .value))
        case "string":
            self = .string(try container.decode(String.self, forKey: .value))
        case "data":
            let base64 = try container.decode(String.self, forKey: .value)
            guard let d = Data(base64Encoded: base64) else {
                throw DecodingError.dataCorruptedError(forKey: .value, in: container, debugDescription: "Invalid base64 data")
            }
            self = .data(d)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown type: \(type)")
        }
    }
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

func roundtrip(_ value: PreferenceValue) -> PreferenceValue? {
    guard let data = try? JSONEncoder().encode(value) else { return nil }
    return try? JSONDecoder().decode(PreferenceValue.self, from: data)
}

// MARK: - Bool roundtrip

print("1. Bool roundtrip")
do {
    check("bool(true)", roundtrip(.bool(true)) == .bool(true))
    check("bool(false)", roundtrip(.bool(false)) == .bool(false))
}

// MARK: - Int roundtrip

print("\n2. Int roundtrip")
do {
    check("int(42)", roundtrip(.int(42)) == .int(42))
    check("int(0)", roundtrip(.int(0)) == .int(0))
    check("int(-1)", roundtrip(.int(-1)) == .int(-1))
    check("int(max)", roundtrip(.int(Int.max)) == .int(Int.max))
}

// MARK: - String roundtrip

print("\n3. String roundtrip")
do {
    check("string(hello)", roundtrip(.string("hello")) == .string("hello"))
    check("string(empty)", roundtrip(.string("")) == .string(""))
    check("string(unicode)", roundtrip(.string("日本語テスト 🎉")) == .string("日本語テスト 🎉"))
    check("string(special chars)", roundtrip(.string("a\\b\"c\nd")) == .string("a\\b\"c\nd"))
}

// MARK: - Data roundtrip

print("\n4. Data roundtrip")
do {
    let testData = Data("test data 123".utf8)
    check("data(utf8)", roundtrip(.data(testData)) == .data(testData))

    let emptyData = Data()
    check("data(empty)", roundtrip(.data(emptyData)) == .data(emptyData))

    let binaryData = Data([0x00, 0xFF, 0x80, 0x7F])
    check("data(binary)", roundtrip(.data(binaryData)) == .data(binaryData))
}

// MARK: - Dictionary roundtrip

print("\n5. Full dictionary roundtrip")
do {
    let original: [String: PreferenceValue] = [
        "enabled": .bool(true),
        "port": .int(39277),
        "name": .string("VibeFocus"),
        "config": .data(Data("{\"key\":\"value\"}".utf8)),
    ]
    if let encoded = try? JSONEncoder().encode(original),
       let decoded = try? JSONDecoder().decode([String: PreferenceValue].self, from: encoded) {
        check("dictionary count matches", decoded.count == original.count)
        check("dict[enabled]", decoded["enabled"] == .bool(true))
        check("dict[port]", decoded["port"] == .int(39277))
        check("dict[name]", decoded["name"] == .string("VibeFocus"))
        check("dict[config]", decoded["config"] == .data(Data("{\"key\":\"value\"}".utf8)))
    } else {
        check("dictionary roundtrip encode/decode", false)
    }
}

// MARK: - Unknown type rejection

print("\n6. Unknown type rejection")
do {
    let badJSON = """
    {"type": "float", "value": 3.14}
    """
    let data = badJSON.data(using: .utf8)!
    let result = try? JSONDecoder().decode(PreferenceValue.self, from: data)
    check("unknown type throws", result == nil)
}

// MARK: - Invalid base64 rejection

print("\n7. Invalid base64 rejection")
do {
    let badJSON = """
    {"type": "data", "value": "!!!not-base64!!!"}
    """
    let data = badJSON.data(using: .utf8)!
    let result = try? JSONDecoder().decode(PreferenceValue.self, from: data)
    check("invalid base64 throws", result == nil)
}

// MARK: - JSON structure verification

print("\n8. JSON structure is human-readable")
do {
    if let encoded = try? JSONEncoder().encode(PreferenceValue.bool(true)),
       let json = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] {
        check("has type key", json["type"] as? String == "bool")
        check("has value key", json["value"] as? Bool == true)
    } else {
        check("JSON structure", false)
    }
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
