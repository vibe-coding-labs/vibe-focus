import Darwin
import Foundation

// MARK: - 主线程调用栈采样器（B182）
//
// 证据链的根因级一环：≥1s 主线程停顿时，看门狗从巡检线程 suspend 主线程、
// 沿 arm64 帧指针链取回调用栈 PC、resume 后异步符号化——停顿日志直接给出
// 「主线程卡在哪个函数」，不再依赖区间覆盖完整性（sections=0 也有证据）。
//
// 安全性设计：
//   - 主线程 mach port 在启动时于主线程捕获（mach_thread_self()），此后只读；
//   - suspend/resume 成对（defer resume），采样失败路径也必然 resume；
//   - 内存读取发生在本进程内且主线程已挂起（帧链稳定），越界防护用
//     对齐+单调递增+帧数上限三重 guard，异常即停走；
//   - dladdr 符号化在 resume 之后执行（dladdr 内部可能拿 malloc 锁，
//     主线程挂起时调用有死锁风险，绝不在 suspend 窗口内调用）；
//   - 非 arm64 架构直接返回空（保持 no-op，不阻碍其余证据链）。

enum BacktraceSampler {

    private static let portBox = PortBox()

    /// 主线程 mach port 盒（static let 引用不变，内容锁保护）。
    final class PortBox: @unchecked Sendable {
        let lock = NSLock()
        var port: thread_act_t = 0
        var captured = false
    }

    /// 启动时在主线程调用一次：捕获主线程 mach port。
    static func captureMainThreadPortOnLaunch() {
        portBox.lock.lock()
        defer { portBox.lock.unlock() }
        portBox.port = mach_thread_self()
        portBox.captured = true
    }

    /// 采样主线程调用栈，返回原始 PC 地址（调用顺序：main 最先）。
    /// 采样失败/非 arm64/端口未捕获 → 空数组（调用方按无栈降级记录）。
    static func sampleMainThread(maxFrames: Int = 32) -> [UInt] {
        #if arch(arm64)
        portBox.lock.lock()
        guard portBox.captured, portBox.port != 0 else {
            portBox.lock.unlock()
            return []
        }
        let thread = portBox.port
        portBox.lock.unlock()

        guard thread_suspend(thread) == KERN_SUCCESS else { return [] }
        defer { thread_resume(thread) }

        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<arm_thread_state64_t>.stride / MemoryLayout<natural_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &state) { stPtr in
            thread_get_state(
                thread,
                ARM_THREAD_STATE64,
                UnsafeMutableRawPointer(stPtr).assumingMemoryBound(to: natural_t.self),
                &count
            )
        }
        guard kr == KERN_SUCCESS else { return [] }

        // arm64：pc = 当前执行地址；fp(x29) = 帧指针。帧布局：[savedFP][returnAddr]。
        let pc = UInt(state.__pc)
        var fp = UInt(state.__fp)
        guard pc != 0 else { return [] }
        var frames: [UInt] = [pc]

        for _ in 0..<maxFrames {
            // 防护：对齐 8、非空、帧指针向高地址单调移动（arm64 栈生长方向的反向）。
            guard fp != 0, fp % 8 == 0,
                  let framePtr = UnsafeRawPointer(bitPattern: fp),
                  let lrPtr = UnsafeRawPointer(bitPattern: fp + 8) else { break }
            let nextFP = framePtr.load(as: UInt.self)
            let returnAddr = lrPtr.load(as: UInt.self)
            guard returnAddr != 0 else { break }
            frames.append(returnAddr)
            guard nextFP > fp, nextFP - fp < 1 << 20, nextFP % 8 == 0 else { break }
            fp = nextFP
        }
        return frames
        #else
        return []
        #endif
    }

    /// 符号化（必须在主线程 resume 之后调用；dladdr 可能取锁）。
    /// 每帧输出 `符号+偏移 (二进制名+0x相对偏移)`，无法符号化给裸地址。
    static func symbolize(_ addresses: [UInt]) -> [String] {
        addresses.map { addr -> String in
            let pointer = UnsafeRawPointer(bitPattern: addr)
            var info = Dl_info()
            guard let pointer, dladdr(UnsafeMutableRawPointer(mutating: pointer), &info) != 0 else {
                return "0x" + String(addr, radix: 16)
            }
            let symbol = info.dli_sname.map { String(cString: $0) } ?? "?"
            var binaryPart = ""
            if let fbase = info.dli_fbase {
                let base = UInt(bitPattern: fbase)
                let binaryName = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
                binaryPart = " (\(binaryName)+0x\(String(addr - base, radix: 16)))"
            }
            let saddr = info.dli_saddr.map { UInt(bitPattern: UnsafeMutableRawPointer(mutating: $0)) } ?? addr
            return "\(symbol)+0x\(String(addr > saddr ? addr - saddr : 0, radix: 16))\(binaryPart)"
        }
    }
}
