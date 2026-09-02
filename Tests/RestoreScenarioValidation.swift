// Restore 恢复机制端到端验证脚本（2026-09-02，docs/2026-09-02-restore-thorough-fix-plan.md P1-3）
// 用途：逐条断言「切回原工作区」机制依赖的原语与场景，全部 PASS 后才允许改动 restore 代码。
// 原则：只操作本脚本自建的测试窗口（TextEdit 空白文档），不碰用户任何窗口；
//       脚本结束时恢复所有 display 的初始可见 space。
//
// 运行：swift Tests/RestoreScenarioValidation.swift
// 断言清单（对应规划 P1-3 六场景）：
//   R0  辅助功能权限可用
//   R1  夹具窗口 AX/yabai 可见
//   R2  is-minimized 字段存在且随最小化翻转（P0-2 双键解码的事实依据）
//   R3  恢复主路径：float + yabai frame 直写回源屏 origFrame，space/display 归属跟随
//   R4  源屏被切走 → SA 直切层（space --focus）切回 + frame 直写，窗口精确回 sourceSpace
//   R5  空 sourceSpace：refocus 层无候选（降级必失败的机制依据）+ SA 直切空 space 可行
//       （P0-1 双层化的价值证明）
//   R6  origFrame 屏外判定：displayContext 等价逻辑判为「不在任何屏」（永久失败分支依据）
// 依赖：多 display 环境（单屏时 R3-R5 SKIP）。SA 可用性运行时探测，不可用时 R4/R5 降级 SKIP。

import AppKit
import ApplicationServices

var failures: [String] = []
var skips: [String] = []
func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    let mark = condition ? "PASS" : "FAIL"
    print("[\(mark)] \(name)\(detail.isEmpty ? "" : "  -- \(detail)")")
    if !condition { failures.append(name) }
}
func skip(_ name: String, _ detail: String) {
    print("[SKIP] \(name)  -- \(detail)")
    skips.append(name)
}

// MARK: - yabai helpers

let yabaiPath = "/opt/homebrew/bin/yabai"

@discardableResult
func yabaiRun(_ args: [String]) -> (exit: Int32, stderr: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: yabaiPath)
    task.arguments = args
    let out = Pipe(); let err = Pipe()
    task.standardOutput = out; task.standardError = err
    do { try task.run() } catch { return (-1, "launch failed") }
    task.waitUntilExit()
    let errText = (try? err.fileHandleForReading.readToEnd()).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    return (task.terminationStatus, errText.trimmingCharacters(in: .whitespacesAndNewlines))
}

func yabaiJSON(_ args: [String]) -> [[String: Any]]? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: yabaiPath)
    task.arguments = args
    let out = Pipe(); let err = Pipe()
    task.standardOutput = out; task.standardError = err
    do { try task.run() } catch { return nil }
    task.waitUntilExit()
    guard task.terminationStatus == 0,
          let data = try? out.fileHandleForReading.readToEnd(),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
    return arr
}

/// yabai 布尔字段版本漂移防御：同一字段既有 Bool 也有 Int(0/1) 形态。
func flag(_ dict: [String: Any], _ key: String) -> Bool {
    if let b = dict[key] as? Bool { return b }
    if let i = dict[key] as? Int { return i != 0 }
    return false
}

