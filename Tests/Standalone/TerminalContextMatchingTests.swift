// Tests/Standalone/TerminalContextMatchingTests.swift
// Verification: 终端上下文窗口匹配纯函数族（命令→标题匹配 / ps 解析 / CGWindowList 过滤 / iTerm2 UUID / 双校验）
// Mirrors: Sources/Window/WindowManager+TerminalContext+Helpers.swift
//         (matchCommandToWindowTitle / parseCommandBasename / filterWindowsByPID /
//          parseItermSessionUUID / isValidUUIDPart / isValidTTYPath)
// Run: swift Tests/Standalone/TerminalContextMatchingTests.swift
//
// 背景（playbook 2.16a 第二十一刀）：终端上下文匹配族六个纯函数标注
// "extracted for testability" 却只有从未编译的 swift-testing 测试（Tests/XCTest），
// 按 2.13 裁决口径属无覆盖。本套补齐分支穷尽，并顺带清理
// matchCommandToWindowTitle 的死分支（"— cmd ◂" 被 "— cmd" 子串包含，永真重复）。
// 怪癖锁定（历史语义，改前须显式决策）：
// - 标题侧大小写不敏感（titleLower），命令侧大小写敏感（cmd 原样进模式串）；
// - 分隔符为 em dash「—」（U+2014），普通连字符不命中；
// - commands 倒序遍历（ps 输出末尾进程优先）。

import Foundation

// MARK: - Extracted pure logic

/// Mirrors WindowIdentity（匹配函数消费的字段子集）
struct MirrorWindowIdentity {
    let windowID: UInt32
    let title: String?
}

/// Mirrors CGWindowEntry（过滤函数消费的字段子集）
struct MirrorCGWindowEntry {
    let windowID: UInt32
    let ownerPID: Int32
    let layer: Int
    let name: String?
}

/// Mirrors WindowManager.matchCommandToWindowTitle（死分支已清理后的语义）
func mirrorMatchCommandToWindowTitle(
    commands: [String],
    windows: [MirrorWindowIdentity]
) -> MirrorWindowIdentity? {
    for cmd in commands.reversed() {
        for win in windows {
            let titleLower = win.title?.lowercased() ?? ""
            if titleLower.contains("— \(cmd)") {
                return win
            }
        }
    }
    return nil
}

/// Mirrors WindowManager.parseCommandBasename
func mirrorParseCommandBasename(from psOutput: String) -> [String] {
    var commands: [String] = []
    for line in psOutput.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }
        let basename = URL(fileURLWithPath: String(trimmed.split(separator: " ").first ?? Substring(trimmed))).lastPathComponent
        commands.append(basename)
    }
    return commands
}

/// Mirrors WindowManager.parseItermSessionUUID
func mirrorParseItermSessionUUID(_ sessionID: String) -> String? {
    let uuidPart: String
    if let colonRange = sessionID.range(of: ":") {
        uuidPart = String(sessionID[colonRange.upperBound...])
    } else {
        uuidPart = sessionID
    }
    return uuidPart.isEmpty ? nil : uuidPart
}

/// Mirrors WindowManager.isValidUUIDPart
func mirrorIsValidUUIDPart(_ uuid: String) -> Bool {
    let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
    return uuid.unicodeScalars.allSatisfy { allowed.contains($0) }
}

