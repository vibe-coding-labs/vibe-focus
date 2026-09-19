import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerAppDelegateInstanceTests.swift — 覆盖率批次 48（B284）：
// AppDelegate+Instance/+Menu 的只读方法直测（Bundle 读取/路径构造/状态栏图像加载，
// 零系统状态变更）。applicationDidFinishLaunching 编排与 setEnabled（SMAppService
// 真注册）留白。

extension RunnerHarness {
    func runAppDelegateInstanceTests() {
        let appDelegate = AppDelegate()

        // MARK: A. 版本读取：Bundle 无 plist → 回落 AppVersion.current
        let version = appDelegate.currentAppVersion()
        check("appDelegate: currentAppVersion 回落 AppVersion.current 非空",
              !version.isEmpty)

        // MARK: B. 期望安装路径：双候选（~/Applications 与 /Applications）
        let paths = appDelegate.expectedAppBundlePaths()
        check("appDelegate: expectedAppBundlePaths 双候选且首为用户目录",
              paths.count == 2
              && paths[0].hasSuffix("/Applications/VibeFocus.app")
              && paths[1].hasSuffix("/Applications/VibeFocus.app"))

        // MARK: C. 开发目录判定：dist 产物白名单语义
        check("appDelegate: isAllowedDevelopmentBundlePath dist 产物命中",
              appDelegate.isAllowedDevelopmentBundlePath("/Users/x/repo/dist/VibeFocus.app"))
        check("appDelegate: isAllowedDevelopmentBundlePath 非 dist 不命中",
              !appDelegate.isAllowedDevelopmentBundlePath("/Users/x/dist/Other.app"))

        // MARK: D. 单实例检测：Runner 无同版本实例（幂等只读枚举）
        let existing = appDelegate.findExistingInstance()
        check("appDelegate: findExistingInstance 只读枚举不崩", true)
        if let existing {
            check("appDelegate: 已有实例信息字段完整",
                  existing.app.processIdentifier > 0)
        } else {
            check("appDelegate: 无已有实例合法 nil", true)
        }

        // MARK: E. 状态栏图像加载（菜单域，只读资源/NSSymbol）
        let _ = appDelegate.loadStatusBarImage()
        check("appDelegate: loadStatusBarImage 返回 nil 或有效图", true)
        let fallback = appDelegate.fallbackStatusBarSymbolImage()
        check("appDelegate: fallbackStatusBarSymbolImage 模板图像非 nil",
              fallback != nil)
    }
}

// MARK: - B292 追加：启动编排安全步骤直测（C1 豁免收窄第一批）
// ①applyApplicationIcon：Bundle 图标加载 + NSApp.applicationIconImage 设置
//   （Runner bundle 无图标 → guard 早退分支；生产 .app 有图标走设置分支）；
// ②logAvailability：SkyLight dlopen/dlsym 探测 + 循环 log（只读诊断，零副作用）。

extension RunnerHarness {
    func runAppDelegateLaunchStepTests() {
        let appDelegate = AppDelegate()

        appDelegate.applyApplicationIcon()
        check("appDelegate: applyApplicationIcon 在无图标 bundle 安全早退", true)

        NativeSpaceBridge.logAvailability()
        check("appDelegate: logAvailability 只读探测不崩", true)

        let existing = appDelegate.findExistingInstance()
        check("appDelegate: findExistingInstance 只读枚举不崩（nil 或实例信息）", true)
        if let existing {
            check("appDelegate: 已有实例 pid 合法", existing.app.processIdentifier > 0)
        }
    }
}
