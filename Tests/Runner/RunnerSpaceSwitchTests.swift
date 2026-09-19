// Tests/Runner/RunnerSpaceSwitchTests.swift — SpaceController+Switch 编排层实例直测（B237）。
// 候选选择纯核（selectRefocusCandidates）已有锁定；本文件测实例编排：focusSpace 守卫序、
// 真实 yabai 只读查询通道、switchToSpace 对「当前可见 space」的 B164 判定（目标已可见
// = 无需切换）、refocus 空候选短路。**红线：绝不聚焦非当前可见 space、绝不碰用户窗口
// 焦点**——refocus 逐候选聚焦循环（92-125）只对自家不可达环境诚实留白。

import AppKit
import Foundation
@testable import VibeFocusKit

extension RunnerHarness {
    func runSpaceSwitchTests() {
        let sc = SpaceController.shared
        // 可用性就绪（B180 探测后台化——泵 RunLoop 等结果）
        check("spaceSwitch: yabai 可用（前置）", waitForSpaceAvailability())

        // A. 不受支持的 space 标识 → 守卫直接拒绝（零 fork，先于可用性判定）
        check("spaceSwitch: nativeID 无 yabai 索引 → false（守卫序第一）",
              !sc.focusSpace(.nativeID(7)))

        // 当前可见 space（守卫类用例的安全靶：聚焦它=视角不变）
        guard let visibleIndex = sc.querySpaces(ignoreCache: true)?
            .first(where: { $0.isVisible == true })?
            .index else {
            check("spaceSwitch: 当前可见 space 可查询（前置）", false)
            return
        }
        check("spaceSwitch: 当前可见 space = \(visibleIndex)", visibleIndex >= 1)

        // B. focusSpace 对当前可见 space：守卫拒（无控制权）或 yabai 拒（「cannot focus
        //    an already focused space」exit 1，2026-09-19 本机实测）——两条路都如实 false
        check("spaceSwitch: focusSpace 当前可见 space → false（守卫或 yabai 拒重复聚焦）",
              !sc.focusSpace(.yabaiIndex(visibleIndex), operationID: "vf-sw-test"))
        // 不存在的 space → 查询失败错误上报分支（零用户影响）
        check("spaceSwitch: focusSpace 不存在的 space → false（错误上报分支）",
              !sc.focusSpace(.yabaiIndex(9999), operationID: "vf-sw-test"))

        // C. 真实只读查询通道：按 space 过滤查询非 nil；全局焦点 id 为正或 nil（契约）
        let windowsOnSpace = sc.queryWindowsOnSpace(visibleIndex, operationID: "vf-sw-test")
        check("spaceSwitch: queryWindowsOnSpace 真实查询非 nil", windowsOnSpace != nil)
        let focused = sc.focusedWindowID(operationID: "vf-sw-test")
        check("spaceSwitch: focusedWindowID 契约（nil 或正整数窗口 id）",
              focused.map { $0 > 0 } ?? true)

        // D. refocus 空候选短路（不触碰任何窗口焦点）：
        //    预取空表 → 查询都不发起；预取仅含被排除窗 → 候选空
        check("spaceSwitch: refocus 预取空表 → false（零聚焦动作）",
              !sc.refocusWindowOnSpace(visibleIndex, operationID: "vf-sw-test", prefetchedWindows: []))
        // 排除后候选空：全合成预取表（唯一条目被排除）——零碰真实窗口。
        // ⚠️ 禁用真实 windowsOnSpace 做排除表：当前 space 有多窗时会真的聚焦用户窗口
        //（首版实测踩到，动用户焦点=事故）。
        let synthetic = window(id: 555_001, space: visibleIndex)
        check("spaceSwitch: refocus 唯一候选被排除 → false（合成表，零聚焦动作）",
              !sc.refocusWindowOnSpace(visibleIndex, excludingWindowID: 555_001,
                                       operationID: "vf-sw-test",
                                       prefetchedWindows: [synthetic]))

        // E. switchToSpace 对当前可见 space（B164 判定：目标屏已显示目标 space
        //    = 无需切换）→ 目标状态 visible，不触发真实切换动作
        let result = sc.switchToSpace(visibleIndex, operationID: "vf-sw-test")
        check("spaceSwitch: switchToSpace 当前可见 space → 状态 visible（B164 不误判切换）",
              result.state == .visible)
    }
}
