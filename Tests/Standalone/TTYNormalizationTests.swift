// Tests/Standalone/TTYNormalizationTests.swift
// Verification: TTY 路径归一化（完整版 normalizeTTY / 前缀半边 fullDevicePath）
// Mirrors: Sources/Window/WindowManager+TerminalContext+Helpers.swift
// Run: swift Tests/Standalone/TTYNormalizationTests.swift
//
// 背景（playbook 2.16a 第十八刀）："/dev/ 前缀补全"逻辑曾内联散落 5 处
// （TerminalContext / iTerm2×3 / TitleEditor+TTYWriter），normalizeTTY 完整版
// 在第十六刀被误判为影子删除（真实消费者以内联副本存在）。本刀恢复唯一事实源
// 并全量接线。本测试穷尽两函数分支，并锁定精确匹配语义的历史怪癖：
// "not a tty"（精确）→ nil，但 "not a tty "（带尾随空格）→ "/dev/not a tty "。

import Foundation

// MARK: - Extracted pure logic

/// Mirrors WindowManager.normalizeTTY / fullDevicePath
enum MirrorTTY {

    /// 前缀半边：无 /dev/ 前缀则补全（Mirrors fullDevicePath）
    static func fullDevicePath(_ tty: String) -> String {
        tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
    }

    /// 完整归一化：nil/空串/"not a tty"（精确）→ nil；其余走前缀半边（Mirrors normalizeTTY）
    static func normalizeTTY(_ tty: String?) -> String? {
        guard let tty, !tty.isEmpty, tty != "not a tty" else { return nil }
        return fullDevicePath(tty)
    }
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

// MARK: 1. normalizeTTY — 完整归一化全分支

print("1. normalizeTTY")

check("nil → nil", MirrorTTY.normalizeTTY(nil) == nil)
check("空串 → nil", MirrorTTY.normalizeTTY("") == nil)
check("「not a tty」（hook-forwarder 无 TTY 场景的哨兵串）→ nil",
      MirrorTTY.normalizeTTY("not a tty") == nil)
check("无前缀 ttys003 → 补全 /dev/ttys003",
      MirrorTTY.normalizeTTY("ttys003") == "/dev/ttys003")
check("已有 /dev/ 前缀 → 原样透传",
      MirrorTTY.normalizeTTY("/dev/ttys003") == "/dev/ttys003")
check("非 ttys 形态的设备名同样补全（归一化不做格式校验，校验归 isValidTTYPath）",
      MirrorTTY.normalizeTTY("pts/0") == "/dev/pts/0")
check("历史怪癖锁定：「not a tty 」带尾随空格 ≠ 精确匹配 → 走补全分支",
      MirrorTTY.normalizeTTY("not a tty ") == "/dev/not a tty ")

// MARK: 2. fullDevicePath — 前缀半边（iTerm2×3 / TitleEditor 消费者的输入契约：非可选已验证）

print("\n2. fullDevicePath")

check("无前缀 → 补全", MirrorTTY.fullDevicePath("ttys007") == "/dev/ttys007")
check("已有前缀 → 透传", MirrorTTY.fullDevicePath("/dev/ttys007") == "/dev/ttys007")
check("空串 → /dev/（契约上不出现；锁定现状防语义漂移）",
      MirrorTTY.fullDevicePath("") == "/dev/")

// MARK: 3. 组合一致性 — normalizeTTY = 校验 guard + fullDevicePath

print("\n3. 组合一致性")

let probes: [String] = ["ttys003", "/dev/ttys003", "pts/0", "not a tty??"]
check("非哨兵输入下 normalizeTTY(t) == fullDevicePath(t)",
      probes.allSatisfy { MirrorTTY.normalizeTTY($0) == MirrorTTY.fullDevicePath($0) })
check("哨兵与空值仅 normalizeTTY 返回 nil（fullDevicePath 无校验职责）",
      MirrorTTY.normalizeTTY("not a tty") == nil && MirrorTTY.normalizeTTY("") == nil
      && MirrorTTY.normalizeTTY(nil) == nil)

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
