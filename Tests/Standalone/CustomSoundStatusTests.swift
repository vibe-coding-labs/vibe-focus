// Tests/Standalone/CustomSoundStatusTests.swift
// Verification: 自定义音频文件有效性三态评估（未配置/有效/缺失）+ detail 文案
// Mirrors: Sources/App/SoundManager.swift (CustomSoundStatus)
// Run: swift Tests/Standalone/CustomSoundStatusTests.swift

import Foundation

// MARK: - Mirrored type

enum CustomSoundStatus: Equatable {
    case notSet
    case valid
    case missing

    static func evaluate(path: String?) -> CustomSoundStatus {
        guard let path, !path.isEmpty else { return .notSet }
        return FileManager.default.fileExists(atPath: path) ? .valid : .missing
    }

    var uiDescription: String {
        switch self {
        case .notSet: return "未选择文件"
        case .valid: return "已选择"
        case .missing: return "⚠️ 文件不存在，完成音将降级为系统默认"
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

print("1. CustomSoundStatus.evaluate 三态")
do {
    check("nil 路径 → notSet", CustomSoundStatus.evaluate(path: nil) == .notSet)
    check("空路径 → notSet", CustomSoundStatus.evaluate(path: "") == .notSet)
    check("不存在的文件 → missing", CustomSoundStatus.evaluate(path: "/tmp/definitely-not-here-\(UUID().uuidString).wav") == .missing)

    // 造一个真实临时文件 → valid，随后清理
    let tmp = "/tmp/vibefocus-sound-status-test-\(UUID().uuidString).wav"
    FileManager.default.createFile(atPath: tmp, contents: Data([0x00]))
    check("存在的文件 → valid", CustomSoundStatus.evaluate(path: tmp) == .valid)
    try? FileManager.default.removeItem(atPath: tmp)
    check("文件删除后 → missing（覆盖用户删文件的场景）", CustomSoundStatus.evaluate(path: tmp) == .missing)
}

print("2. detail 文案")
do {
    check("notSet 文案", CustomSoundStatus.notSet.uiDescription == "未选择文件")
    check("valid 文案", CustomSoundStatus.valid.uiDescription == "已选择")
    check("missing 文案含降级提示", CustomSoundStatus.missing.uiDescription.contains("降级为系统默认"))
}

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed == 0 ? 0 : 1)
