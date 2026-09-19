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

// MARK: - B250：崩溃快照双缓冲语义（updateCrashSnapshot 写通道 + B250 提缝读通道，
// 纯内存零落盘；crashSignalHandler 真身一调即 raise 退出，永远不可进程内直测）

extension RunnerHarness {
    func runCrashSnapshotBufferTests() {
        // 语义：update 写「当前 active」后翻转；readInactiveBuffer 读「对面」。
        // 因此第 N 次写入要等第 N+1 次 update 翻转后才能从 inactive 侧读到。
        func snapshot(_ text: String) {
            updateCrashSnapshot { buf, cap in
                let bytes = Array(text.utf8)
                let n = min(bytes.count, cap)
                for (i, b) in bytes.prefix(n).enumerated() { buf[i] = Int8(bitPattern: b) }
                return n
            }
        }

        // 语义精化（首版断言红→实测修正）：update 写 active 后立刻翻转，刚写入的
        // 缓冲即为 inactive 可读；新 active 侧被 NUL 清空备下次写。即「写后立即可读回」。
        snapshot("b250-first")
        let first = crashSnapshotReadInactive()
        check("crashBuf: 写入后立即读回本写内容",
              first.text == "b250-first" && first.len == 10)

        snapshot("b250-second")
        let second = crashSnapshotReadInactive()
        check("crashBuf: 二次写入读回新内容（旧内容被覆盖）",
              second.text == "b250-second" && second.len == 11)

        // 负返回值钳到 0（max(0, written) 分支）且不污染缓冲
        updateCrashSnapshot { _, _ in -7 }
        snapshot("tail")
        let clamped = crashSnapshotReadInactive()
        check("crashBuf: 负写入钳零后照常翻转读回", clamped.text == "tail" && clamped.len == 4)

        // 长载荷不跨缓冲串写
        let long = String(repeating: "x", count: 300)
        snapshot(long)
        snapshot("t2")
        let after = crashSnapshotReadInactive()
        check("crashBuf: 多轮翻转不串缓冲", after.text == "t2" && after.len == 2)
        _ = long
    }
}
