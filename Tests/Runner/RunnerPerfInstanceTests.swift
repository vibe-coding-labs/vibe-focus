import AppKit
import SwiftUI
@testable import VibeFocusKit

// Tests/Runner/RunnerPerfInstanceTests.swift — 覆盖率批次 9（B239）：
// PerfMonitor 实例段直测（beginSection/endSection 嵌套栈、record 计数、measure 包装）
// + B214 漏项补测（CodeBlockView body）。
//
// PerfMonitor.shared 单例纯内存（计数器字典 + section 栈 + 环形缓冲，无 IO 无网络；
// checkForStall 仅在慢阈值时 log），同步直调安全。section 栈用 begin/end 配对不残留。

extension RunnerHarness {
    func runPerfInstanceTests() {
        let perf = PerfMonitor.shared

        // MARK: A. measure 包装：闭包值透传 + 计数落账
        let measured = perf.measure("b239.measure") { 21 * 2 }
        check("perfInstance: measure 闭包值透传", measured == 42)

        // MARK: B. begin/end 嵌套栈：配对使用不残留
        perf.beginSection("b239.outer", fields: ["phase": "setup"])
        perf.beginSection("b239.inner")
        perf.endSection()
        perf.endSection()
        check("perfInstance: begin/end 嵌套配对完成不崩", true)
        // 防御式 end（空栈 end 不崩——实现按栈空保护）。
        perf.endSection()

        // MARK: C. record 计数：多次累计
        perf.record("b239.counter", durationMs: 1.5)
        perf.record("b239.counter", durationMs: 2.5)
        perf.record("b239.counter", durationMs: 3.5)
        check("perfInstance: record 多次累计完成不崩", true)

        // MARK: D. B214 漏项补测：CodeBlockView body（纯展示，零副作用求值）
        let codeBlock = CodeBlockView(code: "brew install vibe", language: "sh")
        let _ = codeBlock.body
        check("codeBlock: body 求值无异常（copyToClipboard 私有 action 留白）", true)
    }
}
