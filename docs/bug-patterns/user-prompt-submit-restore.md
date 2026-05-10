# Bug 模式：UserPromptSubmit 自动恢复失败

## Bug 表现
回车提交 Claude Code 提示词后，终端窗口不自动从主屏幕回退到副屏幕。

## 历史根因分析（按发生频次排序）

### 1. hook-forwarder.sh 生成错误（本次）
**症状：** 所有 hook 事件（SessionStart、Stop、UserPromptSubmit）都无法到达 VibeFocus。日志中完全没有 hook 相关条目。
**根因：** Swift 多行字符串插值 `\(variable)` 被写成 `#{variable}`，导致 bash 脚本中 URL 是字面量 `http://#{hostDefault}:39277/claude/hook` 而不是 `http://127.0.0.1:39277/claude/hook`。curl 请求发到了无效地址。
**修复：** 将 `#{hostDefault}` 改为 `\(hostDefault)` (commit ce55bea)。
**检测方法：** 检查 `~/.vibefocus/hook-forwarder.sh` 中的 `VF_URL=` 行，确认 URL 包含实际 IP 而非 Swift 变量名。

### 2. hook-forwarder.sh token 传递方式错误（本次修复）
**症状：** hook 请求到达服务器但返回 401 Unauthorized。
**根因：** token 通过 URL query string 传递（`?token=xxx`），但服务器代码优先检查 query string。当修改为 header 传递时，如果 hook-forwarder 没有同步更新就会不匹配。
**修复：** 统一使用 `X-VibeFocus-Token` header 传递 token。

### 3. ToggleRecord 找不到或损坏
**症状：** UserPromptSubmit 事件到达，binding 匹配成功，但 `engine.load(windowID:)` 返回 nil。
**根因：**
- Ctrl+Q toggle 时保存的 windowID 和 session binding 的 windowID 不一致
- ToggleRecord 的 origFrame 和 targetFrame 都在主屏上（数据损坏）
**修复：** 添加多级匹配（windowID → PID+appName → appName），添加 `isValid()` 验证。
**检测方法：** 日志中搜索 `ToggleEngine.load` 或 `no toggle state found`。

### 4. binding 验证失败
**症状：** UserPromptSubmit 日志显示 `binding_verification_failed`。
**根因：** SessionStart 绑定的窗口 PID/TTY 和当前实际的不一致（进程重启、终端 session 变化等）。
**修复：** 添加降级路径 — binding 失败时尝试通过 terminalCtx 重新匹配。

### 5. autoRestoreOnPromptSubmit 偏好被关闭
**症状：** 日志显示 `auto_restore_disabled`。
**根因：** 该偏好默认为 false（之前的 fix commit c506050），用户升级后可能没有手动开启。
**检测方法：** `defaults read VibeFocusHotkeys claudeHookAutoRestoreOnPromptSubmit`

## 快速排查清单

当"回车不回退"再次出现时，按以下顺序检查：

```bash
# 1. 检查 hook-forwarder URL 是否正确
grep "VF_URL=" ~/.vibefocus/hook-forwarder.sh
# 预期: VF_URL="http://127.0.0.1:$VF_PORT/claude/hook" 或含实际 IP

# 2. 检查 autoRestore 是否开启
defaults read VibeFocusHotkeys claudeHookAutoRestoreOnPromptSubmit
# 预期: 1

# 3. 检查 hook 是否安装
cat ~/.claude/settings.json | python3 -c "import sys,json;d=json.load(sys.stdin);print(list(d.get('hooks',{}).keys()))"
# 预期: 包含 UserPromptSubmit

# 4. 检查最近日志中的 hook 事件
grep "UserPromptSubmit\|request received\|routing event" ~/Library/Logs/VibeFocus/vibefocus.log | tail -10

# 5. 检查 ToggleRecord 是否存在
grep "ToggleEngine.load\|no toggle state" ~/Library/Logs/VibeFocus/vibefocus.log | tail -5
```

## 预防措施
- 每次修改 `generateHelperScriptContent` 后，必须检查生成的 `~/.vibefocus/hook-forwarder.sh` 内容
- Swift 多行字符串插值使用 `\(` 不是 `#(`，edit 命令后必须验证实际文件内容
- 部署后验证：运行 `grep "VF_URL=" ~/.vibefocus/hook-forwarder.sh` 确认 URL 正确
