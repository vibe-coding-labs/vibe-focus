// YabaiErrorClassifier.swift
// VibeFocus — yabai stderr 错误分类（纯函数）
// 收敛此前散落 4 处的 stderr 字符串匹配协议（playbook 2.16 第八刀）：
//   - SpaceController+Recovery   "scripting-addition"（SA 未加载探测）
//   - "mission-control"（Mission Control 挡切换；原消费方 switchDisplayToSpace 已
//     下线（2026-09-02 P2-1），类别保留——MC 阻塞仍是 space --focus 的真实失败态）
//   - SpaceController+Query      "could not retrieve window details"（无焦点窗口）
//   - SpaceController+Query      "could not locate window"（窗口已关闭）
// 匹配语义统一为大小写不敏感（历史上有的点 lowercased 再 contains，有的不转小写，
// 对真实 yabai 输出等价——其消息恒为小写；统一后对潜在大小写漂移更稳健）。

import Foundation

/// yabai stderr 的可识别错误类别
enum YabaiErrorKind: Equatable {
    /// scripting-addition 未加载（SA 依赖命令全部不可用）
    case scriptingAdditionMissing
    /// Mission Control 活跃，挡住 space 切换（可 dismiss 后重试）
    case missionControlBlocking
    /// 无焦点窗口（用户点桌面/全部最小化）——预期失败
    case noFocusedWindow
    /// 窗口 ID 无效/已关闭——预期失败
    case windowNotFound
    /// 非空 stderr 但未识别（异常失败，保持 warn 级别关注）
    case unrecognized
    /// 空 stderr（命令失败但无输出）
    case none
}

enum YabaiErrorClassifier {

    /// 已知错误 → 特征子串（小写）。优先级即数组顺序：同一条 stderr 命中多类时取最前。
    /// 顺序依据：SA 缺失是最系统性故障（整个增强层不可用，需恢复流程），
    /// 其次 MC 阻塞（可自愈重试），最后两类是查询类预期失败（仅降日志级别）。
    private static let patterns: [(YabaiErrorKind, String)] = [
        (.scriptingAdditionMissing, "scripting-addition"),
        (.missionControlBlocking, "mission-control"),
        (.noFocusedWindow, "could not retrieve window details"),
        (.windowNotFound, "could not locate window"),
    ]

    /// 纯函数：stderr → 错误类别。子串匹配、大小写不敏感。
    static func classify(stderr: String) -> YabaiErrorKind {
        let lowered = stderr.lowercased()
        guard !lowered.isEmpty else { return .none }
        for (kind, pattern) in patterns where lowered.contains(pattern) {
            return kind
        }
        return .unrecognized
    }
}
