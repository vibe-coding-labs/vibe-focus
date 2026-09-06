# 代码质量提升计划（2026-09-06 立项）

> 背景：2026-09-06 一天内集中爆发四类用户可见 bug（水波/SIGTRAP 秒死/授权反复失效/
> 尺寸搞错）。经堆栈与审计逐一归因：**全部为存量缺陷被环境扰动引爆，无一为当日改动回归**。
> 本计划针对归因暴露的结构性风险，分四个阶段把「稍改即炸」的品类逐个消除。
> 每阶段独立 worktree、独立门禁（构建零警告 + run_all_tests 全绿 + 涉窗口逻辑加跑真机 E2E）、
> 合并推送后真机部署验证——与仓库 AGENTS.md 流程一致。

## 根因模型（为什么「稍改一点就一堆 bug」）

1. **高危模式集中在热路径**：单例 init 链上有主线程同步外部 IPC（NSAppleScript 泵嵌套
   RunLoop、SMAppService XPC）；22 个 dispatch_once 单例被 SwiftUI 渲染路径触碰；
   toggle 行为绑定全局焦点窗口；存在破坏性兜底（stuck 路由撑满整屏）。
2. **运行环境高频扰动**：多会话并行开发同一台机器，每次部署 = 断一次 AX + 抢一次焦点，
   把上述潜伏雷逐个引爆（放大效应）。
3. **热路径此前零真机自动化覆盖**：潜伏缺陷可存活数周（SIGTRAP 潜伏至 6-28 引入的代码）。

## P0 红线：单例 init 链去阻塞外部调用（本阶段，最高优先）

**红线定义**：任何 `static let shared` 单例的 init →（直接或间接）调用链上，禁止出现：
- NSAppleScript / OSA 脚本执行（泵嵌套 RunLoop，dispatch_once 重入 → SIGTRAP 实锤）
- SMAppService 等同步 XPC（延迟不可控）
- yabai / 外部进程 fork（100-650ms 级）
- 超过 10ms 的文件系统扫描

**清查结果（2026-09-06）**：
- ✅ LoginItemManager：cleanupStaleLoginItems 的 NSAppleScript 已移全局队列（be47013）；
  本阶段收尾 `SMAppService.mainApp.status` —— refresh() 从 init 链延迟到主队列异步。
- ⚠️ CrashContextRecorder.bootstrap：启动期崩溃报告目录扫描 + JSON parse，有 P-INST 耗时
  埋点、量级可控 → 观察项，暂不动。
- ⚠️ ScreenOverlayManager / preferences SQLite 读：毫秒级本地读 → 可接受，记录在案。

**验收**：清查清单归零（含注释禁令写入 code-quality-playbook）+ 门禁全绿 + 真机启动后
login item 状态仍正常回填（日志验证）。

## P1 破坏性兜底清查

**定义**：所有「失败/异常时做一个大胆替代动作」的 fallback 路径。已知已修：stuck 解堵
撑满整副屏（6bb3460）。方法：按 WindowManager+Toggle+Routes.swift 的路由表逐条审
fallback 行为，原则改为「保守退让（保持原状/最小移动）+ 诚实上报」。
**验收**：路由级清查清单 + 每条 fallback 有真机 E2E 断言（SIZE_E2E 模式推广）。

## P2 热路径真机 E2E 常态化

- 已有：GRID_SPACE_E2E（space 投递）、SIZE_E2E（尺寸保真四用例）、GRID_TARGET_E2E。
- 待建：move_to_main 全屏适配用例、restore 空间切换用例。
- 归口：`Tests/e2e/` 说明文档列出「动窗口逻辑必须跑」的清单；AGENTS.md 引用。
**验收**：窗口链路改动合并前 E2E 必跑成为门禁的一部分。

## P3 部署节流与安装审计

- run.sh 部署文件锁（同机并发部署互斥）；
- 安装事件（时间/构建哈希/是否替换）追加审计 JSONL——AX 失效与安装的相关性在
  --diagnose 里一眼可见；
- ax=false 引导流每实例只开一次系统设置（避免焦点反复被抢）。
**验收**：连续两次部署（一升一空跑）审计完整、授权状态时间线连续。

## P4 观测运营固化

- 排查首站固化为文档：`--diagnose` → exits.jsonl → crash-fatal 归档 → keepalive 决策行；
- 新增热路径行为变更时，PR 描述必须附 E2E 运行输出。

## 进度台账

| 阶段 | 状态 | 提交 | 备注 |
|---|---|---|---|
| P0 | ✅ 2026-09-06 | 见本文件提交历史 | LoginItemManager refresh 延迟化 + 红线注释固化 |
| P1 | ✅ 2026-09-06 | 见本文件提交历史 | restore 屏外 origFrame 保守退让（clampFrame 夹进源屏重试）+ SIZE_E2E 五用例全绿（跨屏放大/缩小/toggle 往返/解堵尺寸保持/屏外夹取还原） |
| P2 | ✅ 2026-09-06 | 见本文件提交历史 | SIZE_E2E 补 move_to_main 路由直呼用例 + Tests/e2e/README.md 归口文档（清单/红线/跑法） |
| P3 | ✅ 2026-09-06 | 见本文件提交历史 | run.sh 部署文件锁（mkdir+陈锁回收）+ 安装事件（replaced/skipped-unchanged）写入 exits.jsonl，--diagnose 时间线可见 |
| P4 | 文档已建 | 本文件 | — |

## 运行注意事项（实测）

- **E2E 同机互斥**：SIZE_E2E 等 toggle 类真机测试与并行会话的 toggle 测试同机运行时会
  互相扰动（yabai re-tile 把 float 窗口弹回原位、焦点被对方测试抢走）——表现为 toggle
  类用例间歇性 FAIL 但重跑即绿。两个会话不要同时跑窗口类 E2E（P3 部署锁应扩展为测试锁）。
- **部署=真升级时 AX 会断一次**：macOS 对本地签名按 CDHash 校验授权，应用侧无法绕过；
  无变化重装已被 4c99345 哈希跳过保护。

## P1/P2/P3 补充实测（2026-09-06 晚）

- SIZE_E2E 现六用例：跨屏放大/缩小（Δ=0）、toggle 往返（精确还原）、stuck 解堵
  （尺寸保持 900x600）、屏外夹取还原（restored）、move_to_main 路由直呼
  （fill + record 落库）——196/196 真机全绿。
- 部署锁实测：并发第二个 run.sh 被拒（锁存在时）；无变化重装走 skipped-unchanged
  且不替换 bundle、不重启实例。
- 安装事件与 ax 时间线在 --diagnose 同流展示：「授权失效」与「替换二进制」的
  相关性可直接对齐读数。
