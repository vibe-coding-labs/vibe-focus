# Vibe Focus (macOS)

一键把窗口移动到主屏幕并铺满可见区域的 macOS 菜单栏工具。

## 功能
- **按 ⌃M**：当前窗口 → 移到主屏幕并铺满可见区域
- **再按 ⌃M**：窗口 → 恢复原位置和大小
- 最新一次移动的窗口位置会本地记忆，应用重启后仍可恢复

## 快速开始

### 1. 安装
```bash
./install.sh
```

安装完成后会生成：
```
~/Applications/VibeFocus.app
```

### 2. 运行
```bash
open ~/Applications/VibeFocus.app
```

### 3. 开发模式运行
```bash
./run.sh
```

或直接使用：
```bash
./.build/release/VibeFocusHotkeys
```

### 4. 首次使用设置

**必须授予辅助功能权限**，否则无法工作：

1. 运行程序后，菜单栏会出现 **VibeFocus**
2. 打开 **系统设置 → 隐私与安全性 → 辅助功能**
3. 点击左下角的 **"+"**
4. 按 **⌘+Shift+G**，输入：
   ```
   ~/Applications/VibeFocus.app
   ```
5. 选择 **VibeFocus.app**，点击 **"打开"**
6. 勾选 **VibeFocus** 左侧的复选框
7. 权限开启后，快捷键即可使用

## 当前快捷键

- 这是一个菜单栏应用，启动后不会弹主窗口，只会在顶部菜单栏显示 **VibeFocus**
- 默认快捷键：`⌃M`
- 菜单栏入口：点击 **VibeFocus** → **Toggle (⌃M)**
- 打开设置页：点击 **VibeFocus** → **设置…**
- 在设置页里录制新的快捷键后会实时生效，并自动检测常见系统冲突

## 故障排查

### 快捷键没反应？

1. **检查权限**：
   ```bash
   swift -e 'import ApplicationServices; print(AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: false] as CFDictionary) ? "✅ 已授权" : "❌ 未授权")'
   ```

2. **检查程序是否运行**：
   ```bash
   ps aux | grep VibeFocus
   ```

3. **测试功能是否正常**（不需要快捷键）：
   ```bash
   swift test_simple.swift
   ```

4. **尝试菜单栏触发**：
   - 点击菜单栏 **VibeFocus**
   - 选择 **Toggle (⌃M)**
   - 如果菜单触发有效但快捷键无效，通常是辅助功能权限或快捷键冲突问题

### 某些应用窗口无效？

- 部分系统窗口或原生全屏窗口可能不支持直接移动/缩放
- 当前实现是“铺满可见区域”，不是创建 macOS 原生全屏 Space
- 主屏幕以 macOS 当前主显示器为准，不再固定为内置屏

## 技术说明

- **SwiftUI** 设置界面
- **CGEventTap** 全局热键捕获
- **Accessibility API** 跨应用窗口控制
- 支持 macOS 13+

## 文件结构

```
.
├── Sources/
│   └── main.swift          # 主程序代码
├── .build/release/
│   └── VibeFocusHotkeys    # 可执行文件
├── install.sh              # 安装到 ~/Applications/VibeFocus.app
├── run.sh                  # 启动脚本
├── test_simple.swift       # 手动验证：跨屏铺满并恢复
└── README.md               # 本文件
```

## 停止程序

点击菜单栏 **Vibe** → **"Quit"**，或运行：
```bash
killall VibeFocusHotkeys
```
