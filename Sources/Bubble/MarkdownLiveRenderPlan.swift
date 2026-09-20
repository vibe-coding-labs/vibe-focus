import AppKit
import Foundation

// Sources/Bubble/MarkdownLiveRenderPlan.swift — 输入气泡 Markdown 编辑器形态
// （Typora 式输入即渲染，2026-09-20）。纯解析 + 属性组装唯一事实源（Runner 直测）：
// 块级（ATX 标题 / 围栏代码块 / 引用 / 列表 / 分隔线）按行状态机；行内（粗体/斜体/
// 行内代码/删除线/链接）按正则非重叠认领（code > link > bold > strike > italic）。
//
// 设计红线：
// - 源码字符串零改动，只换属性——提交给终端的仍是 Markdown 源文本，注入语义
//   与纯文本模式完全一致（草稿/历史/↑↓ 翻阅全走原通道）；
// - 语法标记保留并弱化显示（# / > / - 等淡色）——NSTextView 无隐藏字符通道，
//   隐藏标记需自定义布局器（选区/IME 风险面大），弱化显示是 Obsidian Live
//   Preview 同款折中；
// - 颜色一律 dynamic provider（深浅色自动跟随，无需重渲染）；字号/字体是静态
//   属性，断言面稳定；
// - 超长文本诚实降级为纯文本（保打字流畅），阈值下不做任何截断。

enum MarkdownLiveRenderPlan {

    /// 渲染长度上限（utf16 单位）：超出跳过实时渲染（保留可编辑纯文本）。
    static let renderLengthCap = 50_000

    // MARK: - 块级解析

    enum BlockKind: Equatable {
        case paragraph
        case heading(level: Int)      // ATX #~######（要求 # 后跟空白或行尾）
        case quote
        case listItem(markerLength: Int)
        case hr
        case fenceMarker              // ``` 行（开/闭围栏本身）
        case codeLine                 // 围栏内代码行
    }

    struct BlockSpan: Equatable {
        /// 整行 range（含行尾换行符，NSString 坐标）
        let range: NSRange
        let kind: BlockKind
        /// 行首语法标记长度（#␣ / >␣ / -␣ 等）——渲染时弱化显示
        let markerLength: Int
    }

    /// ATX 标题级别：# 数 1~6 且后面跟空白或行尾；####### 与 #foo 都不是标题。
    static func headingLevel(ofLine line: String) -> Int? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard trimmed.hasPrefix("#") else { return nil }
        var level = 0
        for ch in trimmed {
            if ch == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        return rest.isEmpty || rest.first == " " || rest.first == "\t" ? level : nil
    }

    /// 围栏标记行：``` 开头（前导空白容忍；只认反引号围栏，~~~ 不支持——诚实窄域）。
    static func isFenceMarker(_ line: String) -> Bool {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        return trimmed.hasPrefix("```")
    }

    /// 分隔线：--- / *** / ___（≥3 个同种字符，中间可夹空白）。
    static func isHorizontalRule(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.count >= 3, let first = t.first, first == "-" || first == "*" || first == "_" else { return false }
        return t.allSatisfy { $0 == first || $0 == " " || $0 == "\t" }
    }

    /// 引用标记长度（> 或 >␣；返回 0 = 非引用）。
    static func quoteMarkerLength(ofLine line: String) -> Int {
        var leading = 0
        for ch in line {
            if ch == " " || ch == "\t" { leading += 1 } else { break }
        }
        let rest = line.dropFirst(leading)
        guard rest.hasPrefix(">") else { return 0 }
        return rest.dropFirst().hasPrefix(" ") ? leading + 2 : leading + 1
    }

    /// 列表标记长度（- * + 或 1. / 1)，标记后须跟空白；返回 0 = 非列表行）。
    static func listItemMarkerLength(ofLine line: String) -> Int {
        var leading = 0
        for ch in line {
            if ch == " " || ch == "\t" { leading += 1 } else { break }
        }
        let rest = line.dropFirst(leading)
        guard let first = rest.first else { return 0 }
        if first == "-" || first == "*" || first == "+" {
            return rest.dropFirst().hasPrefix(" ") ? leading + 2 : 0
        }
        let digits = rest.prefix { $0.isNumber }
        if (1...9).contains(digits.count) {
            let after = rest.dropFirst(digits.count)
            if let punct = after.first, punct == "." || punct == ")", after.dropFirst().hasPrefix(" ") {
                return leading + digits.count + 2
            }
        }
        return 0
    }

