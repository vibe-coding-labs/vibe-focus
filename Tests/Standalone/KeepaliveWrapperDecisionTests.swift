// Tests/Standalone/KeepaliveWrapperDecisionTests.swift
// Verification: keepalive wrapper 崩溃裁决判据（生成物真实行为测试）
// Mirrors: scripts/install-keepalive.sh（write_wrapper 模板 + 决策循环）
// Run: swift Tests/Standalone/KeepaliveWrapperDecisionTests.swift
//
// 背景（2026-09-08 B50）：裁决判据从 (mtime,size) 任一变化收敛为「仅 size 差分」。
// mtime 差分已三次实证误报（2026-07-12 ×3 陈旧复活、2026-09-06 16:43、
// 2026-09-08 02:40 并行派生进程 touch 共享 fatal 文件），全部 size 不变；
// 真崩溃由 CrashSignalHandler 以 O_APPEND 追加内容——size 必增长。
//
// 本测试不镜像决策逻辑：通过 source 生成器（BASH_SOURCE 守卫使 main 不执行）
// 生成真实 wrapper，用注入缝（VIBEFOCUS_KEEPALIVE_OPEN_BIN/_COOLDOWN/_FATAL_LOG/
// _KLOG）以假 open 二进制驱动生成物，穷尽裁决分支。全程不触碰 launchd 与共享
// /tmp 路径；末尾以「真实决策日志字节数不变」作为隔离性总断言。

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
func runShell(_ command: String, environment: [String: String] = [:], timeout: TimeInterval = 30) -> (exit: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", command]
    var env = ProcessInfo.processInfo.environment
    for (k, v) in environment { env[k] = v }
    process.environment = env
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return (-1, "launch error: \(error)")
    }
    let semaphore = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        process.waitUntilExit()
        semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        return (-2, "TIMEOUT after \(timeout)s")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func findRepoRoot() -> String {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 {
        url.deleteLastPathComponent()
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("scripts/install-keepalive.sh").path) {
            return url.path
        }
    }
    fatalError("repo root not found from \(#filePath)")
}

let fm = FileManager.default
let repoRoot = findRepoRoot()
let generator = repoRoot + "/scripts/install-keepalive.sh"
let root = fm.temporaryDirectory.appendingPathComponent("keepalive-wrapper-tests-\(UUID().uuidString)").path
try! fm.createDirectory(atPath: root, withIntermediateDirectories: true)
// 隔离性总断言的基线：整个测试期间真实决策日志不许有任何变化。
let realKlog = "/tmp/vibefocus-keepalive.log"
let realKlogSizeBefore = (try? fm.attributesOfItem(atPath: realKlog)[.size] as? Int) ?? nil

struct Scenario {
    let dir: String
    let klog: String
    let fatal: String
    let counter: String
}

// fatalSetup: 生成 wrapper 前对 fatal 文件的准备命令（@FATAL@ 占位）；nil = 保持缺失。
// fakeOpenBody: 假 open 二进制的行为（@FATAL@/@DIR@ 占位），包装器已附带 invocation 计数。
func makeScenario(_ name: String, fatalSetup: String?, fakeOpenBody: String) -> Scenario {
    let dir = root + "/" + name
    try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let fatal = dir + "/fatal.log"
    let klog = dir + "/klog.log"
    let counter = dir + "/invocations"
    if let cmd = fatalSetup {
        let prepared = runShell(cmd.replacingOccurrences(of: "@FATAL@", with: fatal))
        precondition(prepared.exit == 0, "fatal setup failed: \(prepared.output)")
    }
    let fake = dir + "/fakeopen.sh"
    let body = "#!/bin/bash\necho ran >> \"\(counter)\"\n"
        + fakeOpenBody.replacingOccurrences(of: "@FATAL@", with: fatal).replacingOccurrences(of: "@DIR@", with: dir)
        + "\nexit 0\n"
    try! body.write(toFile: fake, atomically: true, encoding: .utf8)
    _ = runShell("chmod +x \"\(fake)\"")
    let wrapper = dir + "/wrapper.sh"
    let generated = runShell("set -euo pipefail; source \"\(generator)\"; write_wrapper \"\(wrapper)\" \"\(dir)/Fake.app\"")
    precondition(generated.exit == 0, "wrapper generation failed: \(generated.output)")
    return Scenario(dir: dir, klog: klog, fatal: fatal, counter: counter)
}

