import CoreGraphics
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerDisplayWorkAreaTests.swift — B69：「学习型显示器保留区」契约直测。
// DisplayWorkArea 家族（WorkAreaInsets.merged / plannedFrame / inferInsets / probedInsets +
// defaults 注入式存取对）在 B69 前零测试消费——该族是 P40UG 副屏 25px 隐形菜单栏保留区
// 自愈的唯一事实源（重排/恢复共用），锁死其噪声阈/上限/回落/只缩不涨语义。

extension RunnerHarness {
    func runDisplayWorkAreaTests() {
        // ===== WorkAreaInsets.merged：逐边取较大值（学习只更保守） =====
        do {
            let a = WorkAreaInsets(top: 25, left: 0, bottom: 10, right: 5)
            let b = WorkAreaInsets(top: 20, left: 8, bottom: 10, right: 0)
            let m = a.merged(with: b)
            check("insets: merged 逐边取 max", m == WorkAreaInsets(top: 25, left: 8, bottom: 10, right: 5))
            check("insets: 与 zero merged = 恒等", a.merged(with: .zero) == a && .zero.merged(with: a) == a)
        }

        // ===== plannedFrame：visibleFrame 扣 insets（Quartz top 加在 minY）；面积非正回落 =====
        do {
            let visible = CGRect(x: 0, y: 0, width: 3440, height: 1440)
            let insets = WorkAreaInsets(top: 25, left: 0, bottom: 0, right: 15)
            let planned = DisplayWorkArea.plannedFrame(visibleFrame: visible, insets: insets)
            check("planned: 常规扣减（top 加在 minY、宽右缩）",
                  planned == CGRect(x: 0, y: 25, width: 3425, height: 1415))
            check("planned: zero insets = 恒等",
                  DisplayWorkArea.plannedFrame(visibleFrame: visible, insets: .zero) == visible)
            // 扣穿（高 20 扣 top 25）→ 回落原始 frame（insets 异常防御）
            let overSubtracted = DisplayWorkArea.plannedFrame(
                visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 20),
                insets: WorkAreaInsets(top: 25, left: 0, bottom: 0, right: 0))
            check("planned: 面积扣穿 → 回落原始 frame", overSubtracted == CGRect(x: 0, y: 0, width: 800, height: 20))
            // 恰好扣到 0（guard 是 > 0）也回落
            let exactlyZero = DisplayWorkArea.plannedFrame(
                visibleFrame: CGRect(x: 0, y: 0, width: 100, height: 25),
                insets: WorkAreaInsets(top: 25, left: 0, bottom: 0, right: 0))
            check("planned: 高度恰扣为 0 → 回落原始 frame", exactlyZero.height == 25 && exactlyZero.minY == 0)
        }

        // ===== inferInsets：由规划/实际落点推断钳制（贴边格、最小推离、噪声阈、上限） =====
        do {
            let planning = CGRect(x: 0, y: 25, width: 3440, height: 1415)
            func cell(_ x: CGFloat, _ y: CGFloat) -> CGRect { CGRect(x: x, y: y, width: 400, height: 300) }
            // 顶行两格齐规划顶缘同被推离 25 → top=25；底行齐规划底缘未被推 → bottom=0
            let planned = [cell(0, 25), cell(500, 25), cell(0, 1140)]
            let actual = [CGRect(x: 0, y: 50, width: 400, height: 300),
                          CGRect(x: 500, y: 50, width: 400, height: 300),
                          cell(0, 1140)]
            let inferred = DisplayWorkArea.inferInsets(planned: planned, actual: actual, planningFrame: planning)
            check("infer: 顶行同向推离 25 → top=25、贴边底行 → bottom=0",
                  inferred.top == 25 && inferred.bottom == 0 && inferred.left == 0 && inferred.right == 0)
            // 任一格能到达边缘 → 该边无钳制（最小推离胜出）
            let inferred2 = DisplayWorkArea.inferInsets(planned: [cell(0, 25), cell(500, 25)],
                                                        actual: [cell(0, 65), cell(500, 25)],
                                                        planningFrame: planning)
            check("infer: 一格到达边缘 → top=0（任一格可达即无钳制）", inferred2.top == 0)
            // 取整抖动 ≤ noiseThreshold(1.5) 不算钳制（Δ=1.0）
            let jitter = DisplayWorkArea.inferInsets(planned: [cell(0, 25)],
                                                     actual: [cell(0, 26)], planningFrame: planning)
            check("infer: 推离 ≤ 1.5 噪声阈 → 不学习", jitter.top == 0)
            // 超过 maxInset(200) 视为异常读数不学习
            let absurd = DisplayWorkArea.inferInsets(planned: [cell(0, 25)],
                                                     actual: [cell(0, 300)], planningFrame: planning)
            check("infer: 推离 > maxInset(200) → 不学习", absurd.top == 0)
            // 非 0.5px 内贴规划缘的格不参与该边统计
            let notFlush = DisplayWorkArea.inferInsets(planned: [cell(0, 125)],
                                                       actual: [cell(0, 145)], planningFrame: planning)
            check("infer: 非贴规划缘格子不参与推断", notFlush.top == 0)
            // actual 含 nil（读回失败）跳过 → 全 nil 全零
            let withNil = DisplayWorkArea.inferInsets(planned: [cell(0, 25), cell(500, 25)],
                                                      actual: [nil, nil], planningFrame: planning)
            check("infer: nil 读回跳过", withNil == .zero)
            // 最小推离胜出 + 取整
            let minWins = DisplayWorkArea.inferInsets(planned: [cell(0, 25), cell(500, 25)],
                                                      actual: [cell(0, 65), cell(500, 50.6)],
                                                      planningFrame: planning)
            check("infer: 多格取最小推离并取整（25.6→26）", minWins.top == 26)
        }

