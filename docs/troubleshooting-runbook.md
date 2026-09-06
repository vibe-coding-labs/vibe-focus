# VibeFocus 排查首站 Runbook（观测运营固化）

> 立项：docs/quality-plan-2026-09.md P4。任何「莫名退出 / 授权失效 / 行为异常」的排查
> 从本文档出发，按顺序取证，不要先猜原因。全部命令真机可跑、无副作用（除标注）。

## 0. 一键首站：`--diagnose`

```bash
~/Applications/VibeFocus.app/Contents/MacOS/VibeFocusHotkeys --diagnose
```

输出六大段（依次读，多数问题前两段就定位）：

1. **实例生命周期**：exits.jsonl 时间线（launch/exit/install 混排，带 ax 授权状态标签）
   ——「授权失效」与「替换二进制」是否同刻发生，这里直接对齐读数；
2. **最近一次死亡**：reason / signal / 致命信号现场；
3. **疑似外部击杀**：launch 后无对应 exit 记录、且 pid 仍存活的实例（SIGKILL 类无遗言，
   靠 launch 记录反推）；
4. **致命信号记录现场**：crash-fatal 归档内容（含 BACKTRACE）；
5. **.ips 崩溃报告**：~/Library/Logs/DiagnosticReports 里本应用最近的系统级报告；
6. **keepalive 决策** + **应用日志 ERROR**：自动拉起行为与最近错误行。

## 1. 证据文件速查

| 文件 | 写入者 | 内容 |
|---|---|---|
| `~/Library/Logs/VibeFocus/exits.jsonl` | 应用 + run.sh | 生命周期审计（append-only JSONL） |
| `diagnosticFatalLogPath()`（主应用 = `/tmp/vibefocus-crash-fatal.log`） | 信号 handler | FATAL SIGNAL + BACKTRACE（启动时归档后清空） |
| `diagnosticSnapshotLogPath()` | 信号 handler | 崩溃瞬间的现场快照（角色隔离，与 fatal 分离） |
| `/tmp/vibefocus-keepalive.log` | keepalive wrapper | 每次退出的崩溃判定决策行 |
| `~/Library/Application Support/VibeFocus/last-install.sha256` | run.sh | 最近一次安装的构建哈希（无变化重装据此跳过） |

### exits.jsonl 事件与字段

```jsonc
{"kind":"launch","pid":71794,"at":"…","exe":"…","exeMtime":…,"exeInode":…,"bundle":"…","version":"…","ax":true}
{"kind":"exit","pid":63398,"at":"…","reason":"sigterm-graceful"}          // run.sh 部署的优雅退出
{"kind":"exit","pid":…,"at":"-","reason":"fatal-signal","signal":5,"name":"SIGTRAP"}  // 信号 handler 预编码行
{"kind":"exit","pid":…,"reason":"clean"}                                   // atexit 兜底（无显式记录时）
{"kind":"exit","pid":…,"reason":"reuse-existing-activate" | "lock-failed-terminate"}  // 启动互斥
{"kind":"install","at":"…","reason":"replaced"|"skipped-unchanged","sha256":"…"}      // pid=-1 占位
```

读法要点：
- **launch 无配对 exit 且 pid 已死** = 无遗言死亡（SIGKILL/CODESIGNING 击杀）→ 看
  `--diagnose` 的「疑似外部击杀」段与 .ips；
- **`ax` 字段时间线回退 true→false** = AX 授权被断，对照紧邻的 `install` 行：
  有 `replaced` → 真升级 CDHash 变化所致（macOS 行为，重授一次即可）；
  无 install 而断 → 授权漂移，记 `--diagnose` 输出并报障；
- `at:"-"` 的 fatal-signal 行是信号 handler 内**预编码**写的（零构造），at 字段缺失是设计而非损坏。

## 2. 常见症状对照

| 症状 | 首站动作 | 判读 |
|---|---|---|
| 莫名退出/秒死 | `--diagnose` → 最近一次死亡 | fatal-signal → 取 BACKTRACE 归因（SIGTRAP 主线程重入已修 be47013）；无遗言 → 疑似外部击杀段 + .ips |
| ⌃Q 没反应/授权断 | `--diagnose` 生命周期段 | ax 时间线回退点 vs install 行（见上）；恢复：系统设置辅助功能重新勾选（重装断授权是 macOS CDHash 行为，无法应用侧绕过） |
| 窗口尺寸/位置错 | 跑 `VIBEFOCUS_SIZE_E2E=1`（见 Tests/e2e/README） | 全绿则查是否同机并行 E2E 互扰（锁在 /tmp/vibefocus-e2e.lock） |
| 改名不生效/改错窗 | 跑 `VIBEFOCUS_TITLE_E2E=1` + 日志 `targetTTY` 字段 | 写错对象已修（tty 定向，2026-09-07）；「写入成功但回车后被改回」= shell 的 precmd OSC 重设标题（macOS 默认 zsh 行为，应用层不可控；claude 会话窗不画提示符所以能常驻） |
| 按了切换卡顿 | 应用日志 `focusedBranchMs` / `focusedWindowSource` | ax 分支 ~1.5s / yabai 分支 ~648ms 是已知代价（副屏 WindowServer 阻塞），命中 cgwindowlist 应 ~5ms |
| 退出后不自动拉起 | `/tmp/vibefocus-keepalive.log` | 决策行区分「崩溃延迟 60s 拉起」与「用户 Quit 不复活」（设计行为） |
| 部署卡住/互踩 | `ls /tmp/vibefocus-deploy.lock` | 部署锁；>10min 陈锁自动回收，确认无部署在跑可手动 rm -rf |

## 3. 取证后动作

1. 把 `--diagnose` 全文 + exits.jsonl 最后 ~50 行贴进问题记录；
2. 若是致命信号：附带 crash-fatal 归档的 BACKTRACE 段；
3. 自测管道完好性（会真实发一次 SIGTRAP 给测试进程，不动真机实例）：
   `.build/debug/VibeFocusHotkeys --crash-test-signal`。

## 维护约定

- 新增观测工件（新日志/新事件 kind）必须同步更新本文档 §1/§2——文档与实现漂移的
  runbook 比没有更危险；
- 本文档是 P4 的固化物；排查结论若产生新红线/新用例，回流 docs/quality-plan-2026-09.md。
