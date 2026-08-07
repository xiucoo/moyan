import AppKit
import Foundation

/// 链接展示形态（飞书式：链接 / 标题 / 卡片 / 预览）。
enum MoyanLinkView: String, CaseIterable, Identifiable {
    case link
    case title
    case card
    case preview

    var id: String { rawValue }

    var label: String {
        switch self {
        case .link: return "链接视图"
        case .title: return "标题视图"
        case .card: return "卡片视图"
        case .preview: return "预览视图"
        }
    }

    var systemImage: String {
        switch self {
        case .link: return "link"
        case .title: return "text.alignleft"
        case .card: return "rectangle.on.rectangle"
        case .preview: return "desktopcomputer"
        }
    }
}

/// 笔记中一处可切换视图的链接。
struct MoyanDetectedLink {
    var view: MoyanLinkView
    var url: String
    var title: String
    var desc: String
    var image: String
    /// 在当前 NSTextView.string（含附件占位符）中的范围。
    var range: NSRange

    var host: String {
        URL(string: url)?.host ?? url
    }

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? host : t
    }
}

/// 链接块：编辑区为可直接改的文本；卡片/预览用 `:::moyan-card` 围栏（非附件）。
enum MarkdownLinkEmbed {
    /// 旧格式兼容：`{{moyan-link|card|url|title|desc|image}}`
    static let blockRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\{\{moyan-link\|(link|title|card|preview)\|([^|}]+)\|([^|]*)\|([^|]*)\|([^|]*)\}\}"#,
            options: []
        )
    }()

    /// 新格式（可编辑）：
    /// :::moyan-card
    /// url: …
    /// title: …
    /// desc: …
    /// image: …
    /// :::
    static let fenceRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"(?m)^:::moyan-(card|preview)[ \t]*\n([\s\S]*?)^:::[ \t]*$"#,
            options: []
        )
    }()

    static func serialize(
        view: MoyanLinkView,
        url: String,
        title: String = "",
        desc: String = "",
        image: String = ""
    ) -> String {
        switch view {
        case .link:
            return url
        case .title:
            let label = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? url
                : title.trimmingCharacters(in: .whitespacesAndNewlines)
            return "[\(escapeMarkdownLabel(label))](\(url))"
        case .card:
            return """
            :::moyan-card
            url: \(url)
            title: \(title)
            desc: \(desc)
            image: \(image)
            :::
            """
        case .preview:
            return """
            :::moyan-preview
            url: \(url)
            :::
            """
        }
    }

    static func encode(_ value: String) -> String {
        value
            .replacingOccurrences(of: "|", with: "%7C")
            .replacingOccurrences(of: "}", with: "%7D")
            .replacingOccurrences(of: "\n", with: " ")
    }

    static func decode(_ value: String) -> String {
        value
            .replacingOccurrences(of: "%7C", with: "|")
            .replacingOccurrences(of: "%7D", with: "}")
            .replacingOccurrences(of: "%7c", with: "|")
            .replacingOccurrences(of: "%7d", with: "}")
    }

    private static func escapeMarkdownLabel(_ text: String) -> String {
        text
            .replacingOccurrences(of: "[", with: "［")
            .replacingOccurrences(of: "]", with: "］")
    }

    /// 在字符索引处识别链接（裸 URL / Markdown 链接 / 可编辑围栏 / 旧块）。
    static func detect(in textView: NSTextView, at index: Int) -> MoyanDetectedLink? {
        guard let storage = textView.textStorage, storage.length > 0 else { return nil }
        let idx = max(0, min(index, storage.length - 1))
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)

        // 可编辑围栏 :::moyan-card / :::moyan-preview
        for match in fenceRegex.matches(in: storage.string, options: [], range: full)
        where NSLocationInRange(idx, match.range) {
            if let parsed = parseFenceMatch(match, in: ns) { return parsed }
        }

        // 旧单行块
        let blocks = blockRegex.matches(in: storage.string, options: [], range: full)
        for match in blocks where NSLocationInRange(idx, match.range) {
            return parseBlockMatch(match, in: ns)
        }

        // [text](url)
        if let md = detectMarkdownLink(in: ns, at: idx) {
            return md
        }

        // 裸 URL
        if let bare = detectBareURL(in: ns, at: idx) {
            return bare
        }
        return nil
    }

    private static func parseBlockMatch(_ match: NSTextCheckingResult, in ns: NSString) -> MoyanDetectedLink? {
        guard match.numberOfRanges >= 6,
              let view = MoyanLinkView(rawValue: ns.substring(with: match.range(at: 1))) else { return nil }
        return MoyanDetectedLink(
            view: view,
            url: decode(ns.substring(with: match.range(at: 2))),
            title: decode(ns.substring(with: match.range(at: 3))),
            desc: decode(ns.substring(with: match.range(at: 4))),
            image: decode(ns.substring(with: match.range(at: 5))),
            range: match.range
        )
    }

    private static func parseFenceMatch(_ match: NSTextCheckingResult, in ns: NSString) -> MoyanDetectedLink? {
        guard match.numberOfRanges >= 3 else { return nil }
        let kind = ns.substring(with: match.range(at: 1)).lowercased()
        let view: MoyanLinkView = kind == "preview" ? .preview : .card
        let body = ns.substring(with: match.range(at: 2))
        var url = ""
        var title = ""
        var desc = ""
        var image = ""
        for rawLine in body.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.lowercased().hasPrefix("url:") {
                url = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            } else if line.lowercased().hasPrefix("title:") {
                title = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.lowercased().hasPrefix("desc:") {
                desc = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if line.lowercased().hasPrefix("image:") {
                image = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if url.isEmpty, line.hasPrefix("http://") || line.hasPrefix("https://") {
                url = line
            }
        }
        guard !url.isEmpty else { return nil }
        return MoyanDetectedLink(
            view: view,
            url: url,
            title: title,
            desc: desc,
            image: image,
            range: match.range
        )
    }

    private static func detectMarkdownLink(in ns: NSString, at index: Int) -> MoyanDetectedLink? {
        guard let regex = try? NSRegularExpression(pattern: #"\[([^\]]*)\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)"#) else {
            return nil
        }
        let full = NSRange(location: 0, length: ns.length)
        for match in regex.matches(in: ns as String, options: [], range: full)
        where NSLocationInRange(index, match.range) {
            // 跳过图片 `![](...)`
            if match.range.location > 0, ns.character(at: match.range.location - 1) == 33 {
                continue
            }
            let label = ns.substring(with: match.range(at: 1))
            let url = ns.substring(with: match.range(at: 2))
            guard url.hasPrefix("http://") || url.hasPrefix("https://") else { continue }
            let view: MoyanLinkView = (label == url || label.isEmpty) ? .link : .title
            return MoyanDetectedLink(
                view: view,
                url: url,
                title: label == url ? "" : label,
                desc: "",
                image: "",
                range: match.range
            )
        }
        return nil
    }

    private static func detectBareURL(in ns: NSString, at index: Int) -> MoyanDetectedLink? {
        guard let regex = try? NSRegularExpression(pattern: MarkdownAutolink.pattern) else { return nil }
        let full = NSRange(location: 0, length: ns.length)
        for match in regex.matches(in: ns as String, options: [], range: full)
        where NSLocationInRange(index, match.range) {
            let raw = ns.substring(with: match.range)
            let (url, trimmed) = MarkdownAutolink.trimTrailingPunctuation(raw)
            let range = NSRange(location: match.range.location, length: match.range.length - trimmed)
            guard range.length > 0 else { continue }
            return MoyanDetectedLink(
                view: .link,
                url: url,
                title: "",
                desc: "",
                image: "",
                range: range
            )
        }
        return nil
    }

    /// 已废弃：卡片/预览不再转成附件，编辑区保留可改文本。
    static func embedAttachments(in attributed: NSMutableAttributedString) {
        // no-op：可编辑源码优先
    }

    /// 给围栏块上浅色底，提示可直接改字段。
    static func highlightEditableBlocks(in attributed: NSMutableAttributedString) {
        let text = attributed.string
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let bg = NSColor.controlAccentColor.withAlphaComponent(0.08)
        for match in fenceRegex.matches(in: text, options: [], range: full) {
            attributed.addAttributes([
                .backgroundColor: bg,
                .foregroundColor: NSColor.labelColor
            ], range: match.range)
        }
        for match in blockRegex.matches(in: text, options: [], range: full) {
            attributed.addAttributes([
                .backgroundColor: bg,
                .foregroundColor: NSColor.secondaryLabelColor
            ], range: match.range)
        }
    }

    /// 预览 HTML：块级卡片 / iframe。
    static func html(for info: MoyanDetectedLink) -> String {
        let url = escapeHTML(info.url)
        let title = escapeHTML(info.displayTitle)
        let desc = escapeHTML(info.desc)
        let host = escapeHTML(info.host)
        switch info.view {
        case .link:
            return "<a href=\"\(url)\">\(url)</a>"
        case .title:
            return "<a href=\"\(url)\">\(title)</a>"
        case .card:
            let img: String = {
                let raw = info.image.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { return "" }
                return "<img class=\"moyan-card-thumb\" src=\"\(escapeHTML(raw))\" alt=\"\"/>"
            }()
            return """
            <a class="moyan-link-card" href="\(url)" target="_blank" rel="noopener">
              <div class="moyan-card-body">
                <div class="moyan-card-title">\(title)</div>
                \(desc.isEmpty ? "" : "<div class=\"moyan-card-desc\">\(desc)</div>")
                <div class="moyan-card-host">\(host)</div>
              </div>
              \(img)
            </a>
            """
        case .preview:
            return """
            <div class="moyan-link-preview">
              <div class="moyan-preview-bar">
                <a href="\(url)" target="_blank" rel="noopener">\(host)</a>
              </div>
              <iframe src="\(url)" loading="lazy" referrerpolicy="no-referrer" sandbox="allow-scripts allow-same-origin allow-popups allow-forms"></iframe>
            </div>
            """
        }
    }

    static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// 抓取网页标题 / 摘要 / 封面（失败时用主机名兜底）。
    static func fetchMetadata(for urlString: String) async -> (title: String, desc: String, image: String) {
        guard let url = URL(string: urlString) else {
            return (urlString, "", "")
        }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Moyan/1.0",
            forHTTPHeaderField: "User-Agent"
        )
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let host = url.host ?? urlString
            guard let http = response as? HTTPURLResponse, (200...399).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else {
                return (host, "", "")
            }
            let title = firstMatch(html, patterns: [
                #"<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)["']"#,
                #"<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:title["']"#,
                #"<title[^>]*>([^<]+)</title>"#
            ]) ?? host
            let desc = firstMatch(html, patterns: [
                #"<meta[^>]+property=["']og:description["'][^>]+content=["']([^"']+)["']"#,
                #"<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:description["']"#,
                #"<meta[^>]+name=["']description["'][^>]+content=["']([^"']+)["']"#
            ]) ?? ""
            var image = firstMatch(html, patterns: [
                #"<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']"#,
                #"<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']"#
            ]) ?? ""
            if !image.isEmpty, let base = URL(string: urlString), let abs = URL(string: image, relativeTo: base) {
                image = abs.absoluteString
            }
            return (
                decodeHTMLEntities(title.trimmingCharacters(in: .whitespacesAndNewlines)),
                decodeHTMLEntities(desc.trimmingCharacters(in: .whitespacesAndNewlines)),
                image.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch {
            return (url.host ?? urlString, "", "")
        }
    }

    private static func firstMatch(_ html: String, patterns: [String]) -> String? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let ns = html as NSString
            let full = NSRange(location: 0, length: min(ns.length, 500_000))
            if let match = regex.firstMatch(in: html, options: [], range: full),
               match.numberOfRanges >= 2 {
                return ns.substring(with: match.range(at: 1))
            }
        }
        return nil
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        guard let data = text.data(using: .utf8) else { return text }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        if let attr = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
            return attr.string
        }
        return text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}

