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
            // frame 取值器（B103：HookWindowModels 剩余计算属性——orig/target 各四元组齐备才成帧）
            func wsFull(orig: CGRect?, target: CGRect?) -> WindowState {
                WindowState(
                    windowID: 1, pid: 100, tty: nil,
                    axWindowNumber: nil, appName: nil, bundleIdentifier: nil, title: nil,
                    termSessionID: nil, itermSessionID: nil, kittyWindowID: nil, weztermPane: nil,
                    envWindowID: nil, sessionID: nil, cwd: nil, model: nil,
                    origX: orig?.origin.x, origY: orig?.origin.y, origW: orig?.width, origH: orig?.height,
                    targetX: target?.origin.x, targetY: target?.origin.y,
                    targetW: target?.width, targetH: target?.height,
                    isCompleted: false, createdAt: Date(), updatedAt: Date()
                )
            }
            check("toggleState: originalFrame/targetFrame 四元组成帧、缺 target 侧 targetFrame 为 nil",
                  wsFull(orig: CGRect(x: 1, y: 2, width: 3, height: 4), target: CGRect(x: 5, y: 6, width: 7, height: 8)).originalFrame == CGRect(x: 1, y: 2, width: 3, height: 4)
                  && wsFull(orig: CGRect(x: 1, y: 2, width: 3, height: 4), target: CGRect(x: 5, y: 6, width: 7, height: 8)).targetFrame == CGRect(x: 5, y: 6, width: 7, height: 8)
                  && wsFull(orig: CGRect(x: 1, y: 2, width: 3, height: 4), target: nil).targetFrame == nil)
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

        // ===== B191 ToggleCoreOutcome：核心段结果 → 主线程收尾日志字段装配（Sendable 值类型跨队列） =====
        do {
            let outcome = ToggleCoreOutcome(
                mode: "move_to_main",
                coreOpMs: 283,
                context: ["op": "toggle-001", "source": "carbon_hotkey",
                          "frontBefore": "com.apple.Terminal", "ctxMs": "612", "snapshotMs": "1"]
            )
            let finished = outcome.finishedFields(frontAfter: "com.apple.Terminal")
            check("B191 core outcome: finished 字段 = context 全量 + frontAfter + coreOpMs",
                  finished["op"] == "toggle-001" && finished["ctxMs"] == "612"
                  && finished["frontAfter"] == "com.apple.Terminal" && finished["coreOpMs"] == "283")
            check("B191 core outcome: context 不被 finished 装配污染（值类型语义）",
                  outcome.context["frontAfter"] == nil && outcome.context["coreOpMs"] == nil)
            let changed = outcome.frontmostChangeFields(frontAfter: "com.google.Chrome")
            check("B191 core outcome: 前台变化告警字段五键齐全",
                  changed == ["op": "toggle-001", "source": "carbon_hotkey", "mode": "move_to_main",
                              "frontBefore": "com.apple.Terminal", "frontAfter": "com.google.Chrome"])
            check("B191 core outcome: 缺键 context 回退 nil 字面量",
                  ToggleCoreOutcome(mode: "restore", coreOpMs: 1, context: [:])
                    .frontmostChangeFields(frontAfter: "x")["op"] == "nil")
        }
    }
}

// MARK: - B234：stuck 解堵目标屏选择（提纯自 moveStuckWindowToSecondaryScreen 的谓词）

extension RunnerHarness {
    func runStuckRoutingTests() {
        func space(_ display: Int?, _ visible: Bool) -> YabaiSpaceInfo {
            YabaiSpaceInfo(id: display, index: 1, display: display, isVisible: visible)
        }
        // nil/空 spaces → nil（回退 NSScreen 兜底）
        check("stuckRoute: spaces nil → nil", ToggleFocusBranching.stuckTargetYabaiDisplay(currentDisplay: 1, spaces: nil) == nil)
        check("stuckRoute: spaces 空 → nil", ToggleFocusBranching.stuckTargetYabaiDisplay(currentDisplay: 1, spaces: []) == nil)
        // 全部同屏 → nil（单屏机不解堵）
        check("stuckRoute: 全部同屏 → nil",
              ToggleFocusBranching.stuckTargetYabaiDisplay(currentDisplay: 1, spaces: [space(1, true), space(1, true)]) == nil)
        // 异屏但无可见 space → nil（不可见 space 不能当投递目标）
        check("stuckRoute: 异屏但不可见 → nil",
              ToggleFocusBranching.stuckTargetYabaiDisplay(currentDisplay: 1, spaces: [space(2, false)]) == nil)
        // 异屏且可见 → 命中该 display
        check("stuckRoute: 异屏可见 → 命中",
              ToggleFocusBranching.stuckTargetYabaiDisplay(currentDisplay: 1, spaces: [space(2, true)]) == 2)
        // 多候选按 yabai 枚举序取首个
        check("stuckRoute: 多候选取枚举首序",
              ToggleFocusBranching.stuckTargetYabaiDisplay(currentDisplay: 1, spaces: [space(1, false), space(3, true), space(2, true)]) == 3)
        // currentDisplay nil（查询失败）：任何非 nil display 都异于 nil → 首个可见命中
        check("stuckRoute: currentDisplay nil → 首个可见屏",
              ToggleFocusBranching.stuckTargetYabaiDisplay(currentDisplay: nil, spaces: [space(2, true)]) == 2)
    }
}

