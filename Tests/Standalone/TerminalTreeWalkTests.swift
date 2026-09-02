// Tests/Standalone/TerminalTreeWalkTests.swift
// Verification: 进程树向上查找终端 PID 的纯行走核心
// Mirrors: Sources/Support/TerminalRegistry.swift (walkToTerminalPID)
// Run: swift Tests/Standalone/TerminalTreeWalkTests.swift
//
// 背景（playbook 2.16a 第二十刀）：findTerminalPID 的进程树行走（判终端 → 沿父链
// 上溯 → 深度上限/自环/PID>1 三重守卫）内联在 fork 型 I/O 函数中。抽出纯函数
// walkToTerminalPID（parent/isTerminal 两谓词注入），fork 查询留在调用方。
// 本测试穷尽行走分支并锁定调用计数（isTerminal 每轮恰一次、parentPID 仅在
// 未命中轮调用一次——fork 次数是 SessionStart 耗时主因，计数即性能契约）。

import Foundation

// MARK: - Extracted pure logic

/// Mirrors TerminalRegistry.walkToTerminalPID
func mirrorWalkToTerminalPID(
    startPID: Int32,
    parentPID: (Int32) -> Int32?,
    isTerminal: (Int32) -> Bool,
    maxDepth: Int = 10
) -> (pid: Int32?, depth: Int) {
    var currentPID = startPID
    var depth = 0
    for _ in 0..<max(1, maxDepth) {
        depth += 1
        if isTerminal(currentPID) { return (currentPID, depth) }
        guard let ppid = parentPID(currentPID), ppid > 1, ppid != currentPID else { break }
        currentPID = ppid
    }
    return (nil, depth)
}

// MARK: - Test harness

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool) {
    if condition { passed += 1; print("  PASS: \(name)") }
    else { failed += 1; print("  FAIL: \(name)") }
}

/// 链式进程表：pid → ppid
func chain(_ map: [Int32: Int32]) -> (Int32) -> Int32? { { map[$0] } }

// MARK: 1. 命中路径

print("1. 命中路径")

do {
    var parentCalls = 0
    let r = mirrorWalkToTerminalPID(
        startPID: 500,
        parentPID: { _ in parentCalls += 1; return nil },
        isTerminal: { $0 == 500 }
    )
    check("起点即终端 → 命中，depth=1", r.pid == 500 && r.depth == 1)
    check("起点命中时不查父链（parentPID 零次 fork）", parentCalls == 0)
}
do {
    // 进程链：hook(100) → bash(50) → Terminal(10)；10 判定为终端
    let r = mirrorWalkToTerminalPID(
        startPID: 100,
        parentPID: chain([100: 50, 50: 10]),
        isTerminal: { $0 == 10 }
    )
    check("两跳后命中 → pid=10, depth=3", r.pid == 10 && r.depth == 3)
}
do {
    var terminalChecks: [Int32] = []
    let r = mirrorWalkToTerminalPID(
        startPID: 100,
        parentPID: chain([100: 50, 50: 10]),
        isTerminal: { terminalChecks.append($0); return $0 == 10 }
    )
    check("isTerminal 每轮恰一次（检查序 100,50,10）",
          terminalChecks == [100, 50, 10] && r.pid == 10)
}

// MARK: 2. 终止守卫 — 三重条件逐一

print("\n2. 终止守卫")

check("父链断裂（ps 查不到 ppid）→ nil",
      mirrorWalkToTerminalPID(startPID: 100, parentPID: { _ in nil }, isTerminal: { _ in false }).pid == nil)
check("ppid = 1（launchd）→ 守卫截停 → nil",
      mirrorWalkToTerminalPID(startPID: 100, parentPID: chain([100: 1]), isTerminal: { _ in false }).pid == nil)
check("ppid = 0 → 守卫截停 → nil",
      mirrorWalkToTerminalPID(startPID: 100, parentPID: chain([100: 0]), isTerminal: { _ in false }).pid == nil)
check("自环（ppid == 自身）→ nil",
      mirrorWalkToTerminalPID(startPID: 100, parentPID: chain([100: 100]), isTerminal: { _ in false }).pid == nil)
do {
    // A↔B 互环：无深度上限会死循环，10 轮上限截停
    let r = mirrorWalkToTerminalPID(
        startPID: 100,
        parentPID: chain([100: 200, 200: 100]),
        isTerminal: { _ in false }
    )
    check("A↔B 互环 → 深度上限截停 → nil, depth=10", r.pid == nil && r.depth == 10)
}

// MARK: 3. 深度边界

print("\n3. 深度边界")

do {
    // 长链 1←2←…←15（pid i 的父是 i+1），终端在 15，默认上限 10 → 差一步不达
    var map: [Int32: Int32] = [:]
    for i: Int32 in 1...14 { map[i] = i + 1 }
    let r = mirrorWalkToTerminalPID(startPID: 1, parentPID: chain(map), isTerminal: { $0 == 15 })
    check("深度上限截停：终端在第 15 节点、上限 10 → nil, depth=10", r.pid == nil && r.depth == 10)
}
do {
    var map: [Int32: Int32] = [:]
    for i: Int32 in 1...9 { map[i] = i + 1 }
    let r = mirrorWalkToTerminalPID(startPID: 1, parentPID: chain(map), isTerminal: { $0 == 10 })
    check("边界：终端恰在第 10 轮（=maxDepth）→ 命中", r.pid == 10 && r.depth == 10)
}
do {
    let r = mirrorWalkToTerminalPID(
        startPID: 7,
        parentPID: { _ in nil },
        isTerminal: { $0 == 7 },
        maxDepth: 0
    )
    check("maxDepth=0 归一为 1 轮（防 0..<0 空转）：起点命中照常返回", r.pid == 7 && r.depth == 1)
}
do {
    let r = mirrorWalkToTerminalPID(
        startPID: 7,
        parentPID: { _ in 8 },
        isTerminal: { _ in false },
        maxDepth: 0
    )
    check("maxDepth=0 归一为 1 轮：起点不命中 → nil", r.pid == nil && r.depth == 1)
}

// MARK: 4. fork 次数契约（性能契约：SessionStart 耗时主因）

print("\n4. fork 次数契约")

do {
    var parentCalls = 0
    let r = mirrorWalkToTerminalPID(
        startPID: 100,
        parentPID: { _ in parentCalls += 1; return 50 },
        isTerminal: { $0 == 50 }
    )
    check("第 2 轮命中 → parentPID 恰 1 次（每轮未命中才 fork 一次）",
          r.pid == 50 && parentCalls == 1)
}
do {
    var parentCalls = 0
    let r = mirrorWalkToTerminalPID(
        startPID: 100,
        parentPID: { _ in parentCalls += 1; return nil },
        isTerminal: { _ in false }
    )
    check("首轮即断链 → parentPID 恰 1 次后停", r.pid == nil && parentCalls == 1)
}

// MARK: - Summary

print("\n--- Results: \(passed) passed, \(failed) failed ---")
exit(failed > 0 ? 1 : 0)
