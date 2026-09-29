import AppKit
import ApplicationServices.HIServices
import Foundation

// MARK: - AX 直写移动通道（yabai-blind 窗口的安全网 + AX 路径收敛补全）
//
// 背景（2026-09-29，Terminal.app ⌃Q 体验修复拍）：
//
// ## 真机实证（2026-09-29，0.0.95 装机前后对照，须先读再动本通道）
// - 本机 yabai v7 float 布局对 Terminal.app 可见窗口：queryWindow 能查到、
//   `--move abs`/`--resize abs` 真实生效（生产日志 toggle-00000649 移主屏 161ms
//   收敛、grid-create 同证）——「Terminal 窗 yabai 全盲」的旧结论被推翻；
// - yabai-blind 真实存在但属窗口状态子集：窗口处于 yabai 查询失败的状态时
//   （历史取证 `query --window` exit 1 "could not retrieve window details"、
//   setWindowFloat "no AX ref, yabai can't manage"，该态下移动全部静默失败），
//   MoveChannelPolicy（queryWindow==nil → AX 直写）恰好只在这类窗口接管；
// - 管线 AX 路径（toggle 解析走 AX 分支时）历史上 applyAX 两阶段写无 position
//   读回：AX 写异步落地慢时管线假成功、toggle 方向失同步（用户「按了没反应/
//   又被弹回去」的体感来源之一）——本拍补上收敛读回。
//
// ## 通道语义
// position/size 经 AXUIElementSetAttributeValue 直写 + CGWindowList 读回收敛，
// 全程不依赖 yabai。真机探针（2026-09-29，一次性 Terminal 实例）：position/size
// 双属性 settable=true，跨屏 position 写落地 39ms、size 写 33ms——WindowSettle
// 现有收敛预算（400ms）充裕。历史「裸 AX position 跨屏写被 clamp」（+AXWrite.swift
// 头注）是 yabai 管理窗被 re-tile 对抗的教训（60d90fb 时代），对 yabai 管理之外
// 的窗口不成立。
//
// ## 启用边界（必读）
// 仅 yabai-blind（queryWindow==nil）窗口启用 AX 直写：管理窗保持原 yabai 通道，
// 行为零改动（分流决策唯一入口 MoveChannelPolicy，两处消费：moveWindowToFrameViaYabai
// 入口分流 + moveWindowToMainScreen 管线 AX 路径 applyAX 接线——后者同时为 AX
// 路径补上跨屏写收敛，与通道启用无关，凡 yabai-blind 都走收敛读回）。

/// 写入通道选择策略（纯函数，Runner 锁真值表）。
enum MoveChannelPolicy {

    enum Channel: Equatable {
        /// yabai 窗口表认识该窗口：走原 yabai 写通道（行为不变）。
        case yabai
        /// yabai-blind（SA 无法注入的 Apple 自家 app 等）：AX 直写通道。
        case axDirect
    }

    static func channel(yabaiKnowsWindow: Bool) -> Channel {
        yabaiKnowsWindow ? .yabai : .axDirect
    }
}

extension WindowManager {

    /// CGWindowList 原始快照 → 窗口 owner pid（纯函数，Runner 注入假快照锁定）。
    static func ownerPID(fromSnapshot snapshot: [[String: Any]], windowID: UInt32) -> Int32? {
        for entry in snapshot where (entry["kCGWindowNumber"] as? NSNumber)?.uint32Value == windowID {
            if let pid = (entry["kCGWindowOwnerPID"] as? NSNumber)?.int32Value { return pid }
        }
        return nil
    }

    /// AX 窗口数组 → 匹配 CGWindowID 的元素（handle 读取闭包注入，纯函数锁定）。
    static func matchAXWindow(
        _ windows: [AXUIElement],
        windowID: UInt32,
        handle: (AXUIElement) -> UInt32?
    ) -> AXUIElement? {
        windows.first { handle($0) == windowID }
    }

