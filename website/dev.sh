#!/bin/bash
# Vibe Focus 官网开发守护脚本
# 用法: ./dev.sh

cd "$(dirname "$0")"

while true; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 启动开发服务器..."
    npm run dev
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 进程退出，5秒后重启..."
    sleep 5
done
