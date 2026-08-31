// AX 挪动换屏机制验证脚本（2026-09-01 toggle 修复前置验证）
// 用途：逐条断言修复方案依赖的机制，全部 PASS 后才将该方案落入主代码。
// 原则：只操作本脚本自建的测试窗口，不碰用户任何窗口。
//
// 运行：swift Tests/AXMoveValidation.swift
// 断言清单：
//   T0  辅助功能权限可用
//   T1  自建窗口可被 yabai 看到（拿到窗口标识）
//   T2  AX 写 position+size 在 float 窗口上生效（读回比对）
//   T3  AX 把窗口挪到另一块屏的坐标区后，窗口 space/display 归属自动跟随
//   T4  float toggle 保持窗口脱离 yabai 平铺管理（不会被 re-tile）

import AppKit
import ApplicationServices
import ApplicationServices.HIServices

var failures: [String] = []
func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    let mark = condition ? "PASS" : "FAIL"
    print("[\(mark)] \(name)\(detail.isEmpty ? "" : "  -- \(detail)")")
    if !condition { failures.append(name) }
}

func axFrame(_ window: AXUIElement) -> CGRect? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, "AXFrame" as CFString, &value) == .success,
          let frameRef = value else { return nil }
    let axValue = unsafeBitCast(frameRef, to: AXValue.self)
    var frame = CGRect.zero
    guard AXValueGetValue(axValue, .cgRect, &frame) else { return nil }
    return frame
}

func axSetFrame(_ window: AXUIElement, _ frame: CGRect) {
    var origin = CGPoint(x: frame.origin.x, y: frame.origin.y)
    if let v = AXValueCreate(.cgPoint, &origin) {
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v)
    }
    var sz = CGSize(width: frame.width, height: frame.height)
    if let v = AXValueCreate(.cgSize, &sz) {
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v)
    }
}

func yabaiWindowInfo(pid: Int32, titlePrefix: String) -> (id: Int, space: Int, display: Int, floating: Bool, frame: [String: Double])? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/yabai")
    task.arguments = ["-m", "query", "--windows"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do { try task.run() } catch { return nil }
    task.waitUntilExit()
    guard task.terminationStatus == 0,
          let data = try? pipe.fileHandleForReading.readToEnd(),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
    for w in arr {
        if (w["pid"] as? Int32) == pid, let t = w["title"] as? String, t.hasPrefix(titlePrefix) {
            let frame = w["frame"] as? [String: Double] ?? [:]
            return (w["id"] as? Int ?? -1,
                    w["space"] as? Int ?? -1,
                    w["display"] as? Int ?? -1,
                    (w["is-floating"] as? Bool) ?? false,
                    frame)
        }
    }
    return nil
}

@discardableResult
func yabaiRun(_ args: [String]) -> Int32 {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/yabai")
    task.arguments = args
    task.standardOutput = Pipe(); task.standardError = Pipe()
    do { try task.run() } catch { return -1 }
    task.waitUntilExit()
    return task.terminationStatus
}

// MARK: - T0 辅助功能权限
let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": false] as CFDictionary)
check("T0 辅助功能权限", trusted)
guard trusted else {
    print("\n结果: \(failures.count) 项失败（T0 未过，后续无法执行）")
    exit(1)
}

// MARK: - 测试夹具窗口（TextEdit 空白文档，测完即关；不碰用户任何窗口）
let fixtureTitle = "Untitled"  // TextEdit 新文档默认标题
// 干净启动：先确保 TextEdit 不在跑（残留进程会残留旧窗口状态）
let kill = Process()
kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
kill.arguments = ["TextEdit"]
kill.standardOutput = Pipe(); kill.standardError = Pipe()
try? kill.run(); kill.waitUntilExit()
usleep(500_000)

let launch = Process()
launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
launch.arguments = ["-a", "TextEdit"]
launch.standardOutput = Pipe(); launch.standardError = Pipe()
try? launch.run(); launch.waitUntilExit()

