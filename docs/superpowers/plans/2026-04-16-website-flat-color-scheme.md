# Website Flat Color Scheme Refinement Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development`
> Steps use checkbox (`- [ ]`) syntax.

**Goal:** 将官网配色全面转为扁平化风格 — 将描边/轮廓式组件改为填充色背景，统一所有 accent 色值为 CSS 变量，移除 dark-theme 残留的重复 CSS 块和 glow 效果，使整体视觉更干净、更大胆、更扁平。

**Architecture:** 修改 `styles.css` 的 `:root` 色值变量（accent 从 sky-600 升级到 blue-500，新增 `--color-accent-bg` 填充色），然后将所有 outlined 组件（hero-tag、icon-wrapper、ant-tag、header anchor）转为填充色背景，删除 hook-workflow 中的 box-shadow glow，清理 dark-theme 残留重复块。

**Tech Stack:** React 18, TypeScript 5, Ant Design 5, Vite 6, CSS Custom Properties

**Risks:**
- 删除 dark-theme 残留重复块时可能遗漏 `.demo-placeholder` 等仅出现一次的样式 → 缓解：精确标注保留范围
- accent 色值变亮后，部分低对比度文字可能不够清晰 → 缓解：使用 `--color-accent-dark` 作为文字色

---

### Task 1: Update CSS Color Scheme for Flat Design

**Depends on:** None
**Files:**
- Modify: `website/src/styles.css:1-10` (CSS variables)
- Modify: `website/src/styles.css:119-143` (header anchor + github-link hover)
- Modify: `website/src/styles.css:170-181` (hero-tag)
- Modify: `website/src/styles.css:425-436` (feature-icon-wrapper)
- Modify: `website/src/styles.css:462-474` (scene-icon-wrapper)
- Modify: `website/src/styles.css:482-532` (dark-theme duplicate block - delete)
- Modify: `website/src/styles.css:712-727` (ant-tag styles)
- Modify: `website/src/styles.css:1149-1268` (hook-workflow animation)

- [ ] **Step 1: Update :root CSS variables — 更亮更饱和的 flat 色板 + 新增 accent-bg 填充色**

文件: `website/src/styles.css:1-10`

```css
:root {
  --color-bg: #ffffff;
  --color-bg-light: #eff6ff;
  --color-text: #0f172a;
  --color-text-muted: #64748b;
  --color-accent: #3b82f6;
  --color-accent-dark: #2563eb;
  --color-border: #e2e8f0;
  --color-card: #f8fafc;
  --color-accent-bg: #dbeafe;
}
```

变更说明：
- `--color-accent`: `#0284c7` (sky-600) → `#3b82f6` (blue-500) — 更亮更饱和的扁平蓝
- `--color-accent-dark`: `#0369a1` (sky-700) → `#2563eb` (blue-600) — 匹配的深色
- `--color-bg-light`: `#f8fafc` (slate-50) → `#eff6ff` (blue-50) — 更明显的蓝色调区域背景
- 新增 `--color-accent-bg`: `#dbeafe` (blue-100) — 统一的扁平填充背景色

- [ ] **Step 2: Convert hero-tag to filled accent background — 扁平化标签**

文件: `website/src/styles.css:170-181`

```css
.hero-tag {
  display: inline-flex;
  align-items: center;
  padding: 6px 14px;
  font-size: 13px;
  font-weight: 500;
  background: var(--color-accent);
  border: none;
  color: #ffffff;
  border-radius: 6px;
  margin-bottom: 4px;
}
```

变更：`background: transparent; border: 1px solid` → `background: var(--color-accent); border: none; color: #ffffff;` — 从描边标签变为填充扁平标签。

- [ ] **Step 3: Convert feature-icon-wrapper and scene-icon-wrapper to filled flat backgrounds**

文件: `website/src/styles.css:425-436` (feature-icon-wrapper)

```css
.feature-icon-wrapper {
  width: 44px;
  height: 44px;
  border-radius: 8px;
  background: var(--color-accent-bg);
  border: none;
  display: flex;
  align-items: center;
  justify-content: center;
  color: var(--color-accent-dark);
  font-size: 20px;
  flex-shrink: 0;
}
```

文件: `website/src/styles.css:462-474` (scene-icon-wrapper)

```css
.scene-icon-wrapper {
  width: 40px;
  height: 40px;
  border-radius: 8px;
  background: var(--color-accent-bg);
  border: none;
  display: flex;
  align-items: center;
  justify-content: center;
  color: var(--color-accent-dark);
  font-size: 18px;
  flex-shrink: 0;
}
```

变更：`background: transparent; border: 1px solid var(--color-accent)` → `background: var(--color-accent-bg); border: none; color: var(--color-accent-dark)` — 从描边圆框变为浅蓝填充方块，扁平化核心改动。

