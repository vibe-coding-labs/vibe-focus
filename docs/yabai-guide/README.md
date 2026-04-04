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