    /// yabai 是否认识该窗口（不认识/已关闭 = false；失败结果有负缓存，TTL 内重复判定 ~0ms）。
    func yabaiKnows(windowID: UInt32) -> Bool {
        spaceController.queryWindow(windowID: windowID, ignoreCache: false) != nil
    }

    /// AX 直写通道：把窗口 frame 写到位并按 CGWindowList 读回收敛。
    ///
    /// ## 场景
    /// - Terminal.app 等_yabai-blind_ 窗口的唯一有效写通道（yabai --move/--resize 全无效）；
    /// - 消费方：moveWindowToFrameViaYabai 入口分流（restore/stuck/rollback/P2 直写全走这里）、
    ///   moveWindowToMainScreen 管线 AX 路径（跨屏 position 写必须收敛验证——历史 apply
    ///   两阶段写无 position 读回，AX 写异步落地慢时管线假成功、toggle 方向失同步）。
    ///
    /// ## 语义对齐 moveWindowToFrameViaYabai
    /// 同 FrameConvergence.writeOrder 写序自适应、同 FrameWriteExecutor 段间等待 +
    /// 收敛轮询（25ms 节拍/400ms 预算/停滞重发），差别仅写入原语：move=AX position
    /// 单发、resize=AX size 单发（收敛由外层轮询如实裁决，不做嵌套收敛）。
    @discardableResult
    func moveWindowToFrameViaAX(
        windowID: UInt32,
        frame: CGRect,
        op: String,
        stage: String,
        sourceVisibleFrame: CGRect?
    ) -> Bool {
        let segStart = Date()
        // 1. owner pid（CGWindowList 原始快照，非阻塞）。查无此窗 = 已关闭/不可见，如实失败。
        guard let pid = Self.ownerPID(fromSnapshot: Self.rawWindowListSnapshot(), windowID: windowID) else {
            log("[WindowManager] moveWindowToFrameViaAX: window not in CGWindowList", level: .warn, fields: [
                "op": op, "stage": stage, "windowID": String(windowID)
            ])
            return false
        }
        // 2. AX 元素解析（kAXWindows 全量 → _AXUIElementGetWindow 精确匹配 CGWindowID）。
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard status == .success, let axWindows = windowsRef as? [AXUIElement] else {
            log("[WindowManager] moveWindowToFrameViaAX: AX windows unavailable", level: .warn, fields: [
                "op": op, "stage": stage, "windowID": String(windowID),
                "pid": String(pid), "axStatus": String(status.rawValue)
            ])
            return false
        }
        guard let ax = Self.matchAXWindow(axWindows, windowID: windowID, handle: { self.windowHandle(for: $0) }) else {
            log("[WindowManager] moveWindowToFrameViaAX: AX window mismatch", level: .warn, fields: [
                "op": op, "stage": stage, "windowID": String(windowID),
                "pid": String(pid), "axWindowCount": String(axWindows.count)
            ])
            return false
        }
        // 3. 双属性可写检查（任一不可写即失败——半可写的窗口写一半留残态）。
        guard isAttributeSettable(ax, attribute: kAXPositionAttribute),
              isAttributeSettable(ax, attribute: kAXSizeAttribute) else {
            log("[WindowManager] moveWindowToFrameViaAX: attributes not settable", level: .warn, fields: [
                "op": op, "stage": stage, "windowID": String(windowID), "pid": String(pid)
            ])
            return false
        }
        // 4. 写序自适应（与 yabai 通道同源 FrameConvergence.writeOrder：收窄先 resize 后
        //    move、放大先 move 后 resize，中间态被源/目标 frame 包含）。
        let preWriteBounds = cgWindowBounds(for: windowID)
        let writeOrder = FrameConvergence.writeOrder(
            currentSize: preWriteBounds?.size,
            targetSize: frame.size,
            sourceVisibleSize: sourceVisibleFrame?.size,
            currentFrame: preWriteBounds,
            sourceVisibleFrame: sourceVisibleFrame
        )
        // 5. 执行（段间等待/收敛轮询/停滞重发全在 FrameWriteExecutor，写原语为 AX）。
        var positionWriteMs = 0
        var sizeWriteMs = 0
        var positionSendCount = 0
        var sizeSendCount = 0
        let outcome = Self.runAXFrameWrite(
            read: { cgWindowBounds(for: windowID) },
            writeMove: {
                positionSendCount += 1
                var writeMs = 0
                _ = self.writePosition(targetFrame: frame, window: ax, op: op, stage: stage, writeMs: &writeMs)
                positionWriteMs += writeMs
            },
            writeResize: {
                sizeSendCount += 1
                let writeStart = Date()
                _ = self.writeSizeWithReadback(
                    targetFrame: frame,
                    window: ax,
                    attempts: 1,
                    settleDelayMicros: WindowSettle.axWriteSettleMicros,
                    op: op,
                    stage: stage,
                    windowID: windowID
                )
                sizeWriteMs += elapsedMilliseconds(since: writeStart)
            },
            target: frame,
            order: writeOrder,
            tolerance: frameTolerance,
            op: op,
            stage: stage,
            windowID: windowID
        )
        let converged: Bool
        switch outcome {
        case .converged:
            converged = true
            log("[WindowManager] moveWindowToFrameViaAX: verified", level: .debug, fields: [
                "op": op, "stage": stage, "windowID": String(windowID)
            ])
        case .mismatched(let attempts, let lastFrame):
            converged = false
            log("[WindowManager] moveWindowToFrameViaAX: frame not converged after \(attempts) attempts", level: .warn, fields: [
                "op": op, "stage": stage, "windowID": String(windowID),
                "lastFrame": lastFrame.map { QuartzRect($0).description } ?? "nil",
                "target": QuartzRect(frame).description,
                "originDrift": lastFrame.map { String(Int(CoordinateKit.originDrift($0.origin, frame.origin))) } ?? "nil",
                "sizeDrift": lastFrame.map { String(Int(CoordinateKit.sizeDrift($0.size, frame.size))) } ?? "nil"
            ])
        case .writeFailed:
            converged = false
            log("[WindowManager] moveWindowToFrameViaAX: write failed", level: .warn, fields: [
                "op": op, "stage": stage, "windowID": String(windowID)
            ])
        }
        log("[WindowManager] moveWindowToFrameViaAX: segment timing", level: .info, fields: [
            "op": op, "stage": stage, "windowID": String(windowID),
            "order": writeOrder == .resizeThenMove ? "resize_then_move" : "move_then_resize",
            "totalMs": String(elapsedMilliseconds(since: segStart)),
            "positionSendCount": String(positionSendCount),
            "positionWriteMs": String(positionWriteMs),
            "sizeSendCount": String(sizeSendCount),
            "sizeWriteMs": String(sizeWriteMs),
            "pid": String(pid)
        ])
        return converged
    }

    /// 执行核心（读写闭包全注入，Runner 假 IO 锁写序与收敛语义；生产闭包由
    /// moveWindowToFrameViaAX 按 AX 原语接线）。pollSleep 注入供 Runner 虚拟时间跑满预算分支。
    static func runAXFrameWrite(
        read: @escaping () -> CGRect?,
        writeMove: @escaping () -> Void,
        writeResize: @escaping () -> Void,
        target: CGRect,
        order: FrameWriteOrder,
        tolerance: CGFloat,
        op: String,
        stage: String,
        windowID: UInt32,
        pollSleep: @escaping (UInt32) -> Void = { usleep(useconds_t($0) * 1_000) }
    ) -> FrameWriteOutcome {
        let executor = FrameWriteExecutor(
            deps: .init(
                read: read,
                applyMove: writeMove,
                applyResizeAdaptive: writeResize,
                applyResizeRobust: writeResize
            ),
            tolerance: tolerance,
            op: op,
            stage: stage,
            windowID: windowID,
            pollSleep: pollSleep
        )
        return executor.run(target: target, order: order).outcome
    }

    /// CGWindowList 原始快照（owner pid 提取用；非阻塞，与 cgWindowListAll 同源）。
    private static func rawWindowListSnapshot() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    }
}