- [ ] **Step 4: Update ant-tag styles to filled flat backgrounds**

文件: `website/src/styles.css:712-727`

```css
/* Tag styles */
.ant-tag {
  border-radius: 4px;
}

.ant-tag-cyan {
  background: var(--color-accent-bg);
  border-color: transparent;
  color: var(--color-accent-dark);
}

.ant-tag-blue {
  background: var(--color-accent-bg);
  border-color: transparent;
  color: var(--color-accent-dark);
}
```

变更：`background: transparent; border-color: var(--color-accent)` → `background: var(--color-accent-bg); border-color: transparent` — 所有标签从描边改为填充。

- [ ] **Step 5: Fix header anchor active state and github-link hover to use --color-accent-bg**

文件: `website/src/styles.css:121-124` (header anchor active)

```css
.header-anchor .ant-anchor-link-active > .ant-anchor-link-title {
  color: var(--color-accent-dark) !important;
  background: var(--color-accent-bg);
}
```

文件: `website/src/styles.css:140-143` (github-link hover)

```css
.github-link:hover {
  color: var(--color-accent-dark);
  background: var(--color-accent-bg);
}
```

变更：`rgba(2, 132, 199, 0.08)` 硬编码 → `var(--color-accent-bg)` 统一变量。Active 文字色用 `--color-accent-dark` 提高可读性。

- [ ] **Step 6: Remove dark-theme duplicate CSS blocks — 清理 lines 482-532**

删除 `website/src/styles.css` 中第 482-532 行之间的以下重复定义（这些是 dark-theme 残留，颜色如 `#e8f3ff`、`rgba(216, 238, 255, 0.85)` 都不适用于浅色主题）：

需要删除的规则（从第二个 `/* Demo Card Enhanced Styling */` 注释开始）：
- `.demo-media-shell` 第一定义（lines 482-490）
- `.demo-card` 第一定义（lines 493-498）
- `.demo-card:hover` 第一定义（lines 500-503）
- `.demo-card .ant-card-body` 第一定义（lines 505-507）
- `.demo-card h4` 第一定义含 `color: #e8f3ff`（lines 509-515）
- `.demo-card .ant-typography` 第一定义含 `rgba(216, 238, 255, 0.85)`（lines 516-520）
- `.demo-card .ant-tag` 第一定义（lines 522-525）
- `.demo-media` 第一定义（lines 527-532）

**保留** `.demo-placeholder` 区块（lines 534-560），因为该区块无重复定义且使用 CSS 变量无 dark-theme 残留。

**保留**第二组定义（lines 563+），它们已使用 `var(--color-text)` 等正确变量。

- [ ] **Step 7: Fix hook-workflow animation — 移除 glow 效果，统一使用 CSS 变量**

文件: `website/src/styles.css` hook-workflow 区块

替换 `.hook-workflow-step.active`（约 line 1175-1181）：

```css
.hook-workflow-step.active {
  opacity: 1;
  transform: scale(1);
  background: var(--color-card);
  border: 1px solid var(--color-accent);
  box-shadow: none;
}
```

替换 `.hook-workflow-step.active .hook-workflow-step-number`（约 line 1199-1204）：

```css
.hook-workflow-step.active .hook-workflow-step-number {
  border-color: var(--color-accent);
  color: var(--color-accent-dark);
  background: var(--color-accent-bg);
  box-shadow: none;
}
```

变更：
- `box-shadow: 0 0 24px rgba(...)` → `box-shadow: none` — 移除 glow，扁平化核心
- `background: rgba(56, 189, 248, 0.1)` → `background: var(--color-accent-bg)` — 统一变量
- `box-shadow: 0 0 12px rgba(56, 189, 248, 0.15)` → `box-shadow: none` — 移除 glow
- `color: var(--color-accent)` → `color: var(--color-accent-dark)` — 深色文字更易读

- [ ] **Step 8: Commit**

Run: `git add website/src/styles.css && git commit -m "style(website): convert color scheme to flat design with filled backgrounds"`

---

### Task 2: Build and Verify

**Depends on:** Task 1
**Files:**
- Modify: `website/dist/` (build output)

- [ ] **Step 1: Build the website**

Run: `cd /Users/cc11001100/github/vibe-coding-labs/vibe-focus/website && npm run build`

Expected:
  - Exit code: 0
  - Output contains: "built in"
  - Output does NOT contain: "error" or "Error"

- [ ] **Step 2: Verify build output exists**

Run: `ls -la /Users/cc11001100/github/vibe-coding-labs/vibe-focus/website/dist/`

Expected:
  - Directory contains: `index.html`, `assets/`
  - `assets/` contains `.js` and `.css` files

- [ ] **Step 3: Commit build output**

Run: `git add website/dist/ && git commit -m "build(website): rebuild with flat color scheme"`
