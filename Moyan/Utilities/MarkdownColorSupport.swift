import AppKit
import Foundation

extension NSAttributedString.Key {
    /// 编辑区隐藏 span 标签后，用该属性记住色值以便写回 Markdown。
    static let moyanTextStyle = NSAttributedString.Key("moyanTextStyle")
}

/// 附着在所见即所得文字上的颜色信息（磁盘仍存 `<span style>`）。
final class MoyanTextStyleBox: NSObject {
    let foreground: String?
    let background: String?

    init(foreground: String?, background: String?) {
        self.foreground = foreground
        self.background = background
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? MoyanTextStyleBox else { return false }
        return foreground == other.foreground && background == other.background
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(foreground)
        hasher.combine(background)
        return hasher.finalize()
    }
}

/// 选区文字色 / 背景色：用可控的 `<span style="...">` 写入 Markdown。
enum MarkdownColorSupport {
    struct PaletteColor: Identifiable, Hashable {
        let id: String
        let hex: String
        let label: String

        var nsColor: NSColor {
            NSColor(hex: hex) ?? .labelColor
        }
    }

    /// 字体颜色（参考常见文档工具条）。
    static let foregroundColors: [PaletteColor] = [
        .init(id: "fg-black", hex: "#1F2328", label: "黑色"),
        .init(id: "fg-gray", hex: "#8B949E", label: "灰色"),
        .init(id: "fg-red", hex: "#E53935", label: "红色"),
        .init(id: "fg-orange", hex: "#FB8C00", label: "橙色"),
        .init(id: "fg-yellow", hex: "#F9A825", label: "黄色"),
        .init(id: "fg-green", hex: "#43A047", label: "绿色"),
        .init(id: "fg-blue", hex: "#1E88E5", label: "蓝色"),
        .init(id: "fg-purple", hex: "#8E24AA", label: "紫色")
    ]

    /// 浅色背景。
    static let backgroundLightColors: [PaletteColor] = [
        .init(id: "bg-l-gray", hex: "#F0F0F0", label: "浅灰"),
        .init(id: "bg-l-red", hex: "#FFCDD2", label: "浅红"),
        .init(id: "bg-l-orange", hex: "#FFE0B2", label: "浅橙"),
        .init(id: "bg-l-yellow", hex: "#FFF9C4", label: "浅黄"),
        .init(id: "bg-l-green", hex: "#C8E6C9", label: "浅绿"),
        .init(id: "bg-l-blue", hex: "#BBDEFB", label: "浅蓝"),
        .init(id: "bg-l-purple", hex: "#E1BEE7", label: "浅紫")
    ]

    /// 实色背景。
    static let backgroundSolidColors: [PaletteColor] = [
        .init(id: "bg-gray", hex: "#BDBDBD", label: "灰色"),
        .init(id: "bg-dark", hex: "#757575", label: "深灰"),
        .init(id: "bg-red", hex: "#EF5350", label: "红色"),
        .init(id: "bg-orange", hex: "#FFA726", label: "橙色"),
        .init(id: "bg-yellow", hex: "#FFEE58", label: "黄色"),
        .init(id: "bg-green", hex: "#66BB6A", label: "绿色"),
        .init(id: "bg-blue", hex: "#42A5F5", label: "蓝色"),
        .init(id: "bg-purple", hex: "#AB47BC", label: "紫色")
    ]