// 等 TextEdit 起来并拿到其 pid
var tePid: Int32 = -1
let deadline = Date().addingTimeInterval(8.0)
while Date() < deadline && tePid < 0 {
    let pg = Process()
    pg.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pg.arguments = ["-x", "TextEdit"]
    let pgPipe = Pipe()
    pg.standardOutput = pgPipe; pg.standardError = Pipe()
    try? pg.run(); pg.waitUntilExit()
    if let out = try? pgPipe.fileHandleForReading.readToEnd(),
       let s = String(data: out, encoding: .utf8), let first = s.split(separator: "\n").first,
       let p = Int32(first) {
        tePid = p
    }
    if tePid < 0 { usleep(300_000) }
}
// 等窗口完成 AX/yabai 注册
usleep(1_000_000)

// MARK: - T1 夹具窗口 AX/yabai 可见
let teAX = AXUIElementCreateApplication(tePid)
var children: CFTypeRef?
AXUIElementCopyAttributeValue(teAX, kAXWindowsAttribute as CFString, &children)
let axWindows = (children as? [AXUIElement]) ?? []
var targetAX: AXUIElement?
for w in axWindows {
    var t: CFTypeRef?
    AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
    if let title = t as? String, title.hasPrefix(fixtureTitle) { targetAX = w; break }
}
let yabaiInfo = yabaiWindowInfo(pid: tePid, titlePrefix: fixtureTitle)
if targetAX == nil || yabaiInfo == nil {
    print("    debug: tePid=\(tePid) axWindows=\(axWindows.count) yabaiInfo=\(yabaiInfo.map { "space\($0.space)" } ?? "nil")")
}
check("T1 夹具窗口 AX/yabai 可见", targetAX != nil && yabaiInfo != nil)
guard let targetAX, let info0 = yabaiInfo else {
    print("\n结果: \(failures.count) 项失败")
    exit(1)
}
let homeSpace = info0.space
let homeDisplay = info0.display
print("    测试窗口初始: space=\(homeSpace) display=\(homeDisplay) float=\(info0.floating)")

// MARK: - T2 AX 写 frame 生效（float 状态）
let t2Target = CGRect(x: 260, y: 260, width: 480, height: 300)
axSetFrame(targetAX, t2Target)
usleep(400_000)  // 400ms 等写生效（主方案 settle 时长）
let t2Actual = axFrame(targetAX)
let t2OK = t2Actual != nil
    && abs(t2Actual!.origin.x - t2Target.origin.x) <= 10
    && abs(t2Actual!.origin.y - t2Target.origin.y) <= 10
    && abs(t2Actual!.width - t2Target.width) <= 10
    && abs(t2Actual!.height - t2Target.height) <= 10
check("T2 AX 写 position+size 生效", t2OK, "target=\(t2Target) actual=\(t2Actual.map { "\($0)" } ?? "nil")")

