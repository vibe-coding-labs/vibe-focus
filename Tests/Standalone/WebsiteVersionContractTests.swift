// Tests/Standalone/WebsiteVersionContractTests.swift
// Verification: 官网版本徽章单一事实源契约（B325）——website LATEST_VERSION 与 AppVersion.releaseVersion 对齐
// Mirrors: website/src/App.tsx · Sources/App/AppVersion.swift
// Run: swift Tests/Standalone/WebsiteVersionContractTests.swift
//
// 背景（2026-11-24）：AppVersion 已 0.1.5 而 website/src/App.tsx 的
// LATEST_VERSION 停在 0.1.4——发版流程无同步步骤，官网「免费下载 v…」徽章与
// Releases 资产名（VibeFocus-<版本>-macos.zip 模板直接拼该常量）静默滞后一版。
// 本契约锁：①两边版本字面量必须相等（发版漏更即红）；②App.tsx 下载文件名模板
// 必须仍引用 LATEST_VERSION（防有人改回硬编码让契约锁失效）；③AppVersion.swift
// 的 releaseVersion 字面量形态健全（x.y.z 三段）。

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

func findRepoRoot() -> String {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 {
        url.deleteLastPathComponent()
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("run.sh").path) {
            return url.path
        }
    }
    fatalError("repo root not found from #filePath")
}

let root = findRepoRoot()

func readFile(_ rel: String) -> String {
    let url = URL(fileURLWithPath: root).appendingPathComponent(rel)
    guard let data = FileManager.default.contents(atPath: url.path),
          let text = String(data: data, encoding: .utf8) else {
        fatalError("cannot read \(rel)")
    }
    return text
}

// ---- 提取两侧版本字面量 ----

let appTsx = readFile("website/src/App.tsx")
let appVersionSwift = readFile("Sources/App/AppVersion.swift")

func extractMatch(_ text: String, pattern: String) -> String? {
    guard let rx = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let m = rx.firstMatch(in: text, range: range),
          m.numberOfRanges >= 2, let r = Range(m.range(at: 1), in: text) else { return nil }
    return String(text[r])
}

let websiteVersion = extractMatch(appTsx, pattern: "const LATEST_VERSION = '([0-9]+\\.[0-9]+\\.[0-9]+)'")
let appVersion = extractMatch(appVersionSwift, pattern: "static let releaseVersion = \"([0-9]+\\.[0-9]+\\.[0-9]+)\"")

print("=== WebsiteVersionContract (B325) ===")
check(websiteVersion != nil, "App.tsx LATEST_VERSION 字面量可解析", "找不到 const LATEST_VERSION = 'x.y.z' 声明")
check(appVersion != nil, "AppVersion.swift releaseVersion 字面量可解析", "找不到 static let releaseVersion = \"x.y.z\" 声明")

if let wv = websiteVersion, let av = appVersion {
    check(wv == av, "官网徽章版本 == 应用版本（发版同步契约）", "website=\(wv) != app=\(av)——发版漏更官网常量")
    // 下载资产名模板必须引用常量而非硬编码版本（否则上面的相等断言守护不到下载链接）
    check(appTsx.contains("VibeFocus-${LATEST_VERSION}-macos.zip"),
          "下载文件名模板引用 LATEST_VERSION 常量", "模板被改动，下载链接可能绕开契约锁")
}

if failed > 0 {
    print("\n\(failed) check(s) FAILED")
    exit(1)
}
print("\nAll \(passed) checks passed.")
