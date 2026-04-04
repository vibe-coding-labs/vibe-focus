# Yabai 安装引导文档与界面改进 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 创建完整的 yabai 安装配置指南文档，并在设置界面添加代码块展示、一键复制功能和跳转链接

**Architecture:** 
- 在 `docs/yabai-guide/` 目录下创建完整的安装配置指南（Markdown 格式）
- 在 `SettingsUI.swift` 中添加可复制的代码块组件
- 界面保留核心步骤概览，详细说明通过链接跳转到文档

**Tech Stack:** SwiftUI, NSWorkspace, NSPasteboard, Markdown

---

## File Structure

```
docs/yabai-guide/
├── README.md              # 主指南文档（安装+配置+故障排除）
└── QUICKSTART.md          # 快速入门（3步搞定）

Sources/
└── SettingsUI.swift       # 添加 CodeBlockView 组件和界面集成
```

---

## Task 1: 创建 yabai 安装指南文档

**Files:**
- Create: `docs/yabai-guide/README.md`
- Create: `docs/yabai-guide/QUICKSTART.md`

### Step 1.1: 创建完整安装指南

```markdown
# Yabai 安装与配置指南

## 系统要求

- macOS 10.15+ (Catalina 或更高版本)
- Homebrew 包管理器
- 管理员权限（用于配置辅助功能）

## 安装步骤

### 1. 安装 Homebrew（如未安装）

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

### 2. 安装 yabai

```bash
# 添加 yabai 的 tap
brew tap koekeishiya/formulae

# 安装 yabai
brew install koekeishiya/formulae/yabai
```

### 3. 启动 yabai 服务

```bash
# 方式一：使用 brew services（推荐，开机自启）
brew services start yabai

# 方式二：手动启动（仅当前会话有效）
yabai --start-service
```

### 4. 配置辅助功能权限

首次启动后，系统会弹出提示要求授权：

1. 打开「系统设置」→「隐私与安全」→「辅助功能」
2. 点击「+」按钮
3. 按 `Cmd + Shift + G`，输入 `/opt/homebrew/bin/yabai` (Apple Silicon) 或 `/usr/local/bin/yabai` (Intel)
4. 勾选 yabai 以授权
5. 重新启动 yabai: `brew services restart yabai`

### 5. 验证安装

```bash
# 检查 yabai 版本
yabai --version

# 查询当前空间信息
yabai -m query --spaces

# 如果返回 JSON 数据，说明安装成功
```

## 高级配置（可选）

### 配置文件

创建配置文件 `~/.config/yabai/yabairc`：

```bash
mkdir -p ~/.config/yabai

# 创建配置文件
cat > ~/.config/yabai/yabairc << 'EOF'
#!/usr/bin/env sh

# 窗口管理配置
yabai -m config layout bsp
yabai -m config window_placement second_child

# 边距配置
yabai -m config top_padding 10
yabai -m config bottom_padding 10
yabai -m config left_padding 10
yabai -m config right_padding 10
yabai -m config window_gap 10

echo "yabai configuration loaded.."
EOF

# 赋予执行权限
chmod +x ~/.config/yabai/yabairc
```

重启服务以应用配置：
```bash
brew services restart yabai
```

### SIP 配置（仅限 macOS 10.15 - 11.x）

macOS 12+ 用户可跳过此步骤。

如需完整功能，可能需要部分禁用 SIP：

```bash
# 重启到恢复模式（开机时按住 Cmd + R）
# 在终端中执行：
csrutil enable --without debug --without fs
```

⚠️ **警告：** 修改 SIP 存在安全风险，请充分了解后再操作。

## 故障排除

### 问题："yabai: could not access accessibility features"

**解决：**
1. 确保已在「系统设置」→「隐私与安全」→「辅助功能」中添加 yabai
2. 尝试移除后重新添加
3. 重启 yabai 服务：`brew services restart yabai`

### 问题："yabai -m query" 返回空

**解决：**
1. 检查 yabai 是否在运行：`brew services list | grep yabai`
2. 查看日志：`tail -f /opt/homebrew/var/log/yabai/yabai.out.log`
3. 确保当前用户有权限访问窗口

### 问题：VibeFocus 显示 "yabai 不可用"

**解决：**
1. 确认 yabai 已安装：`which yabai`
2. 确认服务正在运行：`yabai -m query --spaces`
3. 重启 VibeFocus 后重试

## 卸载 yabai

```bash
# 停止服务
brew services stop yabai

