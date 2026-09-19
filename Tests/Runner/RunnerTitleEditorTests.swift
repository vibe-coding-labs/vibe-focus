// Tests/Runner/RunnerTitleEditorTests.swift
// B215 覆盖堆叠·标题编辑域：TTYWriter（临时文件模拟 TTY 双路 + pid 无 tty 解析）/
// Channels 守卫路（非终端 bundle 拒写、幻影 AX 元素拒写——绝不向真实终端 AppleScript/
// 弹窗，capture* 会拉起 iTerm2/Terminal 同样不碰）。editTitle 是模态 NSAlert 编排，
// 归真机 E2E。

import AppKit
import ApplicationServices
import Foundation
@testable import VibeFocusKit

extension RunnerHarness {

    func runTitleEditorChannelTests() {
        print("\n=== TitleEditorChannels (B215) ===")
        let svc = TitleEditorService.shared

        // TTY 写入·成功路：临时文件当假 TTY（O_WRONLY 打开），OSC 序列原样落盘
        let tmp = NSTemporaryDirectory() + "b215-tty-fake-\(UUID().uuidString)"
        FileManager.default.createFile(atPath: tmp, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let sequence = "\u{1B}]0;B215-title\u{07}"
        check("tty: 写入可打开文件成功", svc.writeTTYSequence(sequence, to: tmp))
        check("tty: 序列逐字节落盘",
              FileManager.default.contents(atPath: tmp) == Data(sequence.utf8))

        // TTY 写入·失败路：路径不存在 → open() 失败 false
        check("tty: 打不开的路径 false",
              svc.writeTTYSequence("x", to: "/nonexistent-b215/tty") == false)

        // TTY 解析：不存在的 pid（99_998 超出 macOS pid 上限）无控制终端——
        // 不用 pid 1：launchd 子进程里本机实测存在带 TTY 的会话进程，机器相关不可靠
        check("tty: 不存在的 pid 无 tty → nil", svc.resolveTTYPath(for: 99_998) == nil)
        // applyViaTTY 的 no_tty 分支
        check("tty: applyViaTTY 无 tty → false", svc.applyViaTTY("B215", pid: 99_998) == false)

        // AppleScript 通道：非终端 bundle 走 unsupported 守卫（不执行任何脚本）
        check("channel: 不支持的 bundle 拒写",
              svc.applyViaAppleScript("B215", bundleID: "com.b215.notaterminal") == false)

        // AX 通道：幻影 pid 的 AX 元素 kAXTitleAttribute 不可设置 → not_settable false
        let bogus = AXUIElementCreateApplication(999_999)
        check("channel: 幻影 AX 元素拒写",
              svc.applyViaAX("B215", to: bogus) == false)
    }
}