        // ===== probedInsets：探测只缩不涨；能到达即归零（菜单栏改自动隐藏后自愈） =====
        do {
            let learned = WorkAreaInsets(top: 30, left: 20, bottom: 0, right: 0)
            let probeTarget = CGRect(x: 0, y: 0, width: 400, height: 300)
            // 探测窗按原始顶左格写入（单窗同时覆盖顶/左两缘）：顶被推 25.4 → 缩到 25；左可到达 → 归零
            let shrunk = DisplayWorkArea.probedInsets(probeTarget: probeTarget,
                                                      actual: CGRect(x: 0, y: 25.4, width: 400, height: 300),
                                                      learned: learned)
            check("probe: 顶推离 25.4 缩到 25、左可到达归零",
                  shrunk.top == 25 && shrunk.left == 0)
            // 探测推离更多（40 > 30）→ 不涨，保持 learned
            let grew = DisplayWorkArea.probedInsets(probeTarget: probeTarget,
                                                    actual: CGRect(x: 0, y: 40, width: 400, height: 300),
                                                    learned: learned)
            check("probe: 探测推离大于 learned → 只缩不涨", grew.top == 30)
            // 能到达（≤ 噪声阈）→ 归零自愈
            let healed = DisplayWorkArea.probedInsets(probeTarget: probeTarget,
                                                      actual: probeTarget,
                                                      learned: learned)
            check("probe: 顶/左均可到达 → 双归零自愈", healed.top == 0 && healed.left == 0)
            // 左缘单边：顶可到达归零、左仍被钳 10
            let leftOnly = DisplayWorkArea.probedInsets(probeTarget: probeTarget,
                                                        actual: CGRect(x: 10, y: 0, width: 400, height: 300),
                                                        learned: learned)
            check("probe: 左缘钳 10 → left 缩到 10、top 归零", leftOnly.left == 10 && leftOnly.top == 0)
        }

        // ===== learnedInsets/store：defaults 注入式存取回环（临时 suite，零真身偏好污染） =====
        do {
            let suiteName = "vibefocus-b69-displayworkarea-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let insets = WorkAreaInsets(top: 25, left: 0, bottom: 0, right: 0)
            check("store: 未写入 → zero 兜底", DisplayWorkArea.learnedInsets(displayID: 1, defaults: defaults) == .zero)
            DisplayWorkArea.store(insets, displayID: 1, defaults: defaults)
            check("store: 写入回环", DisplayWorkArea.learnedInsets(displayID: 1, defaults: defaults) == insets)
            check("store: 多屏表互不串扰",
                  DisplayWorkArea.learnedInsets(displayID: 2, defaults: defaults) == .zero)
            DisplayWorkArea.store(.zero, displayID: 1, defaults: defaults)
            check("store: 归零即摘键（不残留 zero 条目）",
                  DisplayWorkArea.learnedInsets(displayID: 1, defaults: defaults) == .zero
                  && defaults.data(forKey: DisplayWorkArea.defaultsKey) != nil)
            // 坏数据韧性：解码失败 → zero 不抛错
            defaults.set(Data("not-json".utf8), forKey: DisplayWorkArea.defaultsKey)
            check("store: 缓存坏数据 → zero 兜底不抛错",
                  DisplayWorkArea.learnedInsets(displayID: 1, defaults: defaults) == .zero)
        }
    }
}