func runWrapper(_ s: Scenario) -> (exit: Int32, output: String) {
    runShell("bash \"\(s.dir)/wrapper.sh\"", environment: [
        "VIBEFOCUS_KEEPALIVE_FATAL_LOG": s.fatal,
        "VIBEFOCUS_KEEPALIVE_KLOG": s.klog,
        "VIBEFOCUS_KEEPALIVE_COOLDOWN": "1",
        "VIBEFOCUS_KEEPALIVE_OPEN_BIN": s.dir + "/fakeopen.sh",
    ])
}

func invocationCount(_ s: Scenario) -> Int {
    guard let content = try? String(contentsOfFile: s.counter, encoding: .utf8) else { return 0 }
    return content.split(separator: "\n").count
}

func klogLines(_ s: Scenario) -> String {
    (try? String(contentsOfFile: s.klog, encoding: .utf8)) ?? ""
}

print("=== KeepaliveWrapperDecisionTests ===")

// T0 生成器契约：模板含全部注入缝；裁决只允许 size 差分；plist 合法。
let t0 = makeScenario("T0-contract", fatalSetup: nil, fakeOpenBody: "true")
let wrapperText = (try? String(contentsOfFile: t0.dir + "/wrapper.sh", encoding: .utf8)) ?? ""
for seam in ["VIBEFOCUS_KEEPALIVE_OPEN_BIN", "VIBEFOCUS_KEEPALIVE_COOLDOWN", "VIBEFOCUS_KEEPALIVE_FATAL_LOG", "VIBEFOCUS_KEEPALIVE_KLOG"] {
    check(wrapperText.contains(seam), "T0 注入缝在位: \(seam)")
}
check(wrapperText.contains("\"$OPEN_BIN\" -W"), "T0 open 调用走 OPEN_BIN 缝（生产默认 /usr/bin/open）")
check(!wrapperText.contains("/usr/bin/open -W"), "T0 无绕过注入缝的硬编码 open 调用")
check(wrapperText.contains("[[ \"$size_before\" != \"$size_after\" ]]"), "T0 崩溃裁决 = size 差分唯一判据")
let plistCheck = runShell("set -euo pipefail; source \"\(generator)\"; write_plist \"\(t0.dir)/plist.plist\" \"\(t0.dir)/wrapper.sh\"; plutil -lint \"\(t0.dir)/plist.plist\"")
check(plistCheck.exit == 0, "T0 生成的 plist 通过 plutil -lint", plistCheck.output)

// T1 正常退出 + mtime 被触碰（2026-09-08 02:40 实证场景回归锁）：
// size 不变仅 mtime 变 → 不得误判崩溃。
let t1 = makeScenario(
    "T1-mtime-touch-clean-exit",
    fatalSetup: "printf 'x' > @FATAL@ && touch -t 202609070000 @FATAL@",
    fakeOpenBody: "touch \"@FATAL@\""
)
let r1 = runWrapper(t1)
check(r1.exit == 0, "T1 wrapper 正常结束", "exit=\(r1.exit) \(r1.output)")
check(invocationCount(t1) == 1, "T1 单次拉起即收摊（无 60s 冷却重拉）", "invocations=\(invocationCount(t1))")
let lines1 = klogLines(t1)
check(lines1.contains("decision=no-respawn"), "T1 裁决 = no-respawn", lines1)
check(!lines1.contains("respawn-in"), "T1 无 respawn 决策", lines1)
check(lines1.contains("fatal_mtime=") && lines1.contains("fatal_size=1->1"), "T1 取证字段记录 size 1->1", lines1)

