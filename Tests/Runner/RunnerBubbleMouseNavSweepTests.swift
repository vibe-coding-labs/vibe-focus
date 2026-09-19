import AppKit
import Foundation
import SwiftUI
@testable import VibeFocusKit

// Tests/Runner/RunnerBubbleMouseNavSweepTests.swift — B237 气泡鼠标链/滚动归零/导航栏扫尾
// 靶：InputBubbleViews 鼠标事件链（关闭/提交/缩放把手）与滚动归零、InputBubblePanel
// canBecomeKey、ClaudeHookServer.makeJSONResponse 响应构造、SettingsTabBar 离屏渲染。
// 纪律：全部离屏/无窗口；缩放把手的位移断言只验「回调触发+有限值」（真实全局光标
// 坐标不可控），不验具体数值。

extension RunnerHarness {
    func runBubbleMouseNavSweepTests() {
        runBubbleMouseChains()
        runBubblePanelAndScroll()
        runServerResponseAndTabBar()
    }

    private func keyEvent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: keyCode
        )!
    }

    // MARK: - 鼠标链：关闭钮 / 提交钮 / 缩放把手

    private func runBubbleMouseChains() {
        // 关闭钮：cursorUpdate 悬停手型 + mouseDown→onClose
        let close = BubbleCloseButton(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        var closed = 0
        close.onClose = { closed += 1 }
        close.cursorUpdate(with: keyEvent(keyCode: 0, modifiers: []))
        close.mouseDown(with: keyEvent(keyCode: 0, modifiers: []))
        check("mouse A1: 关闭钮 mouseDown 触发 onClose", closed == 1)

        // 历史入口钮：按下→抬起全程在钮内 → onOpen（B196 底栏历史入口）
        let history = BubbleHistoryButton(frame: NSRect(x: 0, y: 0, width: 48, height: 20))
        var opened = 0
        history.onOpen = { opened += 1 }
        history.cursorUpdate(with: keyEvent(keyCode: 0, modifiers: []))
        history.mouseDown(with: keyEvent(keyCode: 0, modifiers: []))
        history.mouseUp(with: keyEvent(keyCode: 0, modifiers: []))
        check("mouse A2: 历史钮按下+抬起触发 onOpen", opened == 1)

        // 缩放把手：begin/drag/end 全链（位移数值来自真实光标，只断有限）
        let handle = BubbleResizeHandleView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        var began = 0, ended = 0, dragCount = 0, dragFinite = true
        handle.onBegin = { began += 1 }
        handle.onDrag = { dx, dy in dragCount += 1; if dx.isFinite == false || dy.isFinite == false { dragFinite = false } }
        handle.onEnd = { ended += 1 }
        handle.mouseDown(with: keyEvent(keyCode: 0, modifiers: []))
        handle.mouseDragged(with: keyEvent(keyCode: 0, modifiers: []))
        handle.mouseDragged(with: keyEvent(keyCode: 0, modifiers: []))
        handle.mouseUp(with: keyEvent(keyCode: 0, modifiers: []))
        check("mouse A3: 缩放把手 begin→drag×2→end 全链触发",
              began == 1 && dragCount == 2 && ended == 1 && dragFinite)
        // 未 begin 直接 mouseUp：守卫短路
        handle.mouseUp(with: keyEvent(keyCode: 0, modifiers: []))
        check("mouse A4: 无 begin 的 mouseUp 守卫短路（end 不重复）", ended == 1)
    }

    // MARK: - Panel canBecomeKey + 横向滚动归零

    private func runBubblePanelAndScroll() {
        let panel = InputBubblePanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 50),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered, defer: false)
        check("bubble B1: 面板可成为 key 窗（B172 按键链前提）", panel.canBecomeKey)

        // 横向漂移归零：clip 被带偏 x=7 → normalize 后回零（B178 左缘裁字根治语义；
        // 归一入口在 BubbleCardView，内含 clip/textView 双复位）
        let card = BubbleCardView(frame: NSRect(x: 0, y: 0, width: 240, height: 90))
        let scrollView = NSScrollView(frame: NSRect(x: 8, y: 30, width: 200, height: 50))
        let textView = InputBubbleTextView(frame: scrollView.bounds)
        scrollView.documentView = textView
        card.addSubview(scrollView)
        card.scrollView = scrollView
        scrollView.contentView.scroll(to: NSPoint(x: 7, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        card.normalizeHorizontalOrigin()
        check("bubble B2: normalizeHorizontalOrigin 把 clip x 归零",
              scrollView.contentView.bounds.origin.x == 0)
    }

    // MARK: - makeJSONResponse 响应构造 + SettingsTabBar 渲染

    private func runServerResponseAndTabBar() {
        let server = ClaudeHookServer.shared
        let resp = server.makeJSONResponse(
            statusCode: 418,
            response: ClaudeHookResponse(ok: false, code: "ut100", message: "teapot",
                                         sessionID: "s-1", handled: false))
        check("server C1: makeJSONResponse 状态码透传",
              resp.statusCode == 418)

        // 导航标签栏：constant 绑定离屏渲染（凹槽底+滑动选中块构建链）
        let bar = SettingsTabBar(selection: .constant(.orchestration))
        let rendered = ImageRenderer(content: bar.frame(width: 320, height: 36))
        rendered.scale = 1
        check("nav C2: SettingsTabBar 离屏渲染成功", rendered.nsImage != nil)
    }
}
