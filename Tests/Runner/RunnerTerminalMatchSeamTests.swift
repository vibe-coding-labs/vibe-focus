import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerTerminalMatchSeamTests.swift
// 靶：TerminalContext 窗口四路匹配（TerminalMatchEnvironment 注入）——
// iTerm2 UUID AppleScript、Terminal TTY AppleScript、TTY 进程命令、ps 解析 TTY。
// 每路覆盖 命中候选 / 合成身份 / 落空 / 输入校验拒绝；零 fork。

final class TerminalMatchSeamState: @unchecked Sendable {
    var outputs: [String?] = []
    var calls: [(exe: String, args: [String])] = []
    var fallback: String?

    func next() -> String? {
        if outputs.isEmpty { return fallback }
        return outputs.removeFirst()
    }
}

extension RunnerHarness {
    func runTerminalMatchSeamTests() {
        let state = TerminalMatchSeamState()
        func environment() -> TerminalMatchEnvironment {
            TerminalMatchEnvironment(runShellCommand: { exe, args in
                state.calls.append((exe, args))
                return state.next()
            })
        }
        func reset(_ outputs: [String?] = []) {
            state.outputs = outputs
            state.calls = []
            state.fallback = nil
        }
        func identity(_ wid: UInt32, pid: Int32 = 999, title: String? = "t") -> WindowIdentity {
            WindowIdentity(
                windowID: wid, pid: pid, bundleIdentifier: "com.googlecode.iterm2",
                appName: "iTerm2", windowNumber: nil, title: title)
        }
        let wm = WindowManager.shared
        let uuid = "w1t2p3:ABCDEF12-3456-7890-ABCD-EF1234567890"

        // A. iTerm2 UUID AppleScript
        reset()
        check("terminalMatch A1: 无 UUID 段 → nil 且零 shell",
              wm.matchiTerm2WindowBySessionID(itermSessionID: "w0t0p0", windows: [],
                                              environment: environment()) == nil
              && state.calls.isEmpty)
        reset()
        check("terminalMatch A2: UUID 非法字符 → nil 且零 shell",
              wm.matchiTerm2WindowBySessionID(itermSessionID: "w0t0p0:has space", windows: [],
                                              environment: environment()) == nil
              && state.calls.isEmpty)
        reset(["555\n"])
        let hit = wm.matchiTerm2WindowBySessionID(
            itermSessionID: uuid, windows: [identity(555)], environment: environment())
        check("terminalMatch A3: AppleScript 命中候选窗 → 返回候选身份",
              hit?.windowID == 555 && hit?.title == "t")
        check("terminalMatch A4: 脚本带 UUID 且走 /bin/bash -c",
              state.calls.count == 1 && state.calls[0].exe == "/bin/bash"
              && state.calls[0].args.count == 2 && state.calls[0].args[0] == "-c"
              && state.calls[0].args[1].contains("ABCDEF12-3456-7890-ABCD-EF1234567890"))
        reset(["777"])
        let synthesized = wm.matchiTerm2WindowBySessionID(
            itermSessionID: uuid, windows: [identity(555)], environment: environment())
        check("terminalMatch A5: 窗不在候选 → 合成 iTerm2 身份并沿用首候选 pid",
              synthesized?.windowID == 777 && synthesized?.pid == 999
              && synthesized?.bundleIdentifier == "com.googlecode.iterm2"
              && synthesized?.title == nil)
        reset([""])
        check("terminalMatch A6: 脚本空输出 → nil",
              wm.matchiTerm2WindowBySessionID(itermSessionID: uuid, windows: [identity(555)],
                                              environment: environment()) == nil)

        // B. Terminal.app TTY AppleScript
        reset()
        check("terminalMatch B1: TTY 格式非法 → nil 且零 shell",
              wm.matchTerminalWindowByAppleScript(tty: "not a tty", terminalPID: 4242,
                                                  windows: [], environment: environment()) == nil
              && state.calls.isEmpty)
        reset(["503"])
        let termHit = wm.matchTerminalWindowByAppleScript(
            tty: "ttys001", terminalPID: 4242, windows: [identity(503, pid: 4242)],
            environment: environment())
        check("terminalMatch B2: TTY 命中候选窗 → 返回候选身份", termHit?.windowID == 503)
        reset(["888"])
        let termSynth = wm.matchTerminalWindowByAppleScript(
            tty: "/dev/ttys001", terminalPID: 4242, windows: [], environment: environment())
        check("terminalMatch B3: 窗不在候选 → 合成身份带 terminalPID",
              termSynth?.windowID == 888 && termSynth?.pid == 4242)
        reset([nil])
        check("terminalMatch B4: osascript 无输出 → nil",
              wm.matchTerminalWindowByAppleScript(tty: "ttys001", terminalPID: 4242,
                                                  windows: [], environment: environment()) == nil)

        // C. TTY 进程命令匹配
        reset([nil])
        check("terminalMatch C1: ps 无输出 → nil",
              wm.matchWindowByTTYProcess(tty: "ttys001", windows: [], environment: environment()) == nil)
        reset(["claude\n"])
        let cmdHit = wm.matchWindowByTTYProcess(
            tty: "ttys001",
            windows: [identity(604, title: "proj — claude")],
            environment: environment())
        check("terminalMatch C2: 命令命中标题 → 返回窗口", cmdHit?.windowID == 604)
        check("terminalMatch C3: ps 参数带 tty 名",
              state.calls.count == 1 && state.calls[0].exe == "/bin/ps"
              && state.calls[0].args == ["-t", "ttys001", "-o", "command="])
        reset(["othercmd\n"])
        check("terminalMatch C4: 命令不匹配标题 → nil",
              wm.matchWindowByTTYProcess(tty: "ttys001", windows: [identity(604, title: "proj — claude")],
                                          environment: environment()) == nil)

        // D. ps 解析 TTY
        reset(["??"])
        check("terminalMatch D1: ps 返回 ?? → nil",
              wm.resolveTTY(forPID: 4242, environment: environment()) == nil)
        reset(["ttys001\n"])
        check("terminalMatch D2: ps 返回 tty 名 → 补全 /dev 前缀",
              wm.resolveTTY(forPID: 4242, environment: environment()) == "/dev/ttys001")
        reset([nil])
        check("terminalMatch D3: ps 无输出 → nil",
              wm.resolveTTY(forPID: 4242, environment: environment()) == nil)
    }
}