# 卸载
brew uninstall yabai
brew untap koekeishiya/formulae

# 删除配置（可选）
rm -rf ~/.config/yabai
```

## 相关链接

- [Yabai GitHub 仓库](https://github.com/koekeishiya/yabai)
- [Yabai 官方文档](https://github.com/koekeishiya/yabai/wiki)
- [VibeFocus 使用指南](../README.md)
```

### Step 1.2: 创建快速入门文档

```markdown
# Yabai 快速入门

## 3 步完成安装

### 1️⃣ 安装
```bash
brew install koekeishiya/formulae/yabai
```

### 2️⃣ 启动服务
```bash
brew services start yabai
```

### 3️⃣ 授权
打开「系统设置」→「隐私与安全」→「辅助功能」，添加 yabai

---

## 验证安装
```bash
yabai -m query --spaces
```

返回 JSON 即表示成功 ✅

---

[查看完整指南 →](README.md)
```

---

## Task 2: 在 SettingsUI.swift 中添加代码块组件

**Files:**
- Modify: `Sources/SettingsUI.swift` - 添加 CodeBlockView 组件

### Step 2.1: 创建 CodeBlockView 组件

在 `SettingsUI.swift` 中添加以下代码：

```swift
// MARK: - Code Block View
private struct CodeBlockView: View {
    let code: String
    let language: String
    @State private var isCopied = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(language)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.1))
                    )
                
                Spacer()
                
                Button(action: copyToClipboard) {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        Text(isCopied ? "已复制" : "复制")
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(isCopied ? .green : .accentColor)
            }
            
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(2)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                )
        )
    }
    
    private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        
        withAnimation {
            isCopied = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                isCopied = false
            }
        }
    }
}
```

### Step 2.2: 修改 SpaceController 部分添加代码块

在 SettingsUI.swift 的 "跨工作区（高级）" card 中，当 yabai 未安装时添加：

```swift
if spaceController.availability == .notInstalled {
    VStack(alignment: .leading, spacing: 12) {
        Text("安装 yabai 可启用跨工作区移动功能：")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        
        CodeBlockView(
            code: "brew install koekeishiya/formulae/yabai",
            language: "bash"
        )
        
        CodeBlockView(
            code: "brew services start yabai",
            language: "bash"
        )
        
        HStack(spacing: 12) {
            Button("查看完整指南") {
                if let url = URL(string: "https://github.com/CC11001100/vibe-focus/blob/main/docs/yabai-guide/README.md") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            
            Button("验证安装") {
                spaceController.refreshAvailability(force: true)
            }
            .buttonStyle(.bordered)
        }
        
        Text("安装完成后点击「验证安装」按钮，或重新打开设置窗口。")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }
}
```

---

## Task 3: 构建并验证

**Files:**
- Test: Build and run

### Step 3.1: 编译验证

```bash
swift build 2>&1
```

Expected: Build completed successfully (no errors)

### Step 3.2: 运行测试

```bash
swift run
```

验证要点：
- [ ] 打开设置窗口
- [ ] 点击「重新检测」按钮确保 yabai 状态显示正确
- [ ] 如果未安装 yabai，检查是否显示代码块
- [ ] 点击「复制」按钮，验证能否复制到剪贴板
- [ ] 点击「查看完整指南」，验证能打开浏览器

---

## Task 4: 提交更改

### Step 4.1: 添加文件到 git

```bash
git add docs/yabai-guide/
git add Sources/SettingsUI.swift
```

### Step 4.2: 创建提交

```bash
git commit -m "feat: add yabai installation guide with code blocks in settings UI

- Add comprehensive yabai installation guide in docs/yabai-guide/
- Add CodeBlockView component with copy-to-clipboard functionality
- Update Settings UI to show installation steps when yabai not detected
- Add links to full documentation"
```

---

## Implementation Notes

1. **代码块样式**：使用系统字体和颜色，确保与 macOS 原生界面协调
2. **复制反馈**：使用绿色 checkmark 图标和「已复制」文字，2秒后恢复
3. **水平滚动**：命令过长时支持水平滚动
4. **文档链接**：使用 GitHub 仓库的绝对路径，确保用户总能访问最新文档

## Success Criteria

- [x] 文档完整：包含安装、配置、故障排除
- [x] 界面友好：代码块可一键复制
- [x] 导航清晰：能从界面跳转到完整文档
- [x] 无编译错误
- [x] 功能测试通过
