# Restore Width Too Wide Fix Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复从主屏还原回副屏后窗口宽度莫名变宽的 bug — 根因是 `setWindowFloat` 使用 `--toggle float`（切换）而非「仅在非浮动时设为浮动」，导致交替 restore 时把浮动窗口切回 bsp，yabai 立即全屏平铺。

**Root Cause:** `setWindowFloat` 调用 `yabai -m window <id> --toggle float`。`--toggle` 是**翻转**语义：第一次 restore（bsp→float）正确；第二次 restore（float→bsp）yabai 立即 tile 到全显示器宽度 1663px；第三次 toggle 又变 float 但 origFrame 已经被捕获为 1663px。如此循环，origFrame 越来越宽。

**Architecture:** 修改 `setWindowFloat` → 先查询 yabai 窗口当前 floating 状态 → 仅在 `floating == 0` 时执行 toggle。需给 `YabaiWindowInfo` 添加 `floating` 字段以支持解析。

**Tech Stack:** Swift 5.9, macOS 14+, yabai scripting-addition

**Risks:**
- yabai query 可能对不存在的窗口返回错误 → 缓解：queryWindow 已有 nil 处理，fallback 为不 toggle
- 浮动窗口在副屏可能被用户手动调整大小 → 这是用户行为，不影响

---

### Task 1: Add `floating` Field to YabaiWindowInfo

**Depends on:** None
**Files:**
- Modify: `Sources/Space/SpaceController.swift:408-427`

- [ ] **Step 1: 给 YabaiWindowInfo 添加 floating 字段 — 解析 yabai 返回的浮动状态**

文件: `Sources/Space/SpaceController.swift:408-427`

将：
```swift
struct YabaiWindowInfo: Decodable {
    let id: Int?
    let pid: Int?
    let app: String?
    let title: String?
    let space: Int?
    let display: Int?
    let frame: Frame?

    struct Frame: Decodable {
        let x: Double
        let y: Double
        let w: Double
        let h: Double

        var cgRect: CGRect {
            CGRect(x: x, y: y, width: w, height: h)
        }
    }
}
```

替换为：
```swift
struct YabaiWindowInfo: Decodable {
    let id: Int?
    let pid: Int?
    let app: String?
    let title: String?
    let space: Int?
    let display: Int?
    let frame: Frame?
    let floating: Int?

    var isFloating: Bool { floating == 1 }

    struct Frame: Decodable {
        let x: Double
        let y: Double
        let w: Double
        let h: Double

        var cgRect: CGRect {
            CGRect(x: x, y: y, width: w, height: h)
        }
    }
}
```

- [ ] **Step 2: 验证编译**
Run: `swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/Space/SpaceController.swift && git commit -m "feat(space): add floating field to YabaiWindowInfo for float state detection"`

---

### Task 2: Fix setWindowFloat to Only Set Float, Never Toggle Back to Managed

**Depends on:** Task 1
**Files:**
- Modify: `Sources/Space/SpaceController+Move.swift:479-487`

- [ ] **Step 1: 修改 setWindowFloat — 先查询浮动状态，仅在非浮动时 toggle**

文件: `Sources/Space/SpaceController+Move.swift:479-487`

将：
```swift
    func setWindowFloat(_ windowID: UInt32, operationID: String? = nil) {
        let op = operationID ?? "none"
        guard isEnabled else { return }
        _ = runYabai(
            arguments: ["-m", "window", "\(windowID)", "--toggle", "float"],
            operation: "setWindowFloat",
            operationID: op
        )
    }
```

替换为：
```swift
    func setWindowFloat(_ windowID: UInt32, operationID: String? = nil) {
        let op = operationID ?? "none"
        guard isEnabled else { return }

        // 查询当前浮动状态 — 避免把已经浮动的窗口 toggle 回 bsp（导致 yabai 全屏平铺）
        if let info = queryWindow(windowID: windowID), info.isFloating {
            log("setWindowFloat: already floating, skipping toggle", fields: [
                "op": op,
                "windowID": String(windowID)
            ])
            return
        }

        _ = runYabai(
            arguments: ["-m", "window", "\(windowID)", "--toggle", "float"],
            operation: "setWindowFloat",
            operationID: op
        )
    }
```

- [ ] **Step 2: 验证编译**
Run: `swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 构建部署**
Run: `bash scripts/dev-build.sh 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - Output contains: "构建成功"

- [ ] **Step 4: 重启 VibeFocus 并验证无报错**
Run: `pkill -x VibeFocus; sleep 1; open /Applications/VibeFocus.app; sleep 3; tail -10 /Users/cc11001100/Library/Logs/VibeFocus/vibefocus.log | grep -i "error\|crash\|fatal" || echo "No errors"`
Expected:
  - Output: "No errors"

- [ ] **Step 5: 提交**
Run: `git add Sources/Space/SpaceController+Move.swift && git commit -m "fix(restore): setWindowFloat checks current state before toggle — prevents alternating float/bsp cycle"`
