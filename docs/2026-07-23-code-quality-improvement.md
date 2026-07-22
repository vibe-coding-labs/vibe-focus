# VibeFocus 代码质量提升计划

> **创建时间:** 2026-07-23
> **目标:** 系统性提升代码质量，优化代码结构，增强可维护性

---

## 一、代码库现状分析

### 1.1 规模统计

| 指标 | 数值 |
|-----|------|
| **总代码行数** | 17,789 行 |
| **Swift 文件数** | 96 个 |
| **类型定义** | 99 个 (class/struct/enum/protocol) |
| **函数数量** | ~395 个 |
| **Extension 数量** | 58 个 |
| **测试代码行数** | 17,677 行 (测试/代码比 ≈ 1:1) |

### 1.2 模块分布

| 模块 | 代码行数 | 占比 |
|-----|---------|------|
| **Window** | 3,492 行 | 19.6% |
| **Hook** | 3,235 行 | 18.2% |
| **Settings** | 2,608 行 | 14.7% |
| **Space** | 2,269 行 | 12.8% |
| **Overlay** | 1,695 行 | 9.5% |
| **Support** | 1,685 行 | 9.5% |
| **App** | 1,020 行 | 5.7% |
| **HotKey** | 861 行 | 4.8% |
| **TitleEditor** | 520 行 | 2.9% |
| **Toggle** | 390 行 | 2.2% |

### 1.3 优点 ✅

1. **测试覆盖充分** - 测试代码与生产代码比例接近 1:1，包含 31 个 Standalone 测试 + 100+ XCTest 用例
2. **无明显的危险代码** - 无 `try!`、`as!` 强制转换，无 `!.` 强制解包
3. **无技术债标记** - 无 TODO/FIXME/HACK/XXX 注释
4. **良好的埋点体系** - 315 个 P-INST 性能埋点
5. **合理的模块划分** - 按职责分为 Window/Hook/Space/Overlay 等 11 个模块
6. **Extension 使用得当** - 58 个 extension 用于代码组织

### 1.4 问题点 ❌

#### 问题 1: 访问控制不足

```
统计:
- private/fileprivate 使用: 163 处
- public/internal 使用: 12 处
- 大量属性和方法缺少显式访问修饰符
```

**风险:** 内部实现可能被意外访问，破坏封装性

#### 问题 2: 单例过度使用

```
统计: 197 处 .shared 或 static let shared
```

**风险:** 
- 状态共享导致测试困难
- 隐式依赖难以追踪
- 并发安全隐患

#### 问题 3: 类缺少 final 修饰

```
未标记 final 的类:
- WindowManager
- ScreenOverlayManager  
- OverlayWindow
- TitleEditorService
- AppDelegate (public，可接受)
```

**风险:** 意外的类继承，性能损失

#### 问题 4: 大型文件

```
超过 300 行的文件:
- ScreenOverlayManager+SpaceIndex.swift: 537 行, 13 函数
- WindowManager+MoveWindow.swift: 383 行
- WindowManager+Toggle.swift: 469 行
- WindowManager+AXHelpers.swift: 322 行
- NativeSpaceBridge.swift: 307 行
```

**风险:** 职责过多，理解困难

#### 问题 5: Extension 文件过多

```
WindowManager 的 Extension: 11 个文件
SpaceController 的 Extension: 7 个文件
HookEventHandler 的 Extension: 6 个文件
```

**现状:** 用于代码组织是合理的，但可能导致文件碎片化

#### 问题 6: @MainActor 过度使用

```
统计: 71 处 @MainActor
```

**风险:** 可能不必要地限制并发执行

---

## 二、代码质量提升计划

### Phase 1: 访问控制强化 (Priority: High, Effort: Low)

**目标:** 为所有属性和方法添加适当的访问控制修饰符

**步骤:**
1. 使用 SwiftLint 规则 `explicit_acl` 检查
2. 为内部实现添加 `private`
3. 为跨模块接口显式标记 `public` 或 `internal`
4. 审查 `ObservableObject` 的 `@Published` 属性访问级别

**预期成果:**
- 更好的封装性
- 更清晰的 API 边界
- 防止意外访问内部实现

---

### Phase 2: 类标记为 final (Priority: Medium, Effort: Low)

**目标:** 为所有不应被继承的类添加 `final` 修饰符

**步骤:**
1. 识别所有非 final 类
2. 评估是否需要继承
3. 添加 `final` 修饰符
4. 运行测试确认无副作用

**预期成果:**
- 编译器优化机会
- 防止意外继承
- 更明确的设计意图

---

### Phase 3: 单例重构 (Priority: High, Effort: High)

**目标:** 减少单例使用，改用依赖注入

**策略:**
1. **识别可替换的单例**
   - WindowManager.shared → 考虑协议抽象
   - SpaceController.shared → 考虑协议抽象
   - HotKeyManager.shared → 保持（全局热键状态）

