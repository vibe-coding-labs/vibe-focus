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

## 背景注记（2026-09-02/03 首个完整执行样本）

`feat/sound-iteration` 线全程在独立 worktree 开发，rebase 回 main 零冲突、
门禁全绿后 fast-forward 合并。其间主工作区另一会话的在途 WIP（SoundManager.swift
重叠改动）挡住快进，按第 3 条存档 `wip/` 分支让路、待其提交后合并——整套流程
已在真实并行场景跑通，本文件即该经验的固化。
