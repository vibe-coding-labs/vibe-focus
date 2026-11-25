import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerSpaceControllerCacheRaceTests.swift — B327（2026-11-26）：
// SpaceController 缓存/状态并发回归锁（轰炸）。
//
// 背景：SpaceController 是无锁普通类（@unchecked Sendable），缓存与状态历史上靠
// 「主线程独占」约定保证安全；B313/B314 把 grid 链 queryWindow/querySpaces/exact*
// 下放 WindowWorkExecutor 专用串行队列后，主线程 toggle/restore 热路径与 executor
// 线程并发读写同一缓存（spacesQueryCache / windowQueryCache / displayMatchTable /
// lastErrorMessage / canControlSpaces）——无锁字典与值类型 COW 并发读写 = B323 同族
// 崩溃面（锁外 release 叠加 / 字典结构损坏）。
//
// 修复：stateLock 收编全部缓存与状态读写，fork 全部留锁外（AuditLogger B323 同族家法）。
// 本文件按防回归四步写成：修复前在本基线跑轰炸 = 红演示（崩溃/内存损坏即证据）；
// 修复后同轰炸结构性稳定绿（临界区串行化，非概率性）。
//
// 安全边界：经 processRunnerOverride 注入即时假结果零 fork；refreshAvailability 的
// 后台探测走 YabaiClient（不经注入缝）真 fork 一次 query --spaces + SA 探针（节流窗
// 20s 内仅派发一次，只读命令）；结束后恢复注入缝与缓存槽位。

extension RunnerHarness {

