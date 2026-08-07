import AppKit

/// 将 Markdown 源码着色为 NSAttributedString。
enum MarkdownHighlighter {
    static let bodyFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)

    private static let headingColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.72, green: 0.58, blue: 0.95, alpha: 1)
            : NSColor(calibratedRed: 0.45, green: 0.28, blue: 0.72, alpha: 1)
    }

    private static let codeColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.55, alpha: 1)
            : NSColor(calibratedRed: 0.75, green: 0.22, blue: 0.30, alpha: 1)
    }

    private static let codeBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.18, alpha: 1)
            : NSColor(calibratedWhite: 0.96, alpha: 1)
    }

    private static let commentColor = NSColor.secondaryLabelColor
    private static let linkColor = NSColor.systemBlue
    private static let markerColor = NSColor.tertiaryLabelColor

    static func highlight(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: bodyFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle()
            ]
        )

        apply(pattern: "```[\\s\\S]*?```", options: [], in: text, to: result) { attrs in
            attrs[.font] = bodyFont
            attrs[.foregroundColor] = codeColor
            attrs[.backgroundColor] = codeBackground
        }

        apply(pattern: "^#{1,6} .+$", in: text, to: result) { attrs in
            attrs[.foregroundColor] = headingColor
            attrs[.font] = NSFont.monospacedSystemFont(ofSize: 15, weight: .semibold)
        }

        apply(pattern: "`[^`\\n]+`", options: [], in: text, to: result) { attrs in
            attrs[.foregroundColor] = codeColor
        }

        apply(pattern: "^(\\s*[-*+] |\\s*\\d+\\. |\\s*- \\[[ xX]\\] )", in: text, to: result) { attrs in
            attrs[.foregroundColor] = markerColor
        }

        apply(pattern: "^> .+$", in: text, to: result) { attrs in
            attrs[.foregroundColor] = commentColor
        }

        // 链接最后上色，避免被引用/列表样式盖住；代码区内再清掉可点击
        applyBareURLs(in: text, to: result)
        applyMarkdownLinks(in: text, to: result)
        restyleCode(in: text, to: result)
        // 颜色 span 的所见即所得展开在 MarkdownTextView 中处理（隐藏标签）

        return result
    }

    private static func restyleCode(in text: String, to result: NSMutableAttributedString) {
        apply(pattern: "```[\\s\\S]*?```", options: [], in: text, to: result) { attrs in
            attrs[.font] = bodyFont
            attrs[.foregroundColor] = codeColor
            attrs[.backgroundColor] = codeBackground
        }
        removeLinks(matching: "```[\\s\\S]*?```", options: [], in: text, from: result)

        apply(pattern: "`[^`\\n]+`", options: [], in: text, to: result) { attrs in
            attrs[.foregroundColor] = codeColor
        }
        removeLinks(matching: "`[^`\\n]+`", options: [], in: text, from: result)
    }

    private static func applyBareURLs(in text: String, to result: NSMutableAttributedString) {
        guard let regex = try? NSRegularExpression(pattern: MarkdownAutolink.pattern) else { return }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        regex.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
            guard let match else { return }
            let raw = ns.substring(with: match.range)
            let (urlString, trimmed) = MarkdownAutolink.trimTrailingPunctuation(raw)
            let range = NSRange(location: match.range.location, length: match.range.length - trimmed)
            guard range.length > 0, let url = URL(string: urlString) else { return }
            result.addAttributes(
                [
                    .foregroundColor: linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .link: url
                ],
                range: range
            )
        }
    }

    private static func applyMarkdownLinks(in text: String, to result: NSMutableAttributedString) {
        guard let regex = try? NSRegularExpression(pattern: #"\[([^\]]*)\]\(([^)]+)\)"#) else { return }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        regex.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
            guard let match, match.numberOfRanges >= 3 else { return }
            // 图片语法 `![](...)` 留给附件处理，这里跳过
            if match.range.location > 0,
               ns.character(at: match.range.location - 1) == 33 /* ! */ {
                return
            }
            result.addAttributes(
                [
                    .foregroundColor: linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ],
                range: match.range
            )
            let target = ns.substring(with: match.range(at: 2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: target),
               let scheme = url.scheme?.lowercased(),
               ["http", "https", "mailto", ChildNoteMarkerSupport.scheme, WPSLinkSupport.scheme].contains(scheme) {
                result.addAttribute(.link, value: url, range: match.range)
                if scheme == ChildNoteMarkerSupport.scheme {
                    result.addAttributes(
                        [
                            .foregroundColor: NSColor.systemGreen,
                            .cursor: NSCursor.pointingHand
                        ],
                        range: match.range
                    )
                } else if scheme == WPSLinkSupport.scheme {
                    result.addAttributes(
                        [
                            .foregroundColor: NSColor.systemBlue,
                            .cursor: NSCursor.pointingHand
                        ],
                        range: match.range
                    )
                }
            }
        }
    }

    private static func removeLinks(
        matching pattern: String,
        options: NSRegularExpression.Options,
        in text: String,
        from result: NSMutableAttributedString
    ) {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        regex.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
            guard let match else { return }
            result.removeAttribute(.link, range: match.range)
            result.removeAttribute(.underlineStyle, range: match.range)
        }
    }

    private static func paragraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        style.paragraphSpacing = 2
        return style
    }

    private static func apply(
        pattern: String,
        options: NSRegularExpression.Options = [.anchorsMatchLines],
        in text: String,
        to result: NSMutableAttributedString,
        update: (inout [NSAttributedString.Key: Any]) -> Void
    ) {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        regex.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
            guard let match else { return }
            var attrs = result.attributes(at: match.range.location, effectiveRange: nil)
            update(&attrs)
            result.addAttributes(attrs, range: match.range)
        }
    }
}