2. **渐进式重构**
   - 先定义协议接口
   - 通过参数传递替代 .shared 调用
   - 保留单例作为默认实现

3. **保留必要单例**
   - AppDelegate（系统要求）
   - 全局状态管理器（如果确需）

**预期成果:**
- 更好的测试性
- 更清晰的依赖关系
- 更灵活的并发控制

---

### Phase 4: 大文件拆分 (Priority: Medium, Effort: Medium)

**目标:** 将超过 300 行的文件拆分为更小的单元

**重点文件:**
1. `ScreenOverlayManager+SpaceIndex.swift` (537 行)
   - 提取 `SpaceIndexResolver` 为独立模块
   - 提取缓存逻辑为 `SpaceIndexCache`

2. `WindowManager+Toggle.swift` (469 行)
   - 当前已拆分出 Decision.swift，可继续拆分
   - 提取 Restore 逻辑为独立模块

3. `WindowManager+MoveWindow.swift` (383 行)
   - 提取 yabai 调用为 `YabaiWindowMover`
   - 提取 AX 调用为 `AXWindowMover`

**预期成果:**
- 单文件行数控制在 300 行以内
- 单一职责原则更好遵守
- 代码更易理解和维护

---

### Phase 5: 命名规范统一 (Priority: Low, Effort: Low)

**目标:** 统一命名风格

**检查项:**
1. 变量命名: camelCase ✓
2. 常量命名: camelCase 或 UPPER_CASE（静态常量）
3. 函数命名: 动词开头
4. 类型命名: PascalCase ✓
5. 文件命名: 与主类型匹配

**预期成果:**
- 更一致的代码风格
- 更好的可读性

---

### Phase 6: 文档完善 (Priority: Medium, Effort: Medium)

**目标:** 为公开 API 添加文档注释

**步骤:**
1. 为 `public` 和 `internal` 函数添加 `///` 文档
2. 为复杂算法添加实现说明
3. 为非显而易见的设计决策添加 `// rationale:` 注释

**预期成果:**
- 新开发者更快上手
- API 使用更清晰

---

### Phase 7: 性能埋点审计 (Priority: Low, Effort: Low)

**目标:** 清理不必要的性能埋点

**现状:** 315 个 P-INST 埋点

**步骤:**
1. 分析埋点触发频率
2. 移除已稳定的性能监控点
3. 保留关键路径埋点

**预期成果:**
- 减少日志噪音
- 保留关键性能数据

---

## 三、实施优先级

| Phase | 优先级 | 工作量 | 影响范围 | 建议时间 |
|-------|--------|--------|----------|----------|
| Phase 1: 访问控制 | 🔴 High | 🟢 Low | 小 | 1-2 天 |
| Phase 2: final 标记 | 🟡 Medium | 🟢 Low | 小 | 0.5 天 |
| Phase 3: 单例重构 | 🔴 High | 🔴 High | 大 | 3-5 天 |
| Phase 4: 大文件拆分 | 🟡 Medium | 🟡 Medium | 中 | 2-3 天 |
| Phase 5: 命名规范 | 🟢 Low | 🟢 Low | 小 | 1 天 |
| Phase 6: 文档完善 | 🟡 Medium | 🟡 Medium | 中 | 2-3 天 |
| Phase 7: 埋点审计 | 🟢 Low | 🟢 Low | 小 | 1 天 |

---

## 四、建议的执行顺序

```
Week 1: Phase 1 + Phase 2 (基础加固)
    ↓
Week 2: Phase 4 (文件拆分)
    ↓
Week 3-4: Phase 3 (单例重构，可选)
    ↓
Week 5: Phase 5 + Phase 6 + Phase 7 (收尾)
```

---

## 五、风险与缓解

| 风险 | 缓解措施 |
|-----|---------|
| 重构引入 bug | 每次修改后运行完整测试套件 |
| 单例重构影响现有功能 | 渐进式重构，保留兼容层 |
| 访问控制修改影响测试 | 仅限制生产代码，测试代码使用 @testable |

---

## 六、成功指标

- [ ] 所有内部属性标记 `private`
- [ ] 所有非继承类标记 `final`
- [ ] 单文件行数 < 300
- [ ] 公开 API 100% 文档覆盖
- [ ] 测试通过率 100%
- [ ] 无编译警告

---

## 七、附录：当前代码亮点

值得保持的优秀实践：

1. **Extension 组织** - 使用 `+Xxx.swift` 命名清晰
2. **MARK 注释** - 155 处 `// MARK:` 用于代码分区
3. **性能埋点** - 完善的 P-INST 体系
4. **测试覆盖** - 充分的单元测试和集成测试
5. **错误处理** - 无强制解包，使用安全解包
6. **日志体系** - 结构化日志 + 字段字典

---

*本计划将根据实际执行情况动态调整*
