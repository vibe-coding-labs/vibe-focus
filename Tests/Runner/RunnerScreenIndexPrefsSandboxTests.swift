import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerScreenIndexPrefsSandboxTests.swift — 2026-09-20「屏幕序号无法渲染」事故回归锁
//
// 根因：Runner 等非装机进程触发 `ScreenIndexPreferences.save()`（didSet →
// schedulePreferenceSave、legacy 迁移回写、flushPendingPreferenceSave）把测试偏好
// （topLeft/48/0.8，含测试崩溃残留的 enabled=false 中间态）写进生产三源
// （SQLite 主源 ~/.vibefocus/vibefocus.db + CFPreferences 共享 plist + UserDefaults）；
// app 重启后加载测试垃圾 → 用户角标配置（右下角/32/30%）被静默改写甚至整体熄灭
// （2026-09-20 装机 0.0.80 实锤：SQLite 行 09:30:19 被测试风暴改写，log 里成串测试
// pid 的 schedule preference save）。修法 = 进程级持久化沙箱：isProductionAppProcess
// == false 时 load/save 只走按 pid 隔离的 /tmp JSON，生产三源读写均零触碰。
//
// 本文件锁定：Runner 恒为沙箱进程；沙箱 save→load 往返保真；沙箱缺失回落 .default
// （不偷读生产）；生产 SQLite/CFPreferences 偏好键写前写后零变化。

extension RunnerHarness {

    func runScreenIndexPrefsSandboxTests() {
        // A. Runner 恒为沙箱进程（CLI 可执行无 Info.plist，bundle id ≠ canonical）
        check("screenSandbox A1: Runner 进程判定为非装机 app",
              !ScreenIndexPreferences.isProductionAppProcess)
        check("screenSandbox A2: 沙箱文件按 pid 隔离",
              ScreenIndexPreferences.sandboxPreferencesURL.lastPathComponent
                  .contains("\(ProcessInfo.processInfo.processIdentifier)"))

        // B. 生产三源写前快照（读取只读，允许；写入被禁止）
        let prodBefore = WindowStateStore.shared.loadPreference(key: ScreenIndexPreferences.userDefaultsKey)
        let cfpBefore = CFPreferencesCopyAppValue(
            ScreenIndexPreferences.userDefaultsKey as CFString, AppIdentity.bundleID as CFString)

        // C. 沙箱 save→load 往返（哨兵值 = 用户事故现场的右下角/32/30%）
        do {
            let file = ScreenIndexPreferences.sandboxPreferencesURL
            let hadFile = FileManager.default.fileExists(atPath: file.path)
            if hadFile { try? FileManager.default.removeItem(at: file) }
            defer {
                if hadFile { ScreenIndexPreferences.default.save() }
                else { try? FileManager.default.removeItem(at: file) }
            }

            var sentinel = ScreenIndexPreferences.default
            sentinel.position = .bottomRight
            sentinel.fontSize = 32
            sentinel.opacity = 0.3
            sentinel.save()

            check("screenSandbox C1: 沙箱进程 save() 落 /tmp 沙箱文件",
                  FileManager.default.fileExists(atPath: file.path))
            let reloaded = ScreenIndexPreferences.load()
            check("screenSandbox C2: 沙箱 load() 读回哨兵值（同进程往返保真）",
                  reloaded.position == .bottomRight && reloaded.fontSize == 32
                  && reloaded.opacity == 0.3 && reloaded.isEnabled == true)
        }

        // D. 沙箱文件缺失 → .default（绝不偷读生产）
        do {
            let file = ScreenIndexPreferences.sandboxPreferencesURL
            let hadFile = FileManager.default.fileExists(atPath: file.path)
            if hadFile { try? FileManager.default.removeItem(at: file) }
            defer {
                if hadFile { ScreenIndexPreferences.default.save() }
            }
            let prefs = ScreenIndexPreferences.load()
            check("screenSandbox D1: 无沙箱文件回落 .default（不读生产三源）",
                  prefs.position == ScreenIndexPreferences.default.position
                  && prefs.fontSize == ScreenIndexPreferences.default.fontSize
                  && prefs.isEnabled == ScreenIndexPreferences.default.isEnabled)
        }

        // E. 生产三源零污染（save 后回读与写前快照一致）
        let prodAfter = WindowStateStore.shared.loadPreference(key: ScreenIndexPreferences.userDefaultsKey)
        let cfpAfter = CFPreferencesCopyAppValue(
            ScreenIndexPreferences.userDefaultsKey as CFString, AppIdentity.bundleID as CFString)
        check("screenSandbox E1: 生产 SQLite 偏好键写前写后零变化", prodBefore == prodAfter)
        check("screenSandbox E2: 生产 CFPreferences 偏好键写前写后零变化",
              (cfpBefore == nil && cfpAfter == nil)
              || (cfpBefore as? String == cfpAfter as? String))
    }
}
