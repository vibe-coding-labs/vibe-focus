#!/bin/bash
# yabai-space-changed.sh
# 当 yabai 检测到空间切换时执行，发送 SIGUSR1 信号给 VibeFocus

# 发送 SIGUSR1 信号给 VibeFocus 进程
/usr/bin/killall -USR1 VibeFocus 2>/dev/null || true
