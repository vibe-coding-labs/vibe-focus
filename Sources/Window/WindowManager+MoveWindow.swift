import SwiftUI
import AppKit
import ApplicationServices.HIServices
import Foundation

// MARK: - Window Move Operations
@MainActor
extension WindowManager {

    func runShellCommand(_ executable: String, args: [String]) -> String? {
        // P-INST-195: WindowManager shell 命令执行入口耗时（委托 ShellRunner.run fork P-INST-49；窗口移动相关 shell 调用，≥50ms warn 归因调用点）。
        let rscStart = Date()
        let stdout = ShellRunner.run(executable: executable, arguments: args)?.stdout
        let durMs = elapsedMilliseconds(since: rscStart)
        if durMs >= 50 { log("[WindowManager] runShellCommand slow", level: .warn, fields: ["executable": executable, "durationMs": String(durMs)]) }
        return stdout
    }

    func resolveWindow(identity: WindowIdentity) -> AXUIElement? {
        // P-INST-24: resolveWindow 耗时 + 命中路径（P2 yabai 路径调用，窗口已主屏 space，fast path 应命中；
        // exactID_scan 全量 kAXWindowsAttribute 遍历可能阻塞，归因 fast path miss 的成本）。
        let rwStart = Date()
        let pid = pid_t(identity.pid)
        if let focused = focusedWindow(for: pid),
           let focusedID = windowHandle(for: focused),
           focusedID == identity.windowID {
            log("[WindowManager] resolveWindow result", level: .debug, fields: [
                "windowID": String(identity.windowID), "path": "fast", "found": "true",
                "durationMs": String(elapsedMilliseconds(since: rwStart))
            ])
            return focused
        }

        let windows = allWindows(for: pid)
        if let exactID = windows.first(where: { window in
            guard let currentID = windowHandle(for: window) else { return false }
            return currentID == identity.windowID
        }) {
            log("[WindowManager] resolveWindow result", level: .debug, fields: [
                "windowID": String(identity.windowID), "path": "exactID_scan", "found": "true",
                "windowsChecked": String(windows.count),
                "durationMs": String(elapsedMilliseconds(since: rwStart))
            ])
            return exactID
        }

        if let number = identity.windowNumber,
           let matched = windows.first(where: { windowNumber(for: $0) == number }) {
            log("[WindowManager] resolveWindow result", level: .debug, fields: [
                "windowID": String(identity.windowID), "path": "windowNumber", "found": "true",
                "durationMs": String(elapsedMilliseconds(since: rwStart))
            ])
            return matched
        }

        if let expectedTitle = identity.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !expectedTitle.isEmpty,
           let matched = windows.first(where: {
               self.title(of: $0)?.trimmingCharacters(in: .whitespacesAndNewlines) == expectedTitle
           }) {
            log("[WindowManager] resolveWindow result", level: .debug, fields: [
                "windowID": String(identity.windowID), "path": "title", "found": "true",
                "durationMs": String(elapsedMilliseconds(since: rwStart))
            ])
            return matched
        }

        log("[WindowManager] resolveWindow result", level: .debug, fields: [
            "windowID": String(identity.windowID), "path": "none", "found": "false",
            "durationMs": String(elapsedMilliseconds(since: rwStart))
        ])
        return nil
    }

