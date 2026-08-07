import AppKit
import Foundation

/// 父笔记任务行上的「📎子文件」标记：高亮为可点链接，点击跳转子笔记。
enum ChildNoteMarkerSupport {
    static let scheme = "moyan-child"
    /// 正文里的可见标记（与创建子任务时写入的文案一致）。
    static let markerText = "📎子文件"
    static let markerSuffix = " · 📎子文件"
    /// 写入子文件正文的隐藏标记（历史兼容；新子文件不再写入）。
    private static let parentCommentRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"<!--\s*moyan-parent:\s*([0-9A-Fa-f-]{36})\s*-->"#,
            options: [.caseInsensitive]
        )
    }()
    /// 含前后空白行的整段注释，便于一次性删干净。
    private static let parentCommentLineRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"(?m)^[ \t]*<!--\s*moyan-parent:\s*[0-9A-Fa-f-]{36}\s*-->[ \t]*\n?"#,
            options: [.caseInsensitive]
        )
    }()

    static func childNoteURL(id: UUID) -> URL {
        URL(string: "\(scheme)://\(id.uuidString)")!
    }

    static func childNoteID(from link: Any) -> UUID? {
        if let url = link as? URL {
            return id(from: url)
        }
        if let string = link as? String, let url = URL(string: string) {
            return id(from: url)
        }
        return nil
    }

    /// 比较任务文案时忽略空白与 HTML 着色标签，避免 `adx<span>…</span>` 对不上 `adx 流量控制`。
    static func normalizedTaskKey(_ text: String) -> String {
        let plain = MarkdownColorSupport.stripSpans(text)
        return MarkdownListContinuation.strippedTaskText(plain)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .lowercased()
    }

    /// 两段任务文案是否指向同一任务（忽略空白 / span）。
    static func tasksMatch(_ lhs: String, _ rhs: String) -> Bool {
        let a = normalizedTaskKey(lhs)
        let b = normalizedTaskKey(rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b
    }

    /// 父正文里是否包含该任务（先剥 span，再按规范化 key 子串匹配）。
    static func content(_ content: String, mentionsTask task: String) -> Bool {
        let key = normalizedTaskKey(task)
        guard !key.isEmpty else { return false }
        return normalizedTaskKey(content).contains(key)
    }

    /// 子文件正文里的隐藏父笔记标记。
    static func parentComment(parentID: UUID) -> String {
        "<!-- moyan-parent: \(parentID.uuidString) -->"
    }

    /// 从子文件正文解析父笔记 ID（隐藏注释；仅兼容旧文件）。
    static func parentNoteID(fromContent content: String) -> UUID? {
        let ns = content as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = parentCommentRegex.firstMatch(in: content, options: [], range: full),
              match.numberOfRanges >= 2 else { return nil }
        return UUID(uuidString: ns.substring(with: match.range(at: 1)))
    }

    /// 去掉正文中的 `<!-- moyan-parent: … -->`（关联改由 meta 的 parentNoteID 维护）。
    static func removingParentComment(from content: String) -> String {
        let ns = content as NSString
        let full = NSRange(location: 0, length: ns.length)
        var cleaned = parentCommentLineRegex.stringByReplacingMatches(
            in: content,
            options: [],
            range: full,
            withTemplate: ""
        )
        // 兜底：行内残留
        let again = cleaned as NSString
        cleaned = parentCommentRegex.stringByReplacingMatches(
            in: cleaned,
            options: [],
            range: NSRange(location: 0, length: again.length),
            withTemplate: ""
        )
        while cleaned.contains("\n\n\n") {
            cleaned = cleaned.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return cleaned
    }

    /// 旧逻辑：保证子文件带隐藏父标记。新版本不再写入，仅保留 API 以免外部调用崩。
    @available(*, deprecated, message: "父子关联改由 meta.parentNoteID 维护，请用 removingParentComment")
    static func ensuringParentComment(in content: String, parentID: UUID) -> String {
        removingParentComment(from: content)
    }

    private static func id(from url: URL) -> UUID? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let host = url.host ?? ""
        if let id = UUID(uuidString: host) { return id }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let id = UUID(uuidString: path) { return id }
        let stripped = url.absoluteString
            .replacingOccurrences(of: "\(scheme)://", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return UUID(uuidString: stripped)
    }

    /// 在可见正文上为「📎子文件」挂上 `moyan-child://` 链接，供单击跳转。
    static func embedClickableMarkers(
        in attributed: NSMutableAttributedString,
        resolve: (String) -> UUID?
    ) {
        let text = attributed.string as NSString
        guard text.length > 0 else { return }

        // 1) `[📎子文件](moyan-child://UUID)` → 整段可点
        if let md = try? NSRegularExpression(
            pattern: #"\[📎子文件\]\(moyan-child://([^)]+)\)"#,
            options: [.caseInsensitive]
        ) {
            let matches = md.matches(
                in: attributed.string,
                options: [],
                range: NSRange(location: 0, length: text.length)
            )
            for match in matches.reversed() where match.numberOfRanges >= 2 {
                let idRaw = text.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let id = UUID(uuidString: idRaw) else { continue }
                // 连同前面的 ` · ` 一并扩大点击热区
                let clickRange = expandedMarkerRange(containing: match.range, in: text)
                applyLink(childNoteURL(id: id), to: clickRange, in: attributed)
            }
        }

        // 2) 纯文本 `📎子文件`
        guard let plain = try? NSRegularExpression(
            pattern: NSRegularExpression.escapedPattern(for: markerText)
        ) else { return }

        let matches = plain.matches(
            in: attributed.string,
            options: [],
            range: NSRange(location: 0, length: text.length)
        )
        for match in matches.reversed() {
            if attributed.attribute(.link, at: match.range.location, effectiveRange: nil) != nil {
                continue
            }
            let lineRange = text.lineRange(for: match.range)
            let rawLine = text.substring(with: lineRange)
            let line = rawLine.hasSuffix("\n") ? String(rawLine.dropLast()) : rawLine

            // 同行若已有 moyan-child://UUID，直接用（不依赖任务文案匹配）
            if let id = uuidInLine(line) {
                applyLink(childNoteURL(id: id), to: expandedMarkerRange(containing: match.range, in: text), in: attributed)
                continue
            }

            guard let item = MarkdownListContinuation.parse(line) else { continue }
            let task = item.taskText
            guard !task.isEmpty, let id = resolve(task) else { continue }
            applyLink(
                childNoteURL(id: id),
                to: expandedMarkerRange(containing: match.range, in: text),
                in: attributed
            )
        }
    }

    /// 从字符下标解析应打开的子笔记（链接属性 / 同行 UUID / 任务文案）。
    static func childNoteID(
        atCharacterIndex index: Int,
        in attributed: NSAttributedString,
        resolve: (String) -> UUID?
    ) -> UUID? {
        let storage = attributed
        guard storage.length > 0 else { return nil }
        let clamped = min(max(index, 0), storage.length - 1)

        if let link = storage.attribute(.link, at: clamped, effectiveRange: nil),
           let id = childNoteID(from: link) {
            return id
        }

        let ns = storage.string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: clamped, length: 0))
        let rawLine = ns.substring(with: lineRange)
        let line = rawLine.hasSuffix("\n") ? String(rawLine.dropLast()) : rawLine

        // 必须点在标记附近，避免点任务正文误跳
        guard line.contains(markerText) else { return nil }
        let markerRangeInLine: NSRange = {
            let full = NSRange(location: 0, length: (line as NSString).length)
            if let r = line.range(of: markerText) {
                let start = (line as NSString).range(of: markerText).location
                // 允许点在 ` · 📎子文件` 前缀上
                let expandedStart = max(0, start - 3)
                return NSRange(location: expandedStart, length: full.length - expandedStart)
            }
            return full
        }()
        let clickInLine = clamped - lineRange.location
        guard NSLocationInRange(clickInLine, markerRangeInLine) else { return nil }

        if let id = uuidInLine(line) { return id }
        guard let item = MarkdownListContinuation.parse(line) else { return nil }
        let task = item.taskText
        guard !task.isEmpty else { return nil }
        return resolve(task)
    }

    private static func uuidInLine(_ line: String) -> UUID? {
        guard let regex = try? NSRegularExpression(
            pattern: #"moyan-child://([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let ns = line as NSString
        guard let match = regex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2 else { return nil }
        return UUID(uuidString: ns.substring(with: match.range(at: 1)))
    }

    private static func expandedMarkerRange(containing range: NSRange, in text: NSString) -> NSRange {
        var start = range.location
        // 吃掉前面的 ` · ` / `• `
        while start > 0 {
            let ch = text.character(at: start - 1)
            if ch == 0x20 || ch == 0x00B7 || ch == 0x2022 || ch == 0x3000 { // space · • ideographic space
                start -= 1
            } else {
                break
            }
        }
        return NSRange(location: start, length: NSMaxRange(range) - start)
    }

    private static func applyLink(_ url: URL, to range: NSRange, in attributed: NSMutableAttributedString) {
        guard range.location != NSNotFound,
              range.length > 0,
              NSMaxRange(range) <= attributed.length else { return }
        attributed.addAttributes(
            [
                .link: url,
                .foregroundColor: NSColor.systemGreen,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .cursor: NSCursor.pointingHand
            ],
            range: range
        )
    }

    /// 预览用：把纯文本「📎子文件」升级为可点的 `moyan-child://` 链接。
    static func markdownWithResolvedLinks(
        _ content: String,
        resolve: (String) -> UUID?
    ) -> String {
        content.components(separatedBy: "\n").map { line in
            guard line.contains(markerText),
                  !line.contains("moyan-child://"),
                  let item = MarkdownListContinuation.parse(line) else { return line }
            let task = item.taskText
            guard !task.isEmpty, let id = resolve(task) else { return line }
            var base = line
            if let range = base.range(
                of: #"\s*[·•]\s*📎子文件"#,
                options: .regularExpression
            ) {
                base.replaceSubrange(range, with: " · [📎子文件](moyan-child://\(id.uuidString))")
                return base
            }
            return line
        }
        .joined(separator: "\n")
    }

    /// 写入 / 升级任务行标记为可带 UUID 的 markdown 链接（兼容旧纯文本标记）。
    /// - Note: 用剥 span 后的规范化文案匹配，避免父行着色后打不上标记。
    static func annotatingTaskLine(
        in content: String,
        taskText: String,
        childNoteID: UUID
    ) -> String {
        let cleaned = MarkdownListContinuation.strippedTaskText(taskText)
        let link = " · [📎子文件](moyan-child://\(childNoteID.uuidString))"
        let lines = content.components(separatedBy: "\n")
        var changed = false
        let updated = lines.map { line -> String in
            guard let item = MarkdownListContinuation.parse(line) else { return line }
            guard tasksMatch(item.taskText, cleaned) else { return line }

            changed = true
            var base = line
            if let range = base.range(
                of: #"\s*[·•]\s*\[?📎子文件\]?(?:\(moyan-child://[^)]+\))?"#,
                options: .regularExpression
            ) {
                base.removeSubrange(range)
            }
            return base + link
        }
        return changed ? updated.joined(separator: "\n") : content
    }
}
