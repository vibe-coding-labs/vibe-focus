// Tests/Runner/RunnerCrashSignalTests.swift
// B225 覆盖堆叠·崩溃信号层：installCrashSignalHandlers / installAtExitHandler /
// updateCrashSnapshot。FD 与 /tmp 现场按进程角色隔离（DiagnosticPath TestRunner 后缀），
// 安装动作只注册 handler 与打开 FD，不触发任何信号（绝不向自己发致命信号——
// handler 会 SIG_DFL+raise 真崩进程）。

import Foundation
@testable import VibeFocusKit

extension RunnerHarness {

    func runCrashSignalTests() {
        print("\n=== CrashSignal (B225) ===")

        // 1) 安装崩溃信号处理器（6 信号 signal() 注册 + fatal FD lazy open +
        //    exits.jsonl 追加 FD + 各信号审计行预生成 + 上次 fatal 归档检查）
        installCrashSignalHandlers()
        check("crash: 崩溃信号处理器可安装", true)

        // 2) atexit 处理器注册（进程退出时写快照日志尾行 + 退出审计 clean 兜底）
        installAtExitHandler()
        check("crash: atexit 处理器可注册", true)

        // 3) PRE-CRASH STATE 双缓冲写入入口：正常短快照与截断长快照
        var okShort = false
        updateCrashSnapshot { buffer, size in
            let payload = Array("b225-snapshot".utf8)
            guard payload.count <= size else { return 0 }
            for (i, b) in payload.enumerated() { buffer[i] = CChar(bitPattern: b) }
            okShort = true
            return payload.count
        }
        check("crash: 快照缓冲短写入", okShort)

        var wrote = 0
        updateCrashSnapshot { buffer, size in
            // 一次性灌满缓冲（容量 16384），锁「长度截断不死机」
            memset(buffer, 0x41, size)
            wrote = size
            return size
        }
        check("crash: 快照缓冲满容量写入", wrote > 0)
    }
}
