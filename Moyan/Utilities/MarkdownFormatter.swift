import AppKit

/// Markdown 工具栏动作。
enum MarkdownFormatAction: String, CaseIterable, Identifiable {
    case heading1
    case heading2
    case heading3
    case bold
    case italic
    case strikethrough
    case inlineCode
    case codeBlock
    case quote
    case bulletList
    case numberedList
    case taskList
    case link
    case horizontalRule
    case table

    var id: String { rawValue }

    var help: String {
        switch self {
        case .heading1: return "一级标题"
        case .heading2: return "二级标题"
        case .heading3: return "三级标题"
        case .bold: return "粗体"
        case .italic: return "斜体"
        case .strikethrough: return "删除线"
        case .inlineCode: return "行内代码"
        case .codeBlock: return "代码块"
        case .quote: return "引用"
        case .bulletList: return "无序列表"
        case .numberedList: return "有序列表"
        case .taskList: return "任务列表"
        case .link: return "链接"
        case .horizontalRule: return "分隔线"
        case .table: return "表格"
        }
    }

    var systemImage: String {
        switch self {
        case .heading1: return "textformat.size.larger"
        case .heading2: return "textformat.size"
        case .heading3: return "textformat.size.smaller"
        case .bold: return "bold"
        case .italic: return "italic"
        case .strikethrough: return "strikethrough"
        case .inlineCode: return "chevron.left.forwardslash.chevron.right"
        case .codeBlock: return "curlybraces"
        case .quote: return "text.quote"
        case .bulletList: return "list.bullet"
        case .numberedList: return "list.number"
        case .taskList: return "checklist"
        case .link: return "link"
        case .horizontalRule: return "minus"
        case .table: return "tablecells"
        }
    }
}

/// 对 NSTextView 选区施加 Markdown 语法包装 / 行前缀。
enum MarkdownFormatter {
    static func apply(_ action: MarkdownFormatAction, to textView: NSTextView) {
        let string = textView.string as NSString
        let selected = textView.selectedRange()
        let selectedText = string.substring(with: selected)

        switch action {
        case .bold:
            wrap(textView, left: "**", right: "**", placeholder: "粗体", selected: selected, selectedText: selectedText)
        case .italic:
            wrap(textView, left: "*", right: "*", placeholder: "斜体", selected: selected, selectedText: selectedText)
        case .strikethrough:
            wrap(textView, left: "~~", right: "~~", placeholder: "删除线", selected: selected, selectedText: selectedText)
        case .inlineCode:
            wrap(textView, left: "`", right: "`", placeholder: "code", selected: selected, selectedText: selectedText)
        case .link:
            let label = selectedText.isEmpty ? "链接文字" : selectedText
            replace(textView, range: selected, with: "[\(label)](https://)", cursorOffsetFromEnd: -1)
        case .codeBlock:
            let body = selectedText.isEmpty ? "code" : selectedText
            replace(textView, range: selected, with: "```\n\(body)\n```\n")
        case .horizontalRule:
            insertBlock(textView, "\n---\n", selected: selected)
        case .table:
            let block = "\n" + MarkdownTableSupport.template() + "\n"
            replace(textView, range: selected, with: block)
            let header = (textView.string as NSString).range(of: "列1")
            if header.location != NSNotFound {
                textView.setSelectedRange(header)
            }
        case .heading1:
            prefixLines(textView, prefix: "# ", selected: selected)
        case .heading2:
            prefixLines(textView, prefix: "## ", selected: selected)
        case .heading3:
            prefixLines(textView, prefix: "### ", selected: selected)
        case .quote:
            prefixLines(textView, prefix: "> ", selected: selected)
        case .bulletList:
            prefixLines(textView, prefix: "- ", selected: selected)
        case .numberedList:
            prefixLines(textView, prefix: "1. ", selected: selected)
        case .taskList:
            prefixLines(textView, prefix: "- [ ] ", selected: selected)
        }
    }

    private static func wrap(
        _ textView: NSTextView,
        left: String,
        right: String,
        placeholder: String,
        selected: NSRange,
        selectedText: String
    ) {
        let inner = selectedText.isEmpty ? placeholder : selectedText
        let replacement = left + inner + right
        replace(textView, range: selected, with: replacement)
        if selectedText.isEmpty {
            let start = selected.location + left.count
            textView.setSelectedRange(NSRange(location: start, length: (placeholder as NSString).length))
        }
    }

