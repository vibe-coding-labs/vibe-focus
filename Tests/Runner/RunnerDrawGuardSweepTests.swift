import AppKit
import Carbon
import Foundation
import SwiftUI
@testable import VibeFocusKit

// Tests/Runner/RunnerDrawGuardSweepTests.swift — B236 绘制体/按键链/启动失败守卫扫尾
// 靶：InputBubbleViews NSView 绘制体离屏执行（cacheDisplay，不进任何窗口）/
// InputBubbleTextView keyDown 拦截链（Enter/⌘Enter/⌘Y/翻阅回调）/ ClaudeHookServer
// 端口被占启动失败守卫 / InstallInventory 空态与签名分类。
// 纪律：离屏渲染不 orderFront；端口占用用本地 socket 自占自放。

extension RunnerHarness {
    func runDrawGuardSweepTests() {
        runBubbleTextViewKeyChain()
        runBubbleViewOffscreenDraw()
        runHookServerStartFailure()
        runInstallInventoryTail()
    }

    // MARK: - InputBubbleTextView：keyDown 拦截链

    private func runBubbleTextViewKeyChain() {
        let tv = InputBubbleTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))

        func keyEvent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: keyCode
            )!
        }

        var enterCalls: [Bool] = []
        tv.onEnterKey = { commandHeld in enterCalls.append(commandHeld) }

        // 普通 Return → 拦截，commandHeld=false；⌘Return → commandHeld=true
        tv.keyDown(with: keyEvent(keyCode: UInt16(kVK_Return), modifiers: []))
        tv.keyDown(with: keyEvent(keyCode: UInt16(kVK_Return), modifiers: [.command]))
        check("tvKey A1: Return/⌘Return 拦截且 ⌘ 标志透传", enterCalls == [false, true])

        // ⇧Return：IME/换行语义放行 → 不触发 onEnterKey
        tv.keyDown(with: keyEvent(keyCode: UInt16(kVK_Return), modifiers: [.shift]))
        check("tvKey A2: ⇧Return 放行不拦截", enterCalls == [false, true])

        // ⌘Y 历史面板开关：回调消费 → true；未挂回调 → 不崩
        var toggled = 0
        tv.onHistoryPanelToggle = { toggled += 1; return true }
        tv.keyDown(with: keyEvent(keyCode: UInt16(kVK_ANSI_Y), modifiers: [.command]))
        check("tvKey A3: ⌘Y 触发历史面板开关回调", toggled == 1)

        // ↑↓ 翻阅：回调消费
        var prev = 0, next = 0
        tv.onHistoryPrevious = { prev += 1; return true }
        tv.onHistoryNext = { next += 1; return true }
        tv.keyDown(with: keyEvent(keyCode: UInt16(kVK_UpArrow), modifiers: []))
        tv.keyDown(with: keyEvent(keyCode: UInt16(kVK_DownArrow), modifiers: []))
        check("tvKey A4: ↑↓ 翻阅回调各触发一次", prev == 1 && next == 1)
    }

    // MARK: - 绘制体离屏执行（cacheDisplay，无窗口）

    private func runBubbleViewOffscreenDraw() {
        func offscreenRender(_ view: NSView) -> Bool {
            view.frame = NSRect(x: 0, y: 0, width: 160, height: 48)
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep.pixelsWide > 0
        }
        check("draw B1: BubbleCardView draw 离屏执行", offscreenRender(BubbleCardView(frame: .zero)))
        check("draw B2: BubbleSubmitButton draw 离屏执行",
              offscreenRender(BubbleSubmitButton(frame: .zero)))
        check("draw B3: BubbleCloseButton draw 离屏执行",
              offscreenRender(BubbleCloseButton(frame: .zero)))
    }

    // MARK: - ClaudeHookServer：端口被占 → 启动失败守卫

    private func runHookServerStartFailure() {
        // 本地 socket 先占一个临时端口（port 0 → 内核分配），再让 server 尝试同端口
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else {
            check("server C0: socket 创建失败（环境异常跳过）", true)
            return
        }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian)
        let bindOK = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
        guard bindOK == true, listen(sock, 1) == 0 else {
            check("server C0: bind/listen 失败（环境异常跳过）", true)
            return
        }
        var boundAddr = sockaddr_in()
        var len: socklen_t = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameOK = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            getsockname(sock, UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: sockaddr.self), &len)
        } == 0
        let busyPort = nameOK ? Int(CFSwapInt16BigToHost(boundAddr.sin_port)) : 0
        guard busyPort > 0 else {
            check("server C0: 端口读取失败（环境异常跳过）", true)
            return
        }

        let server = ClaudeHookServer.shared
        server.startIfNeeded(port: busyPort, token: "ut100-tok")
        check("server C1: 端口被占 → 启动失败守卫（isRunning=false + 错误文案）",
              !server.isRunning && server.statusDescription == "启动失败")
    }

    // MARK: - InstallInventory：空态行 + 签名分类

    private func runInstallInventoryTail() {
        // 空清单 (0,0) → 走 (_, 0) 警告行（switch 次序：(1,1)/(1,0) 先判）
        let empty = Doctor.installInventoryLines(copies: [], running: [])
        check("inventory D1a: 空清单 → 0 份活体警告行",
              empty.contains("  ⚠️ 检测到 0 份活体安装（疑似双版本）。"))
        // 单份活体 + 无运行 → ✅ 单份安装行
        let single = Doctor.installInventoryLines(
            copies: [Doctor.InstallCopyInfo(path: "/tmp/a.app", bundleID: "b", version: "1",
                                            signature: "unsigned", isBackup: false)],
            running: [])
        check("inventory D1b: 单份无实例 → 单份安装行",
              single.contains("  ✅ 单份安装（当前无运行实例）。"))
        check("inventory D1c: 空运行清单行存在",
              empty.contains("  （当前无运行实例）"))

        // 签名分类：普通文件/不存在路径 → 分类器兜底（codesign 输出随文件而异，
        // 只断言返回非空，具体串（unsigned/adhoc/?）由系统输出决定）
        let dir = NSTemporaryDirectory() + "ut100-sig-\(UUID().uuidString)"
        let plain = dir + "/plain"
        FileManager.default.createFile(atPath: plain, contents: Data([0x01, 0x02]))
        let kind = Doctor.detectSignatureKind(bundlePath: plain)
        check("inventory D2: 普通文件签名分类返回非空",
              !kind.isEmpty)
        let missing = Doctor.detectSignatureKind(bundlePath: dir + "/nonexistent")
        check("inventory D3: 不存在路径分类返回非空兜底",
              !missing.isEmpty)
        try? FileManager.default.removeItem(atPath: plain)
    }
}
