# 测试屏幕索引和工作区索引显示 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 验证屏幕索引和工作区索引在各种场景下正确显示

**Architecture:** 通过手动测试覆盖单显示器、多显示器、不同工作区切换等场景

**Tech Stack:** Swift, macOS, yabai

---

## 测试场景

### Task 1: 测试单显示器屏幕索引

**Files:**
- Test: 手动测试

- [ ] **Step 1: 启动应用**

Run: `./scripts/dev-run.sh`
Expected: 应用启动，屏幕上显示 "1"

- [ ] **Step 2: 验证索引显示位置**

观察屏幕索引面板是否显示在设置的 6 个位置之一（默认右上角）
Expected: 面板显示 "1"，位置正确

- [ ] **Step 3: 切换显示位置测试**

在设置中依次切换：左上角、正上方、右上角、左下角、正下方、右下角
Expected: 面板位置随设置变化正确移动

---

### Task 2: 测试多显示器屏幕索引

**Files:**
- Test: 手动测试（需要外接显示器）

- [ ] **Step 1: 连接外接显示器**

连接第二台显示器
Expected: 主屏显示 "1"，外接屏显示 "2"

- [ ] **Step 2: 验证每个屏幕独立显示**

确认每个屏幕只显示自己的索引，不显示其他屏幕的索引
Expected: 屏幕1只显示 "1"，屏幕2只显示 "2"

- [ ] **Step 3: 断开外接显示器**

断开第二台显示器
Expected: 只剩主屏显示 "1"，没有残留的 "2" 面板

---

### Task 3: 测试工作区索引（需要 yabai）

**Files:**
- Test: 手动测试

- [ ] **Step 1: 确认 yabai 运行**

Run: `yabai -m query --spaces`
Expected: 返回空间列表，命令成功

- [ ] **Step 2: 验证工作区索引显示**

观察当前屏幕，格式应为 "1-1"（屏幕1-工作区1）
Expected: 显示 "1-1" 或 "1-2" 等正确格式

- [ ] **Step 3: 切换工作区**

使用快捷键切换到工作区 2
Expected: 屏幕索引从 "1-1" 变为 "1-2"

- [ ] **Step 4: 三指滑动切换工作区**

使用触控板三指滑动切换工作区
Expected: 索引实时更新，无明显延迟

- [ ] **Step 5: 多显示器工作区测试**

在外接显示器上切换工作区
Expected: 只有该显示器的索引变化，主屏索引保持不变

---

### Task 4: 测试外观设置实时更新

**Files:**
- Test: 手动测试

- [ ] **Step 1: 修改透明度**

在设置中拖动透明度滑块
Expected: 面板背景透明度实时变化，无窗口重建闪烁

- [ ] **Step 2: 修改面板大小**

拖动面板大小滑块
Expected: 面板大小实时缩放，无窗口重建闪烁

- [ ] **Step 3: 修改颜色**

修改文字颜色和背景颜色
Expected: 面板颜色实时变化，无窗口重建闪烁

- [ ] **Step 4: 修改字体大小**

拖动字体大小滑块
Expected: 文字大小实时变化，面板尺寸自动调整

---

### Task 5: 测试开关功能

**Files:**
- Test: 手动测试

- [ ] **Step 1: 关闭屏幕索引**

在设置中取消勾选 "显示屏幕索引"
Expected: 所有屏幕上的索引面板立即消失

- [ ] **Step 2: 重新开启屏幕索引**

勾选 "显示屏幕索引"
Expected: 面板重新出现，显示正确的索引

---

### Task 6: 提交测试报告

**Files:**
- Test: 手动验证

- [ ] **Step 1: 记录测试结果**

所有测试通过：
- [ ] 单显示器屏幕索引 ✓
- [ ] 多显示器屏幕索引 ✓
- [ ] 工作区索引 ✓
- [ ] 外观设置实时更新 ✓
- [ ] 开关功能 ✓

- [ ] **Step 2: 如有问题修复**

根据测试结果修复发现的问题

---

## 依赖关系

Tasks 1-5 可以并行执行，Task 6 依赖前面所有任务完成。