    private static func prefixLines(_ textView: NSTextView, prefix: String, selected: NSRange) {
        let string = textView.string as NSString
        var lineRange = string.lineRange(for: selected)
        if selected.length == 0 {
            lineRange = string.lineRange(for: NSRange(location: selected.location, length: 0))
        }
        let block = string.substring(with: lineRange)
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let transformed = lines.map { line -> String in
            if line.isEmpty { return prefix.trimmingCharacters(in: .whitespaces) == "-" ? line : prefix }
            if line.hasPrefix(prefix) { return line }
            return prefix + line
        }.joined(separator: "\n")
        // 保留原行尾换行
        let hasTrailingNewline = block.hasSuffix("\n")
        let output = hasTrailingNewline && !transformed.hasSuffix("\n") ? transformed + "\n" : transformed
        replace(textView, range: lineRange, with: output)
    }

    private static func insertBlock(_ textView: NSTextView, _ text: String, selected: NSRange) {
        replace(textView, range: selected, with: text)
    }

    private static func replace(_ textView: NSTextView, range: NSRange, with text: String, cursorOffsetFromEnd: Int = 0) {
        guard textView.shouldChangeText(in: range, replacementString: text) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: text)
        textView.didChangeText()
        let location = range.location + (text as NSString).length + cursorOffsetFromEnd
        textView.setSelectedRange(NSRange(location: max(0, location), length: 0))
    }
}

/// 回车时自动延续列表 / 引用前缀（如 `1.` → `2.`、`- `、`- [ ] `、`> `）。
enum MarkdownListContinuation {
    /// 列表行解析结果（供回车延续与右键「新建子文件」复用）。
    struct Item {
        var indent: String
        var content: String
        var nextPrefix: String
        /// 去掉关联标记后的任务正文，用于子文件标题 / 挂钩。
        var taskText: String {
            MarkdownListContinuation.strippedTaskText(content)
        }
    }

    /// 若已处理回车返回 `true`（调用方勿再 `super.insertNewline`）。
    @discardableResult
    static func insertNewline(in textView: NSTextView) -> Bool {
        let selected = textView.selectedRange()
        guard selected.length == 0 else { return false }

        let ns = textView.string as NSString
        let lineRange = ns.lineRange(for: selected)
        let rawLine = ns.substring(with: lineRange)
        let hasTrailingNewline = rawLine.hasSuffix("\n")
        let line = hasTrailingNewline ? String(rawLine.dropLast()) : rawLine

        guard let item = parse(line) else { return false }

        // 空列表项再回车：退出列表，只保留缩进空行
        if item.content.trimmingCharacters(in: .whitespaces).isEmpty {
            let replacement = item.indent + (hasTrailingNewline ? "\n" : "")
            replace(textView, range: lineRange, with: replacement)
            textView.setSelectedRange(NSRange(location: lineRange.location + (item.indent as NSString).length, length: 0))
            return true
        }

        // 在光标处插入换行 + 下一项前缀；光标后的文字落到新行
        let insert = "\n" + item.nextPrefix
        guard textView.shouldChangeText(in: selected, replacementString: insert) else { return false }
        textView.textStorage?.replaceCharacters(in: selected, with: insert)
        textView.didChangeText()
        let location = selected.location + (insert as NSString).length
        textView.setSelectedRange(NSRange(location: location, length: 0))
        return true
    }

    /// 解析某一行是否为列表/任务项。
    static func parse(_ line: String) -> Item? {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)

        // 任务列表：- [ ] / - [x]
        if let regex = try? NSRegularExpression(
            pattern: #"^(\s*)([-*+]\s+\[[ xX]\]\s+)(.*)$"#,
            options: []
        ),
           let match = regex.firstMatch(in: line, options: [], range: full) {
            let indent = ns.substring(with: match.range(at: 1))
            let content = ns.substring(with: match.range(at: 3))
            return Item(indent: indent, content: content, nextPrefix: indent + "- [ ] ")
        }

        // 有序列表：1. / 2． / 3、 / 4)
        if let regex = try? NSRegularExpression(
            pattern: #"^(\s*)(\d+)[\.．、\)]\s*(.*)$"#,
            options: []
        ),
           let match = regex.firstMatch(in: line, options: [], range: full) {
            let indent = ns.substring(with: match.range(at: 1))
            let number = Int(ns.substring(with: match.range(at: 2))) ?? 1
            let content = ns.substring(with: match.range(at: 3))
            return Item(indent: indent, content: content, nextPrefix: indent + "\(number + 1). ")
        }

        // 无序列表：- / * / +
        if let regex = try? NSRegularExpression(
            pattern: #"^(\s*)([-*+])\s+(.*)$"#,
            options: []
        ),
           let match = regex.firstMatch(in: line, options: [], range: full) {
            let indent = ns.substring(with: match.range(at: 1))
            let marker = ns.substring(with: match.range(at: 2))
            let content = ns.substring(with: match.range(at: 3))
            return Item(indent: indent, content: content, nextPrefix: indent + "\(marker) ")
        }

