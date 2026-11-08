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
//
// ## 预算熔断（0.1.5，热键失灵顽疾根治）
// 用户报障（2026-11-09）：应用运行一段时间后快捷键窗口切换失灵、重启才恢复。
// 代码审定根因：热键 toggle / hook 拉窗 / 气泡提交落位四路调用点共用本串行队列，
// 桥接用 withCheckedContinuation——**任一作业内的无界同步调用挂死**（AX 消息在
// 目标 app 挂起/WindowServer 楔死时可无限阻塞；XPC 读 B305 实测可卡秒级）→
// continuation 永不 resume → 调用方 await 永不返回 → HotKeyManager 的
// isToggleInFlight 闸门永久关死 → 三通道热键静默全灭（无崩溃无卡顿，仅按键无
// 反应），重启才复位。熔断语义：作业超预算 → 调用方拿到 nil（诚实失败）+
// **串行队列整体重建**（后续作业不再排在尸体作业后面；挂死闭包不可取消，随其
// 自然结束遗留在旧队列线程上，代价=一个僵尸线程，远优于热键永久失灵）。
// 预算取 90s：正常窗口作业 0.3~2s，B180 记录过的最差合法作业 66s。
enum WindowWorkExecutor {

    /// 串行队列：窗口作业天然互斥（并发移动同一窗口有害），保持全局一条。
    /// 预算熔断时整体替换（stateLock 保护）——换新队列 = 弃用被挂死作业占住的旧队列。
    private static var queue = DispatchQueue(
        label: "vibefocus.window-work",
        qos: .userInitiated,
        target: .global(qos: .userInitiated)
    )
    private static let stateLock = NSLock()

    /// 单作业预算（秒）。熔断时调用方拿 nil，作业本体不中断。
    static let jobBudget: TimeInterval = 90

    /// resume-once 守卫：作业完成路径与看门狗路径竞争同一 continuation，
    /// 只许第一方胜出（withCheckedContinuation 双 resume 会运行时崩溃）。
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        /// 返回 true = 本调用方赢得唯一 resume 权。
        func tryResume() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if resumed { return false }
            resumed = true
            return true
        }
    }

    /// 把同步窗口作业调度到串行后台队列执行；调用方（MainActor async 上下文）
    /// 在 await 期间完全挂起——主线程零占用。返回后调用方经 actor 隔离自动
    /// 跳回主线程，后续 UI 副作用安全。
    /// 返回 nil = 作业超预算被熔断（作业本体仍在旧队列上继续，调用方按失败
    /// 处理并如实上报；热键链的 in-flight 闸门据此释放）。
    static func run<T: Sendable>(
        budget: TimeInterval = jobBudget,
        _ work: @Sendable @escaping () -> T
    ) async -> T? {
        stateLock.lock()
        let currentQueue = queue
        stateLock.unlock()
        return await withCheckedContinuation { continuation in
            let resumeGate = ResumeOnce()
            currentQueue.async {
                let result = work()
                if resumeGate.tryResume() {
                    continuation.resume(returning: result)
                }
            }
            // 看门狗挂独立全局队列：串行队列楔死时 asyncAfter 会排在尸体作业
            // 身后永远轮不到——绝不能把看门狗挂到 currentQueue 上。
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + budget) {
                guard resumeGate.tryResume() else { return }
                stateLock.lock()
                // 仅当楔死的还是当前队列时才换（多次熔断竞态下避免覆盖更新队列）
                if queue === currentQueue {
                    queue = DispatchQueue(
                        label: "vibefocus.window-work",
                        qos: .userInitiated,
                        target: .global(qos: .userInitiated)
                    )
                }
                stateLock.unlock()
                log("[WindowWorkExecutor] job exceeded budget \(Int(budget))s, queue rebuilt", level: .error, fields: [
                    "budgetSec": String(Int(budget))
                ])
                CrashContextRecorder.shared.record("window_work_executor_wedged budget=\(Int(budget))s")
                continuation.resume(returning: nil)
            }
        }
    }
}
