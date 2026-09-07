#!/bin/bash
# 兼容入口（2026-09-08 B55 降级为 run.sh 委派器）：全部行为以 run.sh 单一事实源为准。
#
# ## 历史与降级理由
# 本文件曾是独立的「构建 + 装包 + 签名 + 重启」实现，与 run.sh 构成双份判据并已实质漂移：
#   - bundle id 写的是退役的 com.vibefocus.app（run.sh 与现装机的 canonical id 是
#     com.openai.vibe-focus）——退役 id 正是 docs 记载的「误启旧副本回到无修复行为」陷阱；
#   - Info.plist 缺 NSAppleEventsUsageDescription（标题编辑的 Automation 权限键）；
#   - 无哈希跳过（无谓重装 = 新 CDHash = 白白断一次 TCC 授权）、无部署锁、无安装审计；
#   - 不 rm 旧 bundle（就地覆盖，存在 CODESIGNING 缺页击杀风险，run.sh 已用全新 inode 规避）。
# 双实现的收敛方式：本文件不再包含任何构建/装包/签名逻辑，直接委派 run.sh——
# 既有文档与肌肉记忆（./install.sh）保持可用，行为归一到 run.sh 的全部保护。
#
# Usage:
#   ./install.sh            # 等价于 ./run.sh（构建 → 哈希比对 → 原子装包 → 签名 → 重启）

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/run.sh" "$@"
