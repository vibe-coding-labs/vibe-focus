import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerTerminalContextMatchTests.swift — B226：终端上下文窗口匹配族直测
// （B125 动态绑定的热路径，此前 0 计数行：TTTY/UUID 白名单校验分支、ps 解析、
// findWindowByTerminalContext 早退门）。osascript/ps 路径为只读真实调用（不写不弹），
// 无匹配断言走「垃圾输入 → nil」与「不存在目标 → nil」，不依赖具体终端状态。

extension RunnerHarness {
    func runTerminalContextMatchTests() {
        let wm = WindowManager.shared

        // ===== findWindowByTerminalContext 早退门（无进程树遍历、无写路径） =====
        do {
            func ctx(_ ppid: String?) -> TerminalContext {
                TerminalContext(termSessionID: nil, itermSessionID: nil, kittyWindowID: nil,
                                weztermPane: nil, tty: nil, ppid: ppid,
                                claudeProjectDir: nil, windowID: nil, machineLabel: nil)
            }
            check("termCtx: 无 PPID → nil（无法定位进程树）",
                  wm.findWindowByTerminalContext(ctx(nil)) == nil)
            check("termCtx: PPID=1（launchd）→ 树中无终端 → nil",
                  wm.findWindowByTerminalContext(ctx("1")) == nil)
        }

        // ===== matchiTerm2WindowBySessionID：解析/白名单/无匹配三分支 =====
        do {
            check("termCtx: ITERM_SESSION_ID 无 UUID 段 → nil",
                  wm.matchiTerm2WindowBySessionID(itermSessionID: "garbage", windows: []) == nil)
            check("termCtx: UUID 段含非法字符 → 白名单拦下 nil（防注入）",
                  wm.matchiTerm2WindowBySessionID(
                    itermSessionID: "w1t2p3:zzzz-not-hex-uuid", windows: []) == nil)
            // 合法 hex UUID 但不存在 → 真实 osascript 只读查询 → 无匹配 nil
            check("termCtx: 合法 UUID 不存在 → osascript 无匹配 nil",
                  wm.matchiTerm2WindowBySessionID(
                    itermSessionID: "w0t0p0:00000000-0000-0000-0000-000000000000", windows: []) == nil)
        }

        // ===== matchTerminalWindowByAppleScript：TTTY 白名单 + 无匹配 =====
        do {
            check("termCtx: 非法 TTY 格式 → 白名单拦下 nil（防注入）",
                  wm.matchTerminalWindowByAppleScript(tty: "C:\\evil", terminalPID: 1, windows: []) == nil)
            check("termCtx: 不存在的 ttys998 → osascript 无匹配 nil",
                  wm.matchTerminalWindowByAppleScript(tty: "ttys998", terminalPID: 1, windows: []) == nil)
        }

        // ===== matchWindowByTTYProcess：ps 解析链 =====
        do {
            check("termCtx: 不存在的 TTY → ps 无输出 nil",
                  wm.matchWindowByTTYProcess(tty: "ttys997", windows: []) == nil)
            // 真实 TTY 解析路径：候选空表 → 解析成功也 nil（parse 分支覆盖）
            let ownTTY = wm.resolveTTY(forPID: ProcessInfo.processInfo.processIdentifier)
            if let tty = ownTTY {
                check("termCtx: 真实 TTY + 空候选表 → nil（解析链贯通）",
                      wm.matchWindowByTTYProcess(tty: tty, windows: []) == nil)
            }
        }

        // ===== resolveTTY：无 TTY 进程回落 =====
        do {
            check("termCtx: launchd 无 TTY → nil", wm.resolveTTY(forPID: 1) == nil)
        }

        // ===== findWindowsForPID：真实进程只读扫描 =====
        do {
            // Dock 常驻且有窗口（layer0 主屏徽标层）；空表也算过（结构契约：不炸、类型对）
            let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
            if let dockPID {
                let windows = wm.findWindowsForPID(dockPID)
                check("termCtx: Dock PID 窗口扫描贯通（列表或空均不炸）",
                      windows.allSatisfy { $0.pid == dockPID || $0.pid == 0 })
            }
        }
    }
}
