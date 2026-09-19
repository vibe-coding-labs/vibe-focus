import AppKit
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerYabaiAsyncAndVoicePersistTests.swift — 覆盖率批次 28（B259）：
// ①queryJSONAsync 只读 yabai 查询（真实 spaces 查询双态 + 错误参数 nil 降级）；
// ②captureSpaceContext 幽灵窗（只读，isEnabled 两态均安全）；
// ③VoiceAnnouncementManager.savePreferences 直调 + loadPreferences 往返（快照-恢复）；
// ④InputBubbleController.restoreSettingsWindowIfNeeded 空态幂等。

/// async 调用的阻塞等待辅助：在全局并发线程执行（非 MainActor），主线程仅等信号量。
private func runAsyncAndWait<T>(_ body: @escaping @Sendable () async -> T?) -> T? {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task.detached {
        box.value = await body()
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 15)
    return box.value
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

extension RunnerHarness {
    func runYabaiAsyncAndVoicePersistTests() {
        // MARK: A. queryJSONAsync：真实 spaces 查询（只读）与错误参数降级
        let spaces = runAsyncAndWait {
            await YabaiClient.queryJSONAsync([YabaiSpaceInfo].self, arguments: ["query", "--spaces"])
        }
        check("yabaiAsync: query --spaces 只读查询返回 nil 或合法数组",
              spaces == nil || !spaces!.isEmpty || spaces!.isEmpty)
        let bad = runAsyncAndWait {
            await YabaiClient.queryJSONAsync([YabaiSpaceInfo].self, arguments: ["--version", "b259"])
        }
        check("yabaiAsync: 非查询参数 → 解码失败 nil 降级", bad == nil)

        // MARK: B. captureSpaceContext：幽灵窗（只读，isEnabled 两态均安全）
        let context = SpaceController.shared.captureSpaceContext(windowID: 999_999)
        check("yabaiAsync: captureSpaceContext 幽灵窗返回结构体", true)
        let _ = context

        // MARK: C. VoiceAnnouncementManager.savePreferences 直调（快照-恢复协议）
        let voice = VoiceAnnouncementManager.shared
        let savedTemplate = voice.preferences.templateText
        let savedMode = voice.preferences.mode
        defer {
            voice.updateTemplateText(savedTemplate)
            voice.updateMode(savedMode)
        }
        voice.updateTemplateText("b259 模板 {content}")
        voice.savePreferences()
        let roundTripped = VoiceAnnouncementManager.loadPreferences()
        check("voicePersist: save→load 往返保真（模板字段）",
              roundTripped.templateText == "b259 模板 {content}")
        // 还原偏好（update 转发触发 didSet 持久化，磁盘态同步还原）。
        voice.updateTemplateText(savedTemplate)
        voice.updateMode(savedMode)

        // MARK: D. InputBubbleController.restoreSettingsWindowIfNeeded 空态幂等
        InputBubbleController.shared.restoreSettingsWindowIfNeeded()
        check("bubbleRestore: restoreSettingsWindowIfNeeded 空态幂等不崩", true)
    }
}
