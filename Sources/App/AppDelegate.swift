import AppKit
import SwiftUI
import Foundation

// MARK: - App Delegate
@MainActor
public class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var toggleMenuItem: NSMenuItem?
    var layoutSubmenuItem: NSMenuItem?
    /// 共存探测发现的对决品摘要（设置页/菜单展示用；nil = 无冲突）
    var layoutConflictDetected: String?
    let openSettingsDistributedNotification = Notification.Name("com.vibefocus.app.open-settings")

    struct ExistingInstanceInfo {
        let app: NSRunningApplication
        let version: String?
        let path: String?
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // P-INST-113: 启动总耗时（crash/atexit handler 安装 + logDiagnostics + CrashContextRecorder.bootstrap P-INST-80 + findExistingInstance 单实例 + 菜单/hotkey/hook server/overlay 初始化全序列；启动延迟顶层归因，最关键的启动性能指标）。
        #if PERF_INSTRUMENT
        let adflStart = Date()
        defer {
            log("[AppDelegate] applicationDidFinishLaunching finished", level: .debug, fields: [
                "durationMs": String(elapsedMilliseconds(since: adflStart))
            ])
        }
        #endif
        // 崩溃循环熔断第一步：必须先于 installCrashSignalHandlers()（其内部归档会把
        // /tmp/vibefocus-crash-fatal.log move 走）捕获上次致命信号的时间。
        CrashContextRecorder.shared.capturePreviousCrashFatalDate()
        installCrashSignalHandlers()
        installAtExitHandler()
        installGracefulSigtermHandler()
        // 退出审计：本实例的存在证明（越早写，后续任何死法都能对上账；SIGKILL 类
        // 外部击杀表现为「launch 无配对 exit」，--diagnose 报告可直接点名）。
        ExitJournal.recordLaunch(
            bundleID: Bundle.main.bundleIdentifier,
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            exePath: Bundle.main.executableURL?.path ?? "?"
        )
        log("=== SESSION START ===", fields: [
            "pid": String(ProcessInfo.processInfo.processIdentifier),
            "axTrusted": String(AXIsProcessTrusted()),
            "screens": String(NSScreen.screens.count)
        ])
        log("applicationDidFinishLaunching bundle=\(Bundle.main.bundleIdentifier ?? "nil") path=\(Bundle.main.bundleURL.path)")
        logDiagnostics("launch")
        CrashContextRecorder.shared.bootstrap()
        NativeSpaceBridge.logAvailability()
        // B178 常开性能监控：主线程停顿看门狗 + 区间埋点 + 计数器快照。任何卡顿
        // 发生瞬间即落 [PERF][STALL] 归因日志（含活跃区间栈），不再事后人肉对线。
        PerfMonitor.shared.startHeartbeatOnMain()

        // 单实例处理：同版本复用现有进程，不强制重启。
        if let existing = findExistingInstance() {
            let currentVersion = currentAppVersion()
            let existingVersion = existing.version ?? "unknown"
            log("Found existing instance pid=\(existing.app.processIdentifier) version=\(existingVersion) path=\(existing.path ?? "nil")")
            CrashContextRecorder.shared.record("existing_instance_detected pid=\(existing.app.processIdentifier) version=\(existingVersion)")

            if existing.version == nil || existing.version == currentVersion {
                log("Reusing existing same-version instance; activating and opening settings")
                CrashContextRecorder.shared.record("reuse_existing_instance pid=\(existing.app.processIdentifier)")
                requestExistingInstanceOpenSettings()
                existing.app.activate(options: [.activateAllWindows])
                ExitJournal.recordExit(reason: "reuse-existing-activate")
                NSApp.terminate(nil)
                return
            }

            log("Existing instance version differs (current=\(currentVersion), existing=\(existingVersion)); terminating old instance")
            CrashContextRecorder.shared.record("terminate_old_instance pid=\(existing.app.processIdentifier)")
            existing.app.terminate()
            Thread.sleep(forTimeInterval: 0.3)
            if !existing.app.isTerminated {
                kill(existing.app.processIdentifier, SIGTERM)
                Thread.sleep(forTimeInterval: 0.2)
            }
        }

        // AX 竞态自愈（Sources/Support/AXSelfHeal.swift 头注释有完整实证链）：
        // 重装后 ~1s 内拉起的新进程约半数被 tccd 误判未授权且不自愈，重启进程即恢复。
        // 自包含闭环：派生 detached 看护进程（等死→退让→open），真实用户无 keepalive 也成立。
        // 放在单实例处理之后：复用/接管路径已提前 return，不会对着健康实例自愈。
        let axSelfHealPrevReason = ExitJournal.lastExitReason()
        let axSelfHealBundlePath = Bundle.main.bundleURL.path
        let axSelfHealDecision = AXSelfHeal.decide(
            axTrusted: AXIsProcessTrusted(),
            previousExitWasSelfHeal: axSelfHealPrevReason == AXSelfHeal.exitReason,
            isBundleInstall: axSelfHealBundlePath.hasSuffix(".app")
        )
        switch axSelfHealDecision {
        case .proceedTrusted:
            break
        case .relaunchSelf:
            log("AX self-heal: 未授权且上轮非自愈退出 → 派生看护进程后优雅退出自拉起", level: .warn, fields: [
                "previousExitReason": axSelfHealPrevReason ?? "nil"
            ])
            CrashContextRecorder.shared.record("ax_selfheal relaunch previous=\(axSelfHealPrevReason ?? "nil")")
            let watcherOK = AXSelfHeal.spawnRelaunchWatcher(
                pid: ProcessInfo.processInfo.processIdentifier,
                bundlePath: axSelfHealBundlePath
            )
            if watcherOK {
                ExitJournal.recordExit(reason: AXSelfHeal.exitReason)
                NSApp.terminate(nil)
                return
            }
            // 看护派生失败（罕见）：不退出（退出后无人拉起），落回人工提示路径，
            // 且不写自愈 reason——下轮启动仍可再试自愈。
            log("AX self-heal: 看护进程派生失败，继续启动走人工勾选提示", level: .warn, fields: [:])
            CrashContextRecorder.shared.record("ax_selfheal watcher_spawn_failed")
        case .giveUpPreviousHealFailed:
            log("AX self-heal: 上一进程已自愈过仍未授权 → 真未授权，走人工勾选提示", level: .warn, fields: [:])
            CrashContextRecorder.shared.record("ax_selfheal give_up previous_was_selfheal")
        case .giveUpNoBundle:
            log("AX self-heal: 未授权且非 bundle 安装（裸二进制 dev 运行），不自愈", level: .warn, fields: [:])
            CrashContextRecorder.shared.record("ax_selfheal give_up no_bundle")
        }

        // 获取锁（不同版本替换场景下应能成功）
        if !acquireExclusiveLock() {
            log("Failed to acquire lock after terminating old instance, retrying...")
            CrashContextRecorder.shared.record("lock_retry")
            Thread.sleep(forTimeInterval: 0.5)
            if !acquireExclusiveLock() {
                log("Still cannot acquire lock, terminating self")
                CrashContextRecorder.shared.record("lock_failed_terminate")
                ExitJournal.recordExit(reason: "lock-failed-terminate")
                NSApp.terminate(nil)
                return
            }
        }

        guard enforceExpectedInstallLocation() else {
            return
        }
        applyApplicationIcon()
        setupMenuBar()
        HotKeyManager.shared.setup()
        ClaudeHookServer.shared.applyPreferences()
        // FIX(2026-08-31): 启动路径弃用 refreshOverlays()（hideOverlays+showOverlays = 全量
        // close+重建，即 2026-08-10 SIGSEGV 循环中"启动即崩"的执行者——keepalive 拉起时坏
        // 屏幕配置还在，全量窗口操作与 WindowServer 重排竞争）。改用 updateOverlaysInPlace()
        // 就地创建：无 close 风暴，仅对新屏幕逐个创建窗口。
        ScreenOverlayManager.shared.updateOverlaysInPlace()
        promptAccessibilityIfNeeded()
        // 共存检测：同类摆位窗口管理器（Rectangle 等）运行中且用户未显式选择时，
        // 自动停用摆位热键（不弹窗；提示在设置页与菜单，见 design-rectangle-integration §3）。
        // 必须经 setLayoutActionsEnabled 重注册——setup() 已把默认 11 个摆位热键注册进
        // Carbon/EventTap，只改偏好会留下"死注册"吞掉对方窗口管理器的按键。
        let layoutConflictProfile = WindowLayoutManagerProbe.probe()
        if WindowLayoutManagerProbe.applyCoexistencePolicy(profile: layoutConflictProfile) {
            layoutConflictDetected = layoutConflictProfile.conflictSummary
            HotKeyManager.shared.setLayoutActionsEnabled(false)
        }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in
                SessionWindowRegistry.shared.purgeClosedWindows()
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshMenuLabels),
            name: .hotKeyConfigurationDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshMenuLabels),
            name: .layoutHotKeyTableDidChange,
            object: nil
        )
        // Terminal 网格自动恢复（勾选后重启/登录自动还原布局+目录+claude 会话）。
        // 延迟数秒：等桌面/终端环境稳定，避免与登录时的系统窗口恢复互相踩。
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            TerminalGridController.shared.runAutoRestoreIfEnabled()
        }
        // 终端使用量追踪（「自动：最近常用」编排目标的数据源）
        TerminalUsageTracker.shared.start()
        // B160 输入气泡「聚焦会话自动弹出」观察器（激活通知 + 1s 同 app 窗口切换兜底轮询）
        InputBubbleAutoShow.shared.start()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppBecameActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleOpenSettingsRequest(_:)),
            name: openSettingsDistributedNotification,
            object: nil
        )
        showSettingsWindowOnLaunch()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        log("applicationShouldHandleReopen hasVisibleWindows=\(flag)")
        SettingsWindowController.shared.show()
        return true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        ScreenOverlayManager.shared.flushPendingPreferenceSave(reason: "application_will_terminate")
        CrashContextRecorder.shared.markCleanExit()
    }

    @objc func handleOpenSettingsRequest(_ notification: Notification) {
        // P-INST-263: 分布式打开设置请求入口（frontmostAppDescriptor P-INST-210 + DispatchQueue 调度 show；分布式通知跨实例触发设置唤起，归因入口）。
        #if PERF_INSTRUMENT
        let hosStart = Date()
        defer {
            log("[App] handleOpenSettingsRequest finished", level: .debug, fields: ["durationMs": String(elapsedMilliseconds(since: hosStart))])
        }
        #endif
        log(
            "Received distributed open-settings request",
            fields: [
                "frontmost": frontmostAppDescriptor()
            ]
        )
        DispatchQueue.main.async {
            SettingsWindowController.shared.show(shouldFocus: true)
        }
    }

    func showSettingsWindowOnLaunch() {
        // P-INST-264: 启动时显示设置窗口入口（DispatchQueue 0.15s 后调度 show；首次启动调用，归因启动设置唤起时机）。
        #if PERF_INSTRUMENT
        let sswStart = Date()
        defer {
            log("[App] showSettingsWindowOnLaunch finished", level: .debug, fields: ["durationMs": String(elapsedMilliseconds(since: sswStart))])
        }
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            log("Showing settings window on launch")
            SettingsWindowController.shared.show(shouldFocus: false)
        }
    }

    func requestExistingInstanceOpenSettings() {
        DistributedNotificationCenter.default().post(
            name: openSettingsDistributedNotification,
            object: nil,
            userInfo: nil
        )
    }

    // MARK: - Single Instance Check

    // 文件锁路径，用于防止竞态条件（存储属性必须留类体；检查函数族在 +Instance.swift）
    let lockFilePath = VFConstants.appLockFilePath

}
