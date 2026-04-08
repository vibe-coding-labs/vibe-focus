# 单实例策略改进：新进程替换旧进程

> **Goal:** 修改单实例检查逻辑，让新启动的进程自动终止旧进程，确保始终运行最新实例

**Architecture:** 使用 `NSRunningApplication` 的 `terminate()` 方法优雅地终止旧进程，然后新进程继续启动。这比旧进程自退出的策略更符合用户直觉（最新启动的应该生效）。

**Tech Stack:** Swift, AppKit, Foundation

---

## Task 1: 修改单实例检查逻辑

**Files:**
- Modify: `Sources/SettingsUI.swift:1337-1341` (启动检查逻辑)
- Modify: `Sources/SettingsUI.swift:1439-1496` (findExistingInstance 方法，可选优化)

### Step 1: 修改启动检查逻辑，让新进程终止旧进程

```swift
// 在 applicationDidFinishLaunching 中替换现有的检查逻辑
// 检查是否已有其他实例在运行，如果有则终止旧进程
if let existingInstance = findExistingInstance() {
    log("Another instance already running at PID \(existingInstance.processIdentifier), terminating old instance")
    existingInstance.terminate()
    // 等待一小段时间确保旧进程完全退出
    Thread.sleep(forTimeInterval: 0.5)
}
```

### Step 2: 编译验证

Run: `swift build`
Expected: Build complete with no errors

### Step 3: 测试验证

1. 启动第一个实例
2. 启动第二个实例
3. 验证第一个实例被终止，第二个实例继续运行
4. 检查日志确认行为正确

### Step 4: 提交

```bash
git add Sources/SettingsUI.swift
git commit -m "feat: 新进程启动时自动终止旧进程，确保始终运行最新实例"
```

---

## Design Notes

### 为什么选择终止旧进程而不是自退出？

1. **用户直觉**: 用户最新启动的应该生效
2. **开发体验**: 开发时频繁重启，新代码应该立即生效
3. **升级场景**: 应用更新后启动新版本，旧版本应该被替换

### 优雅终止 vs 强制终止

使用 `NSRunningApplication.terminate()` 是优雅终止，给应用机会保存状态、清理资源。这比 `kill -9` 更友好。

### 等待时间

0.5秒的等待确保旧进程有足够时间释放资源（如菜单栏图标、全局热键等），避免资源冲突。

---

**Estimated time:** 10 minutes
**Risk level:** Low
**Dependencies:** None
