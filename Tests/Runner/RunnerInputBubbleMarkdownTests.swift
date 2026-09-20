import AppKit
import SwiftUI
@testable import VibeFocusKit

// Tests/Runner/RunnerInputBubbleMarkdownTests.swift — 输入气泡 Markdown 编辑器形态
// （Typora 式输入即渲染，2026-09-20）直测：
// 偏好双形态回环/非法值回落/切换通知、面板构建指纹真值表、块级解析状态机
// （标题/围栏/引用/列表/分隔线）、行内认领（粗/斜/码/删除线/链接，非重叠）、
// 渲染契约（源码逐字一致 + 属性落点）、超长诚实降级、打字属性（块基样式继承 /
// 回车回正文 / 围栏续码）、视图层 string setter 与 didChangeText 渲染触发、
// 设置页选择行双态渲染。
// 真机域（真面板热重建、键击语义）归 env-gated E2E 通道（RunnerBubblePanelE2ETests 先例）。

extension RunnerHarness {

    /// 字体符号特征断言助手
    private func hasTrait(_ font: NSFont?, _ trait: NSFontDescriptor.SymbolicTraits) -> Bool {
        guard let font else { return false }
        return font.fontDescriptor.symbolicTraits.contains(trait)
    }

    private func font(at text: NSAttributedString, _ location: Int) -> NSFont? {
        text.attribute(.font, at: location, effectiveRange: nil) as? NSFont
    }

