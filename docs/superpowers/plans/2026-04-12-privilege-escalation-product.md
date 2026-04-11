# yabai scripting-addition 自动权限提升（产品级方案）

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 当 yabai scripting-addition 未加载时，通过 macOS 原生 `NSAppleScript` 弹出系统密码对话框请求管理员权限，自动加载 scripting-addition，实现产品级的零手动配置体验。

**Architecture:** 替换 `SpaceController.attemptScriptingAdditionRecovery` 中的 `sudo -n` 调用为 `NSAppleScript` `do shell script "..." with administrator privileges`。这会弹出 macOS 原生的管理员密码输入框，用户输入密码后即可加载 scripting-addition。同时在 SettingsUI 中添加手动加载按钮作为备用入口。

**Tech Stack:** Swift, NSAppleScript, yabai CLI

---

## 改动范围

**修改文件：**
1. `Sources/SpaceController.swift` — 核心改动：替换 sudo -n 为 NSAppleScript
2. `Sources/SettingsUI.swift` — 添加手动"加载 scripting-addition"按钮

**不改动的部分：**
- WindowManager.swift — 已有 focusSpace 预切换逻辑，不需要改
- Support.swift — 日志基础设施不变
- 其他文件

---

### Task 1: SpaceController — 用 NSAppleScript 替换 sudo -n

**Files:**
- Modify: `Sources/SpaceController.swift:594-672`（attemptScriptingAdditionRecovery 方法）
- Modify: `Sources/SpaceController.swift:678`（markOperationError 中的错误消息）

- [ ] **Step 1: 在 SpaceController 中添加 executeWithAdminPrivileges 辅助方法**

在 `attemptScriptingAdditionRecovery` 方法之前（约第 593 行），插入新的辅助方法：

```swift
    /// 通过 macOS 原生密码对话框以管理员权限执行 shell 命令
    /// 返回 (success: Bool, output: String)
    @discardableResult
    private func executeWithAdminPrivileges(_ command: String, operationID: String? = nil) -> (Bool, String) {
        let op = operationID ?? "none"
        let appleScript = NSAppleScript(source: "do shell script \"\(command)\" with administrator privileges")

        var errorDict: NSDictionary?
        let result = appleScript?.executeAndReturnError(&errorDict)

        if let errorDict {
            let errorMessage = (errorDict[NSAppleScript.errorMessage] as? String) ?? "unknown error"
            let errorNumber = errorDict[NSAppleScript.errorNumber] as? Int ?? -1
            log(
                "[SpaceController] admin privilege execution failed",
                level: .error,
                fields: [
                    "op": op,
                    "command": truncateForLog(command, limit: 120),
                    "errorMessage": errorMessage,
                    "errorNumber": String(errorNumber)
                ]
            )
            return (false, errorMessage)
        }

        let output = result?.stringValue ?? ""
        log(
            "[SpaceController] admin privilege execution succeeded",
            fields: [
                "op": op,
                "command": truncateForLog(command, limit: 120),
                "output": truncateForLog(output, limit: 120)
            ]
        )
        return (true, output)
    }
```

- [ ] **Step 2: 替换 attemptScriptingAdditionRecovery 中的 sudo -n 逻辑**

将第 634-671 行的 sudo -n 块替换为 NSAppleScript 调用：

**旧代码（第 634-671 行）：**
```swift
        guard let sudoResult = runProcess(executable: "/usr/bin/sudo", arguments: ["-n", yabaiPath, "--load-sa"]) else {
            log(...)
            return false
        }

        if sudoResult.exitCode == 0 {
            scriptingAdditionRecoverySucceeded = true
            ...
        }
        let stderr = sudoResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        ...
        lastErrorMessage = "跨工作区恢复失败：需要 root 加载 yabai scripting-addition。请执行: sudo \(yabaiPath) --load-sa"
        return false
```