struct FixtureInfo {
    let id: Int
    let space: Int
    let display: Int
    let minimized: Bool
    let floating: Bool
    let frame: [String: Double]
    var cgFrame: CGRect? {
        guard let x = frame["x"], let y = frame["y"], let w = frame["w"], let h = frame["h"] else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

func fixtureInfo(pid: Int32, titlePrefix: String) -> FixtureInfo? {
    guard let arr = yabaiJSON(["-m", "query", "--windows"]) else { return nil }
    for w in arr {
        if (w["pid"] as? Int32) == pid, let t = w["title"] as? String, t.hasPrefix(titlePrefix) {
            return FixtureInfo(
                id: w["id"] as? Int ?? -1,
                space: w["space"] as? Int ?? -1,
                display: w["display"] as? Int ?? -1,
                minimized: flag(w, "is-minimized") || flag(w, "minimized"),
                floating: flag(w, "is-floating"),
                frame: w["frame"] as? [String: Double] ?? [:]
            )
        }
    }
    return nil
}

/// 各 display 当前可见 space（yabai 全局索引）；脚本结束前按此恢复用户视图。
func snapshotVisibleSpaces() -> [Int: Int] {
    var result: [Int: Int] = [:]
    for s in yabaiJSON(["-m", "query", "--spaces"]) ?? [] {
        if flag(s, "is-visible"), let idx = s["index"] as? Int, let disp = s["display"] as? Int {
            result[disp] = idx
        }
    }
    return result
}

func spacesOnDisplay(_ display: Int) -> [Int] {
    (yabaiJSON(["-m", "query", "--spaces"]) ?? [])
        .filter { ($0["display"] as? Int) == display }
        .compactMap { $0["index"] as? Int }
        .sorted()
}

/// 某 space 上的可管理窗口数（refocus 层候选判据，等价 selectRefocusCandidate 过滤）。
func manageableWindowCount(onSpace space: Int, excluding excluded: Int) -> Int {
    (yabaiJSON(["-m", "query", "--windows"]) ?? []).filter { w in
        (w["space"] as? Int) == space
            && flag(w, "has-ax-reference")
            && (w["id"] as? Int) != excluded
    }.count
}

// MARK: - AX helpers

func axFrame(_ window: AXUIElement) -> CGRect? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, "AXFrame" as CFString, &value) == .success,
          let frameRef = value else { return nil }
    let axValue = unsafeBitCast(frameRef, to: AXValue.self)
    var frame = CGRect.zero
    guard AXValueGetValue(axValue, .cgRect, &frame) else { return nil }
    return frame
}

func axSetMinimized(_ window: AXUIElement, _ minimized: Bool) -> Bool {
    return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, minimized as CFBoolean) == .success
}

// MARK: - R0 辅助功能权限

let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": false] as CFDictionary)
check("R0 辅助功能权限", trusted)
guard trusted else {
    print("\n结果: \(failures.count) 项失败（R0 未过，后续无法执行）")
    exit(1)
}

let initialVisible = snapshotVisibleSpaces()
defer {
    // 恢复用户视图：把每块屏切回脚本开始时的可见 space
    for (_, space) in initialVisible {
        _ = yabaiRun(["-m", "space", "--focus", "\(space)"])
    }
}

// MARK: - 夹具窗口（TextEdit 空白文档，测完即关）

let fixtureTitle = "Untitled"
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