    func runInputBubbleMarkdownTests() {
        print("\n=== InputBubble Markdown Editor (2026-09-20) ===")

        // ===== A. 偏好：双形态回环 / 非法 raw 回落 / 切换通知 =====
        do {
            let savedRaw = UserDefaults.standard.object(forKey: "inputBubbleEditorKind")
            defer {
                if let savedRaw {
                    UserDefaults.standard.set(savedRaw, forKey: "inputBubbleEditorKind")
                } else {
                    UserDefaults.standard.removeObject(forKey: "inputBubbleEditorKind")
                }
            }
            UserDefaults.standard.removeObject(forKey: "inputBubbleEditorKind")
            check("mdPref: 默认形态 = plain（保持现行行为）", InputBubblePreferences.editorKind == .plain)

            InputBubblePreferences.editorKind = .markdown
            check("mdPref: 写读回环 markdown", InputBubblePreferences.editorKind == .markdown)

            UserDefaults.standard.set("bogus", forKey: "inputBubbleEditorKind")
            check("mdPref: 非法 raw 手写回落 plain", InputBubblePreferences.editorKind == .plain)

            // 切换通知：值真变才发（同步 post，观察旗标立即可读）
            UserDefaults.standard.set("plain", forKey: "inputBubbleEditorKind")
            final class FiredBox: @unchecked Sendable { var count = 0 }
            let fired = FiredBox()
            let token = NotificationCenter.default.addObserver(
                forName: InputBubblePreferences.editorKindDidChangeNotification, object: nil, queue: nil
            ) { _ in fired.count += 1 }
            defer { NotificationCenter.default.removeObserver(token) }
            InputBubblePreferences.editorKind = .markdown
            InputBubblePreferences.editorKind = .markdown  // 同值写不广播
            check("mdPref: 切换通知真变才发（2 次写 1 次 fire）", fired.count == 1)
        }

        // ===== B. 面板构建指纹真值表 =====
        do {
            let fp = InputBubblePanelBuildPlan.Fingerprint(
                size: NSSize(width: 480, height: 150), submitOnEnter: false, editorKind: .plain
            )
            check("mdFingerprint: 全同 → 不重建",
                  !InputBubblePanelBuildPlan.needsRebuild(built: fp, size: NSSize(width: 480, height: 150),
                                                          submitOnEnter: false, editorKind: .plain))
            check("mdFingerprint: 无指纹 → 重建",
                  InputBubblePanelBuildPlan.needsRebuild(built: nil, size: NSSize(width: 480, height: 150),
                                                         submitOnEnter: false, editorKind: .plain))
            check("mdFingerprint: 编辑器形态变化 → 重建",
                  InputBubblePanelBuildPlan.needsRebuild(built: fp, size: NSSize(width: 480, height: 150),
                                                         submitOnEnter: false, editorKind: .markdown))
            check("mdFingerprint: 尺寸变化 → 重建",
                  InputBubblePanelBuildPlan.needsRebuild(built: fp, size: NSSize(width: 500, height: 150),
                                                         submitOnEnter: false, editorKind: .plain))
            check("mdFingerprint: 回车语义变化 → 重建",
                  InputBubblePanelBuildPlan.needsRebuild(built: fp, size: NSSize(width: 480, height: 150),
                                                         submitOnEnter: true, editorKind: .plain))
        }

        // ===== C. 块级解析 =====
        do {
            check("mdBlock: # = 1 级", MarkdownLiveRenderPlan.headingLevel(ofLine: "# 标题") == 1)
            check("mdBlock: ###### = 6 级", MarkdownLiveRenderPlan.headingLevel(ofLine: "###### 六") == 6)
            check("mdBlock: ####### 不是标题（7 个 #）", MarkdownLiveRenderPlan.headingLevel(ofLine: "####### 七") == nil)
            check("mdBlock: #无空格不是标题", MarkdownLiveRenderPlan.headingLevel(ofLine: "#标签") == nil)
            check("mdBlock: 空 # 是标题（空内容）", MarkdownLiveRenderPlan.headingLevel(ofLine: "#") == 1)
            check("mdBlock: 前导空白容忍", MarkdownLiveRenderPlan.headingLevel(ofLine: "  ## 二") == 2)
            check("mdBlock: 普通文本不是标题", MarkdownLiveRenderPlan.headingLevel(ofLine: "正文") == nil)

            check("mdBlock: 围栏 ``` 识别", MarkdownLiveRenderPlan.isFenceMarker("```"))
            check("mdBlock: 围栏带语言 ```swift", MarkdownLiveRenderPlan.isFenceMarker("```swift"))
            check("mdBlock: 围栏前导空白", MarkdownLiveRenderPlan.isFenceMarker("  ```"))
            check("mdBlock: `` 不是围栏", !MarkdownLiveRenderPlan.isFenceMarker("``"))

            check("mdBlock: --- 是分隔线", MarkdownLiveRenderPlan.isHorizontalRule("---"))
            check("mdBlock: *** 是分隔线", MarkdownLiveRenderPlan.isHorizontalRule("* * *"))
            check("mdBlock: -- 不是分隔线", !MarkdownLiveRenderPlan.isHorizontalRule("--"))
            check("mdBlock: -x- 不是分隔线", !MarkdownLiveRenderPlan.isHorizontalRule("-x-"))

            check("mdBlock: >␣ 引用标记 2", MarkdownLiveRenderPlan.quoteMarkerLength(ofLine: "> 引") == 2)
            check("mdBlock: > 空格变体标记 2", MarkdownLiveRenderPlan.quoteMarkerLength(ofLine: "> x") == 2)
            check("mdBlock: >紧贴内容标记 1", MarkdownLiveRenderPlan.quoteMarkerLength(ofLine: ">x") == 1)
            check("mdBlock: 非引用返回 0", MarkdownLiveRenderPlan.quoteMarkerLength(ofLine: "正文") == 0)

            check("mdList: - 标记 2", MarkdownLiveRenderPlan.listItemMarkerLength(ofLine: "- 项") == 2)
            check("mdList: * 标记 2", MarkdownLiveRenderPlan.listItemMarkerLength(ofLine: "* 项") == 2)
            check("mdList: 1. 标记 3", MarkdownLiveRenderPlan.listItemMarkerLength(ofLine: "1. 项") == 3)
            check("mdList: 12) 标记 4", MarkdownLiveRenderPlan.listItemMarkerLength(ofLine: "12) 项") == 4)
            check("mdList: -无空格不是列表", MarkdownLiveRenderPlan.listItemMarkerLength(ofLine: "-项") == 0)
            check("mdList: 正文不是列表", MarkdownLiveRenderPlan.listItemMarkerLength(ofLine: "正文") == 0)
        }

        // ===== D. 块状态机：围栏跨行 + 序列锁定 =====
        do {
            let source = "# 标题\n正文\n```\n**不解析**\n```\n> 引用\n- 列表\n---\n"
            let spans = MarkdownLiveRenderPlan.blockSpans(for: source)
            let kinds: [MarkdownLiveRenderPlan.BlockKind] = [
                .heading(level: 1), .paragraph, .fenceMarker, .codeLine, .fenceMarker,
                .quote, .listItem(markerLength: 2), .hr
            ]
            check("mdSpans: 八行块序列逐一锁定（含围栏内不解析）",
                  spans.map(\.kind) == kinds)
            check("mdSpans: 标题标记长 2", spans[0].markerLength == 2)
            check("mdSpans: 引用标记长 2", spans[5].markerLength == 2)
            check("mdSpans: 围栏无标记", spans[2].markerLength == 0 && spans[4].markerLength == 0)

            check("mdFenceOpen: 闭合围栏 → false",
                  !MarkdownLiveRenderPlan.isFenceOpen(atEndOf: "```\ncode\n```\n"))
            check("mdFenceOpen: 未闭合围栏 → true",
                  MarkdownLiveRenderPlan.isFenceOpen(atEndOf: "```\ncode\n"))
        }

        // ===== E. 行内认领：范围锁定 + 非重叠 =====
        do {
            let spans = MarkdownLiveRenderPlan.inlineSpans(in: "**粗** _斜_ `码` ~~删~~ [链](http://x)", baseLocation: 100)
            // 认领序 = 正则模式序（code > link > bold > strike > italic）
            let kinds: [MarkdownLiveRenderPlan.InlineKind] = [.code, .link, .bold, .strike, .italic]
            check("mdInline: 五类认领齐且序稳定", spans.map(\.kind) == kinds)
            check("mdInline: 坐标偏移到全文（baseLocation=100）",
                  spans.allSatisfy { $0.range.location >= 100 })
            var noOverlap = true
            for i in 0..<spans.count {
                for j in (i + 1)..<spans.count where NSIntersectionRange(spans[i].range, spans[j].range).length > 0 {
                    noOverlap = false
                }
            }
            check("mdInline: 五类 range 互不重叠", noOverlap)

            let boldFirst = MarkdownLiveRenderPlan.inlineSpans(in: "*斜* 与 **粗**", baseLocation: 0)
            check("mdInline: *斜* 与 **粗** 相邻各得其所（bold 模式先认领）",
                  boldFirst.map(\.kind) == [.bold, .italic])

            let code = MarkdownLiveRenderPlan.inlineSpans(in: "`**not**`", baseLocation: 0)
            check("mdInline: 行内码优先，内部 ** 不认", code.map(\.kind) == [.code])

            let wordUnderscore = MarkdownLiveRenderPlan.inlineSpans(in: "snake_case_word", baseLocation: 0)
            check("mdInline: 词内下划线不认斜体", wordUnderscore.isEmpty)
        }

        // ===== F. 渲染契约：源码逐字一致 + 属性落点 =====
        do {
            let source = "# 大标题\n## 二级**加粗**\n正文 _斜体_ 与 `代码` 以及 ~~删除~~ 和 [链接](https://example.com)\n> 引用行\n```\nfenced_code\n```\n- 列表项\n"
            let rendered = MarkdownLiveRenderPlan.render(source)
            check("mdRender: 契约——字符串逐字一致（注入语义不变）", rendered.string == source)

            let lines = source.components(separatedBy: "\n")
            var loc = 0
            var lineStarts: [Int] = []
            for line in lines {
                lineStarts.append(loc)
                loc += (line as NSString).length + 1
            }
            // h1 行：20pt 粗体
            let h1 = font(at: rendered, lineStarts[0] + 2)
            check("mdRender: h1 = 20pt 粗体", h1?.pointSize == 20 && hasTrait(h1, .bold))
            // h2 行：17pt；行内 **加粗** 继承 h2 尺寸再叠粗
            let h2 = font(at: rendered, lineStarts[1] + 3)
            check("mdRender: h2 = 17pt 粗体", h2?.pointSize == 17 && hasTrait(h2, .bold))
            let h2Bold = font(at: rendered, lineStarts[1] + 7)
            check("mdRender: h2 内 **加粗** 保持 h2 尺寸", h2Bold?.pointSize == 17 && hasTrait(h2Bold, .bold))
            // 斜体
            let italic = font(at: rendered, lineStarts[2] + 4)
            check("mdRender: _斜体_ 有 italic 特征", hasTrait(italic, .italic))
            // 行内码：Menlo + 底色
            let codeLoc = lineStarts[2] + 11
            let codeFont = font(at: rendered, codeLoc)
            check("mdRender: `代码` = Menlo", codeFont?.familyName == "Menlo")
            check("mdRender: `代码` 有底色",
                  (rendered.attribute(.backgroundColor, at: codeLoc, effectiveRange: nil) as? NSColor) != nil)
            // 删除线
            var strikeFound = false
            rendered.enumerateAttribute(.strikethroughStyle, in: rendered.fullRange) { value, _, _ in
                if let v = value as? Int, v != 0 { strikeFound = true }
            }
            check("mdRender: ~~删除~~ 有删除线", strikeFound)
            // 链接：下划线
            var linkFound = false
            rendered.enumerateAttribute(.underlineStyle, in: rendered.fullRange) { value, _, _ in
                if let v = value as? Int, v != 0 { linkFound = true }
            }
            check("mdRender: [链接]() 有下划线", linkFound)
            // 围栏行 Menlo
            let fence = font(at: rendered, lineStarts[4])
            check("mdRender: 围栏内代码行 = Menlo", fence?.familyName == "Menlo")
            // 围栏内 ** 不认粗体（Menlo 且无 bold）
            check("mdRender: 围栏内 **字面量** 不认粗体",
                  font(at: rendered, lineStarts[4] + 2)?.familyName == "Menlo"
                  && !hasTrait(font(at: rendered, lineStarts[4] + 2), .bold))
            // 正文行基样式 13pt
            check("mdRender: 正文 13pt", font(at: rendered, lineStarts[2])?.pointSize == 13)
            // 动态色：前景色存在（深浅跟随由 NSColor dynamic provider 承担，不做颜色相等断言）
            check("mdRender: 前景色全程有值",
                  (rendered.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) != nil)
        }

        // ===== G. 超长诚实降级 =====
        do {
            let long = String(repeating: "a **b** ", count: 7000)  // 63k > cap 50k
            let rendered = MarkdownLiveRenderPlan.render(long)
            check("mdRender: 超长降级仍字符串一致", rendered.string == long)
            var anyBold = false
            rendered.enumerateAttribute(.font, in: rendered.fullRange) { value, _, _ in
                if hasTrait(value as? NSFont, .bold) { anyBold = true }
            }
            check("mdRender: 超长不渲染（无粗体样式）", !anyBold)
        }

        // ===== H. 打字属性：块基样式继承 / 回车回正文 / 围栏续码 =====
        do {
            let src = "# 标题\n正文\n```\ncode\n```\n"
            let heading = MarkdownLiveRenderPlan.typingAttributes(for: src, cursorLocation: 2)
            check("mdTyping: 标题行打字继承 h1 字体",
                  (heading[.font] as? NSFont)?.pointSize == 20)
            let body = MarkdownLiveRenderPlan.typingAttributes(for: src, cursorLocation: 6)
            check("mdTyping: 正文行打字 13pt",
                  (body[.font] as? NSFont)?.pointSize == 13)
            let inFence = MarkdownLiveRenderPlan.typingAttributes(for: src, cursorLocation: 13)
            check("mdTyping: 围栏内打字 = Menlo",
                  (inFence[.font] as? NSFont)?.familyName == "Menlo")
            // 尾随 \n 后（光标在文末新空行）：围栏已闭合 → 回正文
            let afterEnd = MarkdownLiveRenderPlan.typingAttributes(for: src, cursorLocation: src.count)
            check("mdTyping: 围栏闭合后新行回正文",
                  (afterEnd[.font] as? NSFont)?.pointSize == 13
                  && (afterEnd[.font] as? NSFont)?.familyName != "Menlo")
            // 围栏未闭合时文末新行续代码
            let open = "```\ncode\n"
            let openEnd = MarkdownLiveRenderPlan.typingAttributes(for: open, cursorLocation: open.count)
            check("mdTyping: 围栏未闭合新行续 Menlo",
                  (openEnd[.font] as? NSFont)?.familyName == "Menlo")
            // 空文本
            let empty = MarkdownLiveRenderPlan.typingAttributes(for: "", cursorLocation: 0)
            check("mdTyping: 空文本回正文基样式", (empty[.font] as? NSFont)?.pointSize == 13)
        }

        // ===== I. 视图层：string setter 与 didChangeText 渲染触发 =====
        do {
            let tv = MarkdownBubbleTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
            tv.string = "# Hi"
            check("mdView: string setter 触发渲染（h1 20pt）",
                  font(at: tv.textStorage ?? NSAttributedString(), 2)?.pointSize == 20)
            check("mdView: 渲染不改字符串", tv.string == "# Hi")

            // 用户编辑路径模拟：storage 变更 + didChangeText（真实路径 keyDown→insertText 同入口）
            tv.textStorage?.append(NSAttributedString(string: "\n**粗了**"))
            tv.didChangeText()
            check("mdView: didChangeText 补渲染（新行粗体生效）",
                  hasTrait(font(at: tv.textStorage ?? NSAttributedString(), 8), .bold))
            check("mdView: 补渲染后字符串一致", tv.string == "# Hi\n**粗了**")

            // 打字属性跟随：光标移到标题行 → typingAttributes = h1 字体
            tv.setSelectedRange(NSRange(location: 2, length: 0))
            tv.applyLiveRender()
            check("mdView: 光标在标题行 → 新输入继承 h1",
                  (tv.typingAttributes[.font] as? NSFont)?.pointSize == 20)
        }

        // ===== J. 设置页「编辑器形态」行：双态渲染出图 =====
        do {
            let savedRaw = UserDefaults.standard.object(forKey: "inputBubbleEditorKind")
            defer {
                if let savedRaw {
                    UserDefaults.standard.set(savedRaw, forKey: "inputBubbleEditorKind")
                } else {
                    UserDefaults.standard.removeObject(forKey: "inputBubbleEditorKind")
                }
            }
            let view = SettingsView()
            for kind in [InputBubbleEditorKind.plain, .markdown] {
                UserDefaults.standard.set(kind.rawValue, forKey: "inputBubbleEditorKind")
                let renderer = ImageRenderer(content: view.inputBubbleSection)
                check("mdSettings: 编辑器形态行 \(kind.rawValue) 渲染出图", renderer.nsImage != nil)
            }
        }
    }
}

private extension NSAttributedString {
    var fullRange: NSRange { NSRange(location: 0, length: length) }
}