        // 引用：>
        if let regex = try? NSRegularExpression(
            pattern: #"^(\s*)>\s?(.*)$"#,
            options: []
        ),
           let match = regex.firstMatch(in: line, options: [], range: full) {
            let indent = ns.substring(with: match.range(at: 1))
            let content = ns.substring(with: match.range(at: 2))
            return Item(indent: indent, content: content, nextPrefix: indent + "> ")
        }

        return nil
    }

    /// 在字符索引处取当前行的列表项（引用行不算可拆子任务）。
    /// - Important: `index` 必须与 `text` 同一坐标系（编辑区请传 `textView.string`，勿传含 span 的 Markdown 源）。
    static func listItem(atCharacterIndex index: Int, in text: String) -> (item: Item, lineRange: NSRange)? {
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let clamped = max(0, min(index, max(ns.length - 1, 0)))
        let lineRange = ns.lineRange(for: NSRange(location: clamped, length: 0))
        let rawLine = ns.substring(with: lineRange)
        let line = rawLine.hasSuffix("\n") ? String(rawLine.dropLast()) : rawLine
        return listItem(fromLine: line, lineRange: lineRange)
    }

    /// 从选区 / 右键位置解析「新建子任务」标题。
    /// - Important: **有选区时以选区所在行为准**（右键落点常偏到下一行，不能优先用 clickIndex）。
    static func taskTextForChildNote(
        visibleText: String,
        characterIndex: Int,
        selectedRange: NSRange
    ) -> String? {
        let ns = visibleText as NSString
        guard ns.length > 0 else { return nil }

        // 1) 选区优先：用户明确选中「adx 流量控制」时，取该选区所在列表行
        if selectedRange.length > 0,
           selectedRange.location >= 0,
           NSMaxRange(selectedRange) <= ns.length {
            if let detected = listItem(atCharacterIndex: selectedRange.location, in: visibleText) {
                return detected.item.taskText
            }
            // 选区落在行内但不被识别为列表时，用选中原文
            let selected = ns.substring(with: selectedRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !selected.isEmpty {
                return strippedTaskText(selected)
            }
        }

        // 2) 无选区：用右键落点所在行
        if let detected = listItem(atCharacterIndex: characterIndex, in: visibleText) {
            return detected.item.taskText
        }

        // 3) 非标准列表：去掉序号后的整行
        return plainLineTaskText(in: ns, at: characterIndex)
    }

    private static func plainLineTaskText(in ns: NSString, at characterIndex: Int) -> String? {
        let clamped = max(0, min(characterIndex, max(ns.length - 1, 0)))
        let lineRange = ns.lineRange(for: NSRange(location: clamped, length: 0))
        var line = ns.substring(with: lineRange)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet.newlines))
        if let regex = try? NSRegularExpression(
            pattern: #"^(\d+[\.．、\)]\s*|[-*+]\s+(\[[ xX]\]\s*)?)"#,
            options: []
        ) {
            line = regex.stringByReplacingMatches(
                in: line,
                options: [],
                range: NSRange(location: 0, length: (line as NSString).length),
                withTemplate: ""
            )
        }
        line = strippedTaskText(line)
        return line.isEmpty ? nil : line
    }

    private static func listItem(fromLine line: String, lineRange: NSRange) -> (item: Item, lineRange: NSRange)? {
        // 可见正文偶发带 BOM / 零宽字符，去掉后再解析列表前缀
        let normalized = line.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}\u{200B}\u{200C}\u{200D}"))
        guard let item = parse(normalized) ?? parse(line), !item.nextPrefix.hasSuffix("> ") else { return nil }
        let task = item.taskText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return nil }
        return (item, lineRange)
    }

    /// 去掉任务行上已有的「子文件」关联尾巴，避免重复挂钩。
    static func strippedTaskText(_ content: String) -> String {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // ` · [📎子文件](moyan-child://…)` / ` · 📎子文件`
        if let range = text.range(
            of: #"\s*[·•]\s*\[?📎子文件\]?(?:\(moyan-child://[^)]+\))?\s*$"#,
            options: .regularExpression
        ) {
            text.removeSubrange(range)
        } else if let range = text.range(of: #"\s*[·•]\s*📎.*$"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        if let range = text.range(of: #"\s*→\s*子文件\s*$"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(_ textView: NSTextView, range: NSRange, with text: String) {
        guard textView.shouldChangeText(in: range, replacementString: text) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: text)
        textView.didChangeText()
    }
}
