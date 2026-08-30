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
# 致命信号"（/tmp/vibefocus-crash-fatal.log 非空且 mtime 晚于本次启动）——
#   崩溃   → 延迟 60s 再拉起（与 app 侧 60s 崩溃循环熔断配合，断开循环）
#   正常退出 → 不再拉起（用户 Quit 即真正退出）
# App 自身还有第二层熔断：启动检测到 60s 内崩溃则本次不创建 overlay 窗口。
#
# 判定细节：/tmp/vibefocus-crash-fatal.log 由 app 每次启动重建（空文件），
# 崩溃时 signal handler 以 O_APPEND 写入——"非空且 mtime > 本次拉起时刻"即本次运行崩溃。

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
while true; do
    launched_at=\$(date +%s)
    /usr/bin/open -W "$APP_PATH"
    # open -W 返回 = app 已退出。判定本次运行是否崩溃：
    # 非空 fatal 日志 + mtime 晚于本次拉起时刻。
    crashed=0
    if [[ -s "\$FATAL_LOG" ]]; then
        mtime=\$(stat -f %m "\$FATAL_LOG" 2>/dev/null || echo 0)
        (( mtime > launched_at )) && crashed=1
    fi
    if (( crashed )); then
        echo "\$(date '+%F %T') crash detected, respawn in \${COOLDOWN}s" >> /tmp/vibefocus-keepalive.log
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
echo "行为：崩溃后延迟 ${COOLDOWN}s 再拉起；用户主动 Quit 不再复活。"
echo "卸载：bash scripts/install-keepalive.sh unload"
