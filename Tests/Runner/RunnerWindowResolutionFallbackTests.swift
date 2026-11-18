import AppKit
@testable import VibeFocusKit

// Tests/Runner/RunnerWindowResolutionFallbackTests.swift — 覆盖率批次（2026-11-03）：
// resolveWindow 四级退化链（fast → exactID_scan → windowNumber → title → none）。
//
// 用「不存在的 pid」做安全探针：AXUIElementCreateApplication 后属性读取直接失败，
// focusedWindow 返回 nil、全量枚举为空，四条命中路径全部 miss，落到 path=none 的
// 尾日志。真机零窗口触碰（不读/写任何真实窗口），常规门禁恒跑。
//
// 注：不使用自身 pid——AX 读自身进程在主线程会自阻塞（2026-11-03 CI 实测）。

extension RunnerHarness {
    func runWindowResolutionFallbackTests() {
        print("\n=== WindowResolutionFallback ===")
        let wm = WindowManager.shared
        let ghost: pid_t = 999_999

        let plain = WindowIdentity(
            windowID: 4_000_000_001, pid: ghost,
            bundleIdentifier: nil, appName: nil, title: nil)
        check("winResolve: 幽灵 pid 无候选 → nil", wm.resolveWindow(identity: plain) == nil)

        let withNumber = WindowIdentity(
            windowID: 4_000_000_002, pid: ghost,
            bundleIdentifier: nil, appName: nil, windowNumber: 12_345, title: "任意标题")
        check("winResolve: 带 windowNumber 仍无候选 → nil",
              wm.resolveWindow(identity: withNumber) == nil)

        // 标题空白守卫：trim 后为空 → 不进 title 匹配分支（走 none 尾路）
        let blankTitle = WindowIdentity(
            windowID: 4_000_000_003, pid: ghost,
            bundleIdentifier: nil, appName: nil, title: "   \n\t ")
        check("winResolve: 空白标题不进匹配 → nil",
              wm.resolveWindow(identity: blankTitle) == nil)

        // 标题命中兜底分支的「有候选但都失配」路：同上幽灵 pid，标题正常但无窗口
        let nonBlankTitle = WindowIdentity(
            windowID: 4_000_000_004, pid: ghost,
            bundleIdentifier: nil, appName: nil, title: "VF-No-Such-Window")
        check("winResolve: 有标题但无窗口 → nil",
              wm.resolveWindow(identity: nonBlankTitle) == nil)
    }
}
