import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerTerminalContextMatchSeamTests.swift
// 靶：WindowManager.findWindowByTerminalContext 全匹配链（TerminalContextMatchEnvironment
// 注入）——进程树解析、窗口枚举空/单/多、TTY 直取与沿链爬升、TTY 进程匹配、
// iTerm2 会话匹配、Terminal AppleScript 兜底、全败放弃。
// 零 ps fork、零 AppleScript、零 AX。

final class TerminalContextSeamState: @unchecked Sendable {
    var terminalPID: Int32? = 4242
    var windows: [WindowIdentity] = []
    var resolveTTY: [Int32: String] = [:]
    var parentOf: [Int32: Int32] = [:]
    var ttyMatch: WindowIdentity?
    var itermMatch: WindowIdentity?
    var appleScriptMatch: WindowIdentity?
}

extension RunnerHarness {
    func runTerminalContextMatchSeamTests() {
        let state = TerminalContextSeamState()
        func ident(_ id: UInt32) -> WindowIdentity {
            WindowIdentity(windowID: id, pid: 4242, bundleIdentifier: "com.apple.Terminal",
                           appName: "Terminal", windowNumber: Int(id), title: "t")
        }
        let winA = ident(8801)
        let winB = ident(8802)

        func makeEnv() -> TerminalContextMatchEnvironment {
            TerminalContextMatchEnvironment(
                terminalPID: { _ in state.terminalPID },
                runningAppName: { _ in "Terminal" },
                windowsForPID: { _ in state.windows },
                resolveTTY: { pid in state.resolveTTY[pid] },
                psParentPID: { pid in state.parentOf[pid].map(String.init) },
                matchByTTY: { _, _ in state.ttyMatch },
                matchIterm2: { _, _ in state.itermMatch },
                matchTerminalAppleScript: { _, _, _ in state.appleScriptMatch }
            )
        }
        func context(tty: String? = nil, ppid: String? = "900", itermSID: String? = nil) -> TerminalContext {
            TerminalContext(
                termSessionID: nil, itermSessionID: itermSID,
                kittyWindowID: nil, weztermPane: nil,
                tty: tty, ppid: ppid,
                claudeProjectDir: nil, windowID: nil, machineLabel: nil)
        }
        func reset() {
            state.terminalPID = 4242
            state.windows = []
            state.resolveTTY = [:]
            state.parentOf = [:]
            state.ttyMatch = nil
            state.itermMatch = nil
            state.appleScriptMatch = nil
        }
        let wm = WindowManager.shared

        // A. 进程树里找不到终端 app
        reset()
        state.terminalPID = nil
        check("terminalCtx A1: 进程树无终端 app → nil",
              wm.findWindowByTerminalContext(context(), environment: makeEnv()) == nil)

        // B. 终端 PID 无窗口
        reset()
        check("terminalCtx B1: 终端 PID 无窗口 → nil",
              wm.findWindowByTerminalContext(context(), environment: makeEnv()) == nil)

        // C. 单窗口直取
        reset()
        state.windows = [winA]
        check("terminalCtx C1: 单窗口直接命中（PID 级精确）",
              wm.findWindowByTerminalContext(context(), environment: makeEnv()) == winA)

        // D. 多窗口 + ctx 自带 tty → TTY 进程匹配命中
        reset()
        state.windows = [winA, winB]
        state.ttyMatch = winB
        check("terminalCtx D1: 多窗口按 TTY 进程匹配命中",
              wm.findWindowByTerminalContext(context(tty: "ttys001"), environment: makeEnv()) == winB)

        // E. 多窗口无 tty、起点 PID 无 TTY → 沿进程树上爬拿到 TTY 再匹配
        reset()
        state.windows = [winA, winB]
        state.resolveTTY = [5000: "ttys009"]
        state.parentOf = [900: 5000]
        state.ttyMatch = winA
        check("terminalCtx E1: 进程树爬升解析 TTY 后匹配",
              wm.findWindowByTerminalContext(context(), environment: makeEnv()) == winA)

        // F. 多窗口无 TTY → 明示无法区分
        reset()
        state.windows = [winA, winB]
        check("terminalCtx F1: 多窗口无 TTY → nil",
              wm.findWindowByTerminalContext(context(), environment: makeEnv()) == nil)

        // G. TTY 可解析但 TTY 进程匹配失败 → iTerm2 会话 ID 命中
        reset()
        state.windows = [winA, winB]
        state.resolveTTY = [900: "ttys002"]
        state.itermMatch = winB
        check("terminalCtx G1: TTY 匹配失败后 iTerm2 会话命中",
              wm.findWindowByTerminalContext(context(itermSID: "w0t0p0"), environment: makeEnv()) == winB)

        // H. iTerm2 也失败 → Terminal AppleScript 兜底命中
        reset()
        state.windows = [winA, winB]
        state.resolveTTY = [900: "ttys003"]
        state.appleScriptMatch = winA
        check("terminalCtx H1: 前两策略失败后 AppleScript 兜底命中",
              wm.findWindowByTerminalContext(context(itermSID: "w0t0p1"), environment: makeEnv()) == winA)

        // I. 三策略全败 → nil（如实放弃）
        reset()
        state.windows = [winA, winB]
        state.resolveTTY = [900: "ttys004"]
        check("terminalCtx I1: 全部策略失败 → nil",
              wm.findWindowByTerminalContext(context(itermSID: "w0t0p2"), environment: makeEnv()) == nil)

        // J. 无效 ppid（<=1）早退
        reset()
        check("terminalCtx J1: ppid 非法 → nil 早退",
              wm.findWindowByTerminalContext(context(ppid: "1"), environment: makeEnv()) == nil)
    }
}
