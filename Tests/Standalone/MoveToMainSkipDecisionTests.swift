// Tests/Standalone/MoveToMainSkipDecisionTests.swift
// Verification: move_to_main「已在主屏跳过」纯决策
// Mirrors: Sources/Support/MoveToMainPipeline.swift
//          (MoveToMainPipeline.isAlreadyMaximizedOnMain)
// Run: swift Tests/Standalone/MoveToMainSkipDecisionTests.swift

import Foundation
import CoreGraphics

// MARK: - Mirrored types

enum MoveToMainPipelineMirror {
    /// 已在主屏即视为已最大化（仅 AX 路径消费）：display == 1 且 frame 中心落在主屏内。
    static func isAlreadyMaximizedOnMain(displayYabaiIndex: Int?, mainScreenFrame: CGRect?, frame: CGRect) -> Bool {
        guard displayYabaiIndex == 1, let mainScreenFrame else { return false }
        return mainScreenFrame.contains(CGPoint(x: frame.midX, y: frame.midY))
    }
}

// MARK: - Test harness

var passed = 0
var failed = 0
func check(_ name: String, _ condition: Bool) {
    if condition {
        passed += 1
    } else {
        failed += 1
        print("FAIL: \(name)")
    }
}

let mainScreen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
let insideMain = CGRect(x: 100, y: 100, width: 800, height: 600)
let outsideMain = CGRect(x: -800, y: -700, width: 400, height: 300)

check("display yabai 1 + 中心在主屏 → skip",
      MoveToMainPipelineMirror.isAlreadyMaximizedOnMain(displayYabaiIndex: 1, mainScreenFrame: mainScreen, frame: insideMain))
check("display yabai 2 不 skip（副屏窗口）",
      !MoveToMainPipelineMirror.isAlreadyMaximizedOnMain(displayYabaiIndex: 2, mainScreenFrame: mainScreen, frame: insideMain))
check("display nil 不 skip（查询失败按最坏情况继续 apply）",
      !MoveToMainPipelineMirror.isAlreadyMaximizedOnMain(displayYabaiIndex: nil, mainScreenFrame: mainScreen, frame: insideMain))
check("主屏 frame nil 不 skip（防御）",
      !MoveToMainPipelineMirror.isAlreadyMaximizedOnMain(displayYabaiIndex: 1, mainScreenFrame: nil, frame: insideMain))
check("中心在主屏外不 skip（原点判断会误判，中心判断防跨屏半悬窗）",
      !MoveToMainPipelineMirror.isAlreadyMaximizedOnMain(displayYabaiIndex: 1, mainScreenFrame: mainScreen, frame: outsideMain))
check("display 1 + frame 恰等于主屏可视区 → skip",
      MoveToMainPipelineMirror.isAlreadyMaximizedOnMain(displayYabaiIndex: 1, mainScreenFrame: mainScreen, frame: mainScreen))
check("仅边缘搭接（中心在内）→ skip",
      MoveToMainPipelineMirror.isAlreadyMaximizedOnMain(displayYabaiIndex: 1, mainScreenFrame: mainScreen, frame: CGRect(x: -200, y: -100, width: 400, height: 300)))
check("中心恰在主屏右边缘外不 skip（contains 开区间语义）",
      !MoveToMainPipelineMirror.isAlreadyMaximizedOnMain(displayYabaiIndex: 1, mainScreenFrame: mainScreen, frame: CGRect(x: mainScreen.maxX, y: 0, width: 400, height: 300)))

print("\nMoveToMainSkipDecisionTests: \(passed + failed) checks, \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
