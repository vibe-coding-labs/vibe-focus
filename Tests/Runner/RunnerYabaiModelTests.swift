import CoreGraphics
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerYabaiModelTests.swift — B73：YabaiModelTests 漂移镜像退役转真身直测。
// Tests/Standalone/YabaiModelTests.swift（389 行）机械比对实锤漂移：镜像的
// YabaiWindowInfo 副本没有 hasFocusRaw（真身 has-focus 字段，守卫降级路径消费）——
// 镜像的全字段解码对真身新字段永久失明；YabaiSpaceInfo 副本也无宽容解码（合成
// Decodable 遇 int 形态会整体失败，真身 decodeFlexibleBool 不炸）。
// 其空间/窗口 minimized/ax 双键解码、decodeSingleOrFirst 已在 PureSweepA/RestoreOrchestration/
// RunnerSpaceIdentityTests(B71) 直测，本文件只补真身剩余缺口：
// WindowInfo 全字段黄金解码（含 has-focus）、flexible bool 三态补充、Frame 换算、
// DisplayInfo 负 y、formatErrorMessage、decodeArray、ScriptWindowSnapshot 契约。

extension RunnerHarness {
    func runYabaiModelTests() {
        // ===== A. YabaiWindowInfo 全字段黄金解码（自定义 Decodable 的 11 键映射总锁） =====
        do {
            let win = try! JSONDecoder().decode(
                YabaiWindowInfo.self,
                from: Data(#"""
                {"id":42,"pid":1234,"app":"Terminal","title":"bash","space":2,"display":1,
                 "frame":{"x":0,"y":0,"w":800,"h":600},"is-floating":true,
                 "has-ax-reference":true,"is-minimized":false,"has-focus":true}
                """#.utf8))
            check("yabaiWin: 全字段黄金解码（id/pid/app/title/space/display/frame）",
                  win.id == 42 && win.pid == 1234 && win.app == "Terminal" && win.title == "bash"
                  && win.space == 2 && win.display == 1
                  && win.frame?.cgRect == CGRect(x: 0, y: 0, width: 800, height: 600))
            check("yabaiWin: 四计算属性随解码值就位（floating/ax/minimized/has-focus）",
                  win.isFloating && win.isManageableByYabai && !win.isMinimized && win.hasFocus)
        }

        // ===== B. has-focus 解码（镜像漂移证明点：副本无此键）+ 缺失容错 =====
        do {
            func decodeWin(_ json: String) -> YabaiWindowInfo? {
                try? JSONDecoder().decode(YabaiWindowInfo.self, from: Data(json.utf8))
            }
            check("yabaiWin: has-focus bool true / 缺失按无焦点",
                  decodeWin(#"{"has-focus": true}"#)?.hasFocus == true
                  && decodeWin(#"{"has-focus": 1}"#)?.hasFocus == true
                  && decodeWin(#"{}"#)?.hasFocus == false)
        }

        // ===== C. flexible bool 三态补充（is-floating false/缺失/Int 形态）=====
        do {
            func decodeWin(_ json: String) -> YabaiWindowInfo? {
                try? JSONDecoder().decode(YabaiWindowInfo.self, from: Data(json.utf8))
            }
            check("yabaiWin: is-floating false/缺失 → false；int 1 → true（合成 Decodable 已死路）",
                  decodeWin(#"{"is-floating": false}"#)?.isFloating == false
                  && decodeWin(#"{}"#)?.isFloating == false
                  && decodeWin(#"{"is-floating": 1}"#)?.isFloating == true)
        }

        // ===== D. minimized 双键并存 v7 优先 + 垃圾类型不炸整体解码 =====
        do {
            func decodeWin(_ json: String) -> YabaiWindowInfo? {
                try? JSONDecoder().decode(YabaiWindowInfo.self, from: Data(json.utf8))
            }
            check("yabaiWin: 双键并存 v7 is-minimized 优先压过旧版 minimized",
                  decodeWin(#"{"is-minimized": false, "minimized": true}"#)?.isMinimized == false)
            check("yabaiWin: 垃圾字符串值 → 字段 nil 按未最小化、整体解码不炸",
                  decodeWin(#"{"is-minimized": "yes"}"#)?.isMinimized == false
                  && decodeWin(#"{"is-minimized": "yes"}"#)?.id == nil)
        }

        // ===== E. Frame.cgRect 换算 =====
        do {
            let cg = YabaiWindowInfo.Frame(x: 100, y: 200, w: 800, h: 600).cgRect
            check("yabaiWin: Frame cgRect 换算（x/y/w/h 逐项）",
                  cg == CGRect(x: 100, y: 200, width: 800, height: 600))
        }

        // ===== F. YabaiDisplayInfo：负 y（副屏在主屏上方）+ frame 缺失 =====
        do {
            let di = try? JSONDecoder().decode(
                YabaiDisplayInfo.self,
                from: Data(#"{"index":2,"frame":{"x":0,"y":-1440,"w":2560,"h":1440}}"#.utf8))
            check("yabaiDisplay: 副屏负 y 保真解析", di?.index == 2 && di?.frame?.y == -1440
                  && di?.frame?.w == 2560)
            let bare = try? JSONDecoder().decode(YabaiDisplayInfo.self, from: Data(#"{"index":1}"#.utf8))
            check("yabaiDisplay: frame 缺失 → nil 不炸", bare?.index == 1 && bare?.frame == nil)
        }

        // ===== G. formatErrorMessage：stderr 优先 / stdout 回落 / 双空默认 / 修剪 =====
        do {
            check("yabaiErr: stderr 优先于 stdout",
                  SpaceController.formatErrorMessage(stdout: "ok output", stderr: "error msg") == "error msg")
            check("yabaiErr: stderr 空 → stdout 回落",
                  SpaceController.formatErrorMessage(stdout: "some output", stderr: "") == "some output")
            check("yabaiErr: 双空/纯空白 → 固定默认文案",
                  SpaceController.formatErrorMessage(stdout: "", stderr: "") == "yabai returned empty error output"
                  && SpaceController.formatErrorMessage(stdout: "  ", stderr: "  ") == "yabai returned empty error output")
            check("yabaiErr: 输出首尾空白修剪",
                  SpaceController.formatErrorMessage(stdout: "", stderr: "  actual error  ") == "actual error")
        }

        // ===== H. decodeArray（4 个查询路径共用的数组解析单一出口） =====
        do {
            let two = SpaceController.shared.decodeArray(
                YabaiSpaceInfo.self,
                from: #"[{"id":1,"index":1},{"id":2,"index":2}]"#)
            check("yabaiArr: 数组解码全量返回（非取首）",
                  two?.count == 2 && two?.first?.id == 1 && two?.last?.id == 2)
            check("yabaiArr: 单对象/垃圾输入 → nil",
                  SpaceController.shared.decodeArray(YabaiSpaceInfo.self, from: #"{"id":1}"#) == nil
                  && SpaceController.shared.decodeArray(YabaiSpaceInfo.self, from: "not json") == nil)
        }

        // ===== I. WindowManager.ScriptWindowSnapshot：Codable 回环 + frame 换算 =====
        do {
            let snap = WindowManager.ScriptWindowSnapshot(
                windowID: 42, appName: "Terminal", title: "bash",
                x: 100, y: 200, width: 800, height: 600)
            let decoded = try? JSONDecoder().decode(
                WindowManager.ScriptWindowSnapshot.self,
                from: JSONEncoder().encode(snap))
            check("scriptSnap: Codable 回环全字段 + frame 换算",
                  decoded?.windowID == 42 && decoded?.appName == "Terminal" && decoded?.title == "bash"
                  && decoded?.frame == CGRect(x: 100, y: 200, width: 800, height: 600))
            let anonymous = WindowManager.ScriptWindowSnapshot(
                windowID: nil, appName: "App", title: nil, x: 50, y: 75, width: 640, height: 480)
            let anonDecoded = try? JSONDecoder().decode(
                WindowManager.ScriptWindowSnapshot.self, from: JSONEncoder().encode(anonymous))
            check("scriptSnap: windowID/title 可选 nil 回环",
                  anonDecoded?.windowID == nil && anonDecoded?.title == nil
                  && anonDecoded?.appName == "App")
        }
    }
}