extension RunnerHarness {
    /// B232：move-to-main 决策层的终端身份判定 wrapper 直测（委托 TerminalRegistry 单一事实源）。
    func runMoveToMainIdentityWrapperTests() {
        print("\n=== MoveToMainIdentityWrapper (B232) ===")
        check("wrapper: 终端名命中透传",
              HookEventHandler.isTerminalOrIDEApp(appName: "iTerm2", bundleIdentifier: nil))
        check("wrapper: IDE bundleID 命中透传",
              HookEventHandler.isTerminalOrIDEApp(appName: nil, bundleIdentifier: "com.microsoft.VSCode"))
        check("wrapper: 未知身份 false 透传",
              !HookEventHandler.isTerminalOrIDEApp(appName: "Safari", bundleIdentifier: "com.apple.Safari"))
    }
}

extension RunnerHarness {
    /// 0.1.1：单屏机 ⌃Q 同屏最大化——displayCount 进决策/路由维度的真身直测。
    /// 语义：单屏 record 有效性 = 双中心都在主屏（orig=网格单元帧是常态非损坏）；
    /// 路由 = 非 restore 一律 singleDisplayMaximize；save 拒收门对单屏记录绕行。
    func runSingleDisplayToggleTests() {
        print("\n=== SingleDisplayToggle (0.1.1) ===")
        let main = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        func record(orig: CGRect, target: CGRect, windowID: UInt32 = 77) -> ToggleRecord {
            ToggleRecord(
                windowID: windowID, pid: 100, bundleIdentifier: "com.apple.Terminal",
                appName: "Terminal", origFrame: orig, sourceSpace: 1, sourceDisplay: 1,
                sourceYabaiDisp: 1, sourceDispSpace: 1, targetFrame: target, targetDisplay: 1,
                toggledAt: Date(timeIntervalSince1970: 1_800_000_000), sessionID: nil
            )
        }
        let onMainTarget = CGRect(x: 100, y: 100, width: 800, height: 600)
        // 单屏最大化记录夹具：orig=网格单元帧（主屏内），target=满屏帧（主屏内）
        let singleMaximized = record(orig: CGRect(x: 60, y: 80, width: 840, height: 500),
                                     target: CGRect(x: 0, y: 0, width: 1728, height: 1117))
        // 双屏时代陈旧记录：orig 指向已拔副屏（Quartz 负 y），target 主屏
        let staleDual = record(orig: CGRect(x: 100, y: -700, width: 800, height: 600),
                               target: onMainTarget)

        // ===== isValid：displayCount 维度真值表 =====
        do {
            check("sdValid: 单屏 orig/target 双中心在主屏 → valid（单屏最大化记录是常态）",
                  singleMaximized.isValid(mainScreenFrame: main, displayCount: 1))
            check("sdValid: 单屏 orig 指向已拔副屏 → 损坏（restore 直写会落屏外）",
                  !staleDual.isValid(mainScreenFrame: main, displayCount: 1))
            check("sdValid: 单屏 target 中心越出主屏 → 损坏",
                  !record(orig: CGRect(x: 60, y: 80, width: 840, height: 500),
                          target: CGRect(x: 3000, y: 100, width: 800, height: 600))
                  .isValid(mainScreenFrame: main, displayCount: 1))
            // 双屏旧规则不被放宽（回归锁）
            check("sdValid: 双屏 orig 在主屏 → 损坏（旧判据保持）",
                  !singleMaximized.isValid(mainScreenFrame: main, displayCount: 2))
            check("sdValid: 双屏 orig 副屏 + target 主屏 → valid（旧判据保持）",
                  staleDual.isValid(mainScreenFrame: main, displayCount: 2))
            check("sdValid: 缺省签名 = 双屏语义（既有调用方零漂移）",
                  record(orig: CGRect(x: 60, y: 80, width: 840, height: 500), target: onMainTarget)
                  .isValid(mainScreenFrame: main)
                  == record(orig: CGRect(x: 60, y: 80, width: 840, height: 500), target: onMainTarget)
                  .isValid(mainScreenFrame: main, displayCount: 2))
        }

        // ===== decideRestore：displayCount=1 分支 =====
        do {
            check("sdDecide: 单屏 + 单屏最大化记录 → restore（⌃Q 二次回退原尺寸）",
                  WindowManager.decideRestore(focusedOnMain: true, recordByWindowID: singleMaximized,
                                              mainScreenFrame: main, displayCount: 1)
                  == .restore)
            check("sdDecide: 单屏 + 双屏陈旧记录 → corruptedClearWindowID（清掉后按单屏语义重建）",
                  WindowManager.decideRestore(focusedOnMain: true, recordByWindowID: staleDual,
                                              mainScreenFrame: main, displayCount: 1)
                  == .corruptedClearWindowID(77))
            check("sdDecide: 单屏 + 无记录 → noRecord（路由层转最大化）",
                  WindowManager.decideRestore(focusedOnMain: true, recordByWindowID: nil,
                                              mainScreenFrame: main, displayCount: 1)
                  == .noRecord)
            check("sdDecide: 焦点未知 → noFocusedWindow（不随屏数变化）",
                  WindowManager.decideRestore(focusedOnMain: nil, recordByWindowID: singleMaximized,
                                              mainScreenFrame: main, displayCount: 1)
                  == .noFocusedWindow)
            check("sdDecide: 双屏 + orig 在主屏 → corrupted（displayCount 显式 2 回归锁）",
                  WindowManager.decideRestore(focusedOnMain: true, recordByWindowID: singleMaximized,
                                              mainScreenFrame: main, displayCount: 2)
                  == .corruptedClearWindowID(77))
        }

        // ===== route：displayCount 维度分支穷尽 =====
        do {
            check("sdRoute: 单屏 restore → restore",
                  WindowManager.route(for: .restore, onMainScreen: true, displayCount: 1) == .restore)
            check("sdRoute: 单屏 noRecord → singleDisplayMaximize",
                  WindowManager.route(for: .noRecord, onMainScreen: true, displayCount: 1)
                  == .singleDisplayMaximize)
            check("sdRoute: 单屏 moveToMain（解析层异常态）→ 同屏最大化兜底",
                  WindowManager.route(for: .moveToMain, onMainScreen: false, displayCount: 1)
                  == .singleDisplayMaximize)
            check("sdRoute: 单屏 corrupted → singleDisplayMaximize",
                  WindowManager.route(for: .corruptedClearWindowID(7), onMainScreen: nil, displayCount: 1)
                  == .singleDisplayMaximize)
            check("sdRoute: 单屏 noMainScreen → singleDisplayMaximize",
                  WindowManager.route(for: .noMainScreen, onMainScreen: true, displayCount: 1)
                  == .singleDisplayMaximize)
            check("sdRoute: 双屏 noRecord + 在主屏 → moveSecondaryStuck（旧路由回归锁）",
                  WindowManager.route(for: .noRecord, onMainScreen: true, displayCount: 2)
                  == .moveSecondaryStuck)
            check("sdRoute: 旧双参签名委托 = displayCount 2 语义",
                  WindowManager.route(for: .noRecord, onMainScreen: nil)
                  == WindowManager.route(for: .noRecord, onMainScreen: nil, displayCount: 2))
            check("sdRoute: logName = single_display_maximize",
                  WindowManager.ToggleRoute.singleDisplayMaximize.logName == "single_display_maximize")
        }

        // ===== save：单屏记录绕行 orig-on-main 拒收门（store 注入真身落库） =====
        do {
            let dir = "/tmp/vibefocus-sdtoggle-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let engine = ToggleEngine(store: WindowStateStore(dbPath: dir + "/sdtoggle.db"))

            // 单屏最大化记录：orig 在主屏内 + singleDisplay: true → 落库
            let orig = CGRect(x: 60, y: 80, width: 840, height: 500)
            let target = CGRect(x: 0, y: 0, width: 1728, height: 1117)
            engine.save(windowID: 7701, pid: 1000, bundleIdentifier: "com.apple.Terminal",
                        appName: "Terminal", origFrame: orig,
                        sourceSpace: .yabai(1), sourceDisplay: .yabai(1), sourceYabaiDisp: .yabai(1),
                        sourceDispSpace: 1, targetFrame: target, targetDisplay: 1,
                        sessionID: nil, reason: .manualHotkey, singleDisplay: true)
            var savedOK = false
            if let r = engine.load(windowID: 7701) {
                savedOK = r.origFrame == orig && r.targetFrame == target
                    && r.reason == WindowMoveReason.manualHotkey.rawValue
            }
            check("sdSave: singleDisplay 绕行拒收门 → 记录落库可回读", savedOK)

            // 默认签名（多屏语义）对同帧仍拒收——拒收门未被放开（回归锁）
            engine.save(windowID: 7702, pid: 1000, bundleIdentifier: nil, appName: nil,
                        origFrame: orig,
                        sourceSpace: .yabai(1), sourceDisplay: .yabai(1), sourceYabaiDisp: .yabai(1),
                        sourceDispSpace: 1, targetFrame: target, targetDisplay: 1, sessionID: nil)
            check("sdSave: 默认多屏语义同帧仍拒收不落库",
                  engine.load(windowID: 7702) == nil)
        }
    }
}