**新代码：**
```swift
        // 使用 macOS 原生密码对话框请求管理员权限加载 scripting-addition
        let (privSuccess, privOutput) = executeWithAdminPrivileges(
            "\(yabaiPath) --load-sa",
            operationID: op
        )

        if privSuccess {
            scriptingAdditionRecoverySucceeded = true
            canControlSpaces = true
            lastErrorMessage = nil
            log(
                "[SpaceController] scripting-addition recovered via admin privileges",
                fields: [
                    "op": op,
                    "output": truncateForLog(privOutput, limit: 120)
                ]
            )
            return true
        }

        log(
            "[SpaceController] scripting-addition recovery failed: admin privilege dialog cancelled or error",
            level: .error,
            fields: [
                "op": op,
                "detail": truncateForLog(privOutput, limit: 220)
            ]
        )
        lastErrorMessage = "跨工作区恢复需要管理员权限来加载 yabai scripting-addition。可以在设置中点击"加载"按钮手动触发。"
        return false
```

- [ ] **Step 3: 更新 markOperationError 中的错误消息**

将第 678 行的错误消息从：
```swift
                lastErrorMessage = "yabai scripting-addition 不可用，跨工作区恢复不可用。可执行: sudo yabai --load-sa"
```
改为：
```swift
                lastErrorMessage = "yabai scripting-addition 不可用，跨工作区恢复功能受限。请在设置中加载 scripting-addition。"
```

---

### Task 2: SettingsUI — 添加手动加载 scripting-addition 按钮

**Files:**
- Modify: `Sources/SettingsUI.swift`（space 相关设置区域）

- [ ] **Step 4: 在 SettingsUI 的 space 设置区域添加手动加载按钮**

在 SettingsUI.swift 中找到 space 不可用时的错误提示区域（约第 895 行），在错误提示后添加加载按钮：

在现有的 `if let error = spaceController.lastErrorMessage` 块之后（约第 902 行之后），添加：

```swift
if spaceController.availability == .unavailable {
    Button("加载 scripting-addition") {
        spaceController.requestScriptingAdditionLoad()
    }
    .buttonStyle(.bordered)
}
```

- [ ] **Step 5: 在 SpaceController 中添加公开的手动加载方法**

在 SpaceController 的公开方法区域（约第 281 行 focusSpace 方法之后）添加：

```swift
    /// 手动触发 scripting-addition 加载（从设置 UI 调用）
    func requestScriptingAdditionLoad() {
        let op = makeOperationID(prefix: "sa-load")
        log(
            "[SpaceController] manual scripting-addition load requested",
            fields: ["op": op]
        )
        // 重置恢复标记，允许重新尝试
        didAttemptScriptingAdditionRecovery = false
        scriptingAdditionRecoverySucceeded = false
        _ = attemptScriptingAdditionRecovery(trigger: "manual", operationID: op)
        // 加载成功后刷新可用性
        if scriptingAdditionRecoverySucceeded {
            refreshAvailability(force: true)
        }
    }
```

---

### Task 3: 编译验证

- [ ] **Step 6: 编译**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -20`
Expected: `Build complete!`

---

### Task 4: 测试验证

- [ ] **Step 7: 构建并运行 release 版本**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build -c release && pkill -x VibeFocusHotkeys; sleep 0.5; .build/release/VibeFocusHotkeys &`

- [ ] **Step 8: 手动测试**

测试步骤：
1. 确保 yabai 已安装但 scripting-addition 未加载（重启电脑后就是此状态）
2. 在副屏打开一个窗口，按快捷键移到主屏
3. 切换副屏到另一个工作区
4. 按快捷键恢复
5. **预期：** 弹出 macOS 原生密码对话框，输入密码后，副屏自动切换回原工作区，窗口恢复到正确位置

- [ ] **Step 9: 检查日志**

Run: `grep "scripting-addition\|admin privilege" /tmp/vibefocus-events.jsonl | tail -10 | python3 -c "import sys,json; [print(json.dumps(json.loads(l),indent=2)) for l in sys.stdin]"`

---

### Task 5: 提交

- [ ] **Step 10: 提交代码**
