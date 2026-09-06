#!/bin/bash
# 安装/更新 VibeFocus keepalive LaunchAgent（带崩溃熔断 + 正常退出不复活）。
#
# Usage:
#   bash scripts/install-keepalive.sh          # 安装并立即加载
#   bash scripts/install-keepalive.sh unload   # 卸载（用户不想要自动拉起时）
#
# ## 背景（2026-08-31 崩溃诊断）
# 机器上曾存在裸的 keepalive plist（KeepAlive=true + 直接 open -W），有两个问题：
# 1. 崩溃循环加速器：app 崩溃 → 10s 后无条件拉起 → 坏屏幕配置下启动即再崩
#    （~/Library/Logs/VibeFocus/crash-fatal-*.log 每 10 秒一条，7-18 / 8-10 两轮实证）。
# 2. 用户主动 Quit 后 10 秒被无条件复活（退不掉）。
#
# ## 本脚本方案
# plist 指向 wrapper 脚本而非直接 open：wrapper 在 app 退出后检查"本次运行期间是否发生
# 致命信号"——fatal 日志在本次拉起前后 (mtime,size) 是否变化——
#   崩溃   → 延迟 60s 再拉起（与 app 侧 60s 崩溃循环熔断配合，断开循环）
#   正常退出 → 不再拉起（用户 Quit 即真正退出）
# App 自身还有第二层熔断：启动检测到 60s 内崩溃则本次不创建 overlay 窗口。
#
# 判定细节：比较本次拉起前后 fatal 文件的 (mtime,size) 差分，而非「非空且 mtime 晚于
# 本次启动」的绝对时间比较。原因（2026-09-06 16:43 实证）：该 /tmp 路径被全机所有
# VibeFocus 派生进程共享（历史旧构建、各 worktree 的测试 runner），app 每次启动重建
# 空文件的前提并不总成立——2026-07-12 的 SIGSEGV 记录曾以新 mtime 在文件中复活，
# 01:24 / 04:30 / 16:43 三次把安装重拉的正常退出误判为崩溃，各造成 60s 无应用窗口。
# 差分比较只认本次运行期间的真实追加，陈旧记录不变即不误触发。

set -euo pipefail

LABEL="com.vibefocus.app.keepalive"
PLIST_PATH="$HOME/Library/LaunchAgents/${LABEL}.plist"
WRAPPER_PATH="$HOME/Library/Application Support/VibeFocus/keepalive-wrapper.sh"
APP_PATH="${APP_PATH:-$HOME/Applications/VibeFocus.app}"

if [[ "${1:-}" == "unload" ]]; then
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm -f "$PLIST_PATH"
    echo "keepalive removed ($PLIST_PATH). App 不再自动拉起。"
    exit 0
fi

[[ -d "$APP_PATH" ]] || { echo "ERROR: $APP_PATH 不存在（可用 APP_PATH=... 指定）"; exit 1; }

mkdir -p "$(dirname "$WRAPPER_PATH")"

cat > "$WRAPPER_PATH" <<WRAPPER
#!/bin/bash
# 由 scripts/install-keepalive.sh 生成，勿手改。
FATAL_LOG="/tmp/vibefocus-crash-fatal.log"
COOLDOWN=60
fatal_sig() { stat -f '%m_%z' "\$FATAL_LOG" 2>/dev/null || echo none; }
while true; do
    fatal_before=\$(fatal_sig)
    /usr/bin/open -W "$APP_PATH"
    # open -W 返回 = app 已退出。判定本次运行是否发生致命信号：
    # 本次拉起前后 fatal 文件 (mtime,size) 差分——只在本次运行期间被真实
    # 追加过才算崩溃（陈旧共享记录 mtime 复活不会误触发，见生成脚本注释）。
    fatal_after=\$(fatal_sig)
    crashed=0
    [[ "\$fatal_before" != "\$fatal_after" ]] && crashed=1
    if (( crashed )); then
        echo "\$(date '+%F %T') crash detected (fatal log changed: \$fatal_before -> \$fatal_after), respawn in \${COOLDOWN}s" >> /tmp/vibefocus-keepalive.log
        sleep "\$COOLDOWN"
        continue
    fi
    break   # 正常退出（用户 Quit）：不再拉起
done
WRAPPER
chmod +x "$WRAPPER_PATH"

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${WRAPPER_PATH}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>/tmp/vibefocus-keepalive.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/vibefocus-keepalive.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || launchctl load "$PLIST_PATH"

echo "keepalive installed:"
echo "  plist   : $PLIST_PATH"
echo "  wrapper : $WRAPPER_PATH"
echo "行为：崩溃后延迟 60s 再拉起；用户主动 Quit 不再复活。"
echo "卸载：bash scripts/install-keepalive.sh unload"
