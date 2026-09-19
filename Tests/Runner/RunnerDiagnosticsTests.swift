// Tests/Runner/RunnerDiagnosticsTests.swift
// B215 覆盖堆叠·诊断与屏幕定位域：Support+Diagnostics（进程执行助手三态 + mdfind
// 查询 + 全诊断流程只读演练）/ WindowManager+ScreenPosition（frame→屏解析、
// displayID 转换、CGWindowList 幻影守卫路）/ LoginItemManager.refresh（未注册态读取；
// setEnabled 会真注册登录项，绝不调用）。

import AppKit
import ApplicationServices
import Foundation
@testable import VibeFocusKit

extension RunnerHarness {

    // MARK: - Support+Diagnostics（诊断只读编排）

    func runDiagnosticsTests() {
        print("\n=== Diagnostics (B215) ===")

        // runProcessForDiagnostics 三态：成功/非零退出/可执行不存在
        let ok = runProcessForDiagnostics(executable: "/usr/bin/true", arguments: [])
        check("diag: true 退出码 0", ok?.exitCode == 0)
        let fail = runProcessForDiagnostics(executable: "/usr/bin/false", arguments: [])
        check("diag: false 退出码 1", fail?.exitCode == 1)
        let echo = runProcessForDiagnostics(executable: "/bin/echo", arguments: ["b215-hello"])
        check("diag: echo stdout 捕获",
              echo?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "b215-hello")
        let missing = runProcessForDiagnostics(executable: "/nonexistent-b215-probe", arguments: [])
        check("diag: 不存在可执行 → nil", missing == nil)

        // findAppBundlePaths：无命中 → 空数组（mdfind 正常退出零行）
        let apps = findAppBundlePaths(bundleIdentifier: "com.b215.nonexistent")
        check("diag: mdfind 无命中 → 空数组", apps.isEmpty)

        // logDiagnostics 全流程：bundle/进程/AX/前后台 app 采集 + BuildCapabilities
        // 自检 + codesign/security fork——全部只读，锁「可跑不崩溃」契约
        logDiagnostics("b215-runner")
        check("diag: logDiagnostics 全流程可跑不崩溃", true)
    }

    // MARK: - WindowManager+ScreenPosition（frame→屏解析）

    func runScreenPositionTests() {
        print("\n=== ScreenPosition (B215) ===")
        let wm = WindowManager.shared
        guard let main = NSScreen.main else {
            check("screenPos: 有主屏（环境前提）", false)
            return
        }

        // 主屏内的 Quartz frame（Quartz y 轴原点在主屏左下、向上为正）
        let h = CoordinateKit.mainScreenHeight
        let frameOnMain = CGRect(x: 100, y: h - 500, width: 300, height: 200)
        let ctx = wm.displayContext(for: frameOnMain)
        check("screenPos: 主屏 frame 命中 yabai index 1", ctx.yabaiIndex == 1)
        check("screenPos: 主屏 frame 命中 displayID", ctx.displayID != nil)
        check("screenPos: displayID(for:) 委托一致", wm.displayID(for: frameOnMain) == ctx.displayID)

        // 远离所有屏 → 双 nil（Quartz→Cocoa 变换后落在无屏区）
        let off = wm.displayContext(for: CGRect(x: 999_999, y: -999_999, width: 10, height: 10))
        check("screenPos: 离屏 frame 双 nil", off.yabaiIndex == nil && off.displayID == nil)

        // displayID ↔ 数组下标转换
        let mainID = wm.displayID(for: main)
        check("screenPos: 主屏 displayID 非空", mainID != nil)
        // B235 修：原断言「主 displayID → 下标 0」是错误环境假设——NSScreen.main
        // （菜单栏/焦点屏）在多屏布局下不保证是 NSScreen.screens[0]（本机三屏实测
        // 非 0）。实现语义 = NSScreen.screens 数组序往返，断言改为该不变量。
        check("screenPos: 主 displayID → 下标与 NSScreen.screens 序往返一致",
              wm.displayIndex(forDisplayID: mainID) == NSScreen.screens.firstIndex(of: main))
        check("screenPos: nil displayID → nil", wm.displayIndex(forDisplayID: nil) == nil)
        check("screenPos: 幻影 displayID → nil", wm.displayIndex(forDisplayID: 0xF00D) == nil)

        // 可见帧（去菜单栏/Dock）非退化
        let vis = wm.axFrame(forVisibleFrameOf: main)
        check("screenPos: 可见帧非退化", vis.width > 0 && vis.height > 0)

        // CGWindowList 守卫路：幻影窗口 ID（不存在 → 不在主屏 / frame nil）
        check("screenPos: 幻影窗口不在主屏", wm.isWindowOnMainScreen(windowID: 0xB215) == false)
        check("screenPos: 幻影窗口 frame nil", wm.cgWindowFrame(forWindowID: 0xB215) == nil)
    }

    // MARK: - LoginItemManager（只读 refresh；setEnabled 会真注册登录项绝不调用）

    func runLoginItemRefreshTests() {
        print("\n=== LoginItemRefresh (B215) ===")
        let lim = LoginItemManager.shared
        // Runner 无 bundle id：SMAppService.mainApp 不可能是已注册登录项。
        // refresh 同步刷新 @Published 态，status 落在 notRegistered/notFound 等未启用象限。
        lim.refresh()
        check("loginItem: Runner 内 isEnabled false", lim.isEnabled == false)
        check("loginItem: 状态文案已脱离初始未知", lim.statusTitle != "未知")
        check("loginItem: refresh 不产生错误消息", lim.lastErrorMessage == nil)
        check("loginItem: requiresApproval false", lim.requiresApproval == false)
    }
}
