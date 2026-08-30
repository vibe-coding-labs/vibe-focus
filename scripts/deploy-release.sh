#!/bin/bash
# 【用户本机执行】把 dist/VibeFocus.app 替换为运行中的 app，并安装带熔断的 keepalive。
# 前置：先执行 scripts/build-release.sh 生成产物。
#
# 执行步骤（幂等，可重复运行）：
#   1. 停掉旧 keepalive（防止替换过程中旧 LaunchAgent 拉起旧 app）
#   2. 停掉运行中的 VibeFocus
#   3. 备份旧 app 到 ~/Applications/VibeFocus.app.backup-<时间戳>
#   4. 拷贝新 app 到 ~/Applications/VibeFocus.app + ad-hoc 签名 + 去隔离
#   5. 启动新 app
#   6. 安装带熔断的 keepalive（scripts/install-keepalive.sh）
#
# 回滚：备份目录拷回原位后重新 open 即可。
set -euo pipefail

APP_NAME="VibeFocus"
EXECUTABLE_NAME="VibeFocusHotkeys"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_APP="$SCRIPT_DIR/dist/$APP_NAME.app"
DST_APP="$HOME/Applications/$APP_NAME.app"
LABEL="com.vibefocus.app.keepalive"

[[ -d "$SRC_APP" ]] || { echo "ERROR: 产物 $SRC_APP 不存在，先执行 scripts/build-release.sh"; exit 1; }
[[ -x "$SRC_APP/Contents/MacOS/$EXECUTABLE_NAME" ]] || { echo "ERROR: 产物缺少可执行文件"; exit 1; }

echo "1/6 停止旧 keepalive..."
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || launchctl unload "$HOME/Library/LaunchAgents/${LABEL}.plist" 2>/dev/null || true

echo "2/6 停止运行中的 VibeFocus..."
pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
sleep 1

echo "3/6 备份旧 app..."
if [[ -d "$DST_APP" ]]; then
    BACKUP="${DST_APP}.backup-$(date +%Y%m%d-%H%M%S)"
    mv "$DST_APP" "$BACKUP"
    echo "  备份: $BACKUP"
fi

echo "4/6 安装新 app..."
ditto "$SRC_APP" "$DST_APP"
codesign --force --deep --sign - "$DST_APP" >/dev/null 2>&1
xattr -rd com.apple.quarantine "$DST_APP" 2>/dev/null || true

echo "5/6 启动新 app..."
open "$DST_APP"
sleep 2

echo "6/6 安装带熔断的 keepalive..."
bash "$SCRIPT_DIR/install-keepalive.sh"

echo ""
echo "✅ 替换完成。"
echo "  运行版本: $(defaults read "$DST_APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo '?')"
echo "  验证熔断已生效: grep 'CRASH LOOP' /tmp/vibefocus.log（有屏幕热插拔崩溃时出现）"
echo "  应用日志: /tmp/vibefocus.log"
echo "  回滚: mv $DST_APP ${DST_APP}.old && mv <备份目录> $DST_APP && open $DST_APP"