/// 编辑区卡片 / 预览占位附件。
final class MoyanLinkAttachment: NSTextAttachment {
    let view: MoyanLinkView
    let url: String
    let title: String
    let desc: String
    let imageURL: String

    var serialized: String {
        MarkdownLinkEmbed.serialize(
            view: view,
            url: url,
            title: title,
            desc: desc,
            image: imageURL
        )
    }

    init(view: MoyanLinkView, url: String, title: String, desc: String, imageURL: String) {
        self.view = view
        self.url = url
        self.title = title
        self.desc = desc
        self.imageURL = imageURL
        super.init(data: nil, ofType: nil)
        let image = view == .preview
            ? Self.renderPreview(url: url, title: title)
            : Self.renderCard(url: url, title: title, desc: desc)
        self.image = image
        bounds = CGRect(origin: .zero, size: image.size)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func renderCard(url: String, title: String, desc: String) -> NSImage {
        let width: CGFloat = 360
        let height: CGFloat = desc.isEmpty ? 72 : 96
        let host = URL(string: url)?.host ?? url
        let titleText = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? host : title
        return NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let bg = NSColor.controlBackgroundColor
            bg.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
            NSColor.separatorColor.setStroke()
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
            border.lineWidth = 1
            border.stroke()

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
            let descAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let hostAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]

            let titleRect = CGRect(x: 14, y: height - 28, width: width - 28, height: 18)
            (titleText as NSString).draw(
                with: titleRect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: titleAttrs
            )
            if !desc.isEmpty {
                let descRect = CGRect(x: 14, y: 28, width: width - 28, height: 32)
                (desc as NSString).draw(
                    with: descRect,
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                    attributes: descAttrs
                )
            }
            let hostRect = CGRect(x: 14, y: 10, width: width - 28, height: 14)
            (host as NSString).draw(with: hostRect, options: [.usesLineFragmentOrigin], attributes: hostAttrs)
            return true
        }
    }

    private static func renderPreview(url: String, title: String) -> NSImage {
        let width: CGFloat = 420
        let height: CGFloat = 160
        let host = URL(string: url)?.host ?? url
        let label = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? host : title
        return NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
            NSColor.separatorColor.setStroke()
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
            border.lineWidth = 1
            border.stroke()

            let bar = CGRect(x: 2, y: height - 28, width: width - 4, height: 26)
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(rect: bar).fill()

            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            (host as NSString).draw(at: CGPoint(x: 12, y: height - 22), withAttributes: attrs)

            let centerAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]
            let tip = "网页预览（预览模式可见）\n\(label)" as NSString
            let tipSize = tip.size(withAttributes: centerAttrs)
            tip.draw(
                at: CGPoint(x: (width - tipSize.width) / 2, y: (height - tipSize.height) / 2 - 4),
                withAttributes: centerAttrs
            )
            return true
        }
    }
}
