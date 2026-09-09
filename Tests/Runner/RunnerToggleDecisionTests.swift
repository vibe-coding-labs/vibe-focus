import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerToggleDecisionTests.swift — B68：toggle 决策链漂移镜像退役转真身直测。
// 取代 5 个 Standalone 镜像：ToggleSaveValidationTests / ToggleDecisionRoutingTests /
// ToggleRecordTests（测自己的副本，含已废弃的 2×tol 容差判据）+ TerminalAppRegistryTests /
// ShutdownSnapshotTests（源类型已分别死于 ccc11a7 终端列表统一、3566882 restore 重写——纯死镜像）。
// 本文件直锁生产真身：ToggleEngine.shouldRejectSave / WindowManager.decideRestore（守护顺序）/
// ToggleRecord.isValid（Quartz→Cocoa 双包含）/ CoordinateKit.isOnMainScreen 注入式重载。

extension RunnerHarness {
    func runToggleDecisionTests() {
        // ===== shouldRejectSave：save 拒收判定（origFrame 中心落主屏=数据异常） =====
        do {
            let main = CGRect(x: 0, y: 0, width: 1920, height: 1117)
            check("rejectSave: 中心在主屏 → 拒",
                  ToggleEngine.shouldRejectSave(origFrame: CGRect(x: 500, y: 300, width: 800, height: 600),
                                                mainScreenFrame: main))
            check("rejectSave: 副屏在上方（Quartz 负 y）→ 收",
                  !ToggleEngine.shouldRejectSave(origFrame: CGRect(x: 100, y: -800, width: 800, height: 600),
                                                 mainScreenFrame: main))
            check("rejectSave: 副屏在右（x 超界）→ 收",
                  !ToggleEngine.shouldRejectSave(origFrame: CGRect(x: 2000, y: 100, width: 800, height: 600),
                                                 mainScreenFrame: main))
            check("rejectSave: 副屏在下（y 超界）→ 收",
                  !ToggleEngine.shouldRejectSave(origFrame: CGRect(x: 100, y: 1200, width: 800, height: 600),
                                                 mainScreenFrame: main))
            // CGRect.contains 对 max 边排除：中心恰在右缘不属包含
            check("rejectSave: 中心恰在主屏右缘（max 边排除）→ 收",
                  !ToggleEngine.shouldRejectSave(origFrame: CGRect(x: 1520, y: 300, width: 800, height: 600),
                                                 mainScreenFrame: main))
            check("rejectSave: mainScreen nil → 永不拒",
                  !ToggleEngine.shouldRejectSave(origFrame: CGRect(x: 500, y: 300, width: 800, height: 600),
                                                 mainScreenFrame: nil))
        }

        // ===== decideRestore：restore 决策树六 case + 守护顺序 =====
        do {
            let main = CGRect(x: 0, y: 0, width: 1728, height: 1117)
            func record(orig: CGRect, target: CGRect, windowID: UInt32 = 42) -> ToggleRecord {
                ToggleRecord(
                    windowID: windowID, pid: 100, bundleIdentifier: "com.apple.Terminal",
                    appName: "Terminal", origFrame: orig, sourceSpace: 3, sourceDisplay: 1,
                    sourceYabaiDisp: 1, sourceDispSpace: 3, targetFrame: target, targetDisplay: 1,
                    toggledAt: Date(timeIntervalSince1970: 1_800_000_000), sessionID: nil
                )
            }
            // 有效性夹具：orig 在上方副屏（Quartz 负 y 中心），target 在主屏内
            let valid = record(orig: CGRect(x: 100, y: -700, width: 800, height: 600),
                               target: CGRect(x: 100, y: 100, width: 800, height: 600))
            // 损坏夹具：orig 中心在主屏（save 环节漏拦的异常数据）
            let corrupted = record(orig: CGRect(x: 500, y: 300, width: 800, height: 600),
                                   target: CGRect(x: 100, y: 100, width: 800, height: 600))

            check("decide: focusedOnMain=nil → noFocusedWindow",
                  WindowManager.decideRestore(focusedOnMain: nil, recordByWindowID: valid, mainScreenFrame: main)
                  == .noFocusedWindow)
            check("decide: 不在主屏 → moveToMain（短路在前，record/屏参即使齐备也不细查）",
                  WindowManager.decideRestore(focusedOnMain: false, recordByWindowID: nil, mainScreenFrame: nil)
                  == .moveToMain)
            check("decide: 在主屏 + 无 record → noRecord",
                  WindowManager.decideRestore(focusedOnMain: true, recordByWindowID: nil, mainScreenFrame: main)
                  == .noRecord)
            check("decide: 在主屏 + record + mainScreenFrame=nil → noMainScreen",
                  WindowManager.decideRestore(focusedOnMain: true, recordByWindowID: valid, mainScreenFrame: nil)
                  == .noMainScreen)
            check("decide: corrupted record（orig 在主屏）→ corruptedClearWindowID 且携带 windowID",
                  WindowManager.decideRestore(focusedOnMain: true, recordByWindowID: corrupted, mainScreenFrame: main)
                  == .corruptedClearWindowID(42))
            check("decide: valid record → restore",
                  WindowManager.decideRestore(focusedOnMain: true, recordByWindowID: valid, mainScreenFrame: main)
                  == .restore)
        }

        // ===== ToggleRecord.isValid：Quartz→Cocoa 换算后双包含（orig 须离主屏、target 须在主屏） =====
        do {
            let main = CGRect(x: 0, y: 0, width: 1728, height: 1117)
            func record(orig: CGRect, target: CGRect) -> ToggleRecord {
                ToggleRecord(
                    windowID: 1, pid: 100, bundleIdentifier: nil, appName: nil,
                    origFrame: orig, sourceSpace: 1, sourceDisplay: 1,
                    sourceYabaiDisp: 1, sourceDispSpace: 1, targetFrame: target, targetDisplay: 1,
                    toggledAt: Date(timeIntervalSince1970: 1_800_000_000), sessionID: nil
                )
            }
            let onMainTarget = CGRect(x: 100, y: 100, width: 800, height: 600)
            check("isValid: orig 上方副屏 + target 主屏 → valid",
                  record(orig: CGRect(x: 100, y: -700, width: 800, height: 600), target: onMainTarget)
                  .isValid(mainScreenFrame: main))
            check("isValid: orig 中心在主屏 → 损坏",
                  !record(orig: CGRect(x: 500, y: 300, width: 800, height: 600), target: onMainTarget)
                  .isValid(mainScreenFrame: main))
            check("isValid: target 中心越出主屏下缘 → 损坏",
                  !record(orig: CGRect(x: 100, y: -700, width: 800, height: 600),
                          target: CGRect(x: 100, y: 1500, width: 800, height: 600))
                  .isValid(mainScreenFrame: main))
            check("isValid: orig 副屏在下 → valid",
                  record(orig: CGRect(x: 100, y: 1500, width: 800, height: 600), target: onMainTarget)
                  .isValid(mainScreenFrame: main))
            check("isValid: orig 副屏在右 → valid",
                  record(orig: CGRect(x: 2500, y: 300, width: 800, height: 600), target: onMainTarget)
                  .isValid(mainScreenFrame: main))
            check("isValid: orig 副屏在左（Quartz 负 x）→ valid",
                  record(orig: CGRect(x: -1000, y: 300, width: 800, height: 600), target: onMainTarget)
                  .isValid(mainScreenFrame: main))
            // 边界：Quartz midY=0 → Cocoa y=1117 恰落主屏 max 缘（contains 排除）→ target 不在主屏 → 损坏
            check("isValid: target 中心恰在主屏下缘（max 边排除）→ 损坏",
                  !record(orig: CGRect(x: 100, y: -700, width: 800, height: 600),
                          target: CGRect(x: 100, y: -300, width: 800, height: 600))
                  .isValid(mainScreenFrame: main))
        }

        // ===== WindowState.hasToggleState：toggle 态半填充语义（B75：WindowStateTests 死镜像退役转真身） =====
        do {
            func ws(origX: CGFloat?, targetX: CGFloat?) -> WindowState {
                WindowState(
                    windowID: 1, pid: 100, tty: nil,
                    axWindowNumber: nil, appName: nil, bundleIdentifier: nil, title: nil,
                    termSessionID: nil, itermSessionID: nil, kittyWindowID: nil, weztermPane: nil,
                    envWindowID: nil, sessionID: nil, cwd: nil, model: nil,
                    origX: origX, targetX: targetX,
                    isCompleted: false, createdAt: Date(), updatedAt: Date()
                )
            }
            check("toggleState: origX+targetX 齐备 → 有 toggle 态",
                  ws(origX: 100, targetX: 200).hasToggleState)
            check("toggleState: 缺 orig / 缺 target / 全空 → 无 toggle 态",
                  !ws(origX: nil, targetX: 200).hasToggleState
                  && !ws(origX: 100, targetX: nil).hasToggleState
                  && !ws(origX: nil, targetX: nil).hasToggleState)
        }

        // ===== pickFallbackFrontWindow：无窗口前台兜底选取（B93：ToggleFallbackWindowTests 镜像退役转真身） =====
        do {
            func entry(_ id: UInt32, pid: Int32, layer: Int = 0, onScreen: Bool = true,
                       w: CGFloat = 800, h: CGFloat = 600) -> CGWindowEntry {
                var d: [String: Any] = [
                    kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid,
                    kCGWindowLayer as String: layer, kCGWindowIsOnscreen as String: onScreen,
                ]
                if w > 0 { d[kCGWindowBounds as String] = ["X": CGFloat(0), "Y": CGFloat(0), "Width": w, "Height": h] }
                return CGWindowEntry(from: d)!
            }
            let own: pid_t = 999
            let regular: (pid_t) -> NSApplication.ActivationPolicy? = { _ in .regular }
            // z-order 语义：快照首个合格者胜出（CGWindowList 前→后）
            check("fallback: 首个合格窗口入选（z-order 前→后）",
                  pickFallbackFrontWindow(
                    snapshot: [entry(1, pid: 100), entry(2, pid: 200)], ownPID: own,
                    activationPolicyOf: regular)?.windowID == 1)
            // 排除规则：自身 overlay / 非零 layer / 离屏 / 1x1 占位窗 / 非 regular 激活策略
            check("fallback: 自身/非零 layer/离屏/1x1 占位/非 regular 全部跳过",
                  pickFallbackFrontWindow(
                    snapshot: [entry(9, pid: own), entry(10, pid: 100, layer: 5),
                               entry(11, pid: 100, onScreen: false), entry(12, pid: 100, w: 1, h: 1),
                               entry(13, pid: 300), entry(14, pid: 200)],
                    ownPID: own,
                    activationPolicyOf: { $0 == 300 ? .accessory : .regular })?.windowID == 14)
            // 全部不合格 → nil（调用方保持无操作兜底）
            check("fallback: 无合格候选 → nil",
                  pickFallbackFrontWindow(
                    snapshot: [entry(9, pid: own), entry(10, pid: 100, layer: 5)], ownPID: own,
                    activationPolicyOf: regular) == nil)
        }

        // ===== isOnMainScreen(rect, mainScreenFrame:)：中心点归属（注入式重载，与活屏无关） =====
        do {
            let main = CGRect(x: 0, y: 0, width: 1728, height: 1117)
            check("onMain: 主屏内窗口 → true",
                  CoordinateKit.isOnMainScreen(CGRect(x: 100, y: 200, width: 800, height: 600),
                                               mainScreenFrame: main))
            check("onMain: 右侧越界 → false",
                  !CoordinateKit.isOnMainScreen(CGRect(x: 2000, y: 100, width: 800, height: 600),
                                                mainScreenFrame: main))
            check("onMain: 上方（Quartz 负 y）→ false",
                  !CoordinateKit.isOnMainScreen(CGRect(x: 100, y: -800, width: 800, height: 600),
                                                mainScreenFrame: main))
        }
    }
}
