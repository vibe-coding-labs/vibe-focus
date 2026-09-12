import Foundation

// MARK: - 窗口作业串行执行队列（B180）
//
// 根因（2026-09-12 用户报告「气泡打字卡死几秒 + 整页卡顿」，日志量化）：
// hook 触发的窗口作业（UPS 归位 restore / Stop 移动 moveWindowToMainScreen）
// 此前同步跑在主线程——577 个 hook 请求中 89 次阻塞 >200ms（UPS 归位 34/35、
// Stop 移动 16/16，风暴期单次 66s），主线程被占用期间整个 app UI 冻结。
//
// 解法：窗口作业链的 @MainActor 是编译注解而非真实需求（链上只碰 AX/CG/yabai，
// 零 NSApp/NSWindow 依赖，B180 已全链 nonisolated 化），本执行器把它们下放到
// **专用串行队列**：调用方（MainActor async）await 挂起——主线程解放，打字/页面
// 不再冻结；串行性保持「同窗并发移动互斥」的既有隐式约定（主线程天然串行
// → 队列串行等价替代）。
//
// PerfMonitor 区间：作业函数内部自带的 move.toMain/restore 区间栈随执行线程
// 落在本队列线程上，看门狗快照跨线程收集——停顿归因不丢。
enum WindowWorkExecutor {

    /// 串行队列：窗口作业天然互斥（并发移动同一窗口有害），保持全局一条。
    private static let queue = DispatchQueue(
        label: "vibefocus.window-work",
        qos: .userInitiated,
        target: .global(qos: .userInitiated)
    )

    /// 把同步窗口作业调度到串行后台队列执行；调用方（MainActor async 上下文）
    /// 在 await 期间完全挂起——主线程零占用。返回后调用方经 actor 隔离自动
    /// 跳回主线程，后续 UI 副作用安全。
    static func run<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }
}
