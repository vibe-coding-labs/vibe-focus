#!/bin/bash
# 安装/更新 VibeFocus keepalive LaunchAgent（带崩溃熔断 + 正常退出不复活）。
#
# Usage:
#   bash scripts/install-keepalive.sh          # 安装并立即加载
#   bash scripts/install-keepalive.sh unload   # 卸载（用户不想要自动拉起时）
#
# 本脚本同时是「可 source 的模板库」：write_wrapper / write_plist 供
# Tests/Standalone/KeepaliveWrapperDecisionTests.swift 生成 wrapper 做真实行为测试
# （source 时仅定义函数，不触碰 launchd 与 $HOME 下的任何路径；main 流程由
#  BASH_SOURCE 守卫，仅直接执行时运行）。
#
# ## 背景（2026-08-31 崩溃诊断）
# 机器上曾存在裸的 keepalive plist（KeepAlive=true + 直接 open -W），有两个问题：
# 1. 崩溃循环加速器：app 崩溃 → 10s 后无条件拉起 → 坏屏幕配置下启动即再崩
#    （~/Library/Logs/VibeFocus/crash-fatal-*.log 每 10 秒一条，7-18 / 8-10 两轮实证）。
# 2. 用户主动 Quit 后 10 秒被无条件复活（退不掉）。
#
# ## 本脚本方案
# plist 指向 wrapper 脚本而非直接 open：wrapper 在 app 退出后检查"本次运行期间是否发生
# 致命信号"，崩溃 → 延迟 60s 再拉起（与 app 侧 60s 崩溃循环熔断配合，断开循环）；
# 正常退出 → 不再拉起。App 自身还有第二层熔断：启动检测到 60s 内崩溃则本次不创建
# overlay 窗口。
#
# ## 崩溃裁决判据（2026-09-08 起：仅 size 差分）
# fatal 文件（/tmp/vibefocus-crash-fatal.log）由 CrashSignalHandler 以 O_APPEND 持有，
# 真崩溃时追加信号现场内容——**size 必增长**；mtime 不参与裁决，只随行记录供取证。
# 理由是 mtime 差分已三次实证误报（全部 size 不变）：
#   ① 2026-07-12：陈旧 SIGSEGV 记录以新 mtime「复活」，三次把安装重拉的正常退出
#      误判为崩溃（01:24 / 04:30 / 16:43，各造成 60s 无应用窗口）；
#   ② 2026-09-06 16:43：同上（促成 (mtime,size) 差分方案，但 mtime 变化仍可单独触发）；
#   ③ 2026-09-08 02:40：安装重启（SIGTERM）期间，并行会话的 VibeFocus 派生进程
#      （测试 runner 启动路径）touch/重建共享 fatal 文件，mtime 变、size 0→0，
#      再次误判为崩溃进入 60s 冷却。
# 「absent」与「size=0」等价：任何派生进程启动都会把旧 fatal 文件 move 归档并新建
# 空文件（archive+create），故 size N→0 视为归档而非本次运行新崩溃；毫秒级
# 「崩溃追加后立即被并行启动归档」的窗口接受漏判（.ips 与 exits.jsonl 独立兜底）。
#
# ## 测试注入缝（默认值 = 生产行为，不变）
# wrapper 运行时读环境变量，仅供 KeepaliveWrapperDecisionTests 以假 open 二进制
# 驱动生成物穷尽分支，生产环境不设置：
#   VIBEFOCUS_KEEPALIVE_OPEN_BIN   替换 /usr/bin/open（假 open 立即返回=app 退出）
#   VIBEFOCUS_KEEPALIVE_COOLDOWN   替换 60s 冷却（测试用 1s）
#   VIBEFOCUS_KEEPALIVE_FATAL_LOG  替换共享 fatal 路径（测试指向临时目录）
#   VIBEFOCUS_KEEPALIVE_KLOG       替换决策日志路径（测试指向临时目录）

set -euo pipefail

LABEL="com.vibefocus.app.keepalive"
PLIST_PATH="$HOME/Library/LaunchAgents/${LABEL}.plist"
WRAPPER_PATH="$HOME/Library/Application Support/VibeFocus/keepalive-wrapper.sh"
APP_PATH="${APP_PATH:-$HOME/Applications/VibeFocus.app}"