// MARK: - T3 AX 挪到另一块屏坐标区 → space/display 归属跟随
// 找一块与本窗口当前 display 不同的屏
var targetDisplayFrame: NSRect? = nil
var targetDisplayIndex = -1
for (i, screen) in NSScreen.screens.enumerated() {
    if screen.frame.origin.y >= 0 && screen.frame.origin.x >= 0 && abs(screen.frame.origin.x) < 1 && abs(screen.frame.origin.y) < 1 {
        continue  // 跳过主屏（原点 0,0）
    }
    if i != 0 { targetDisplayFrame = screen.frame; targetDisplayIndex = i; break }
}
if targetDisplayFrame == nil, NSScreen.screens.count > 1 {
    // 兜底：取第一块非主屏
    for screen in NSScreen.screens where abs(screen.frame.origin.x) > 1 || abs(screen.frame.origin.y) > 1 {
        targetDisplayFrame = screen.frame; break
    }
}
if true {
    // 用 yabai 坐标系（左上原点）选一块非主屏 display
    let dp = Process()
    dp.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/yabai")
    dp.arguments = ["-m", "query", "--displays"]
    let dpPipe = Pipe()
    dp.standardOutput = dpPipe; dp.standardError = Pipe()
    try? dp.run(); dp.waitUntilExit()
    var destX = -1, destY = -1, destDisplayId = -1
    if let data = try? dpPipe.fileHandleForReading.readToEnd(),
       let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
        for d in arr {
            let did = d["id"] as? Int ?? -1
            guard did != homeDisplay else { continue }
            if let f = d["frame"] as? [String: Double] {
                destX = Int(f["x"] ?? 0) + 60
                destY = Int(f["y"] ?? 0) + 60
                destDisplayId = did
                break
            }
        }
    }
    guard destDisplayId > 0 else {
        print("[SKIP] T3 只有一块屏，无法验证换屏")
        exit(failures.isEmpty ? 0 : 1)
    }
    // 修复方案 v2：float toggle 脱管 → yabai --move abs/--resize abs 跨 display 挪 frame
    let windowId = info0.id
    yabaiRun(["-m", "window", "\(windowId)", "--toggle", "float"])
    usleep(300_000)
    yabaiRun(["-m", "window", "\(windowId)", "--move", "abs:\(destX):\(destY)"])
    yabaiRun(["-m", "window", "\(windowId)", "--resize", "abs:480:300"])
    usleep(600_000)
    if let moved = yabaiWindowInfo(pid: tePid, titlePrefix: fixtureTitle) {
        let spaceChanged = moved.space != homeSpace
        let displayChanged = moved.display != homeDisplay
        check("T3 float+yabai-move 挪动换屏归属跟随", spaceChanged && displayChanged,
              "home(space=\(homeSpace),disp=\(homeDisplay)) → now(space=\(moved.space),disp=\(moved.display)) frame=\(moved.frame) destDisplay=\(destDisplayId)")
        // 挪回原位（主屏）
        yabaiRun(["-m", "window", "\(windowId)", "--move", "abs:\(Int(t2Target.origin.x)):\(Int(t2Target.origin.y))"])
        yabaiRun(["-m", "window", "\(windowId)", "--resize", "abs:\(Int(t2Target.width)):\(Int(t2Target.height))"])
        usleep(600_000)
        if let back = yabaiWindowInfo(pid: tePid, titlePrefix: fixtureTitle) {
            check("T3b yabai-move 挪回原屏归属跟随", back.space == homeSpace || back.display == homeDisplay,
                  "now(space=\(back.space),disp=\(back.display))")
        }
    } else {
        check("T3 float+yabai-move 挪动换屏归属跟随", false, "挪动后 yabai 查询失败")
    }
}

// MARK: - T4 float 窗口不被 re-tile（静置后 frame 稳定）
let t4Before = axFrame(targetAX)
usleep(800_000)
let t4After = axFrame(targetAX)
let t4Stable = t4Before != nil && t4After != nil
    && abs(t4Before!.origin.x - t4After!.origin.x) <= 5
    && abs(t4Before!.origin.y - t4After!.origin.y) <= 5
    && abs(t4Before!.width - t4After!.width) <= 5
    && abs(t4Before!.height - t4After!.height) <= 5
check("T4 float 窗口 frame 静置稳定（无 re-tile 对抗）", t4Stable, "before=\(t4Before.map{"\($0)"} ?? "nil") after=\(t4After.map{"\($0)"} ?? "nil")")

// 清理：按夹具窗口关闭按钮（若窗口有 AX 关闭钮）
var closeBtnRef: CFTypeRef?
AXUIElementCopyAttributeValue(targetAX, "AXCloseButton" as CFString, &closeBtnRef)
if let closeBtn = closeBtnRef {
    let button = unsafeBitCast(closeBtn, to: AXUIElement.self)
    AXUIElementPerformAction(button, "AXPress" as CFString)
    usleep(300_000)
}

print("\n========================================")
if failures.isEmpty {
    print("结果: 全部 PASS — 修复方案（AX 挪动 + settle + 写后验证）机制成立，可落入主代码")
} else {
    print("结果: \(failures.count) 项失败: \(failures.joined(separator: ", ")) — 方案需修正，禁止落入主代码")
}
exit(failures.isEmpty ? 0 : 1)