// T2 真崩溃：fatal 被 O_APPEND 追加（size 增长）→ respawn；重拉后干净退出 → 收摊。
let t2 = makeScenario(
    "T2-crash-append-respawn",
    fatalSetup: "printf 'x' > @FATAL@",
    fakeOpenBody: "if [[ ! -f \"@DIR@/crashed\" ]]; then echo \"SIGSEGV $(date)\" >> \"@FATAL@\"; touch \"@DIR@/crashed\"; fi"
)
let r2 = runWrapper(t2)
check(r2.exit == 0, "T2 wrapper 正常结束", "exit=\(r2.exit) \(r2.output)")
check(klogLines(t2).contains("decision=respawn-in-1s"), "T2 size 增长判为崩溃 → respawn-in-1s", klogLines(t2))
check(invocationCount(t2) == 2, "T2 冷却后重拉一次", "invocations=\(invocationCount(t2))")
check(klogLines(t2).contains("decision=no-respawn"), "T2 重拉后干净退出收摊", klogLines(t2))

// T3 陈旧记录复活（2026-07-12 / 2026-09-06 16:43 实证场景回归锁）：
// fatal 带旧内容，运行期间 mtime 被外部刷新、size 不变 → 不得误判。
let t3 = makeScenario(
    "T3-stale-record-revival",
    fatalSetup: "python3 -c \"print('stale' * 50, end='')\" > @FATAL@ && touch -t 202607120000 @FATAL@",
    fakeOpenBody: "touch \"@FATAL@\""
)
let r3 = runWrapper(t3)
check(r3.exit == 0, "T3 wrapper 正常结束", "exit=\(r3.exit) \(r3.output)")
check(klogLines(t3).contains("decision=no-respawn"), "T3 陈旧内容 mtime 复活不误判", klogLines(t3))
check(invocationCount(t3) == 1, "T3 单次拉起", "invocations=\(invocationCount(t3))")

// T4 缺失 → 启动期创建空文件：absent 与 size=0 等价，不误判（归档即清空语义）。
let t4 = makeScenario(
    "T4-absent-to-empty",
    fatalSetup: nil,
    fakeOpenBody: ": > \"@FATAL@\""
)
let r4 = runWrapper(t4)
check(r4.exit == 0, "T4 wrapper 正常结束", "exit=\(r4.exit) \(r4.output)")
check(klogLines(t4).contains("fatal_size=0->0"), "T4 absent≡0 等价成立", klogLines(t4))
check(klogLines(t4).contains("decision=no-respawn"), "T4 启动建空文件不误判", klogLines(t4))

// T5 基线：fatal 全程无变化 → no-respawn（决策表基线项）。
let t5 = makeScenario(
    "T5-untouched-baseline",
    fatalSetup: "printf 'old' > @FATAL@",
    fakeOpenBody: "true"
)
let r5 = runWrapper(t5)
check(r5.exit == 0 && klogLines(t5).contains("fatal_size=3->3") && klogLines(t5).contains("decision=no-respawn"),
      "T5 无变化基线 = no-respawn", klogLines(t5))

// T6 缺失 → 追加内容（absent→N）：真崩溃且文件本不存在，必须判崩溃。
let t6 = makeScenario(
    "T6-absent-then-append",
    fatalSetup: nil,
    fakeOpenBody: "if [[ ! -f \"@DIR@/crashed\" ]]; then printf 'SIGSEGV line' >> \"@FATAL@\"; touch \"@DIR@/crashed\"; fi"
)
let r6 = runWrapper(t6)
check(r6.exit == 0, "T6 wrapper 正常结束", "exit=\(r6.exit) \(r6.output)")
check(klogLines(t6).contains("decision=respawn-in-1s"), "T6 absent→N 判为崩溃", klogLines(t6))
check(invocationCount(t6) == 2, "T6 冷却后重拉一次", "invocations=\(invocationCount(t6))")

// 隔离性总断言：测试全程真实决策日志字节不变（测试从未指向共享路径）。
let realKlogSizeAfter = (try? fm.attributesOfItem(atPath: realKlog)[.size] as? Int) ?? nil
check(realKlogSizeBefore == realKlogSizeAfter, "真实决策日志全程未被测试触碰", "\(String(describing: realKlogSizeBefore)) -> \(String(describing: realKlogSizeAfter))")

try? fm.removeItem(atPath: root)

print("")
print("--- Results: \(passed + failed) passed, \(failed) failed ---")
if failed > 0 {
    exit(1)
}
