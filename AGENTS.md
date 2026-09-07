# vibe-focus 项目开发约定

## 强制规则：所有变更一律走 worktree（2026-09-03 起）

本项目由多个 agent 会话并行开发。直接在共享主工作区（检出 `main`）里改文件或提交，
会互相覆盖在途 WIP、编译互相打断、提交互相卷入。因此：

### 1. 开新任务先 fork 独立 worktree

```bash
git fetch origin
git worktree add ../vibe-focus-<topic> -b <type>/<topic> origin/main
```

- `<type>` 用 `feat` / `fix` / `perf` / `docs` / `refactor` / `test`；
- 必须从最新 `origin/main` 起程，不要从本地旧分支起程；
- 之后的编辑、构建、测试、提交全部在 worktree 内进行；**主工作区只读**。

### 2. 提交一律 pathspec 定向

```bash
git add <具体文件...>
git commit -m "..." -- <具体文件...>
```

禁止 `git add -A` / `git add .` / `git commit -a`——并行会话下宽泛 add 必然卷入他人 WIP
（2026-09-02 实际发生过：`git add` 卷入并行会话已暂存文件，靠 reset 拆分才没污染对方工作）。

### 3. 别人的在途改动一律不碰

主工作区里发现未提交/编译不过的文件，那是别的会话的工作中间态：
不修改、不修复、不提交、不 stash。需要合并通道时存档到 `wip/` 分支让路，
并把冲突现场留给该会话本人解决。

### 4. 任务完成的定义 = 合并回 main 并推送

1. worktree 内跑门禁，全绿才准合：
   - `swift build` 零警告；
   - `bash Tests/run_all_tests.sh` 全绿；
   - 涉及 restore 链路时加跑 `swift run VibeFocusTestRunner` 全绿；
2. `git fetch origin` 确认 `origin/main` 无新提交（有则先 rebase/merge 解决冲突）；
3. `git push origin HEAD:main`（fast-forward）；
4. 合并推送后清理：`git worktree remove ../vibe-focus-<topic>` + `git branch -d <分支>`。
   长期工作的 worktree 可保留，已完成的一律清掉。

### 5. 例外

仅当确认无并行会话且改动为单文件小改时，可就地提交，但 add 仍须定向；
用户在当前会话明确要求就地改时从其指示。

## 单一事实源契约（2026-09-08 起，BundleIdentityContractTests 守护）

1. **bundle id**：canonical = `com.openai.vibe-focus`（run.sh 装机现状）。退役 id
   `com.vibefocus.app` 是「误启旧副本回到无修复行为」陷阱的来源——任何脚本/代码
   不得再把它写进新建 bundle 的 plist。`install.sh` 是 run.sh 的纯委派器，
   不得复活第二套构建/装包/签名实现；签名一律「证书或拒绝」。
2. **装包/重启**：生产事实源 = `run.sh`（哈希跳过保 TCC、部署锁、安装审计、
   rm 旧 bundle 全新 inode、等待旧进程退出再 open）。改动装包逻辑只改 run.sh。

## Runner 测试布局（2026-09-08 B56 起）

`Tests/Runner/main.swift` 只保留 harness 基类 `RunnerHarness`（check/计数器/构造助手）、
假依赖类与 E2E 锁尾区——**不再往 main.swift 里加测试**。新增断言：

- 找到被测域对应的 `Tests/Runner/RunnerXxxTests.swift`，把 do-block 加进它的
  `extension RunnerHarness` 方法；
- 没有对应域文件就新建一个（模仿现有文件的 extension 结构）；
- 在 `RunnerHarness.runAllTests()` 里按想跑的顺序登记一行调用。

## 脚本行为测试模式（B50/B54/B55 固化）

仓库脚本要改行为时：函数化 + `BASH_SOURCE` 守卫做成可 source 模板库 + 环境变量
注入缝，然后按 `Tests/Standalone/KeepaliveWrapperDecisionTests.swift` /
`InstallRestartHardeningTests.swift` 的方式对**生成物/真实脚本**做行为测试——
不写镜像副本。

## 背景注记（2026-09-02/03 首个完整执行样本）

`feat/sound-iteration` 线全程在独立 worktree 开发，rebase 回 main 零冲突、
门禁全绿后 fast-forward 合并。其间主工作区另一会话的在途 WIP（SoundManager.swift
重叠改动）挡住快进，按第 3 条存档 `wip/` 分支让路、待其提交后合并——整套流程
已在真实并行场景跑通，本文件即该经验的固化。
