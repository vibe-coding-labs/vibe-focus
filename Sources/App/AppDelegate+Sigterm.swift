import AppKit
import Darwin
import Foundation

// Sources/App/AppDelegate+Sigterm.swift — B159 自 AppDelegate.swift 按域拆出（逐字搬移零行为变更）
// 优雅 SIGTERM（退出审计语义闭合）：pkill/安装脚本对 AppKit 进程发的 SIGTERM 是裸信号
// 死亡——atexit 不运行、退出审计缺 exit 记录、--diagnose 把安装重拉误报成「疑似外部击杀」。
// 改由 DispatchSource 收敛到主线程走 NSApp.terminate：完整 AppKit 退出流程 + 审计落
// sigterm-graceful 专属 reason。
private nonisolated(unsafe) var gracefulSigtermSource: DispatchSourceSignal?

extension AppDelegate {
    func installGracefulSigtermHandler() {
        signal(SIGTERM, SIG_IGN)  // 阻断默认死亡行为，交给 DispatchSource
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                ExitJournal.recordExit(reason: "sigterm-graceful")
                NSApp.terminate(nil)
            }
        }
        source.resume()
        gracefulSigtermSource = source
    }
}
