import CoreGraphics

// WorkAreaLearning.swift
// VibeFocus — 屏幕工作区保留区学习的决策内核（纯函数）
//
// 编排侧（TerminalGridController.createGrid）只负责回读与持久化，分支口径集中在此：
//   1. 回读格子实际落点 → inferInsets 反推四边钳制；学到非零 → merged 后学习；
//   2. 本轮没学到（格子全贴规划边缘）且已有非零学习值 → 应做探测写验证能否缩回
//      （菜单栏改自动隐藏等设置变化后自愈）；
//   3. 只有 insets 相对输入变化才需要按新可用区整体重排。
// 这些布尔组合此前内联在 createGrid 的嵌套 if 里，真机学习出错时难以单测定位。

enum WorkAreaLearning {

    /// 一轮学习的决策结果。
    struct Decision: Equatable {
        /// 学习后的保留区（observed 非零时已 merged 进 learned）
        let insets: WorkAreaInsets
        /// 本轮是否学到非零保留区（调用方据此持久化并记日志）
        let learnedNonzero: Bool
        /// 是否应做探测写：本轮没学到 + 已有非零学习值（可能可缩回）
        let shouldProbe: Bool
        /// insets 相对输入 learned 是否变化（变化才整体重排）
        let changedFromLearned: Bool
    }

    /// 纯决策：不改状态、不写 UserDefaults，只回答「学到什么 / 要不要探测 / 要不要重排」。
    static func decide(
        learned: WorkAreaInsets,
        planned: [CGRect],
        actual: [CGRect?],
        planningFrame: CGRect
    ) -> Decision {
        let observed = DisplayWorkArea.inferInsets(
            planned: planned,
            actual: actual,
            planningFrame: planningFrame
        )
        let merged = observed.isZero ? learned : learned.merged(with: observed)
        return Decision(
            insets: merged,
            learnedNonzero: !observed.isZero,
            shouldProbe: observed.isZero && !learned.isZero,
            changedFromLearned: merged != learned
        )
    }
}