    func runSpaceControllerCacheRaceTests() {
        print("\n=== SpaceControllerCacheRace (B327) ===")
        let sc = SpaceController.shared
        let savedSpaces = sc.spacesQueryCache
        let savedWindows = sc.windowQueryCache
        let savedTable = sc.displayMatchTable
        defer {
            sc.processRunnerOverride = nil
            sc.spacesQueryCache = savedSpaces
            sc.windowQueryCache = savedWindows
            sc.displayMatchTable = savedTable
        }

        // ---- 替身 JSON（字段形状与真 yabai 输出一致，RunnerYabaiStubSeamTests 同源） ----
        let spacesJSON = #"[{"id":11,"index":1,"display":1,"is-visible":true},{"id":12,"index":2,"display":1,"is-visible":false}]"#
        let windowJSON = #"{"id":3220,"pid":99,"app":"iTerm2","title":"race stub","space":1,"display":1,"frame":{"x":0,"y":0,"w":800,"h":600},"is-floating":false,"has-ax-reference":true,"is-minimized":false,"has-focus":true}"#
        let windowsJSON = "[\(windowJSON),{\"id\":3221,\"pid\":99,\"app\":\"iTerm2\",\"title\":\"race stub 2\",\"space\":2,\"display\":1,\"frame\":{\"x\":0,\"y\":0,\"w\":400,\"h\":300},\"is-floating\":false,\"has-ax-reference\":true,\"is-minimized\":false,\"has-focus\":false}]"
        // displays 帧按本机主屏做 Cocoa→Quartz 换算，保证几何匹配表非空（打满写表路径）
        let screens = NSScreen.screens
        var displaysJSON = "[]"
        if let main = screens.first {
            let primaryHeight = ScreenGeometry(cocoaFrames: screens.map { $0.frame }).primaryHeight
            let q = CoordinateKit.quartzRect(fromCocoa: main.frame, primaryHeight: primaryHeight)
            displaysJSON = "[{\"index\":1,\"frame\":{\"x\":\(q.minX),\"y\":\(q.minY),\"w\":\(q.width),\"h\":\(q.height)}}]"
        }

        // ---- A. 注入缝语义 ----
        sc.processRunnerOverride = { _, args in
            let payload: String
            if args.contains("--spaces") {
                payload = spacesJSON
            } else if args.contains("--displays") {
                payload = displaysJSON
            } else if args.contains("--windows") {
                payload = windowsJSON
            } else {
                payload = "race-stub-ok"
            }
            return YabaiClient.YabaiResult(exitCode: 0, stdout: payload, stderr: "")
        }
        sc.clearQueryCache()
        let seamSpaces = sc.querySpaces(caller: "raceSeam", ignoreCache: true)
        check("spaceRace: 注入缝生效——querySpaces 返回替身 JSON", seamSpaces?.count == 2)
        check("spaceRace: 注入缝生效——queryWindow 返回替身窗",
              sc.queryWindow(windowID: 3220, ignoreCache: true)?.id == 3220)

        // ---- B. 轰炸：querySpaces / queryWindow 缓存并发读写 ----
        // 8 路 worker（concurrentPerform 调用线程 + GCD 池 7 线程）混布读/写/双缓存操作；
        // 修复前：无锁字典并发读写（B313/B314 下放后的真实生产并发形态）。
        do {
            let iterations = 8 * 1200
            DispatchQueue.concurrentPerform(iterations: iterations) { i in
                switch i % 8 {
                case 0, 1, 2:
                    // 写 spacesQueryCache（executor 线程下放形态：恒 ignoreCache 直查回写）
                    _ = sc.querySpaces(caller: "raceWrite\(i % 8)", ignoreCache: true)
                case 3, 4:
                    // 读 spacesQueryCache（主线程 toggle/restore 形态：吃缓存）
                    _ = sc.querySpaces(caller: "raceRead")
                case 5, 6:
                    // 写 windowQueryCache（grid 链 queryWindow 下放形态）
                    _ = sc.queryWindow(windowID: UInt32(3220 + (i % 2)), ignoreCache: true)
                default:
                    // 读 windowQueryCache
                    _ = sc.queryWindow(windowID: 3220)
                }
            }
            check("spaceRace: 缓存并发轰炸 \(iterations) 次零崩溃（字典/COW 结构完好）", true)
            // 收尾一致性：轰炸后缓存读路径返回合法替身数据
            let postSpaces = sc.querySpaces(caller: "racePost")
            check("spaceRace: 轰炸后 querySpaces 一致", postSpaces?.count == 2)
            let postWindow = sc.queryWindow(windowID: 3220)
            check("spaceRace: 轰炸后 queryWindow 一致", postWindow?.id == 3220)
        }

        // ---- C. 轰炸：displayMatchTable 并发重建（exact* 双端：主线程 + executor 线程） ----
        do {
            sc.invalidateDisplayMatchTable()
            let backgroundIterations = 6 * 250
            DispatchQueue.concurrentPerform(iterations: backgroundIterations) { _ in
                // executor 线程形态（activeSpaceIndexOffMain / restore 链 exactNSScreen）
                _ = sc.exactNSScreen(forYabaiDisplayIndex: 1)
            }
            // 主线程形态（toggle/overlay 热路径 exactYabaiDisplayIndex）与后台并发交错
            if let screen = NSScreen.screens.first {
                for _ in 0..<250 {
                    _ = sc.exactYabaiDisplayIndex(for: screen)
                }
            }
            check("spaceRace: 几何匹配表并发重建轰炸零崩溃", true)
            // 重建路径真实命中过（表已重建且几何匹配到本机屏，displays 替身按主屏换算）
            check("spaceRace: 轰炸后 exactNSScreen 解析到本机屏",
                  sc.exactNSScreen(forYabaiDisplayIndex: 1) != nil)
        }

        // ---- D. 轰炸：toggle 清扫（clear*）与写路径并发（锁内 removeAll vs 锁内写回） ----
        // 注记：@Published 值面（markOperationError/refreshAvailability）不进 concurrentPerform——
        // 后台线程持 stateLock 写 @Published 会同步触发 SwiftUI Update.syncMain 等主线程，
        // 与主线程 concurrentPerform 等待构成三环死锁（2026-11-26 首轮实测卡死，sample 铁证；
        // 生产无此形态=主线程从不同步等待 WindowWorkExecutor）。值面竞态非崩溃面，显式留白。
        do {
            let iterations = 8 * 600
            DispatchQueue.concurrentPerform(iterations: iterations) { i in
                switch i % 4 {
                case 0:
                    sc.clearQueryCache()            // toggle 收尾清扫（全清）
                case 1:
                    sc.clearWindowQueryCache()      // move_to_main 清扫（只清窗口缓存）
                case 2:
                    _ = sc.querySpaces(caller: "raceSweep", ignoreCache: true)
                default:
                    _ = sc.queryWindow(windowID: 3220, ignoreCache: true)
                }
            }
            check("spaceRace: 清扫×写并发轰炸零崩溃（clear* 与写回临界区互斥完好）", true)
        }

        // ---- E. 清扫（防跨域残留：确定性红先查 Runner 域残留的家法） ----
        sc.clearQueryCache()
        sc.invalidateDisplayMatchTable()
        sc.processRunnerOverride = nil
    }
}
