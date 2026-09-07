// Tests/Standalone/BundleIdentityContractTests.swift
// Verification: bundle id 单一事实源契约（B55）——脚本与 Sources 全量对齐 canonical id
// Mirrors: run.sh / install.sh / scripts/{dev-build,package_release,uninstall}.sh / Sources fallback
// Run: swift Tests/Standalone/BundleIdentityContractTests.swift
//
// 背景（2026-09-08）：5 个脚本各自内联写 CFBundleIdentifier，其中 3 个写的是退役 id
// com.vibefocus.app（run.sh/装机现状 = com.openai.vibe-focus）——退役 id 正是 docs 记载的
// 「误启旧副本回到无修复行为」陷阱的制造机（TCC 行、诊断 bundle id 校验全部按 id 分叉）。
// 本契约锁：①任何脚本不得再写退役 id 的 plist 值；②四个 plist 写入方全部为 canonical id；
// ③install.sh 保持纯委派（不得复活第二套构建/装包/签名实现）；④run.sh 版本路径正确；
// ⑤Sources fallback 对齐 canonical；⑥跨进程通知名与 keepalive label 历史契约不受误伤；
// ⑦uninstall 双 id 清理在位。

import Foundation

var passed = 0
var failed = 0
func check(_ cond: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if cond {
        passed += 1
        print("  PASS: \(name)")
    } else {
        failed += 1
        print("  FAIL: \(name) —— \(detail())")
    }
}

@discardableResult
func runShell(_ command: String) -> (exit: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", command]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return (-1, "launch error: \(error)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func findRepoRoot() -> String {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 {
        url.deleteLastPathComponent()
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("run.sh").path) {
            return url.path
        }
    }
    fatalError("repo root not found from \(#filePath)")
}

let root = findRepoRoot()
func content(_ relative: String) -> String {
    (try? String(contentsOfFile: root + "/" + relative, encoding: .utf8)) ?? ""
}

print("=== BundleIdentityContractTests ===")

let canonical = "com.openai.vibe-focus"
let retired = "com.vibefocus.app"

// T1 任何脚本不得写退役 id 的 plist 值（plist 值形态精确匹配，不误伤 keepalive label）。
let t1 = runShell("grep -R -l '<string>\(retired)</string>' \"\(root)\"/*.sh \"\(root)/scripts\" 2>/dev/null")
check(t1.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      "T1 无脚本再写退役 id 的 plist 值", t1.output)

// T2 四个 plist 写入方全部为 canonical id。
for script in ["run.sh", "scripts/build-release.sh", "scripts/dev-build.sh", "scripts/package_release.sh"] {
    check(content(script).contains("<string>\(canonical)</string>"), "T2 canonical id 在位: \(script)")
}

// T3 install.sh 保持纯委派：禁止复活第二套构建/装包/签名实现。
let install = content("install.sh")
check(install.contains("run.sh"), "T3 install.sh 委派 run.sh")
check(!install.contains("swift build"), "T3 install.sh 无构建逻辑")
check(!install.contains("CFBundleIdentifier"), "T3 install.sh 无 plist 模板")
check(!install.contains("codesign"), "T3 install.sh 无签名逻辑")

// T4 run.sh 版本路径正确（B55 修复：Sources/AppVersion.swift 不存在 → VERSION 恒 0.0.0）。
let runSh = content("run.sh")
check(runSh.contains("Sources/App/AppVersion.swift"), "T4 run.sh 版本读取路径正确")
check(!runSh.contains("Sources/AppVersion.swift"), "T4 无断版本路径残留")

// T5 Sources fallback 收敛为 AppIdentity.bundleID 单一事实源（B58：字面量三副本提纯为常量）。
let t5 = runShell("grep -rn '?? \"\(retired)\"' \"\(root)/Sources\" 2>/dev/null")
check(t5.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      "T5 Sources 无退役 id fallback", t5.output)
let t5b = runShell("grep -rn '?? \"\(canonical)\"' \"\(root)/Sources\" 2>/dev/null | wc -l")
check(Int(t5b.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1 == 0,
      "T5 Sources 无字面量 fallback 副本（全部走 AppIdentity.bundleID）", t5b.output)
let t5c = runShell("grep -rn 'AppIdentity.bundleID' \"\(root)/Sources\" 2>/dev/null | wc -l")
check(Int(t5c.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 >= 3,
      "T5 Sources 经 AppIdentity.bundleID 引用 ≥3 处", t5c.output)
let t5d = runShell("grep -n 'static let bundleID = \"\(canonical)\"' \"\(root)/Sources/App/AppIdentity.swift\"")
check(t5d.exit == 0, "T5 AppIdentity 常量定义在位且值为 canonical", t5d.output)

// T6 跨进程通知名历史契约不受误伤（分布式 open-settings 与实例通信按此名）。
check(content("Sources/App/AppDelegate.swift").contains("\(retired).open-settings"),
      "T6 分布式通知名契约保留")

// T7 keepalive LaunchAgent label 历史契约不受误伤。
check(content("scripts/install-keepalive.sh").contains("\(retired).keepalive"),
      "T7 keepalive label 契约保留")

// T8 uninstall 双 id 清理在位（canonical + 退役残留）。
let uninstall = content("scripts/uninstall.sh")
check(uninstall.contains(canonical), "T8 uninstall 清理 canonical id")
check(uninstall.contains(retired), "T8 uninstall 保留退役 id 残留清理")

print("")
print("--- Results: \(passed + failed) passed, \(failed) failed ---")
if failed > 0 {
    exit(1)
}
