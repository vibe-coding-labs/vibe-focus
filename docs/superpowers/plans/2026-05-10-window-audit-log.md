# Window Audit Log + Enhanced Logging Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 创建窗口变更审计表（最近 1 万条）+ 增强日志密度。审计表记录所有窗口状态变更（toggle、restore、session bind、space move、UserPromptSubmit），用于事后查询"某个窗口经历了什么"。日志增强在关键决策点补充更多上下文信息。

**Architecture:** 创建独立的 AuditLogger 服务（单例），所有核心路径（toggle/restore/hook/space）在关键状态变更点调用 `AuditLogger.shared.record()`。AuditLogger 直接写入 SQLite `window_audit_log` 表，自动清理超过 10,000 条的旧记录。日志增强在现有 `log()` 调用中补充字段。

**Tech Stack:** Swift 5.9, SQLite3 (C API), macOS 14+

**Risks:**
- Task 2-4 修改多个核心路径，审计调用是附加的，不改变原有逻辑 → 低风险
- 审计表高频写入可能影响 toggle/restore 延迟 → 缓解：INSERT 是单行操作，SQLite WAL 模式下 <1ms
- Task 4 日志增强会增加日志文件体积 → 缓解：日志已有 rotate 机制

---

### Task 1: 创建 AuditLogger 服务和数据库表

**Depends on:** None
**Files:**
- Create: `Sources/AuditLogger.swift`

- [ ] **Step 1: 创建 AuditLogger.swift — 审计日志记录服务**

- [ ] **Step 2: 验证编译通过**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 3: 提交**
Run: `git add Sources/AuditLogger.swift && git commit -m "feat(audit): add AuditLogger service with window_audit_log SQLite table"`

---

### Task 2: 在 Toggle/Restore 路径添加审计记录

**Depends on:** Task 1
**Files:**
- Modify: `Sources/WindowManager+Toggle.swift`
- Modify: `Sources/WindowManager+Restore.swift`

- [ ] **Step 1: 修改 toggle() — 在 toggle 完成后添加审计记录**

- [ ] **Step 2: 修改 moveToMainScreen() — 在窗口移动到主屏幕后添加审计记录**

- [ ] **Step 3: 修改 restore() — 在 restore 成功和失败路径添加审计记录**

- [ ] **Step 4: 验证编译通过**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 5: 提交**
Run: `git add Sources/WindowManager+Toggle.swift Sources/WindowManager+Restore.swift && git commit -m "feat(audit): add audit records to toggle and restore paths"`

---

### Task 3: 在 Hook/Space 路径添加审计记录

**Depends on:** Task 1
**Files:**
- Modify: `Sources/HookEventHandler.swift`
- Modify: `Sources/SpaceController+Move.swift`

- [ ] **Step 1: 修改 handleSessionStart() — 在 session 绑定成功后添加审计记录**

- [ ] **Step 2: 修改 handleUserPromptSubmit() — 在各决策分支添加审计记录**

- [ ] **Step 3: 修改 moveWindow() — 在 space 移动结果添加审计记录**

- [ ] **Step 4: 验证编译通过**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 5: 提交**
Run: `git add Sources/HookEventHandler.swift Sources/SpaceController+Move.swift && git commit -m "feat(audit): add audit records to hook event handler and space move paths"`

---

### Task 4: 增强关键决策点的日志密度

**Depends on:** None
**Files:**
- Modify: `Sources/WindowManager+Toggle.swift`
- Modify: `Sources/HookEventHandler.swift`
- Modify: `Sources/WindowManager+Restore.swift`

- [ ] **Step 1: 增强 toggle() 决策日志**

- [ ] **Step 2: 增强 handleUserPromptSubmit() 解析日志**

- [ ] **Step 3: 增强 restore() 步骤日志**

- [ ] **Step 4: 验证编译通过**
Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus && swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete"

- [ ] **Step 5: 提交**
Run: `git add Sources/WindowManager+Toggle.swift Sources/HookEventHandler.swift Sources/WindowManager+Restore.swift && git commit -m "feat(logging): enhance log density at key decision points in toggle, restore, and hook paths"`
