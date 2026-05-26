# Bug 模式：yabai Float 状态跨 Space 不持久化

## Bug 表现
窗口 restore 到原始位置后，yabai 立即把它 tile（平铺）到错误位置。
或者窗口在跨 Space 移动后丢失 float 状态，被 yabai 自动管理。

## 根因分析

### yabai 的 float 状态作用域

yabai 的 `window --toggle float` 设置的 float 状态**只对当前 Space 有效**。
当窗口被 `window --space <N>` 移动到另一个 Space 时：

1. 窗口从源 Space 移除 → 源 Space 的 float 状态被清除
2. 窗口到达目标 Space → 目标 Space 上窗口默认是 **managed（被管理）**
3. yabai 会在目标 Space 上重新 tile 这个窗口

这意味着 restore 流程的步骤顺序至关重要：

```
✅ 正确顺序:
1. yabai window --space <original_space>  → 移动窗口到原始 Space
2. yabai window --toggle float            → 在目标 Space 设为 float
3. AX setFrame                            → 设置原始位置和大小

❌ 错误顺序:
1. yabai window --toggle float            → 在当前 Space 设 float
2. yabai window --space <original_space>  → 移走，float 状态丢失
3. AX setFrame                            → 位置被 yabai tiling 覆盖

❌ 另一个错误:
1. yabai window --space <original_space>  → 移动到目标 Space
2. AX setFrame                            → 设了位置，但 yabai 马上 tile 掉
3. (忘了 set float)                       → 窗口位置被 tiling 覆盖
```

### 当前代码中的处理

`ToggleEngine+Restore.swift` 的执行顺序：
1. `sc.moveWindow()` → yabai space move
2. `sc.setWindowFloat()` → yabai toggle float
3. `wm.apply(frame:)` → AX 设位置

这是正确的顺序。但修改时必须保持这个顺序。

## 防范规则

1. **Space 移动必须先于 float 设置**
   - 先 float 再 move 会导致 float 状态丢失
   - 必须在目标 Space 上设 float

2. **AX setFrame 必须在 float 之后**
   - yabai tiling 会覆盖 AX 设置的位置
   - 必须 float → AX setFrame

3. **不要依赖 AX setFrame 的"隐式 float"**
   - 某些 WM 在 AX 设位置时会自动 float
   - yabai 不会 — 它会忽略未经 float 的 AX 位置变更

4. **修改 restore 逻辑时检查步骤顺序**
   - 任何步骤重排都可能引入此 bug
   - 参见 `ToggleEngine+Restore.swift` 注释

## 快速排查

当"restore 后窗口位置不对（被 tile 了）"时：

```bash
# 检查 yabai 是否在管理这个窗口
yabai -m query --windows | python3 -c "
import sys, json
for w in json.load(sys.stdin):
    if not w.get('floating', False):
        print(f'MANAGED: id={w[\"id\"]} app={w[\"app\"]} space={w[\"space\"]}')
    else:
        print(f'FLOAT:   id={w[\"id\"]} app={w[\"app\"]} space={w[\"space\"]}')
"

# 检查日志中 float 和 space move 的顺序
grep "setWindowFloat\|space.*move\|restore:" ~/Library/Logs/VibeFocus/vibefocus.log | tail -10
```
