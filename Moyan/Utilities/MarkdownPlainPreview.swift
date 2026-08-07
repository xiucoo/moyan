import Foundation

/// 画廊卡片用的 Markdown 摘要：把任务勾选、代码围栏、子文件链接等源语法收成可读行。
enum MarkdownPlainPreview {
    enum Line: Equatable {
        case heading(String)
        case task(done: Bool, text: String, depth: Int)
        case bullet(text: String, depth: Int)
        case numbered(index: String, text: String, depth: Int)
        case code(String)
        case body(String)
    }

    /// 解析正文为结构化预览行（已去掉标题 / 副标题 / 分隔线 / HTML 注释）。
    static func lines(from markdown: String, maxLines: Int = 14) -> [Line] {
        let plain = MarkdownColorSupport.stripSpans(markdown)
        var raw = plain.components(separatedBy: .newlines)
        stripLeadingMeta(&raw)

        var result: [Line] = []
        var index = 0
        var inFence = false
        var fenceBuffer: [String] = []

        while index < raw.count, result.count < maxLines {
            let rawLine = raw[index]
            index += 1
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inFence {
                    if let code = condensedCode(from: fenceBuffer) {
                        result.append(.code(code))
                    }
                    fenceBuffer.removeAll(keepingCapacity: true)
                    inFence = false
                } else {
                    inFence = true
                    fenceBuffer.removeAll(keepingCapacity: true)
                }
                continue
            }

            if inFence {
                if !trimmed.isEmpty { fenceBuffer.append(trimmed) }
                continue
            }

            if trimmed.isEmpty || trimmed == "---" { continue }
            if trimmed.hasPrefix("<!--") { continue }

            if let line = parseContentLine(rawLine) {
                result.append(line)
            }
        }

        // 未闭合围栏：仍给出摘要，避免卡片空白
        if inFence, result.count < maxLines, let code = condensedCode(from: fenceBuffer) {
            result.append(.code(code))
        }

        return result
    }

    /// 兼容只需字符串的场景。
    static func plainText(from markdown: String, maxLines: Int = 14) -> String {
        let mapped = lines(from: markdown, maxLines: maxLines).map { line -> String in
            switch line {
            case .heading(let t):
                return t
            case .task(let done, let t, let depth):
                return String(repeating: "  ", count: depth) + (done ? "☑ " : "☐ ") + t
            case .bullet(let t, let depth):
                return String(repeating: "  ", count: depth) + "• " + t
            case .numbered(let i, let t, let depth):
                return String(repeating: "  ", count: depth) + "\(i). " + t
            case .code(let t):
                return "⌘ " + t
            case .body(let t):
                return t
            }
        }
        return mapped.joined(separator: "\n")
    }

    // MARK: - Parsing

    private static func stripLeadingMeta(_ lines: inout [String]) {
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            lines.removeFirst()
        }
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
            lines.removeFirst()
            while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeFirst()
            }
        }
    }

    private static func parseContentLine(_ raw: String) -> Line? {
        let indent = leadingIndentDepth(raw)
        var text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        // ATX 标题
        if let match = text.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
            let body = cleanInline(String(text[match.upperBound...]))
            return body.isEmpty ? nil : .heading(body)
        }

        // 任务列表
        if let regex = try? NSRegularExpression(
            pattern: #"^[-*+]\s+\[([ xX])\]\s+(.*)$"#,
            options: []
        ) {
            let ns = text as NSString
            let full = NSRange(location: 0, length: ns.length)
            if let match = regex.firstMatch(in: text, options: [], range: full),
               match.numberOfRanges >= 3 {
                let mark = ns.substring(with: match.range(at: 1))
                let body = cleanInline(ns.substring(with: match.range(at: 2)))
                guard !body.isEmpty else { return nil }
                return .task(done: mark.lowercased() == "x", text: body, depth: indent)
            }
        }

        // 有序列表
        if let regex = try? NSRegularExpression(
            pattern: #"^(\d+)[\.．、\)]\s+(.*)$"#,
            options: []
        ) {
            let ns = text as NSString
            let full = NSRange(location: 0, length: ns.length)
            if let match = regex.firstMatch(in: text, options: [], range: full),
               match.numberOfRanges >= 3 {
                let index = ns.substring(with: match.range(at: 1))
                let body = cleanInline(ns.substring(with: match.range(at: 2)))
                guard !body.isEmpty else { return nil }
                return .numbered(index: index, text: body, depth: indent)
            }
        }

        // 无序列表
        if let regex = try? NSRegularExpression(
            pattern: #"^[-*+]\s+(.*)$"#,
            options: []
        ) {
            let ns = text as NSString
            let full = NSRange(location: 0, length: ns.length)
            if let match = regex.firstMatch(in: text, options: [], range: full),
               match.numberOfRanges >= 2 {
                let body = cleanInline(ns.substring(with: match.range(at: 1)))
                guard !body.isEmpty else { return nil }
                return .bullet(text: body, depth: indent)
            }
        }

        // 引用当正文
        if text.hasPrefix(">") {
            text = String(text.drop(while: { $0 == ">" || $0 == " " }))
        }

        let body = cleanInline(text)
        return body.isEmpty ? nil : .body(truncate(body, limit: 72))
    }

    private static func leadingIndentDepth(_ line: String) -> Int {
        var spaces = 0
        for ch in line {
            if ch == " " { spaces += 1 }
            else if ch == "\t" { spaces += 4 }
            else { break }
        }
        return min(spaces / 2, 4)
    }

    /// 围栏内多行命令压成一行摘要，避免长 shell 把卡片撑满。
    private static func condensedCode(from lines: [String]) -> String? {
        let joined = lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: #"\\\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !joined.isEmpty else { return nil }
        return truncate(joined, limit: 56)
    }

    private static func cleanInline(_ text: String) -> String {
        var value = MarkdownListContinuation.strippedTaskText(text)

        // 图片 → 占位；链接保留可见文案
        value = value.replacingOccurrences(
            of: #"!\[[^\]]*\]\([^)]*\)"#,
            with: "🖼",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]*\)"#,
            with: "$1",
            options: .regularExpression
        )
        // 残留 moyan-child / 裸 URL
        value = value.replacingOccurrences(
            of: #"moyan-child://[0-9A-Fa-f-]+"#,
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"\*\*([^*]+)\*\*"#,
            with: "$1",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"\*([^*]+)\*"#,
            with: "$1",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"`([^`]+)`"#,
            with: "$1",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let end = text.index(text.startIndex, offsetBy: max(limit - 1, 0))
        return String(text[..<end]) + "…"
    }
}