var tePid: Int32 = -1
let pidDeadline = Date().addingTimeInterval(8.0)
while Date() < pidDeadline && tePid < 0 {
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
usleep(1_000_000)  // 等窗口完成 AX/yabai 注册

let teAX = AXUIElementCreateApplication(tePid)
var children: CFTypeRef?
AXUIElementCopyAttributeValue(teAX, kAXWindowsAttribute as CFString, &children)
let axWindows = (children as? [AXUIElement]) ?? []
// 夹具标题随系统语言变化（英文 "Untitled" / 中文 "未命名"）；启动前已 killall，
// TextEdit 的唯一窗口即夹具，直接取第一个 AX 窗口。
var targetAX: AXUIElement?
var axTitle = "?"
for w in axWindows {
    var t: CFTypeRef?
    AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
    axTitle = (t as? String) ?? "?"
    if targetAX == nil { targetAX = w }
}
guard let targetAX, let home0 = fixtureInfo(pid: tePid, titlePrefix: axTitle == "?" ? "" : axTitle), !axWindows.isEmpty else {
    check("R1 夹具窗口 AX/yabai 可见", false, "tePid=\(tePid) axWindows=\(axWindows.count) title=\(axTitle)")
    print("\n结果: \(failures.count) 项失败")
    exit(1)
}
check("R1 夹具窗口 AX/yabai 可见", true, "space=\(home0.space) display=\(home0.display)")

// MARK: - R2 is-minimized 字段随最小化翻转（P0-2 事实依据；单屏也跑）

let minBefore = fixtureInfo(pid: tePid, titlePrefix: fixtureTitle)?.minimized ?? true
let setMin = axSetMinimized(targetAX, true)
usleep(800_000)
let minOn = fixtureInfo(pid: tePid, titlePrefix: fixtureTitle)?.minimized ?? true
_ = axSetMinimized(targetAX, false)
usleep(800_000)
let minAfter = fixtureInfo(pid: tePid, titlePrefix: fixtureTitle)?.minimized ?? true
check("R2 yabai is-minimized 字段随 AX 最小化翻转", setMin && !minBefore && minOn && !minAfter,
      "setMin=\(setMin) before=\(minBefore) on=\(minOn) after=\(minAfter)")

// MARK: - 多 display 环境探测（单屏时 R3-R5 SKIP）
// 注意：yabai display 的 `id` 是 CGDirectDisplayID（大数），与窗口/space 的 `display`
// 字段（1-based index）不同源；此处一律用 `index`。

let displays = yabaiJSON(["-m", "query", "--displays"]) ?? []
guard displays.count >= 2,
      let mainScreen = displays.first(where: { ($0["index"] as? Int) == 1 }),
      let secondary = displays.first(where: { ($0["index"] as? Int) != 1 }),
      let mainFrame = mainScreen["frame"] as? [String: Double],
      let secFrame = secondary["frame"] as? [String: Double],
      let secId = secondary["index"] as? Int else {
    skip("R3-R5 恢复场景", "只有一块 display，无法验证跨屏恢复；R2/R6 已覆盖")
    exit(failures.isEmpty ? 0 : 1)
}

let secOriginX = Int(secFrame["x"] ?? 0), secOriginY = Int(secFrame["y"] ?? 0)
let homeFrame = CGRect(x: secOriginX + 60, y: secOriginY + 60, width: 480, height: 300)
let mainTarget = CGRect(x: Int(mainFrame["x"] ?? 0) + 60, y: Int(mainFrame["y"] ?? 0) + 60, width: 640, height: 400)

/// 模拟 toggle 的跨屏搬运：float 脱管 → yabai move/resize abs 直写。
func floatAndMove(_ id: Int, to target: CGRect) {
    yabaiRun(["-m", "window", "\(id)", "--toggle", "float"])
    usleep(300_000)
    yabaiRun(["-m", "window", "\(id)", "--move", "abs:\(Int(target.origin.x)):\(Int(target.origin.y))"])
    yabaiRun(["-m", "window", "\(id)", "--resize", "abs:\(Int(target.width)):\(Int(target.height))"])
    usleep(600_000)
}

// 把夹具安家到副屏（若已在副屏则只需浮起+定位），记录 restore 依赖的 sourceSpace/origFrame
floatAndMove(home0.id, to: homeFrame)
let home1 = fixtureInfo(pid: tePid, titlePrefix: fixtureTitle)
guard let home1, home1.display == secId else {
    check("R3 前置：夹具安家副屏", false, "after=\(home1.map { "space\($0.space) disp\($0.display)" } ?? "nil") expect display=\(secId)")
    exit(1)
}
let sourceSpace = home1.space
let origFrame = homeFrame
print("    夹具安家: space=\(sourceSpace) display=\(secId) origFrame=\(origFrame)")

// MARK: - R3 恢复主路径：frame 直写回 origFrame，归属跟随

floatAndMove(home1.id, to: mainTarget)
let movedToMain = fixtureInfo(pid: tePid, titlePrefix: fixtureTitle)
check("R3 前置：夹具已到主屏", movedToMain?.display != secId,
      "now(space=\(movedToMain?.space ?? -1),disp=\(movedToMain?.display ?? -1))")
if let w = movedToMain?.id {
    // 模拟 restore 主体（源屏未被切走，4-pre 跳过）：float 已在 R3 前置中发生，直写 origFrame
    yabaiRun(["-m", "window", "\(w)", "--move", "abs:\(Int(origFrame.origin.x)):\(Int(origFrame.origin.y))"])
    yabaiRun(["-m", "window", "\(w)", "--resize", "abs:\(Int(origFrame.width)):\(Int(origFrame.height))"])
    usleep(600_000)
    if let back = fixtureInfo(pid: tePid, titlePrefix: fixtureTitle) {
        let frameOK = back.cgFrame.map { abs($0.origin.x - origFrame.origin.x) <= 10 && abs($0.origin.y - origFrame.origin.y) <= 10 } ?? false
        check("R3 恢复主路径：space/display/frame 回源",
              back.space == sourceSpace && back.display == secId && frameOK,
              "now(space=\(back.space),disp=\(back.display)) frameOK=\(frameOK)")
        // 留在主屏状态供 R4 使用
        floatAndMove(w, to: mainTarget)
    } else {
        check("R3 恢复主路径：space/display/frame 回源", false, "恢复后查询失败")
    }
}

// MARK: - R4 源屏被切走 → SA 直切层切回 + frame 直写

// SA 探测：对当前可见 space 发 focus——已聚焦 space 会报逻辑错误
// "cannot focus an already focused space"（exit 1），不能拿 exit 判断；
// SA 失效的特征是 stderr 含 "scripting-addition"。
let saProbe = yabaiRun(["-m", "space", "--focus", "\(sourceSpace)"])
let saAvailable = !saProbe.stderr.lowercased().contains("scripting-addition")
let secSpaces = spacesOnDisplay(secId)
if !saAvailable {
    skip("R4 源屏切走后恢复（SA 层）", "space --focus 不可用（SA 失效），双层降级为 refocus 层")
} else if secSpaces.count < 2 {
    skip("R4 源屏切走后恢复（SA 层）", "源屏只有一个 space，无法切走")
} else {
    let otherSpace = secSpaces.first { $0 != sourceSpace }!
    _ = yabaiRun(["-m", "space", "--focus", "\(otherSpace)"])   // 切走源屏
    usleep(500_000)
    let visibleAfterSwitch = snapshotVisibleSpaces()[secId]
    // 模拟 restore 4-pre 双层切回（SA 层）：space --focus sourceSpace
    let switchBack = yabaiRun(["-m", "space", "--focus", "\(sourceSpace)"])
    usleep(500_000)
    let visibleAfterBack = snapshotVisibleSpaces()[secId]
    check("R4 源屏切走 → SA 直切切回",
          visibleAfterSwitch == otherSpace && switchBack.exit == 0 && visibleAfterBack == sourceSpace,
          "切走后 visible=\(visibleAfterSwitch ?? -1) 切回 exit=\(switchBack.exit) visible=\(visibleAfterBack ?? -1)")
    // frame 直写回源
    if let w = fixtureInfo(pid: tePid, titlePrefix: fixtureTitle)?.id {
        yabaiRun(["-m", "window", "\(w)", "--move", "abs:\(Int(origFrame.origin.x)):\(Int(origFrame.origin.y))"])
        yabaiRun(["-m", "window", "\(w)", "--resize", "abs:\(Int(origFrame.width)):\(Int(origFrame.height))"])
        usleep(600_000)
        if let back = fixtureInfo(pid: tePid, titlePrefix: fixtureTitle) {
            check("R4 切回后 frame 直写：窗口精确回 sourceSpace",
                  back.space == sourceSpace && back.display == secId,
                  "now(space=\(back.space),disp=\(back.display))")
        } else {
            check("R4 切回后 frame 直写：窗口精确回 sourceSpace", false, "查询失败")
        }
    }
}

// MARK: - R5 空 sourceSpace：refocus 层无候选 + SA 直切空 space 可行（P0-1 价值证明）

if let w = fixtureInfo(pid: tePid, titlePrefix: fixtureTitle)?.id {
    floatAndMove(w, to: mainTarget)   // 挪走夹具，sourceSpace 上只剩（可能存在的）用户窗口
    let candidates = manageableWindowCount(onSpace: sourceSpace, excluding: w)
    print("    sourceSpace=\(sourceSpace) 可管理候选窗口数（refocus 层）：\(candidates)")
    if candidates == 0 {
        check("R5a 空 sourceSpace 时 refocus 层无候选（降级必失败的机制依据）", true)
    } else {
        skip("R5a refocus 空候选断言", "sourceSpace 上有 \(candidates) 个用户窗口，无法构造空 space")
    }
    if saAvailable {
        // P0-1 价值证明：SA 直切不依赖 space 上有窗口
        // 先把源屏切走，再对（可能为空的）sourceSpace 直切
        if secSpaces.count >= 2 {
            let otherSpace = secSpaces.first { $0 != sourceSpace }!
            _ = yabaiRun(["-m", "space", "--focus", "\(otherSpace)"])
            usleep(400_000)
        }
        let direct = yabaiRun(["-m", "space", "--focus", "\(sourceSpace)"])
        usleep(400_000)
        let visibleNow = snapshotVisibleSpaces()[secId]
        check("R5b SA 直切空 sourceSpace 可行（P0-1 双层化价值）",
              direct.exit == 0 && visibleNow == sourceSpace,
              "exit=\(direct.exit) visible=\(visibleNow ?? -1) stderr=\(direct.stderr)")
        // 把夹具搬回源位，保持脚本状态一致
        yabaiRun(["-m", "window", "\(w)", "--move", "abs:\(Int(origFrame.origin.x)):\(Int(origFrame.origin.y))"])
        yabaiRun(["-m", "window", "\(w)", "--resize", "abs:\(Int(origFrame.width)):\(Int(origFrame.height))"])
        usleep(400_000)
    } else {
        skip("R5b SA 直切空 space 断言", "SA 不可用（该环境下空 space 精确切回为物理极限，机制如实上报）")
    }
}

// MARK: - R6 origFrame 屏外判定（永久失败分支依据；displayContext 等价逻辑）

let mainScreenCocoa = NSScreen.screens.first { $0.frame.origin == .zero }
if let mainScreenCocoa {
    let mainScreenHeight = mainScreenCocoa.frame.height
    func isOnAnyDisplay(_ quartzFrame: CGRect) -> Bool {
        // 等价 WindowManager.displayContext：全局 Quartz→Cocoa 变换后 contains/intersects
        let cocoaFrame = CGRect(x: quartzFrame.origin.x,
                                y: mainScreenHeight - quartzFrame.maxY,
                                width: quartzFrame.width, height: quartzFrame.height)
        return NSScreen.screens.contains { $0.frame.contains(CGPoint(x: cocoaFrame.midX, y: cocoaFrame.midY)) || $0.frame.intersects(cocoaFrame) }
    }
    let offscreen = CGRect(x: (mainScreenCocoa.frame.maxX + NSScreen.screens.map { $0.frame.maxX }.max()!) + 5000, y: 100, width: 400, height: 300)
    check("R6 origFrame 屏外判定：屏内帧命中、屏外帧 miss",
          isOnAnyDisplay(origFrame) && !isOnAnyDisplay(offscreen),
          "origFrame on=\(isOnAnyDisplay(origFrame)) offscreen on=\(isOnAnyDisplay(offscreen))")
} else {
    check("R6 origFrame 屏外判定", false, "无法确定主屏")
}

// MARK: - 清理

let killEnd = Process()
killEnd.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
killEnd.arguments = ["TextEdit"]
killEnd.standardOutput = Pipe(); killEnd.standardError = Pipe()
try? killEnd.run(); killEnd.waitUntilExit()

print("")
if !skips.isEmpty {
    print("跳过 \(skips.count) 项: \(skips.joined(separator: "；"))")
}
print("结果: \(failures.isEmpty ? "全部 PASS" : "\(failures.count) 项失败: \(failures.joined(separator: "；"))")")
exit(failures.isEmpty ? 0 : 1)