    @discardableResult
    func moveWindowToMainScreen(
        identity: WindowIdentity,
        reason: WindowMoveReason,
        sessionID: String?,
        operationID: String? = nil,
        knownWindowAX: AXUIElement? = nil
    ) -> Bool {
        let op = operationID ?? makeOperationID(prefix: "move")
        let startedAt = Date()
        log("[WindowManager] moveWindowToMainScreen started", fields: [
            "op": op,
            "windowID": String(identity.windowID),
            "pid": String(identity.pid),
            "reason": reason.rawValue,
            "sessionID": sessionID ?? "nil"
        ])

        guard hasAccessibilityPermission() else {
            log("moveWindowToMainScreen failed: accessibility not granted", level: .error, fields: ["op": op])
            notifyAccessibilityPermissionRequired()
            return false
        }

        // P2: captureSpaceContext 必须在 window move 之前（sourceSpace = 移动前 space）。
        // AX 路径（knownWindowAX != nil）和 yabai 路径都依赖此 sourceSpace 供 restore 移回。
        // 提前到 windowAX 解析前：yabai 路径会先 yabai space move 改变窗口 space，必须在 move 前捕获。
        // P-INST-3: captureSpaceContextMs 诊断移动前 space 上下文捕获（含 queryWindow + querySpaces + visibleSpaceIndex）。
        let captureCtxStart = Date()
        let spaceContext = spaceController.captureSpaceContext(windowID: identity.windowID, operationID: op)
        let captureSpaceContextMs = elapsedMilliseconds(since: captureCtxStart)

        // P2: windowAX 解析分两路径。
        // - AX 路径（knownWindowAX != nil，toggle 入口 AX 解析）：直接复用（省 resolveWindow 的 2 个 AX）。
        // - yabai 路径（knownWindowAX == nil，toggle 入口 yabai query）：先 yabai space move 到主屏
        //   visible space（窗口物理 + space 到主屏，focus=false 不切用户视角），再 resolveWindow
        //   （窗口主屏，AX 不阻塞）。这是消除 toggle 入口 focusedWindow AX 副屏阻塞 1.5s 的核心机制变更。
        //   memory space_switch_regression：yabai space move 是跨屏移动唯一可靠手段（SLS 无权限），
        //   restore 路径已用此机制（ToggleEngine+Restore 主屏→副屏；P2 反向 副屏→主屏）。
        let windowAX: AXUIElement
        var p2YabaiSpaceMoveMs = 0
        // P-INST-3: yabai 路径子阶段计时（visibleSpaceIndex + resolveWindow，AX 路径恒 0）。
        var visibleSpaceIndexMs = 0
        var resolveWindowMs = 0
        if let knownAX = knownWindowAX {
            windowAX = knownAX
        } else {
            // P-INST-3: visibleSpaceIndexMs 诊断主屏 visible space 查询（querySpaces 缓存命中应 <1ms）。
            let visibleSpaceStart = Date()
            let visibleSpace = spaceController.visibleSpaceIndex(forDisplayIndex: 1)?.yabaiIndex
            visibleSpaceIndexMs = elapsedMilliseconds(since: visibleSpaceStart)
            guard let mainScreenSpaceIndex = visibleSpace else {
                log("moveWindowToMainScreen P2 failed: cannot resolve main screen visible space", level: .error, fields: ["op": op])
                return false
            }
            let spaceMoveStart = Date()
            let moved = spaceController.moveWindow(
                identity.windowID,
                toSpace: .yabai(mainScreenSpaceIndex),
                focus: false,
                operationID: op
            )
            p2YabaiSpaceMoveMs = elapsedMilliseconds(since: spaceMoveStart)
            log("[WindowManager] moveWindowToMainScreen P2: yabai space move to main", fields: [
                "op": op, "windowID": String(identity.windowID),
                "mainScreenSpace": String(mainScreenSpaceIndex),
                "moved": String(moved), "spaceMoveMs": String(p2YabaiSpaceMoveMs)
            ])
            // yabai space move 改变窗口 space，clear queryWindow 缓存（否则后续 queryWindow 返回
            // 移动前副屏陈旧值，影响 windowInfo.display 判断）。仅清 windowQueryCache：focus=false 不切
            // 任何 display 的 visible space（visible/index/display 映射不变），spacesQueryCache 保留供
            // 连续 toggle 的 captureSpaceContext 命中省 querySpaces fork（has-focus 字段 SpaceController
            // 侧无消费方）。restore 路径仍用 clearQueryCache（清两个，restore 涉及 space 移回）。
            if moved { spaceController.clearWindowQueryCache() }
            // 窗口已到主屏 space（yabai display 1），AX resolveWindow + frame read 不被副屏阻塞。
            // P-INST-3: resolveWindowMs 诊断窗口主屏后的 AX resolveWindow（focused fast path + 全量遍历 fallback）。
            let resolveStart = Date()
            let resolvedAXOpt = resolveWindow(identity: identity)
            resolveWindowMs = elapsedMilliseconds(since: resolveStart)
            guard let resolvedAX = resolvedAXOpt else {
                log("moveWindowToMainScreen P2 failed: cannot resolve window after space move", level: .error, fields: ["op": op])
                return false
            }
            windowAX = resolvedAX
        }

        // P-INST-3: frameReadMs 诊断 AX frame(of:) 读取（窗口已在主屏 space，应 <20ms；若高说明 AX 跨屏阻塞）。
        let frameReadStart = Date()
        let origFrameOpt = frame(of: windowAX)
        let frameReadMs = elapsedMilliseconds(since: frameReadStart)
        guard let origFrame = origFrameOpt else {
            log("moveWindowToMainScreen failed: cannot read current frame", level: .error, fields: ["op": op])
            return false
        }

        log("[WindowManager] moveWindowToMainScreen: space context captured", fields: [
            "op": op,
            "windowID": String(identity.windowID),
            "sourceSpaceIndex": spaceContext.sourceSpaceIndex.map { String(describing: $0) } ?? "nil",
            "sourceDisplayIndex": spaceContext.sourceDisplayIndex.map { String(describing: $0) } ?? "nil",
            "sourceDisplaySpaceIndex": String(spaceContext.sourceDisplaySpaceIndex ?? -1),
            "origFrame": "\(Int(origFrame.origin.x)),\(Int(origFrame.origin.y)) \(Int(origFrame.width))x\(Int(origFrame.height))"
        ])

        // Skip if already on main screen — 仅 AX 路径检查。
        // P2 yabai 路径已主动把窗口移到主屏 space，但 frame size 可能仍是副屏尺寸（yabai space move
        // 不 resize），需继续 apply 全屏 size，不能 skip。一次性查询窗口信息，后续复用缓存。
        // P-INST-3: queryWindowMs 诊断移动前窗口信息查询（toggle 入口已缓存通常命中 ~0ms，未命中则 fork）。
        let queryWindowStart = Date()
        let windowInfo = spaceController.queryWindow(windowID: identity.windowID)
        let queryWindowMs = elapsedMilliseconds(since: queryWindowStart)
        if knownWindowAX != nil {
            let yabaiDisplay = windowInfo?.display.map { DisplayIdentifier.yabai($0) }
            if let display = yabaiDisplay?.yabaiIndex, display == 1 {
                if let mainScreen = getMainScreen() {
                    let windowCenter = CGPoint(x: origFrame.midX, y: origFrame.midY)
                    if mainScreen.frame.contains(windowCenter) {
                        log("[WindowManager] moveWindowToMainScreen skipped: already on main screen", fields: [
                            "op": op, "windowID": String(identity.windowID)
                        ])
                        return true
                    }
                }
            }
        }

        // P-INST-3: settableCheckMs 诊断两次 AX isAttributeSettable 检查（应 <5ms）。
        let settableStart = Date()
        let posSettable = isAttributeSettable(windowAX, attribute: kAXPositionAttribute)
        let sizeSettable = isAttributeSettable(windowAX, attribute: kAXSizeAttribute)
        let settableCheckMs = elapsedMilliseconds(since: settableStart)
        guard posSettable, sizeSettable else {
            log("moveWindowToMainScreen failed: window attributes not settable", level: .error, fields: ["op": op])
            return false
        }

        guard let mainScreen = getMainScreen() else {
            log("moveWindowToMainScreen failed: cannot determine main screen", level: .error, fields: ["op": op])
            return false
        }

        let targetFrame = axFrame(forVisibleFrameOf: mainScreen)
        let targetDisplayID = displayID(for: mainScreen)
        let targetDisplayIndex = displayIndex(forDisplayID: targetDisplayID)

        // 先 float 脱离 yabai 管理，再 apply 设全屏 size —— 顺序关键。
        // 若窗口被 yabai 管理（tiled），apply 的 AX size write 会被 yabai re-tile 覆盖，
        // 导致 move_to_main 后窗口 height 不全屏（实测 lingdongditu: width 生效到主屏宽 1646，
        // 但 height 卡在副屏高 707，未达主屏全屏高 1079）。先 toggle float 让窗口脱离 yabai，
        // apply 的 size 才能可靠生效。复用第 80 行 windowInfo（缓存命中），避免再次 queryWindow fork。
        // CGWindowID 跨屏移动后不变，提前计算并复用给 setWindowFloat 和 save record。
        let effectiveWindowID = windowHandle(for: windowAX) ?? identity.windowID
        let floatKnownInfo = (effectiveWindowID == identity.windowID) ? windowInfo : nil
        let floatStart = Date()
        spaceController.setWindowFloat(effectiveWindowID, operationID: op, knownWindowInfo: floatKnownInfo)
        let floatMs = elapsedMilliseconds(since: floatStart)

        // AX apply: move window to main screen + set fullscreen size
        // P3.1: positionFirst 按路径选择。
        // - P2 yabai 路径（knownWindowAX==nil）：窗口已 yabai space move 到主屏 space，但物理 frame 仍在副屏
        //   坐标。position 先 + settle：position write 移物理到主屏，settle 等移动，再 size write 主屏全屏 ——
        //   避免 size 被副屏 visibleFrame clamp（sizeDrift=372 半屏 bug）。size readback 在 settle 后窗口物理
        //   主屏，不跨屏阻塞（task #7 回退前提是 P2 前窗口副屏，现已主屏 space）。
        // - AX 路径（knownWindowAX!=nil）：窗口副屏，position 先的 size readback 跨屏阻塞（task #7 回退），
        //   保持 size 先（positionFirst=false）；半屏 clamp 由 postMoveCheck rewrite 兜底。
        // maxAttempts: 3 + 回读验证确保 size 可靠生效，避免单次模式下异步窗口（Electron 等）size 未应用就返回。
        let p2PositionFirst = (knownWindowAX == nil)
        let applyStart = Date()
        guard apply(frame: targetFrame, to: windowAX, operationID: op, stage: "move_to_main", maxAttempts: 3, positionFirst: p2PositionFirst, windowID: effectiveWindowID) else {
            log("moveWindowToMainScreen failed: AX apply failed", level: .error, fields: [
                "op": op, "targetFrame": String(describing: targetFrame)
            ])
            return false
        }
        let applyMs = elapsedMilliseconds(since: applyStart)

        // Post-move 一致性验证（observation 22047：yabai re-tile 覆盖 AX size write → 半屏高 bug）。
        // apply 两阶段重构（0d5378e）后，Phase 2 跨屏 position write 不再回读验证最终 frame；
        // setWindowFloat 的 toggle float 是异步 fork，时序竞争或跨屏 re-tile 可能在 apply 返回后
        // 覆盖 Phase 1 写入的 height（卡在副屏高 707，未达主屏全屏高 ~1079）。9157d08 删除的
        // RestoreWatchdog 曾对抗 yabai 异步 tiling 干扰，move 路径此前无等价保护 —— 这是半屏 bug
        // 反复 reopen 的结构性原因。等 yabai 异步 tiling 稳定后读最终 frame：若 size drift 超阈值
        // 则重写 size（窗口已 floating + 主屏为 float space，重写后稳定）。幂等单次，不进循环；
        // 始终 log finalFrame 供取证。move_to_main 不切 space，AX frame(of:) 读主屏窗口不阻塞。
        let postMoveCheckStart = Date()
        // P3.5: 移除 usleep(30_000) + frame read 改 CGWindowList（非阻塞）。P3.1 positionFirst +
        // setWindowFloat（move_to_main 窗口已 floating，floatMs=0 skipped）后 yabai 无 re-tile，压测
        // sizeDrift 恒 0（postMoveCheck 从未 rewrite），30ms usleep 等 re-tile 冗余。apply phase2 已
        // usleep 25ms + sizeReadbackMatched 验证，紧随的 CGWindowList 读 frame 时 WindowServer 已更新。
        // drift check + rewrite 保留兜底偶发（memory feedback_apply_float_order）。frame read 用 CGWindowList
        // 遵循 memory feedback_toggle_ctxms_cgwindowlist（热路径读 frame 禁 AX）。
        if let finalFrame = cgWindowBounds(for: effectiveWindowID) {
            let sizeDrift = abs(finalFrame.height - targetFrame.height) + abs(finalFrame.width - targetFrame.width)
            log("[WindowManager] moveWindowToMainScreen: post-move frame check", fields: [
                "op": op,
                "windowID": String(effectiveWindowID),
                "finalFrame": "\(Int(finalFrame.origin.x)),\(Int(finalFrame.origin.y)) \(Int(finalFrame.width))x\(Int(finalFrame.height))",
                "targetSize": "\(Int(targetFrame.width))x\(Int(targetFrame.height))",
                "sizeDrift": String(Int(sizeDrift))
            ])
            if sizeDrift > frameTolerance {
                log("[WindowManager] moveWindowToMainScreen: size drifted after move — rewriting size", level: .warn, fields: [
                    "op": op, "windowID": String(effectiveWindowID), "sizeDrift": String(Int(sizeDrift))
                ])
                // 重写最多两次 + 每次回读验证。iTerm2 等窗口异步 clamp height，单次 AX write 未必生效；
                // 窗口此时已在主屏（无跨屏干扰），重写应能突破 clamp。两次后仍 drift 说明 app 硬 clamp，
                // post-rewrite check 日志会暴露 postDrift，供后续用 yabai --resize 等更强手段。不进无限循环。
                for rewriteAttempt in 1...2 {
                    // P-INST-11: 每次 rewrite 耗时（AX write + usleep15 + cgWindowBounds readback，正常 ~17ms）。
                    let rewriteAttemptStart = Date()
                    var rewriteSize = CGSize(width: targetFrame.width, height: targetFrame.height)
                    if let rewriteValue = AXValueCreate(.cgSize, &rewriteSize) {
                        _ = AXUIElementSetAttributeValue(windowAX, kAXSizeAttribute as CFString, rewriteValue)
                    }
                    usleep(15_000)
                    guard let postRewriteFrame = cgWindowBounds(for: effectiveWindowID) else { break }
                    let postDrift = abs(postRewriteFrame.height - targetFrame.height) + abs(postRewriteFrame.width - targetFrame.width)
                    log("[WindowManager] moveWindowToMainScreen: post-rewrite check", fields: [
                        "op": op, "windowID": String(effectiveWindowID),
                        "rewriteAttempt": String(rewriteAttempt),
                        "postRewriteFrame": "\(Int(postRewriteFrame.width))x\(Int(postRewriteFrame.height))",
                        "postDrift": String(Int(postDrift)),
                        "rewriteMs": String(elapsedMilliseconds(since: rewriteAttemptStart))
                    ])
                    if postDrift <= frameTolerance { break }
                }
            }
        }
        let postMoveCheckMs = elapsedMilliseconds(since: postMoveCheckStart)

        // Save toggle record — always save, even when yabai can't determine space
        // (sourceSpace=0 signals "no space info, skip yabai space move on restore")
        let actualTargetFrame = targetFrame
        let sourceSpaceIndex = spaceContext.sourceSpaceIndex ?? .yabai(0)
        let sourceContext = displayContext(for: origFrame)
        let teSourceDisplay: DisplayIdentifier = spaceContext.sourceDisplayIndex ?? sourceContext.index.map { .yabai($0) } ?? .yabai(0)
        let postMoveWindowID = effectiveWindowID
        let saveStart = Date()
        ToggleEngine.shared.save(
            windowID: postMoveWindowID,
            pid: identity.pid,
            bundleIdentifier: identity.bundleIdentifier,
            appName: identity.appName,
            origFrame: origFrame,
            sourceSpace: sourceSpaceIndex,
            sourceDisplay: teSourceDisplay,
            sourceYabaiDisp: spaceContext.sourceDisplayIndex ?? .yabai(0),
            sourceDispSpace: spaceContext.sourceDisplaySpaceIndex ?? 0,
            targetFrame: actualTargetFrame,
            targetDisplay: targetDisplayIndex ?? 0,
            sessionID: sessionID
        )
        let saveMs = elapsedMilliseconds(since: saveStart)

        log("[WindowManager] moveWindowToMainScreen: ToggleRecord saved", fields: [
            "op": op,
            "windowID": String(postMoveWindowID),
            "sourceSpace": String(describing: sourceSpaceIndex),
            "origFrame": "\(Int(origFrame.origin.x)),\(Int(origFrame.origin.y))",
            "targetFrame": "\(Int(actualTargetFrame.origin.x)),\(Int(actualTargetFrame.origin.y))",
            "reason": reason.rawValue,
            "sessionID": sessionID ?? "nil"
        ])

        log("[WindowManager] moveWindowToMainScreen finished", fields: [
            "op": op,
            "windowID": String(effectiveWindowID),
            "durationMs": String(elapsedMilliseconds(since: startedAt)),
            "floatMs": String(floatMs),
            "applyMs": String(applyMs),
            "postMoveCheckMs": String(postMoveCheckMs),
            "saveMs": String(saveMs),
            "p2SpaceMoveMs": String(p2YabaiSpaceMoveMs),
            // P-INST-3: 内部子阶段，解释 durationMs - floatMs - applyMs - postMoveCheckMs - saveMs - p2SpaceMoveMs 的差值。
            "captureSpaceContextMs": String(captureSpaceContextMs),
            "visibleSpaceIndexMs": String(visibleSpaceIndexMs),
            "resolveWindowMs": String(resolveWindowMs),
            "frameReadMs": String(frameReadMs),
            "queryWindowMs": String(queryWindowMs),
            "settableCheckMs": String(settableCheckMs)
        ])
        return true
    }

    private func allWindows(for pid: pid_t) -> [AXUIElement] {
        // P-INST-46: AX 全量窗口枚举耗时（kAXWindowsAttribute；resolveWindow 退化路径，AX 可阻塞；slow-op ≥50ms warn）。
        let allWinStart = Date()
        defer {
            let durMs = elapsedMilliseconds(since: allWinStart)
            if durMs >= 50 {
                log("[WindowManager] allWindows slow AX", level: .warn, fields: ["pid": String(pid), "durationMs": String(durMs)])
            }
        }
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard status == .success, let windowsRef else { return [] }
        return windowsRef as? [AXUIElement] ?? []
    }
}