    /// 全文块分类状态机：每行恰产出一个 span（含空行=paragraph）；围栏态跨行持续。
    static func blockSpans(for source: String) -> [BlockSpan] {
        var spans: [BlockSpan] = []
        let ns = source as NSString
        var inFence = false
        var loc = 0
        while loc < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
            let content = stripTrailingNewline(ns.substring(with: lineRange))
            func append(_ kind: BlockKind, markerLength: Int = 0) {
                spans.append(BlockSpan(range: lineRange, kind: kind, markerLength: markerLength))
            }
            if isFenceMarker(content) {
                append(.fenceMarker)
                inFence.toggle()
            } else if inFence {
                append(.codeLine)
            } else if let level = headingLevel(ofLine: content) {
                append(.heading(level: level), markerLength: level + 1)
            } else if quoteMarkerLength(ofLine: content) > 0 {
                append(.quote, markerLength: quoteMarkerLength(ofLine: content))
            } else if isHorizontalRule(content) {
                append(.hr)
            } else if listItemMarkerLength(ofLine: content) > 0 {
                append(.listItem(markerLength: listItemMarkerLength(ofLine: content)),
                       markerLength: listItemMarkerLength(ofLine: content))
            } else {
                append(.paragraph)
            }
            let next = NSMaxRange(lineRange)
            if next <= loc { break }  // 零推进防御（NSString lineRange 恒含换行，理论不可达）
            loc = next
        }
        return spans
    }

    /// 读完最后一行后是否仍处于未闭合围栏内（打字属性判定用）。
    static func isFenceOpen(atEndOf source: String) -> Bool {
        var inFence = false
        let ns = source as NSString
        var loc = 0
        while loc < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
            if isFenceMarker(stripTrailingNewline(ns.substring(with: lineRange))) {
                inFence.toggle()
            }
            let next = NSMaxRange(lineRange)
            if next <= loc { break }
            loc = next
        }
        return inFence
    }

    private static func stripTrailingNewline(_ line: String) -> String {
        var content = line
        if content.hasSuffix("\n") { content.removeLast() }
        if content.hasSuffix("\r") { content.removeLast() }
        return content
    }

    // MARK: - 行内解析

    enum InlineKind: Equatable {
        case code, link, bold, italic, strike
    }

    struct InlineSpan: Equatable {
        /// range 已偏移到全文坐标（含 baseLocation）
        let range: NSRange
        let kind: InlineKind
    }

    /// 行内语法认领：先到先得、重叠丢弃（`code` 内不再认粗体等）；
    /// baseLocation = 行内容在全文中的起点（跳过块标记后）。
    static func inlineSpans(in content: String, baseLocation: Int) -> [InlineSpan] {
        let ns = content as NSString
        guard ns.length > 0 else { return [] }
        let full = NSRange(location: 0, length: ns.length)
        let patterns: [(String, InlineKind)] = [
            ("`[^`\\n]+`", .code),
            ("\\[[^\\]\n]*\\]\\([^)\n]*\\)", .link),
            ("\\*\\*[^*\\n]+\\*\\*", .bold),
            ("__[^_\\n]+__", .bold),
            ("~~[^~\\n]+~~", .strike),
            ("\\*[^*\\n]+\\*", .italic),
            ("(?<![A-Za-z0-9_])_[^_\n]+_(?![A-Za-z0-9_])", .italic)
        ]
        var claimed: [NSRange] = []
        var spans: [InlineSpan] = []
        for (pattern, kind) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: content, range: full) {
                let r = match.range
                guard r.length > 0,
                      !claimed.contains(where: { NSIntersectionRange($0, r).length > 0 }) else { continue }
                claimed.append(r)
                spans.append(InlineSpan(
                    range: NSRange(location: baseLocation + r.location, length: r.length),
                    kind: kind
                ))
            }
        }
        return spans
    }

    // MARK: - 样式事实源

    static let headingFontSizes: [Int: CGFloat] = [1: 20, 2: 17, 3: 15, 4: 14, 5: 13, 6: 12]

    static var baseFont: NSFont { NSFont.systemFont(ofSize: 13) }
    static var codeFont: NSFont {
        NSFont(name: "Menlo", size: 12)
            ?? NSFont.userFixedPitchFont(ofSize: 12)
            ?? baseFont
    }

    static func headingFont(level: Int) -> NSFont {
        let size = headingFontSizes[level] ?? 13
        return level >= 5
            ? NSFont.systemFont(ofSize: size, weight: .semibold)
            : NSFont.boldSystemFont(ofSize: size)
    }

    static func italicFont(of font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }

    /// 颜色全部 dynamic（深浅色自动跟随，appearance 变化触发重绘即可）；
    /// 正文/弱化色与气泡现行色系同源（InputBubbleViews 的 0x40362B / 0xB9A98E 族），
    /// 强调色 = VibeColors 珊瑚（0xE64A33 / 0xFF8266）。
    static var textColor: NSColor { dynamicColor(light: 0x40362B, dark: 0xF1E9DE) }
    static var accentColor: NSColor { dynamicColor(light: 0xE64A33, dark: 0xFF8266) }
    static var dimColor: NSColor { dynamicColor(light: 0xB9A98E, dark: 0x8A7B68) }
    static var codeBackgroundColor: NSColor { dynamicColor(light: 0xEFE7D8, dark: 0x342B23) }

    private static func dynamicColor(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgbHex: isDark ? dark : light)
        }
    }

    /// 正文基样式（全文先铺底，再逐块/逐行内叠加）。
    static func baseAttributes() -> [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: textColor]
    }

    private static func codeAttributes() -> [NSAttributedString.Key: Any] {
        [.font: codeFont, .foregroundColor: textColor, .backgroundColor: codeBackgroundColor]
    }

    // MARK: - 全文渲染

    /// 源码 → 带样式 NSAttributedString：字符串逐字一致（Runner 锁此契约），
    /// 超长回落纯基样式（不渲染）。
    static func render(_ source: String) -> NSAttributedString {
        let out = NSMutableAttributedString(string: source)
        out.setAttributes(baseAttributes(), range: NSRange(location: 0, length: out.length))
        guard out.length <= renderLengthCap else { return out }
        let ns = source as NSString
        for block in blockSpans(for: source) {
            switch block.kind {
            case .heading(let level):
                out.addAttributes([
                    .font: headingFont(level: level),
                    .foregroundColor: level <= 3 ? accentColor : textColor
                ], range: block.range)
            case .quote:
                out.addAttributes([
                    .font: italicFont(of: baseFont),
                    .foregroundColor: dimColor
                ], range: block.range)
            case .hr:
                out.addAttribute(.foregroundColor, value: dimColor, range: block.range)
            case .fenceMarker, .codeLine:
                out.addAttributes(codeAttributes(), range: block.range)
            case .listItem, .paragraph:
                break  // 段落/列表行：只做标记弱化与行内认领，无块级属性
            }
            // 块标记弱化（标题 # / 引用 > / 列表 -；围栏与分隔线整行已淡）
            if block.markerLength > 0 {
                out.addAttribute(
                    .foregroundColor,
                    value: dimColor,
                    range: NSRange(location: block.range.location, length: block.markerLength)
                )
            }
            // 行内认领（围栏内代码行不做行内解析——代码里 * _ 是字面量）
            switch block.kind {
            case .fenceMarker, .codeLine:
                continue
            default:
                break
            }
            let contentBase = block.range.location + block.markerLength
            let contentLength = block.range.length - block.markerLength
            guard contentLength > 0, contentBase + contentLength <= ns.length else { continue }
            let content = ns.substring(with: NSRange(location: contentBase, length: contentLength))
            for span in inlineSpans(in: content, baseLocation: contentBase) {
                switch span.kind {
                case .code:
                    out.addAttributes([.font: codeFont, .backgroundColor: codeBackgroundColor],
                                      range: span.range)
                case .link:
                    out.addAttributes([
                        .foregroundColor: accentColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ], range: span.range)
                case .bold:
                    if let f = out.attribute(.font, at: span.range.location, effectiveRange: nil) as? NSFont {
                        out.addAttribute(
                            .font,
                            value: NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask),
                            range: span.range
                        )
                    }
                case .italic:
                    if let f = out.attribute(.font, at: span.range.location, effectiveRange: nil) as? NSFont {
                        out.addAttribute(.font, value: italicFont(of: f), range: span.range)
                    }
                case .strike:
                    out.addAttribute(
                        .strikethroughStyle,
                        value: NSUnderlineStyle.single.rawValue,
                        range: span.range
                    )
                }
            }
        }
        return out
    }

    // MARK: - 打字属性（新输入字符继承当前块基样式）

    /// 光标处打字属性：所在行块的基样式（行内样式不延续——粗体打完回车新行回正文，
    /// Typora 同款语义）。尾随 \n 后的空行（无 span）按围栏闭合态裁决：围栏未闭合
    /// 续代码样式，否则回正文。
    static func typingAttributes(for source: String, cursorLocation: Int) -> [NSAttributedString.Key: Any] {
        let ns = source as NSString
        guard ns.length > 0 else { return baseAttributes() }
        let clamped = min(max(cursorLocation, 0), ns.length)
        // 光标所在行：行首 = 前一个 \n 之后；行内容 = 行首到下一个 \n
        let head = ns.substring(with: NSRange(location: 0, length: clamped))
        let lastNL = (head as NSString).range(of: "\n", options: .backwards)
        let lineStart = lastNL.location == NSNotFound ? 0 : NSMaxRange(lastNL)
        guard lineStart <= ns.length else { return baseAttributes() }
        let rest = ns.substring(from: lineStart)
        let nlInRest = (rest as NSString).range(of: "\n")
        let lineContent = nlInRest.location == NSNotFound ? rest : (rest as NSString).substring(to: nlInRest.location)

        // 每个真实行恰有一个 span；尾随 \n 后的幻影空行没有 span
        guard let span = blockSpans(for: source).first(where: { NSLocationInRange(lineStart, $0.range) }) else {
            return isFenceOpen(atEndOf: source) ? codeAttributes() : baseAttributes()
        }
        if lineContent.isEmpty {
            switch span.kind {
            case .codeLine, .fenceMarker: return codeAttributes()
            default: return baseAttributes()
            }
        }
        if let level = headingLevel(ofLine: lineContent) {
            return [
                .font: headingFont(level: level),
                .foregroundColor: level <= 3 ? accentColor : textColor
            ]
        }
        if quoteMarkerLength(ofLine: lineContent) > 0 {
            return [.font: italicFont(of: baseFont), .foregroundColor: dimColor]
        }
        switch span.kind {
        case .codeLine, .fenceMarker: return codeAttributes()
        default: return baseAttributes()
        }
    }
}
