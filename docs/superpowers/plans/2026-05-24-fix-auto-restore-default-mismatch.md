# Bug Fix: autoRestoreOnPromptSubmit 默认值不一致导致每次重启被重置为 false

**Symptom:** 用户开启「提交后自动恢复」后，app 重启该设置自动变回关闭状态，settings.json 中的 UserPromptSubmit hook 被移除
**Root Cause:** 三处默认值互相冲突：SettingsUI.swift @AppStorage 默认 `true`，ClaudeHookPreferences getter 默认 `false`，PreferencesSync registry 默认 `false`。重启时 PreferencesSync 将 `false` 写入 UserDefaults → hook 被移除
**Impact:** 所有依赖 autoRestoreOnPromptSubmit 的用户在 app 重启后功能失效
**Scope:** Tiny
**Risk:** Low

**Risks:**
- 修改默认值可能影响从未手动设置过的用户 → 已排除：默认 true 符合用户预期（UI 就显示为开启）

---

### Task 1: 统一 autoRestoreOnPromptSubmit 默认值为 true

**Depends on:** None
**Files:**
- Modify: `Sources/Support/PreferencesSync.swift:24`
- Modify: `Sources/Hook/ClaudeHookPreferences.swift:127`

- [ ] **Step 1: 修改 PreferencesSync preferenceRegistry 默认值**

文件: `Sources/Support/PreferencesSync.swift:24`（将 `false` 改为 `true`）

```swift
// 替换 Sources/Support/PreferencesSync.swift 第 24 行
        ClaudeHookPreferences.autoRestoreOnPromptSubmitKey: true,
```

- [ ] **Step 2: 修改 ClaudeHookPreferences getter 默认值**

文件: `Sources/Hook/ClaudeHookPreferences.swift:127`（将 `?? false` 改为 `?? true`）

```swift
// 替换 Sources/Hook/ClaudeHookPreferences.swift 第 127 行
        get { UserDefaults.standard.object(forKey: autoRestoreOnPromptSubmitKey) as? Bool ?? true }
```

- [ ] **Step 3: 质量门禁检查**

Run: `swift build 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - 无编译错误

- [ ] **Step 4: 提交**

Run: `git add Sources/Support/PreferencesSync.swift Sources/Hook/ClaudeHookPreferences.swift && git commit -m "fix(hook): unify autoRestoreOnPromptSubmit default to true across PreferencesSync and ClaudeHookPreferences"`

---

### Task 2: 部署并修复当前状态

**Depends on:** Task 1
**Files:** None

- [ ] **Step 1: 修复当前 UserDefaults 值**

Run: `defaults write com.vibefocus.app claudeHookAutoRestoreOnPromptSubmit -bool true`
Expected:
  - Exit code: 0

- [ ] **Step 2: 构建签名部署**

Run: `./scripts/dev-build.sh 2>&1 | tail -10`
Expected:
  - Exit code: 0

- [ ] **Step 3: 部署到本地应用**

Run: `killall VibeFocus 2>/dev/null; sleep 1; open /Applications/VibeFocus.app`
Expected:
  - VibeFocus 重启

- [ ] **Step 4: 验证 — 确认 UserPromptSubmit hook 已写入 settings.json**

Run: `cat ~/.claude/settings.json | python3 -c "import json,sys; d=json.load(sys.stdin); hooks=d.get('hooks',{}); print('UserPromptSubmit' in hooks)"`
Expected:
  - Output: `True`

- [ ] **Step 5: 验证 — 确认 UserDefaults 值为 true**

Run: `defaults read com.vibefocus.app claudeHookAutoRestoreOnPromptSubmit`
Expected:
  - Output: `1`

- [ ] **Step 6: 验证 — 日志确认 autoRestoreEnabled=true**

Run: `tail -200 ~/Library/Logs/VibeFocus/vibefocus.log | grep -i "autoRestoreEnabled"`
Expected:
  - 日志中出现 `autoRestoreEnabled=true`
