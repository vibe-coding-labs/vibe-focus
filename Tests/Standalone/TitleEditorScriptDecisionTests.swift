// Tests/Standalone/TitleEditorScriptDecisionTests.swift
// Verification: 标题写入 AppleScript 模板决策表（分支矩阵 + 寻址铁律 + 转义 + 哨兵语义）
// Mirrors: Sources/TitleEditor/TitleEditorService+ScriptDecision.swift
// Run: swift Tests/Standalone/TitleEditorScriptDecisionTests.swift
//
// 背景（2026-09-07）：模板此前内联在 applyViaAppleScript 里，内嵌真实回归史——
// tty 定向寻址铁律（window id 与 CGWindowNumber 不同源、current window 被弹框焦点
// 污染）、matched/not_found 哨兵（repeat 未命中在 AppleScript 层不算错误）、标题转义。
// 提取为纯函数后，本测试锁定四分支模板与全部铁律不变量。
// Runner 直测段补齐中（镜像锁 + Runner 真身锁双通道模型）。

import Foundation

// MARK: - Mirrors (与源码同步维护)

func escapingAppleScriptString(_ title: String) -> String {
    title
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

func makeTitleScript(bundleID: String, title: String, targetTTY: String?) -> String? {
    let escaped = escapingAppleScriptString(title)
    switch bundleID {
    case "com.apple.Terminal":
        if let tty = targetTTY {
            return """
                tell application "Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t = "\(tty)" then
                                set custom title of t to "\(escaped)"
                                tell current settings of w
                                    set title displays custom title to true
                                    set title displays device name to false
                                    set title displays shell path to false
                                    set title displays window size to false
                                    set title displays settings name to false
                                end tell
                                return "matched"
                            end if
                        end repeat
                    end repeat
                    return "not_found"
                end tell
                """
        } else {
            return """
                tell application "Terminal"
                    set custom title of selected tab of front window to "\(escaped)"
                    tell current settings of front window
                        set title displays custom title to true
                        set title displays device name to false
                        set title displays shell path to false
                        set title displays window size to false
                        set title displays settings name to false
                    end tell
                end tell
                """
        }
    case "com.googlecode.iterm2":
        if let tty = targetTTY {
            return """
                tell application "iTerm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s = "\(tty)" then
                                    set name of s to "\(escaped)"
                                    return "matched"
                                end if
                            end repeat
                        end repeat
                    end repeat
                    return "not_found"
                end tell
                """
        } else {
            return "tell application \"iTerm2\" to set name of current session of current window to \"\(escaped)\""
        }
    default:
        return nil
    }
}

func isMatchedVerdict(_ verdict: String?) -> Bool {
    verdict == "matched"
}

func makeTerminalDiagnosticScript(targetTTY: String?) -> String {
    if let tty = targetTTY {
        return """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t = "\(tty)" then
                            set s to current settings of w
                            return (custom title of t) & "|" & (title displays custom title of s)
                        end if
                    end repeat
                end repeat
                return "target_gone"
            end tell
            """
    } else {
        return """
            tell application "Terminal"
                set s to current settings of front window
                return (custom title of selected tab of front window) & "|" & (title displays custom title of s)
            end tell
            """
    }
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

// MARK: - Tests

// A. 模板决策表：bundleID × targetTTY 四分支 + 不支持跳过。
let termTTY = makeTitleScript(bundleID: "com.apple.Terminal", title: "t1", targetTTY: "ttys001")!
check("script A1: Terminal 定向按 tty 寻址 tab", termTTY.contains(#"if tty of t = "ttys001""#))
check("script A2: Terminal 设 custom title + 关四项干扰显示",
      termTTY.contains("set custom title of t to")
      && termTTY.contains("title displays device name to false")
      && termTTY.contains("title displays shell path to false")
      && termTTY.contains("title displays window size to false")
      && termTTY.contains("title displays settings name to false"))
check("script A3: Terminal 定向带 matched/not_found 双哨兵",
      termTTY.contains(#"return "matched""#) && termTTY.contains(#"return "not_found""#))

let termFront = makeTitleScript(bundleID: "com.apple.Terminal", title: "t2", targetTTY: nil)!
check("script A4: Terminal 回退 front window 旧语义（无 repeat 寻址）",
      termFront.contains("selected tab of front window") && !termFront.contains("repeat"))

let itermTTY = makeTitleScript(bundleID: "com.googlecode.iterm2", title: "t3", targetTTY: "ttys002")!
check("script A5: iTerm2 定向按 session tty 寻址", itermTTY.contains(#"if tty of s = "ttys002""#) && itermTTY.contains("set name of s to"))
check("script A6: iTerm2 定向带双哨兵",
      itermTTY.contains(#"return "matched""#) && itermTTY.contains(#"return "not_found""#))

let itermFront = makeTitleScript(bundleID: "com.googlecode.iterm2", title: "t4", targetTTY: nil)!
check("script A7: iTerm2 回退 current session of current window",
      itermFront.contains("set name of current session of current window") && !itermFront.contains("repeat"))

check("script A8: 不支持 bundleID → nil（unsupported_bundle 结局）",
      makeTitleScript(bundleID: "com.apple.Safari", title: "x", targetTTY: "ttys001") == nil)

// B. 铁律不变量：定向禁 window id 寻址；标题转义进模板。
let tricky = #"my \proj "x""#
let trickyScripts = [
    makeTitleScript(bundleID: "com.apple.Terminal", title: tricky, targetTTY: "ttys001")!,
    makeTitleScript(bundleID: "com.apple.Terminal", title: tricky, targetTTY: nil)!,
    makeTitleScript(bundleID: "com.googlecode.iterm2", title: tricky, targetTTY: "ttys001")!,
    makeTitleScript(bundleID: "com.googlecode.iterm2", title: tricky, targetTTY: nil)!,
]
check("script B1: 四分支模板全部不含 window id 寻址（寻址铁律）",
      trickyScripts.allSatisfy { !$0.contains("window id") })
check("script B2: 引号在模板内已转义（AppleScript 字面量安全）",
      trickyScripts.allSatisfy { $0.contains(#"my \\proj \"x\""#) })
check("script B3: 反斜杠先转义（转义顺序防二次转义）",
      escapingAppleScriptString("a\\b") == "a\\\\b" && escapingAppleScriptString(tricky) == #"my \\proj \"x\""#)

// C. verdict 哨兵判定：只有 "matched" 算命中。
check("script C1: matched → 命中",
      isMatchedVerdict("matched"))
check("script C2: not_found/nil/任意值 → 未命中",
      !isMatchedVerdict("not_found") && !isMatchedVerdict(nil) && !isMatchedVerdict("ok"))

// D. Terminal 诊断回读模板：tty 定向 / front 回退。
let diagTTY = makeTerminalDiagnosticScript(targetTTY: "ttys003")
check("script D1: 诊断定向按 tty 寻址 + target_gone 哨兵 + 分隔符",
      diagTTY.contains(#"if tty of t = "ttys003""#) && diagTTY.contains(#"return "target_gone""#) && diagTTY.contains(#""|"#))
let diagFront = makeTerminalDiagnosticScript(targetTTY: nil)
check("script D2: 诊断回退 front window（无 repeat）",
      diagFront.contains("front window") && !diagFront.contains("repeat"))

// MARK: - Summary

print("\nTitleEditorScriptDecisionTests: \(passed + failed) checks, \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
