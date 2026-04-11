# Codex 插件能力对齐路线图（Claude Hooks 对照）

**目标：** 在不破坏现有 VibeFocus + Claude Hooks 方案的前提下，评估并规划 Codex 侧“同等可扩展能力”的落地路径。

## 结论先行（基于官方文档）

- Codex **已经有插件体系**，可打包 `skills + apps + MCP servers`。  
  参考：<https://developers.openai.com/codex/plugins>
- Codex **支持 hooks.json 生命周期钩子**，但目前属于实验/开发中能力（默认关闭）。  
  参考：<https://developers.openai.com/codex/hooks>  
  参考：<https://developers.openai.com/codex/config-basic#supported-features>
- 插件工程可本地 marketplace 安装、测试和迭代。  
  参考：<https://developers.openai.com/codex/plugins/build>

## 能力映射（Claude -> Codex）

1. Claude `SessionStart/SessionEnd` 事件驱动  
对应 Codex `SessionStart/Stop/UserPromptSubmit/PreToolUse/PostToolUse` 钩子事件。

2. Claude 本地 Hook 脚本转发到 VibeFocus  
对应 Codex `hooks.json` 中 `type=command`，stdin 接收 JSON，stdout 返回控制字段。

3. Claude 手动配置 Hook  
对应 Codex 启用 `[features] codex_hooks = true`，并放置 `~/.codex/hooks.json` 或 `<repo>/.codex/hooks.json`。

## 风险与边界

- `codex_hooks` 当前为 **Under development**，需要按实验特性管理，不能当稳定 API 承诺。
- 当前 `PreToolUse/PostToolUse` 主要针对 Bash 工具流，不覆盖全部工具类型。
- Hooks 在同一事件下可能并发执行，不能依赖串行副作用。
- Windows 上 hooks 当前不可用（官方文档标注临时关闭）。

## 分阶段实施计划

## Phase 0：文档化与可观测性（立即）

- [x] 输出本路线图，明确能力边界与落地顺序。
- [ ] 在 README 增加 Codex 对接章节（与 Claude 章节并列），标注实验性质与开关步骤。

## Phase 1：最小可行联动（MVP）

- [ ] 新增 `Resources/codex-session-hook-example.*` 示例（command hook -> POST VibeFocus 本地端点）。
- [ ] 提供 `hooks.json` 最小模板（SessionStart + Stop）。
- [ ] 增加本地验收脚本：验证事件到达、会话绑定、窗口移动、Ctrl+M 恢复。

## Phase 2：插件化分发（可复用）

- [ ] 新建 `plugins/vibefocus-codex-plugin/` 目录，包含：
  - `.codex-plugin/plugin.json`
  - `skills/`（接入说明与故障排查）
  - 可选 `.mcp.json`（若后续需要远程状态查询）
- [ ] 新建 repo 级 marketplace：`$REPO_ROOT/.agents/plugins/marketplace.json`。
- [ ] 在本机完成“安装 -> 启用 -> 验证”闭环。

## Phase 3：Claude/Codex 统一协议（增强）

- [ ] 统一事件模型（session_id、source、timestamp、event）。
- [ ] 统一幂等策略（重复结束事件不重复移动）。
- [ ] 统一状态可视化（设置页显示来源：Claude/Codex + 最近事件）。

## 验收标准

1. Codex hooks 可触发 VibeFocus 本地端点，成功完成会话窗口绑定与聚焦。
2. 多会话并发下，窗口可独立恢复到原屏幕/工作区/几何。
3. 关闭 `codex_hooks` 后不影响现有 Claude 方案。
4. 无系统侵入：不自动改用户全局配置，仅给模板与显式步骤。