    static let spanRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"<span\s+style=\"([^\"]*)\">([\s\S]*?)</span>"#,
            options: [.caseInsensitive]
        )
    }()

    /// 去掉 span，保留正文。
    static func stripSpans(_ text: String) -> String {
        var current = text
        for _ in 0..<8 {
            let ns = current as NSString
            let full = NSRange(location: 0, length: ns.length)
            let matches = spanRegex.matches(in: current, options: [], range: full)
            if matches.isEmpty { break }
            let mutable = NSMutableString(string: current)
            for match in matches.reversed() where match.numberOfRanges >= 3 {
                let inner = ns.substring(with: match.range(at: 2))
                mutable.replaceCharacters(in: match.range, with: inner)
            }
            current = mutable as String
        }
        return current
    }

    /// 解析 style 属性里的 color / background-color（仅 #RGB / #RRGGBB）。
    static func parseStyle(_ style: String) -> (fg: String?, bg: String?) {
        var fg: String?
        var bg: String?
        let parts = style.split(separator: ";").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for part in parts {
            let kv = part.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard kv.count == 2 else { continue }
            let key = kv[0].lowercased()
            guard let hex = normalizeHex(String(kv[1])) else { continue }
            if key == "color" { fg = hex }
            if key == "background-color" || key == "background" { bg = hex }
        }
        return (fg, bg)
    }

    static func normalizeHex(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("\"") || s.hasPrefix("'") { s.removeFirst() }
        if s.hasSuffix("\"") || s.hasSuffix("'") { s.removeLast() }
        if !s.hasPrefix("#") { s = "#" + s }
        let body = String(s.dropFirst())
        guard body.count == 6 || body.count == 3,
              body.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
            return nil
        }
        if body.count == 3 {
            let chars = Array(body)
            return "#\(chars[0])\(chars[0])\(chars[1])\(chars[1])\(chars[2])\(chars[2])".uppercased()
        }
        return "#\(body.uppercased())"
    }

    static func wrap(_ text: String, foreground: String?, background: String?) -> String {
        let inner = stripSpans(text)
        var parts: [String] = []
        if let fg = foreground.flatMap(normalizeHex) {
            parts.append("color: \(fg)")
        }
        if let bg = background.flatMap(normalizeHex) {
            parts.append("background-color: \(bg)")
        }
        guard !parts.isEmpty else { return inner }
        return "<span style=\"\(parts.joined(separator: "; "))\">\(inner)</span>"
    }

    /// 在现有样式上更新文字色或背景色；传 `Optional.some(nil)` 表示清除该项。
    static func updateStyle(
        _ text: String,
        foreground: String?? = nil,
        background: String?? = nil
    ) -> String {
        let existing = extractOuterStyle(text)
        let inner = stripSpans(text)
        let fg: String? = {
            if let override = foreground { return override }
            return existing.fg
        }()
        let bg: String? = {
            if let override = background { return override }
            return existing.bg
        }()
        return wrap(inner, foreground: fg, background: bg)
    }

    private static func extractOuterStyle(_ text: String) -> (fg: String?, bg: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = trimmed as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = spanRegex.firstMatch(in: trimmed, options: [], range: full),
              match.numberOfRanges >= 3,
              match.range.location == 0,
              NSMaxRange(match.range) == ns.length else {
            return (nil, nil)
        }
        return parseStyle(ns.substring(with: match.range(at: 1)))
    }

    /// 所见即所得：去掉 `<span>` 标签，只保留着色正文。
    static func embedStyledText(in attributed: NSMutableAttributedString) {
        for _ in 0..<12 {
            let text = attributed.string
            let ns = text as NSString
            let full = NSRange(location: 0, length: ns.length)
            let matches = spanRegex.matches(in: text, options: [], range: full)
            if matches.isEmpty { break }

            // 先处理最短匹配，尽量展开嵌套
            let ordered = matches.sorted { $0.range.length < $1.range.length }
            guard let match = ordered.first, match.numberOfRanges >= 3 else { break }

            let style = ns.substring(with: match.range(at: 1))
            let (fgHex, bgHex) = parseStyle(style)
            guard fgHex != nil || bgHex != nil else {
                // 非法 style：剥掉标签留正文
                let inner = ns.substring(with: match.range(at: 2))
                attributed.replaceCharacters(in: match.range, with: inner)
                continue
            }

            let inner = ns.substring(with: match.range(at: 2))
            let box = MoyanTextStyleBox(foreground: fgHex, background: bgHex)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: MarkdownHighlighter.bodyFont,
                .foregroundColor: NSColor.labelColor,
                .moyanTextStyle: box,
                .paragraphStyle: {
                    let style = NSMutableParagraphStyle()
                    style.lineSpacing = 4
                    style.paragraphSpacing = 2
                    return style
                }()
            ]
            if let fgHex, let color = NSColor(hex: fgHex) {
                attrs[.foregroundColor] = color
            }
            if let bgHex, let color = NSColor(hex: bgHex) {
                attrs[.backgroundColor] = color
            }
            let replacement = NSAttributedString(string: inner, attributes: attrs)
            attributed.replaceCharacters(in: match.range, with: replacement)
        }
    }

    /// 把带 `moyanTextStyle` 的连续文字还原为 `<span style>`。
    static func appendSerializedStyleRuns(
        from attributed: NSAttributedString,
        start index: inout Int,
        into out: NSMutableString
    ) -> Bool {
        var effective = NSRange()
        guard let box = attributed.attribute(.moyanTextStyle, at: index, effectiveRange: &effective)
            as? MoyanTextStyleBox else { return false }

        var end = NSMaxRange(effective)
        while end < attributed.length {
            var next = NSRange()
            guard let other = attributed.attribute(.moyanTextStyle, at: end, effectiveRange: &next)
                as? MoyanTextStyleBox,
                  other.isEqual(box) else { break }
            end = NSMaxRange(next)
        }

        let inner = (attributed.string as NSString).substring(
            with: NSRange(location: index, length: end - index)
        )
        out.append(wrap(inner, foreground: box.foreground, background: box.background))
        index = end
        return true
    }

    /// 光标处继承颜色，保证继续输入仍是所见即所得。
    static func typingAttributes(at location: Int, in storage: NSTextStorage) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: MarkdownHighlighter.bodyFont,
            .foregroundColor: NSColor.labelColor
        ]
        guard storage.length > 0 else { return attrs }
        let idx = min(max(location, 0), storage.length - 1)
        // 优先看光标左侧，便于在色块末尾续写
        let probe = location > 0 ? min(location - 1, storage.length - 1) : idx
        if let box = storage.attribute(.moyanTextStyle, at: probe, effectiveRange: nil) as? MoyanTextStyleBox {
            attrs[.moyanTextStyle] = box
            if let fg = box.foreground, let color = NSColor(hex: fg) {
                attrs[.foregroundColor] = color
            }
            if let bg = box.background, let color = NSColor(hex: bg) {
                attrs[.backgroundColor] = color
            }
        }
        return attrs
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        self.init(calibratedRed: r, green: g, blue: b, alpha: 1)
    }
}
