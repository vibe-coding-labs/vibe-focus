// ProjectSoundResolver.swift
// VibeFocus — 按项目区分提示音（纯类型 + 纯函数，产品迭代轮次 2）
//
// 产品设计：多会话并开时，用户听到 ding 只知道"有会话完成"，不知道是哪个项目。
// 本层提供「项目名 → 音效」规则表，命中规则的项目用专属音效，未命中回落全局设置——
// 听到声音即知哪个项目完成，与语音播报的 {project_name} 模板变量互补。

import Foundation

/// 单条项目音效规则
struct ProjectSoundRule: Codable, Equatable {
    /// 项目名（也接受任意路径，匹配时双侧经 WindowManager.projectName(fromCwd:) 归一）
    var projectName: String
    /// CompletionSoundType.rawValue（存字符串保持 JSON 稳定，解失败视作未命中回落全局）
    var soundRawValue: String

    var soundType: CompletionSoundType? {
        CompletionSoundType(rawValue: soundRawValue)
    }

    init(projectName: String, soundType: CompletionSoundType) {
        self.projectName = projectName
        self.soundRawValue = soundType.rawValue
    }
}

/// 项目音效解析（纯函数命名空间，fixture 可测，见 Standalone/ProjectSoundResolverTests.swift）。
enum ProjectSoundResolver {

    /// 项目名提取：优先 claudeProjectDir，缺失回落 cwd（双侧同源）。
    /// 复用 WindowManager.projectName(fromCwd:)（末段路径 + 小写归一）——唯一提取实现，
    /// 不再造第二份路径解析（十六刀"零调用/影子函数"教训）。
    static func projectName(claudeProjectDir: String?, cwd: String?) -> String? {
        WindowManager.projectName(fromCwd: claudeProjectDir ?? cwd)
    }

    /// 解析本次完成音应使用的音效类型：规则表从上到下首个命中者，未命中回落全局。
    ///
    /// ## 场景
    /// - `SoundManager.playCompletionSound` 的音效类型前置解析（在防打扰门控之前——
    ///   全局 .none 但项目命中规则时，该项目仍应发声）；
    /// - 匹配双侧均经 projectName(fromCwd:) 归一（用户在规则里粘贴绝对路径也能命中）。
    ///
    /// ## 边界裁决
    /// - projectName 为 nil/空（无 cwd 上下文）→ 全局；
    /// - 规则的 soundRawValue 非法（历史数据漂移）→ 跳过该规则继续匹配；
    /// - 「自定义文件」规则共用全局自定义音频文件（v1 限制，UI 有提示）。
    static func resolvedType(
        projectName: String?,
        rules: [ProjectSoundRule],
        globalType: CompletionSoundType
    ) -> CompletionSoundType {
        guard let projectName, !projectName.isEmpty else { return globalType }
        for rule in rules {
            guard let ruleSound = rule.soundType else { continue }
            if ruleMatches(ruleName: rule.projectName, liveProjectName: projectName) {
                return ruleSound
            }
        }
        return globalType
    }

    /// 规则名与运行时项目名是否指向同一项目（双侧同一归一函数）
    static func ruleMatches(ruleName: String, liveProjectName: String) -> Bool {
        guard let normalizedRule = WindowManager.projectName(fromCwd: ruleName),
              let normalizedLive = WindowManager.projectName(fromCwd: liveProjectName) else {
            return false
        }
        return normalizedRule == normalizedLive
    }
}