/// Mirrors WindowManager.isValidTTYPath
func mirrorIsValidTTYPath(_ path: String) -> Bool {
    let pattern = "^/dev/(tty[s\\d]+|pty[\\d]+)$"
    return path.range(of: pattern, options: .regularExpression) != nil
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

func win(_ id: UInt32, _ title: String?) -> MirrorWindowIdentity {
    MirrorWindowIdentity(windowID: id, title: title)
}

// MARK: 1. matchCommandToWindowTitle — 模式与遍历序

print("1. matchCommandToWindowTitle")

do {
    let windows = [win(1, "user — vim"), win(2, "zsh")]
    let r = mirrorMatchCommandToWindowTitle(commands: ["vim"], windows: windows)
    check("em dash 模式命中「— vim」", r?.windowID == 1)
}
do {
    let windows = [win(1, "user — vim ◂")]
    let r = mirrorMatchCommandToWindowTitle(commands: ["vim"], windows: windows)
    check("带 ◂ 前台标记的标题仍命中（◂ 分支被子串包含，死分支已清理）", r?.windowID == 1)
}
do {
    let windows = [win(1, "user - vim")]
    let r = mirrorMatchCommandToWindowTitle(commands: ["vim"], windows: windows)
    check("普通连字符「-」不命中（分隔符必须是 em dash）", r == nil)
}
do {
    let windows = [win(1, "user — VIM")]
    let r = mirrorMatchCommandToWindowTitle(commands: ["vim"], windows: windows)
    check("标题侧大小写不敏感（titleLower）", r?.windowID == 1)
}
do {
    let windows = [win(1, "user — vim")]
    let r = mirrorMatchCommandToWindowTitle(commands: ["Vim"], windows: windows)
    check("命令侧大小写敏感（cmd 原样进模式串——历史怪癖锁定）", r == nil)
}
do {
    let windows = [win(1, "— a"), win(2, "— b")]
    let r = mirrorMatchCommandToWindowTitle(commands: ["a", "b"], windows: windows)
    check("commands 倒序遍历：末位命令（最新进程）优先命中", r?.windowID == 2)
}
do {
    let windows = [win(1, "— vim notes.md"), win(2, "— vim")]
    let r = mirrorMatchCommandToWindowTitle(commands: ["vim"], windows: windows)
    check("多窗口同中 → 取首位", r?.windowID == 1)
}
do {
    let r = mirrorMatchCommandToWindowTitle(commands: [], windows: [win(1, "— vim")])
    check("空命令表 → nil", r == nil)
}
do {
    let r = mirrorMatchCommandToWindowTitle(commands: ["vim"], windows: [win(1, nil)])
    check("标题 nil 视为空串 → 不命中", r == nil)
}

// MARK: 2. parseCommandBasename — ps 输出解析

print("\n2. parseCommandBasename")

do {
    let ps = """
    /usr/local/bin/node /Users/cc/.claude/cli.js
      /usr/bin/vim notes.md
    zsh
    """
    let r = mirrorParseCommandBasename(from: ps)
    check("典型 ps 输出：取首 token 的 lastPathComponent，顺序保留",
          r == ["node", "vim", "zsh"])
}
check("空输入 → 空数组", mirrorParseCommandBasename(from: "").isEmpty)
check("全空行输入 → 空数组", mirrorParseCommandBasename(from: "\n   \n\n").isEmpty)
do {
    let r = mirrorParseCommandBasename(from: "   ")
    check("纯空白行（trim 后空）被跳过", r.isEmpty)
}
check("单 token 行 → 自身为 basename", mirrorParseCommandBasename(from: "login") == ["login"])

// MARK: 3. parseItermSessionUUID — 会话 ID 解析

print("\n3. parseItermSessionUUID")

check("标准格式 w0t0p0:UUID → 冒号后段",
      mirrorParseItermSessionUUID("w0t0p0:5C7B-11EC-9B2A") == "5C7B-11EC-9B2A")
check("无冒号 → 整串即 UUID", mirrorParseItermSessionUUID("bare-uuid") == "bare-uuid")
check("冒号后为空 → nil", mirrorParseItermSessionUUID("w0t0p0:") == nil)
check("空串 → nil", mirrorParseItermSessionUUID("") == nil)
check("多冒号按首个切分（UUID 段可含冒号原样保留）",
      mirrorParseItermSessionUUID("w1t2p3:a:b") == "a:b")

// MARK: 4. isValidUUIDPart — AppleScript 注入防御

print("\n4. isValidUUIDPart")

check("十六进制小写 + 连字符 → 通过", mirrorIsValidUUIDPart("5c7b-11ec-9b2a"))
check("十六进制大写 → 通过", mirrorIsValidUUIDPart("ABCDEF"))
check("空串 → true（allSatisfy 空集恒真——历史怪癖锁定）", mirrorIsValidUUIDPart(""))
check("分号注入 → 拒绝", !mirrorIsValidUUIDPart("abc;"))
check("反斜杠注入 → 拒绝", !mirrorIsValidUUIDPart("abc\\"))
check("引号注入 → 拒绝", !mirrorIsValidUUIDPart("abc\""))
check("空格 → 拒绝", !mirrorIsValidUUIDPart("abc def"))

// MARK: 5. isValidTTYPath — TTY 白名单防御

print("\n5. isValidTTYPath")

check("/dev/ttys003 → 通过", mirrorIsValidTTYPath("/dev/ttys003"))
check("/dev/ttys3（单数字）→ 通过", mirrorIsValidTTYPath("/dev/ttys3"))
check("/dev/pty12 → 通过", mirrorIsValidTTYPath("/dev/pty12"))
check("/dev/tty（无编号）→ 拒绝", !mirrorIsValidTTYPath("/dev/tty"))
check("/dev/ttys（无编号）→ 通过（[s\\d]+ 中 s 自身即满足一个字符——历史正则的宽松怪癖锁定）",
      mirrorIsValidTTYPath("/dev/ttys"))
check("/etc/passwd → 拒绝", !mirrorIsValidTTYPath("/etc/passwd"))
check("尾部注入 → 拒绝", !mirrorIsValidTTYPath("/dev/ttys003; rm -rf /"))
check("换行注入 → 拒绝", !mirrorIsValidTTYPath("/dev/ttys003\n"))

// MARK: 6. filterWindowsByPID — CGWindowList 过滤

print("\n6. filterWindowsByPID")

/// Mirrors WindowManager.filterWindowsByPID
func mirrorFilterWindowsByPID(
    entries: [MirrorCGWindowEntry],
    targetPID: Int32,
    appName: String?,
    bundleID: String?
) -> [MirrorWindowIdentity] {
    entries.filter { $0.layer == 0 && $0.ownerPID == targetPID }.map { entry in
        MirrorWindowIdentity(windowID: entry.windowID, title: entry.name)
    }
}

do {
    let entries = [
        MirrorCGWindowEntry(windowID: 1, ownerPID: 100, layer: 0, name: "main"),
        MirrorCGWindowEntry(windowID: 2, ownerPID: 100, layer: 25, name: "overlay"),  // 非 0 层
        MirrorCGWindowEntry(windowID: 3, ownerPID: 200, layer: 0, name: "other"),     // 非目标 PID
        MirrorCGWindowEntry(windowID: 4, ownerPID: 100, layer: 0, name: nil),         // 无标题也保留
    ]
    let r = mirrorFilterWindowsByPID(entries: entries, targetPID: 100, appName: "iTerm2", bundleID: "com.googlecode.iterm2")
    check("过滤：仅 layer==0 且 PID 匹配者保留（无标题窗口照留）",
          r.map(\.windowID) == [1, 4])
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
