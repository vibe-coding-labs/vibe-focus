import AppKit
import ApplicationServices.HIServices
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerAXWriteE2ETests.swift — B252：AXWrite 域真机 E2E（AX 写入编排层
// resizeViaAX/apply 的专属取证通道）。单测通道结构性不可达（AX 写需要真授权真窗口），
// 本通道在真机上用自建 iTerm2 scratch 窗逐函数取证，结束真实关窗+盘点归零。
// 前置：iTerm2、yabai、本机证书重签 Runner（见 Tests/e2e/README）。
// 跑法：VIBEFOCUS_AXWRITE_E2E=1 .build/debug/VibeFocusTestRunner
//
// ⚠️B252 事故教训（已固化）：iTerm2 AppleScript window id 与 yabai id 不同源——
// 清理严禁走 `window id <yabaiID>` 或 close every window（会危及用户窗）；本文件
// 全程只用 yabai 通道（窗口 JSON 自带 pid/frame，id 空间天然一致）。

extension RunnerHarness {
    func runAXWriteE2E() {
        guard ProcessInfo.processInfo.environment["VIBEFOCUS_AXWRITE_E2E"] == "1" else { return }
        print("\n=== AXWrite 域真机 E2E ===")

        func yabaiWindowIDs() -> Set<UInt32> {
            guard let out = ShellRunner.run(executable: "/opt/homebrew/bin/yabai", arguments: ["-m", "query", "--windows"], timeout: 30),
                  out.exitCode == 0 else { return [] }
            let regex = try? NSRegularExpression(pattern: "\"id\":\\s*(\\d+)")
            let range = NSRange(out.stdout.startIndex..., in: out.stdout)
            var ids: Set<UInt32> = []
            for result in (regex ?? NSRegularExpression()).matches(in: out.stdout, range: range) {
                guard result.numberOfRanges > 1, let r = Range(result.range(at: 1), in: out.stdout),
                      let n = UInt32(out.stdout[r]) else { continue }
                ids.insert(n)
            }
            return ids
        }
        /// 返回 (frame, pid)：pid 直接取自 yabai 窗口 JSON（B252：绕开 AppleScript
        /// unix id 在多实例/裸副本机器上的不确定性，且 id 空间与后续清理通道一致）
        func yabaiWindowFrameAndPID(_ id: UInt32) -> (frame: CGRect, pid: Int32)? {
            guard let out = ShellRunner.run(executable: "/opt/homebrew/bin/yabai",
                arguments: ["-m", "query", "--windows", "--window", "\(id)"], timeout: 30),
                out.exitCode == 0,
                let data = out.stdout.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let f = obj["frame"] as? [String: Any],
                let x = (f["x"] as? NSNumber)?.doubleValue,
                let y = (f["y"] as? NSNumber)?.doubleValue,
                let w = (f["w"] as? NSNumber)?.doubleValue,
                let h = (f["h"] as? NSNumber)?.doubleValue else { return nil }
            let pid = (obj["pid"] as? NSNumber)?.int32Value ?? 0
            return (CGRect(x: x, y: y, width: w, height: h), pid)
        }
        func yabaiPlace(_ id: UInt32, frame: CGRect) {
            _ = SpaceController.shared.runYabai(
                arguments: ["-m", "window", "\(id)", "--move", "abs:\(Int(frame.origin.x)):\(Int(frame.origin.y))"],
                operation: "axwrite-e2e.place", operationID: "axwrite-e2e")
            _ = SpaceController.shared.runYabai(
                arguments: ["-m", "window", "\(id)", "--resize", "abs:\(Int(frame.width)):\(Int(frame.height))"],
                operation: "axwrite-e2e.place", operationID: "axwrite-e2e")
        }
        /// scoped 关窗：只碰自建 wid（yabai close 幂等重试；失败时先 focus 再试）。
        /// 延迟复核 yabai 盘点归零（close 落地可能有延迟）。
        func scopedCloseAndVerify(_ wid: UInt32) -> Bool {
            _ = SpaceController.shared.runYabai(
                arguments: ["-m", "window", "\(wid)", "--close"],
                operation: "axwrite-e2e.cleanup", operationID: "axwrite-e2e")
            var gone = !yabaiWindowIDs().contains(wid)
            for _ in 0..<12 where !gone {
                Thread.sleep(forTimeInterval: 1.5)
                gone = !yabaiWindowIDs().contains(wid)
                if !gone {
                    _ = SpaceController.shared.runYabai(
                        arguments: ["-m", "window", "\(wid)", "--focus"],
                        operation: "axwrite-e2e.cleanup", operationID: "axwrite-e2e")
                    _ = SpaceController.shared.runYabai(
                        arguments: ["-m", "window", "\(wid)", "--close"],
                        operation: "axwrite-e2e.cleanup", operationID: "axwrite-e2e")
                }
            }
            return gone
        }

        // 预检：直探 yabai（refreshAvailability 是异步回填，禁即时断言）
        let directProbe = ShellRunner.run(executable: "/opt/homebrew/bin/yabai",
            arguments: ["-m", "query", "--windows"], timeout: 30)
        check("AXWriteE2E: yabai 可用（直探 exit 0）",
              directProbe?.exitCode == 0 && directProbe?.stdout.isEmpty == false)

        guard let mainScreen = NSScreen.screens.first(where: { CoordinateKit.cgDisplayID(for: $0) == CGMainDisplayID() }) else {
            check("AXWriteE2E: 主屏存在", false)
            return
        }
        let mainVisible = CoordinateKit.quartzVisibleFrame(of: mainScreen)
        let idsBefore = yabaiWindowIDs()
        _ = ShellRunner.run(executable: "/usr/bin/osascript", arguments: ["-e",
            "tell application id \"com.googlecode.iterm2\" to create window with default profile"], timeout: 30)
        Thread.sleep(forTimeInterval: 1.5)
        let created = yabaiWindowIDs().subtracting(idsBefore)
        guard created.count == 1, let wid = created.first else {
            check("AXWriteE2E: 创建 iTerm2 测试窗口", false)
            return
        }
        print("    [诊断] 测试窗口 yabai id=\(wid)")
        check("AXWriteE2E: 创建 iTerm2 测试窗口", true)

        // 清场闸门：无论后续成败，从这里出去前必须真实关窗
        defer {
            if !scopedCloseAndVerify(wid) {
                check("AXWriteE2E: 测试窗口已真实关闭（yabai 盘点归零）", false)
            }
        }

        let originalFrame = CGRect(x: mainVisible.minX + 40, y: mainVisible.minY + 40, width: 900, height: 600)
        yabaiPlace(wid, frame: originalFrame)
        Thread.sleep(forTimeInterval: 0.6)
        guard let placed = yabaiWindowFrameAndPID(wid), placed.pid > 0 else {
            check("AXWriteE2E: 初始摆位与 pid 读取", false)
            return
        }
        check("AXWriteE2E: 初始摆位与 pid 读取（pid=\(placed.pid)）", true)

        // AX ref 解析：iTerm2 新窗 AX 懒注册（Terminal 同款），轮询重试
        var axRef: AXUIElement?
        for _ in 0..<5 {
            axRef = WindowManager.shared.findWindowByPID(placed.pid, windowID: wid)
            if axRef != nil { break }
            Thread.sleep(forTimeInterval: 0.8)
        }
        guard let axRef else {
            check("AXWriteE2E: AX 窗口引用解析（pid=\(placed.pid) wid=\(wid)）", false)
            return
        }
        check("AXWriteE2E: AX 窗口引用解析", true)

        // Case A：resizeViaAX 同屏收窄（900x600 → 640x480），yabai 读回对账 ±30
        let shrinkTarget = CGRect(x: originalFrame.minX + 20, y: originalFrame.minY + 20, width: 640, height: 480)
        let resizeOK = WindowManager.shared.resizeViaAX(
            targetFrame: shrinkTarget, window: axRef, windowID: wid,
            op: "axwrite-e2e", stage: "resize_via_ax")
        Thread.sleep(forTimeInterval: 0.6)
        if let frame = yabaiWindowFrameAndPID(wid)?.frame {
            let sizeOK = abs(frame.width - 640) <= 30 && abs(frame.height - 480) <= 30
            print("    [诊断] resizeViaAX 终帧=\(frame)")
            check("AXWriteE2E resizeViaAX: AX 调用成功", resizeOK)
            check("AXWriteE2E resizeViaAX: 读回尺寸一致（±30）", sizeOK)
        } else {
            check("AXWriteE2E resizeViaAX: 读回终帧", false)
        }

        // Case B：apply 两阶段全 frame（size+position），yabai 读回对账 ±30/±60
        let applyTarget = CGRect(x: mainVisible.minX + 80, y: mainVisible.minY + 80, width: 800, height: 560)
        let applyOK = WindowManager.shared.apply(
            frame: applyTarget, to: axRef,
            operationID: "axwrite-e2e-apply", stage: "apply_e2e", maxAttempts: 3, windowID: wid)
        Thread.sleep(forTimeInterval: 0.6)
        if let frame = yabaiWindowFrameAndPID(wid)?.frame {
            let sizeOK = abs(frame.width - 800) <= 30 && abs(frame.height - 560) <= 30
            let posOK = abs(frame.minX - applyTarget.minX) <= 60 && abs(frame.minY - applyTarget.minY) <= 60
            print("    [诊断] apply 终帧=\(frame)")
            check("AXWriteE2E apply: 两阶段调用成功", applyOK)
            check("AXWriteE2E apply: 读回尺寸一致（±30）", sizeOK)
            check("AXWriteE2E apply: 读回位置一致（±60）", posOK)
        } else {
            check("AXWriteE2E apply: 读回终帧", false)
        }
    }
}
