import AppKit
import ApplicationServices.HIServices
import Foundation
@testable import VibeFocusKit

// Tests/Runner/RunnerHookTestAndAXReadTests.swift — 覆盖率批次 26（B257）：
// ①HookTest 静态纯函数（makeTestHookPayload/buildHookRequest/hookResponseVerdict）；
// ②AXRead 失败分支补齐（windowHandle/windowNumber/title/isAttributeSettable 无授权→nil/false）；
// ③locateYabai 转发（YabaiClient.yabaiPath 缓存主路径）。

extension RunnerHarness {
    func runHookTestAndAXReadTests() {
        // MARK: A. makeTestHookPayload：三字段契约
        let payload = SettingsView.makeTestHookPayload(event: "Stop", sessionID: "b257-s")
        check("hookTest: payload 三字段（event/session_id/source=test-ui）",
              payload == ["event": "Stop", "session_id": "b257-s", "source": "test-ui"])

        // MARK: B. buildHookRequest：URL/方法/头/body 构造
        do {
            let request = try SettingsView.buildHookRequest(
                port: 39277, endpoint: "/hook",
                payload: ["event": "Stop"], token: "b257-token")
            check("hookTest: buildHookRequest URL/方法/Content-Type",
                  request.url?.absoluteString == "http://127.0.0.1:39277/hook"
                  && request.httpMethod == "POST"
                  && request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            check("hookTest: token 头透传",
                  request.value(forHTTPHeaderField: "X-VibeFocus-Token") == "b257-token")
        } catch {
            check("hookTest: buildHookRequest 合法输入不抛错", false)
        }

        // MARK: C. hookResponseVerdict：三态裁决
        let okResponse = HTTPURLResponse(url: URL(string: "http://127.0.0.1/hook")!,
                                         statusCode: 200, httpVersion: nil, headerFields: nil)
        let failResponse = HTTPURLResponse(url: URL(string: "http://127.0.0.1/hook")!,
                                           statusCode: 401, httpVersion: nil, headerFields: nil)
        if case .success = SettingsView.hookResponseVerdict(response: okResponse, data: nil) {
            check("hookTest: 200 → success", true)
        } else {
            check("hookTest: 200 → success", false)
        }
        if case .failure(let err) = SettingsView.hookResponseVerdict(response: failResponse,
                                                                     data: Data("unauthorized".utf8)) {
            check("hookTest: 401 → failure 携带状态码与响应体",
                  (err as NSError).code == 401
                  && err.localizedDescription.contains("401")
                  && err.localizedDescription.contains("unauthorized"))
        } else {
            check("hookTest: 401 → failure 携带状态码与响应体", false)
        }
        if case .failure = SettingsView.hookResponseVerdict(response: nil, data: nil) {
            check("hookTest: 非 HTTP response → failure", true)
        } else {
            check("hookTest: 非 HTTP response → failure", false)
        }

        // MARK: D. AXRead 失败分支补齐（无授权 CLI 进程，systemWide 元素恒 nil/false）
        let wm = WindowManager.shared
        let systemWide = AXUIElementCreateSystemWide()
        check("axRead: windowHandle 无授权 → nil", wm.windowHandle(for: systemWide) == nil)
        check("axRead: windowNumber 无授权 → nil", wm.windowNumber(for: systemWide) == nil)
        check("axRead: title 无授权 → nil", wm.title(of: systemWide) == nil)
        check("axRead: isAttributeSettable 无授权 → false",
              wm.isAttributeSettable(systemWide, attribute: kAXTitleAttribute as String) == false)

        // MARK: E. locateYabai：YabaiClient.yabaiPath 缓存主路径转发
        if let path = SpaceController.shared.locateYabai() {
            check("locateYabai: 返回绝对路径", path.hasPrefix("/") && path.hasSuffix("yabai"))
        } else {
            check("locateYabai: 无 yabai 环境合法 nil", true)
        }
    }
}
