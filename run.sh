#!/bin/bash
# VibeFocus 启动脚本

echo "=== VibeFocus 启动器 ==="
echo ""

# 检查辅助功能权限
swift -e '
import ApplicationServices
let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: false] as CFDictionary
let trusted = AXIsProcessTrustedWithOptions(options)
print("辅助功能权限: \(trusted ? "✅ 已授权" : "❌ 未授权")")
'

echo ""
echo "启动 VibeFocusHotkeys..."
echo "快捷键: ⌃⌥⌘M (Control+Option+Command+M)"
echo ""
echo "使用说明:"
echo "1. 点击任意窗口"
echo "2. 按 ⌃⌥⌘M 移到主屏幕并铺满"
echo "3. 再按 ⌃⌥⌘M 恢复窗口"
echo ""
echo "按 Ctrl+C 停止"
echo ""

# 启动程序
"$(dirname "$0")/.build/release/VibeFocusHotkeys"
