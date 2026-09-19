// Tests/Runner/RunnerBacktraceTests.swift
// B220 覆盖堆叠·崩溃取证采样器域：BacktraceSampler（arm64 帧指针链采样）。
// 采样路径=生产看门狗同款（后台线程 suspend 主线程取栈后 resume）：
// 主线程此刻阻塞在信号量等待 syscall 上，suspend/resume 全程 defer 配对。
// 未捕获端口降级路先行断言（进程内 PortBox 尚未 capture）。

import Foundation
@testable import VibeFocusKit

extension RunnerHarness {

    func runBacktraceSamplerTests() {
        print("\n=== BacktraceSampler (B220) ===")

        // 降级路：端口未捕获 → 空数组（调用方按无栈降级记录）
        let uncaptured = BacktraceSampler.sampleMainThread()
        check("backtrace: 未捕获端口 → 空数组", uncaptured.isEmpty)

        // 启动捕获契约：主线程调用一次
        BacktraceSampler.captureMainThreadPortOnLaunch()
        check("backtrace: capture 可调用", true)

        // 采样路：从后台线程采样主线程（生产看门狗同款调用方向）
        final class Box: @unchecked Sendable { var frames: [UInt] = [] }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.frames = BacktraceSampler.sampleMainThread(maxFrames: 32)
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)
        check("backtrace: arm64 采样回主线程栈非空", !box.frames.isEmpty)
        check("backtrace: 帧数不超上限", box.frames.count <= 32)
    }
}
