import Testing
import Foundation
@testable import VibeFocusKit

@Suite("SpacePreferences UserDefaults Roundtrip", .serialized)
struct SpacePreferencesTests {

    private func saveAndRestore(key: String, _ block: () -> Void) {
        let original = UserDefaults.standard.object(forKey: key)
        block()
        if let original {
            UserDefaults.standard.set(original, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - integrationEnabled

    @Test("integrationEnabled default is true when key absent")
    func integrationEnabledDefault() {
        saveAndRestore(key: SpacePreferences.integrationEnabledKey) {
            UserDefaults.standard.removeObject(forKey: SpacePreferences.integrationEnabledKey)
            #expect(SpacePreferences.integrationEnabled == true)
        }
    }

    @Test("integrationEnabled returns false when set to false")
    func integrationEnabledFalse() {
        saveAndRestore(key: SpacePreferences.integrationEnabledKey) {
            SpacePreferences.integrationEnabled = false
            #expect(SpacePreferences.integrationEnabled == false)
        }
    }

    @Test("integrationEnabled returns true when set to true")
    func integrationEnabledTrue() {
        saveAndRestore(key: SpacePreferences.integrationEnabledKey) {
            SpacePreferences.integrationEnabled = true
            #expect(SpacePreferences.integrationEnabled == true)
        }
    }

    // MARK: - restoreStrategy（已下线）
    // 历史注（playbook 2.16 第六刀）：restoreStrategy/pullToCurrent 是零消费的死设置——
    // "拉到当前工作区"依赖 yabai v7 float 布局下静默失效的 `window --space` 原语，
    // 无法诚实实现，UI 与偏好已整体移除，恢复固定为"切回原工作区"语义。

    // MARK: - key stability

    @Test("integrationEnabledKey is stable")
    func integrationEnabledKeyStable() {
        #expect(SpacePreferences.integrationEnabledKey == "spaceIntegrationEnabled")
    }
}
