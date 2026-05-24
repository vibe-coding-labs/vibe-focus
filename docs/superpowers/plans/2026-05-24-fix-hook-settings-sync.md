# Bug Fix: Hook 设置变更后 settings.json 不同步

**Symptom:** 用户在 UI 中切换「提交后自动恢复」/「Stop 触发」/「SessionEnd 触发」后，UserDefaults 更新了但 `~/.claude/settings.json` 中的 hooks 没有同步变更，导致功能静默失效
**Root Cause:** `SettingsView+ClaudeHookSection.swift` 中三个 toggle 的 `set` 闭包只写 UserDefaults，不调用 `installHookToClaudeSettings()` 重新同步 hooks 到 Claude settings.json
**Impact:** 任何通过 UI 切换 hook 触发时机的操作都会导致 settings.json 失效，直到用户手动点「重新安装 Hook」
**Scope:** Small
**Risk:** Low

**Risks:**
- `installHookToClaudeSettings()` 有 3 秒冷却，快速连续切换可能被 debounce → 可接受，3 秒后重试即可

---

### Task 1: 修改三个 toggle 的 set 闭包，在值变更后重新安装 hooks

**Depends on:** None
**Files:**
- Modify: `Sources/Settings/SettingsView+ClaudeHookSection.swift:117-150`

- [ ] **Step 1: 修改 triggerOnStop toggle 的 set 闭包，添加 hook 重装逻辑**

文件: `Sources/Settings/SettingsView+ClaudeHookSection.swift:117-121`（替换 triggerOnStop toggle）

```swift
Toggle("对话完成（Stop 事件，推荐）", isOn: Binding(
    get: { triggerOnStop },
    set: { newValue in
        triggerOnStop = newValue
        ClaudeHookPreferences.triggerOnStop = newValue
        if hookEnabled { hookServer.applyPreferences() }
    }
))
.toggleStyle(.checkbox)
```

- [ ] **Step 2: 修改 triggerOnSessionEnd toggle 的 set 闭包，添加 hook 重装逻辑**

文件: `Sources/Settings/SettingsView+ClaudeHookSection.swift:123-127`（替换 triggerOnSessionEnd toggle）

```swift
Toggle("会话结束（SessionEnd 事件）", isOn: Binding(
    get: { triggerOnSessionEnd },
    set: { newValue in
        triggerOnSessionEnd = newValue
        ClaudeHookPreferences.triggerOnSessionEnd = newValue
        if hookEnabled { hookServer.applyPreferences() }
    }
))
.toggleStyle(.checkbox)
```

- [ ] **Step 3: 修改 autoRestoreOnPromptSubmit toggle 的 set 闭包，添加 hook 重装逻辑**

文件: `Sources/Settings/SettingsView+ClaudeHookSection.swift:141-149`（替换 autoRestoreOnPromptSubmit toggle）

```swift
Toggle("", isOn: Binding(
    get: { autoRestoreOnPromptSubmit },
    set: { newValue in
        autoRestoreOnPromptSubmit = newValue
        ClaudeHookPreferences.autoRestoreOnPromptSubmit = newValue
        if hookEnabled { hookServer.applyPreferences() }
    }
))
.labelsHidden()
.toggleStyle(.checkbox)
```

- [ ] **Step 4: 质量门禁检查**

Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - 无编译错误

- [ ] **Step 5: 提交**

Run: `git add Sources/Settings/SettingsView+ClaudeHookSection.swift && git commit -m "fix(settings): sync hooks to settings.json when toggle preferences change"`

---

### Task 2: 部署并验证

**Depends on:** Task 1
**Files:** None

- [ ] **Step 1: 构建签名部署**

Run: `./scripts/build-sign.sh 2>&1 | tail -10`
Expected:
  - Exit code: 0
  - 输出包含 "Signed" 或 "Build succeeded"

- [ ] **Step 2: 部署到本地应用**

Run: `./scripts/deploy.sh 2>&1 | tail -10`
Expected:
  - Exit code: 0

- [ ] **Step 3: 验证 — 在 VibeFocus 设置中切换「提交后自动恢复」后检查 settings.json**

验证步骤：
1. 打开 VibeFocus 设置 → Claude Code 集成
2. 关闭「提交后自动恢复」
3. 检查 `~/.claude/settings.json` 中是否没有 `UserPromptSubmit` hook
4. 重新打开「提交后自动恢复」
5. 检查 `~/.claude/settings.json` 中是否自动添加了 `UserPromptSubmit` hook

Run: `cat ~/.claude/settings.json | python3 -c "import json,sys; d=json.load(sys.stdin); print('UserPromptSubmit' in d.get('hooks',{}))"`
Expected:
  - 输出 `True`