write_wrapper() {
    local out="$1" app_path="$2"
    mkdir -p "$(dirname "$out")"
    cat > "$out" <<WRAPPER
#!/bin/bash
# 由 scripts/install-keepalive.sh 生成，勿手改。
# 每次拉起/退出都留痕：决策日志一行一个决策，含 fatal 文件 size 差分与二进制身份
# 差分——取证时无需重放推理（2026-09-06 教训；裁决判据沿革见生成器文件头）。
FATAL_LOG="\${VIBEFOCUS_KEEPALIVE_FATAL_LOG:-/tmp/vibefocus-crash-fatal.log}"
KLOG="\${VIBEFOCUS_KEEPALIVE_KLOG:-/tmp/vibefocus-keepalive.log}"
COOLDOWN="\${VIBEFOCUS_KEEPALIVE_COOLDOWN:-60}"
OPEN_BIN="\${VIBEFOCUS_KEEPALIVE_OPEN_BIN:-/usr/bin/open}"
APP_BIN="$app_path/Contents/MacOS/VibeFocusHotkeys"
# 裁决签名 = size（absent 与 0 等价：归档即清空）；mtime 只取证不裁决。
fatal_size() { if [[ -f "\$FATAL_LOG" ]]; then stat -f '%z' "\$FATAL_LOG"; else echo 0; fi; }
fatal_mtime() { stat -f '%m' "\$FATAL_LOG" 2>/dev/null || echo none; }
bin_ident() { stat -f '%m_%i' "\$APP_BIN" 2>/dev/null || echo none; }
echo "\$(date '+%F %T') wrapper start pid=\$\$ app=$app_path" >> "\$KLOG"
while true; do
    size_before=\$(fatal_size)
    mtime_before=\$(fatal_mtime)
    bin_before=\$(bin_ident)
    "\$OPEN_BIN" -W "$app_path"
    # \$OPEN_BIN 返回 = app 已退出。裁决只看 size：本次运行期间 fatal 文件被真实
    # 追加（size 变化）才算崩溃；mtime 变化（陈旧记录复活/派生进程启动触碰）不误判。
    size_after=\$(fatal_size)
    mtime_after=\$(fatal_mtime)
    bin_after=\$(bin_ident)
    crashed=0
    [[ "\$size_before" != "\$size_after" ]] && crashed=1
    binflag=same
    [[ "\$bin_before" != "\$bin_after" ]] && binflag=REPLACED
    if (( crashed )); then
        echo "\$(date '+%F %T') app exited fatal_size=\$size_before->\$size_after fatal_mtime=\$mtime_before->\$mtime_after bin=\$binflag decision=respawn-in-\${COOLDOWN}s" >> "\$KLOG"
        sleep "\$COOLDOWN"
        continue
    fi
    echo "\$(date '+%F %T') app exited fatal_size=\$size_before->\$size_after fatal_mtime=\$mtime_before->\$mtime_after bin=\$binflag decision=no-respawn" >> "\$KLOG"
    break   # 正常退出（用户 Quit）：不再拉起
done
WRAPPER
    chmod +x "$out"
}

write_plist() {
    local out="$1" wrapper="$2"
    mkdir -p "$(dirname "$out")"
    cat > "$out" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${wrapper}</string>
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
}

uninstall_keepalive() {
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm -f "$PLIST_PATH"
    echo "keepalive removed ($PLIST_PATH). App 不再自动拉起。"
}

# source 时仅提供函数（测试模板库模式），main 流程不执行。
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0 2>/dev/null || true
fi

if [[ "${1:-}" == "unload" ]]; then
    uninstall_keepalive
    exit 0
fi

[[ -d "$APP_PATH" ]] || { echo "ERROR: $APP_PATH 不存在（可用 APP_PATH=... 指定）"; exit 1; }

write_wrapper "$WRAPPER_PATH" "$APP_PATH"
write_plist "$PLIST_PATH" "$WRAPPER_PATH"

launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || launchctl load "$PLIST_PATH"

echo "keepalive installed:"
echo "  plist   : $PLIST_PATH"
echo "  wrapper : $WRAPPER_PATH"
echo "行为：崩溃（fatal 文件 size 增长）后延迟 60s 再拉起；正常退出不再拉起。"
echo "卸载：bash scripts/install-keepalive.sh unload"
