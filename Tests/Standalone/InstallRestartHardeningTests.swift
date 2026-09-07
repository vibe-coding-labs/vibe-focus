// Tests/Standalone/InstallRestartHardeningTests.swift
// Verification: install.sh 重启竞态加固（B54）——等待原语真实行为 + source 模板库隔离
// Mirrors: install.sh（wait_for_process_exit 轮询原语 + BASH_SOURCE 守卫）
// Run: swift Tests/Standalone/InstallRestartHardeningTests.swift
//
// 背景（2026-09-08）：install.sh 旧实现 pkill（异步）后立即 open，旧进程未死透时
// LaunchServices 返回 -609（LSOpenURLsWithCompletionHandler failed），新包当场没被
// 拉起。加固=pgrep 取 pid → pkill → wait_for_process_exit 轮询（0.2s 间隔）→ open。
//
// 本测试不镜像逻辑：source 真实 install.sh（BASH_SOURCE 守卫使 main 不执行），
// 对 wait_for_process_exit 原语做生成物级行为测试。全程不构建、不触碰
// ~/Applications、不 pkill 真实应用。

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
func runShell(_ command: String, timeout: TimeInterval = 30) -> (exit: Int32, output: String) {
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
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("run.sh").path) {
            return url.path
        }
    }
    fatalError("repo root not found from \(#filePath)")
}

let fm = FileManager.default
let repoRoot = findRepoRoot()
// B55：等待原语迁入 run.sh（重启的生产事实源）；install.sh 降级为委派器。
let installScript = repoRoot + "/run.sh"

print("=== InstallRestartHardeningTests ===")

// T0 source 守卫：source 只定义函数、零副作用（无构建输出、无主流程）。
let t0 = runShell("set -euo pipefail; source \"\(installScript)\"; echo \"FUNCS=$(type -t wait_for_process_exit)\"")
check(t0.exit == 0, "T0 source run.sh 不触发主流程", t0.output)
check(!t0.output.contains("release 二进制") && !t0.output.contains("安装运行"), "T0 source 无构建/安装副作用", t0.output)
check(t0.output.contains("FUNCS=function"), "T0 等待原语以 function 形式在位", t0.output)

// T1 已死 pid：立即返回 0（先拉起再杀掉，确定 pid 存在过且已死）。
let t1 = runShell("""
set -euo pipefail
source "\(installScript)"
"\(repoRoot)/Tests/Standalone/InstallRestartHardeningTests.sleeper" 30 &
victim=$!
kill -9 "$victim" 2>/dev/null || true
wait "$victim" 2>/dev/null || true
if wait_for_process_exit 2 "$victim"; then echo DEAD_OK; else echo DEAD_TIMEOUT; fi
""")
check(t1.exit == 0 && t1.output.contains("DEAD_OK"), "T1 已死 pid 立即通过", t1.output)

// T2 进程在超时窗口内退出 → 返回 0，且总耗时受控（<4s）。
let t2 = runShell("""
set -euo pipefail
source "\(installScript)"
sleep 0.6 &
victim=$!
SECONDS=0
if wait_for_process_exit 5 "$victim"; then rc=0; else rc=1; fi
echo "RC=$rc ELAPSED=$SECONDS"
""")
check(t2.output.contains("RC=0"), "T2 窗口内退出 → 0", t2.output)
let t2Elapsed = t2.output.split(separator: "\n").last.map { String($0) } ?? ""
let t2Seconds = t2Elapsed.split(separator: "ELAPSED=").last.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 99
check(t2Seconds <= 4, "T2 总耗时受控", t2Elapsed)

// T3 超时路径：进程不退 → 返回 1，耗时达到下限；测试自清理幸存进程。
let t3 = runShell("""
set -euo pipefail
source "\(installScript)"
sleep 4 &
victim=$!
SECONDS=0
if wait_for_process_exit 1 "$victim"; then rc=0; else rc=1; fi
echo "RC=$rc ELAPSED=$SECONDS"
kill -9 "$victim" 2>/dev/null || true
""")
check(t3.output.contains("RC=1"), "T3 不退出进程 → 超时返回 1", t3.output)
let t3Elapsed = t3.output.split(separator: "\n").first { $0.contains("ELAPSED=") }.map { String($0) } ?? ""
check(t3Elapsed.contains("ELAPSED=1") || t3Elapsed.contains("ELAPSED=2"), "T3 超时耗时在 1~2s 量级（0.2s 轮询粒度）", t3Elapsed)

// T4 多 pid 混合：一死一活（活进程随即退出）→ 全部退出返回 0。
let t4 = runShell("""
set -euo pipefail
source "\(installScript)"
sleep 30 & dead=$!
kill -9 "$dead" 2>/dev/null || true
wait "$dead" 2>/dev/null || true
sleep 0.4 & dying=$!
if wait_for_process_exit 5 "$dead" "$dying"; then echo MIXED_OK; else echo MIXED_TIMEOUT; fi
kill -9 "$dying" 2>/dev/null || true
""")
check(t4.exit == 0 && t4.output.contains("MIXED_OK"), "T4 多 pid 全退 → 0", t4.output)

print("")
print("--- Results: \(passed + failed) passed, \(failed) failed ---")
if failed > 0 {
    exit(1)
}
