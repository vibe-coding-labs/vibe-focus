# Vibe Focus (macOS)

Vibe Focus 是一个面向 macOS 多窗口、多显示器工作流的菜单栏工具。  
它把“找到当前窗口 → 拖回主屏 → 调整大小 → 结束后再摆回去”这套重复动作，压缩成一次快捷键切换。

## 我们解决什么问题

在多显示器办公里，很多人会反复遇到这些低频但高打断的问题：

- 当前工作窗口跑到了副屏，演示、录屏、开会前还要手动拖回主屏
- 拖回主屏后还要重新拉伸到合适大小，切换过程打断思路
- 临时聚焦完成后，又很难准确恢复原来的位置和尺寸
- 原生全屏会切到独立 Space，太重；手动摆窗又太慢
- 菜单栏工具想要“随时可用”，但权限、登录项、快捷键冲突往往不好排查

Vibe Focus 的目标是：

- 让窗口聚焦动作变成一次按键
- 让临时聚焦后还能一键回到原布局
- 尽量不改变你原来的工作方式，只减少重复机械操作

## 核心能力

- **一键聚焦当前窗口**：按 `Ctrl+M`，把当前窗口移动到主屏并铺满可见区域
- **一键恢复原布局**：再次按 `Ctrl+M`，恢复窗口原始位置和大小
- **记忆窗口状态**：最近一次移动的窗口位置会本地保存，应用重启后仍可恢复
- **菜单栏常驻**：应用启动后留在菜单栏，不打断桌面
- **自定义快捷键**：可在设置页录制新的全局快捷键
- **快捷诊断权限问题**：设置页内可检查辅助功能权限、安装路径与登录项状态
- **开机启动控制**：支持登录后自动启动
- **Claude Hooks 联动（可选）**：会话结束后自动把绑定窗口拉回主屏并最大化

## 适用场景

### 1. 录屏 / 演示 / 直播
- 当前窗口在副屏
- 需要快速切回主屏并铺满
- 完成后再恢复原布局

### 2. 深度工作模式
- 当前任务需要暂时进入“只看一个窗口”的状态
- 不想切原生全屏，也不想破坏桌面布局

### 3. 多显示器切换
- 主副屏之间来回工作
- 手动拖窗频率高，容易打断节奏

### 4. 临时聚焦后回退
- 聚焦只是一段短流程
- 结束后希望回到原来的窗口摆放，而不是重新整理桌面

## 产品体验

- 这是一个菜单栏应用，启动后不会弹主窗口，只会在顶部菜单栏显示 **VibeFocus**
- 默认快捷键：`Ctrl+M`
- 菜单栏入口：点击 **VibeFocus** → **Toggle (Ctrl+M)**
- 打开设置页：点击 **VibeFocus** → **设置…**
- 在设置页里录制新的快捷键后会实时生效，并自动检测常见系统冲突
- 设置页提供 **开机启动** 开关，用于控制登录后是否自动启动

## 快速开始

### 1. 安装
```bash
./install.sh
```

> 首次安装前需要准备一次“本地稳定签名证书”，否则会导致辅助功能授权不稳定：
> 1) 打开 Keychain Access
> 2) 菜单：Keychain Access → Certificate Assistant → Create a Certificate
> 3) Name: `VibeFocus Local Code Signing`
> 4) Identity Type: `Self Signed Root`
> 5) Certificate Type: `Code Signing`

安装完成后会生成：
```bash
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

### 4. 首次授权

**必须授予辅助功能权限，否则无法控制其他应用窗口。**

1. 运行程序后，菜单栏会出现 **VibeFocus**
2. 打开 **系统设置 → 隐私与安全性 → 辅助功能**
3. 点击左下角 **+**
4. 按 `Cmd + Shift + G` 输入：
   ```text
   ~/Applications/VibeFocus.app
   ```
5. 选择 `VibeFocus.app`
6. 勾选 **VibeFocus**
7. 权限开启后，快捷键即可使用

## 官网（website）

仓库内提供了一个使用 **TypeScript + React + Ant Design** 编写的产品官网目录：`website`

启动开发环境：
```bash
cd website
npm install
npm run dev
```

构建生产版本：
```bash
cd website
npm run build
```

## 故障排查

### 快捷键没反应？

1. **检查辅助功能权限**
   ```bash
   swift -e 'import ApplicationServices; print(AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: false] as CFDictionary) ? "✅ 已授权" : "❌ 未授权")'
   ```

2. **检查程序是否运行**
   ```bash
   ps aux | grep VibeFocus
   ```

3. **尝试菜单栏触发**
   - 点击菜单栏 **VibeFocus**
   - 选择 **Toggle (Ctrl+M)**
   - 如果菜单触发有效但快捷键无效，通常是辅助功能权限或快捷键冲突问题

4. **测试核心窗口能力**
   ```bash
   swift test_simple.swift
   ```

### 授权后仍显示未授权？

这通常不是“功能坏了”，而是 **授权记录与当前安装实例不一致**。常见原因：

- 授权的是旧副本，不是 `~/Applications/VibeFocus.app`
- 应用重新签名后，系统把它识别成了新的实例
- 之前既跑过安装版，也跑过开发版，授权记录混在一起

处理方式：

```bash
tccutil reset Accessibility com.openai.vibe-focus
```

然后重新打开安装版：
```bash
open ~/Applications/VibeFocus.app
```

再回到系统设置里重新勾选 `VibeFocus.app`。

## Claude Hooks 联动（可选）

VibeFocus 支持接收 Claude Code Hooks 的 `SessionStart` 与 `SessionEnd` 事件：

- `SessionStart`：记录当前前台窗口与 `session_id` 的绑定
- `SessionEnd`：自动把绑定窗口移动到主屏并最大化
- 之后可对该窗口按 `Ctrl+M` 恢复到原位置、原尺寸、原工作区（若 yabai 可用）

### 配置步骤

1. 打开 **设置 → Claude Hooks 联动**，开启并确认监听地址（默认 `127.0.0.1:39277`）
2. 复制设置页里的 Hook 示例命令
3. 粘贴到你的 Claude Code Hooks 配置（`SessionStart` 和 `SessionEnd`）

### 零系统侵入说明

- VibeFocus **不会自动修改** `~/.claude/settings.json`
- 只提供本地监听能力与可复制命令，是否接入由你手动决定

### 某些窗口无效？

- 部分系统窗口或原生全屏窗口不支持直接移动 / 缩放
- 当前实现是“铺满可见区域”，不是创建 macOS 原生全屏 Space
- 主屏幕以 macOS 当前主显示器为准

## 技术说明

- **SwiftUI**：设置界面
- **CGEventTap / Carbon HotKey**：全局热键捕获
- **Accessibility API**：跨应用窗口控制
- **菜单栏应用模式**：常驻但不打断桌面
- **macOS 13+**

## 项目结构

```text
.
├── Sources/                     # 主程序源码
├── assets/                      # 图标与品牌资源
├── scripts/                     # 安装/品牌资产脚本
├── website/                     # 官网（TypeScript + React + Ant Design）
├── .build/release/              # Swift 构建产物
├── install.sh                   # 安装到 ~/Applications/VibeFocus.app
├── run.sh                       # 本地启动脚本
├── test_simple.swift            # 手动验证脚本
└── README.md
```

## 停止程序

点击菜单栏 **VibeFocus** → **Quit**，或运行：
```bash
killall VibeFocusHotkeys
```
