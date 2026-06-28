# Refactor: 彻底移除 ScreenOverlayManager.init() 启动期 preference 写入

**Goal:** 删除 init() 里的 preference save 路径（当前是 guarded backfill），让 init() 只读不写，根治 bottomRight→topRight 反复覆盖几十次的回归。

**Before/After:**
- Before: `init()` 里 `if loadPreference(key:) == nil { preferences.save() }` —— 仍是启动期写路径，残留"覆盖"心智负担，且历史证明这段区域是反复引入 bug 的温床（无条件 save → guarded backfill 都出过事）。
- After: `init()` 只保留 `self.preferences = ScreenIndexPreferences.load()` + setup。持久化完全由 `didSet → schedulePreferenceSave → save()` 在用户实际修改时驱动。

**Safety Net:** `Tests/XCTest/ScreenIndexPreferencePersistenceTests.swift`（14 个测试，针对 `WindowStateStore.savePreference/loadPreference` + `ScreenIndexPreferences` Codable，全部用 `:memory:` db，**不依赖** `ScreenOverlayManager.init()`）。

**Scope:** Tiny（单源文件删 ~15 行 + 1 测试注释更新）
**Risk:** Low
**Risks:**
- 首次全新安装时 SQLite 暂无 `screenIndexPreferences` key（直到首次用户改动触发 didSet）→ 缓解：默认值正确生效（load() 返回 `.default`），CF/UD 在首次 save 时同步写入；现有用户（SQLite 已有值）零影响。
- `loadPreference` 是否变 dead code → 不会，`ScreenIndexPreferences.loadFromSQLite()` 仍用它（主 load 路径）。

**Autonomy Level:** Full

---

### Task 1: 移除 init() preference 写入 + 更新过时测试注释

**Depends on:** None
**Files:**
- Modify: `Sources/Overlay/ScreenOverlayManager.swift:45-67`（删除 guarded backfill 块）
- Modify: `Tests/XCTest/ScreenIndexPreferencePersistenceTests.swift:4,176`（更新引用已删除行为的注释）

- [ ] **Step 1: 修改 ScreenOverlayManager.init() — 删除启动期 save，只读不写**
文件: `Sources/Overlay/ScreenOverlayManager.swift:45-67`（替换整个 init()）

```swift
    private init() {
        self.preferences = ScreenIndexPreferences.load()
        // init() 只读不写：持久化完全由 didSet → save() 在用户实际修改时驱动。
        // 历史上这里曾有启动期 save()（无条件 → guarded backfill），在 SQLite 瞬时
        // 读取失败时会用 load() 的 fallback 陈旧默认覆盖 SQLite 真实配置
        // （bottomRight→topRight 反复几十次）。彻底移除启动期写路径，根除此类回归。
        log("ScreenOverlayManager initialized, isEnabled=\(preferences.isEnabled)")
        setupSignalHandler()
        registerYabaiSignals()
        startRefreshTimer()
    }
```

- [ ] **Step 2: 更新过时测试注释 — 移除对 init() save 行为的引用**
文件: `Tests/XCTest/ScreenIndexPreferencePersistenceTests.swift:4`（文件头注释）

```swift
// Tests/XCTest/ScreenIndexPreferencePersistenceTests.swift
// Regression tests for: config lost after reinstall (3 bugs fixed)
// Bug 1: UserDefaults String/Data mismatch — save() writes String, load() used .data(forKey:)
// Bug 2: init() didSet doesn't fire — historical fix once added init() save(), later REMOVED
//        because it overwrote real config on transient SQLite read miss (bottomRight→topRight).
//        Persistence is now driven solely by didSet → save(). These tests cover the
//        WindowStateStore + Codable layer, decoupled from ScreenOverlayManager.init().
// Bug 3: Bundle ID mismatch between install scripts — CFPreferences lost
// Run: swift test --filter ScreenIndexPreferencePersistenceTests
```

文件: `Tests/XCTest/ScreenIndexPreferencePersistenceTests.swift:176`（Step 3 注释）

```swift
        // Step 3: Persist the fallback value to SQLite (legacy-migration path still does this;
        //         init() no longer saves — see ScreenOverlayManager.init comment)
```

- [ ] **Step 3: 验证 — release 编译**
Run: `swift build -c release 2>&1 | tail -5`
Expected:
  - Exit code: 0
  - Output contains: "Build complete!"

- [ ] **Step 4: 验证 — 持久化测试 + 全量回归**
Run: `swift test 2>&1 | tail -15`
Expected:
  - Exit code: 0
  - Output contains: "Test Suite passed" 或 passed 计数
  - Output does NOT contain: "failed"

- [ ] **Step 5: 质量门禁 — 部署 + 运行时验证**
Run: `bash scripts/dev-build.sh && open /Applications/VibeFocus.app`
Expected:
  - 签名验证通过
  - 启动后 `sqlite3 ~/.vibefocus/vibefocus.db "SELECT json_extract(value,'$.position') FROM preferences WHERE key='screenIndexPreferences';"` 输出 `bottomRight`（证明 init() 不再触发任何写，已存的 bottomRight 保持）
  - 日志含 `ScreenOverlayManager initialized`，**无** `first-run backfill`（启动期写路径已彻底移除）

- [ ] **Step 6: 提交**
Run: `git add Sources/Overlay/ScreenOverlayManager.swift Tests/XCTest/ScreenIndexPreferencePersistenceTests.swift && git commit -m "refactor(prefs): remove startup-time preference save from init() entirely"`
