import AppKit
import Combine
import Foundation

/// 连接 Markdown 工具栏与当前活跃的 NSTextView。
@MainActor
final class EditorBridge: ObservableObject {
    weak var textView: NSTextView?
    /// 文本被工具栏改写后回调，用于写回 NoteStore。
    var onTextMutated: ((String) -> Void)?
    /// 右键 / 工具栏触发 AI 搜索（参数为选中 Markdown 文本）。
    var onAISearchRequested: ((String) -> Void)?
    /// 右键列表项「从此任务新建子文件」；参数为任务正文。
    var onCreateChildNoteFromTask: ((String) -> Void)?
    /// 点击「📎子文件」链接时打开对应子笔记。
    var onOpenChildNote: ((UUID) -> Void)?
    /// 点击 `moyan-wps://` 链接时打开 WPS 预览。
    var onOpenWPSFile: ((UUID) -> Void)?
    /// 右键新建 WPS 表格/文档。
    var onCreateWPSFile: ((WPSFileKind) -> Void)?
    /// 右键关联已有 WPS 文件。
    var onLinkExternalWPS: (() -> Void)?
    /// 用本机 WPS 打开（非预览）。
    var onOpenWPSInApp: ((UUID) -> Void)?
    /// 解除 WPS 链接。
    var onUnlinkWPS: ((UUID) -> Void)?
    /// 按任务文案解析当前父笔记下的子笔记 ID（供高亮挂链接）。
    var resolveChildNoteID: ((String) -> UUID?)?

    func register(_ textView: NSTextView) {
        self.textView = textView
        if let pasteView = textView as? PasteAwareTextView {
            pasteView.bridge = self
        }
    }

    /// 在任务行末尾打上子文件关联标记，便于正文内感知挂钩。
    func annotateTaskLineWithChildLink(taskText: String) {
        guard let textView else { return }
        let markdown = markdownContent(from: textView)
        let ns = markdown as NSString
        var search = NSRange(location: 0, length: ns.length)
        while search.length > 0 {
            let lineRange = ns.lineRange(for: NSRange(location: search.location, length: 0))
            let raw = ns.substring(with: lineRange)
            let line = raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
            if let item = MarkdownListContinuation.parse(line),
               item.taskText == taskText || MarkdownListContinuation.strippedTaskText(item.content) == taskText {
                let marker = " · 📎子文件"
                if line.contains("📎子文件") {
                    onTextMutated?(markdown)
                    return
                }
                let suffix = raw.hasSuffix("\n") ? "\n" : ""
                let replacement = line + marker + suffix
                if textView.shouldChangeText(in: lineRange, replacementString: replacement) {
                    textView.textStorage?.replaceCharacters(in: lineRange, with: replacement)
                    textView.didChangeText()
                    onTextMutated?(markdownContent(from: textView))
                }
                return
            }
            let next = NSMaxRange(lineRange)
            if next >= ns.length { break }
            search = NSRange(location: next, length: ns.length - next)
        }
    }

    func unregister(_ textView: NSTextView) {
        if self.textView === textView {
            self.textView = nil
        }
    }

    /// 把键盘焦点交回正文，避免预览 WebView 抢走点击却无法输入。
    func focusEditor() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    func perform(_ action: MarkdownFormatAction) {
        guard let textView else { return }
        MarkdownFormatter.apply(action, to: textView)
        onTextMutated?(markdownContent(from: textView))
    }

    /// 从 textStorage 还原 Markdown（图片附件 → `![](assets/...)`）。
    private func markdownContent(from textView: NSTextView) -> String {
        if let storage = textView.textStorage {
            return MarkdownImageSupport.markdownString(from: storage)
        }
        return textView.string
    }

    /// 当前选区对应的 Markdown（无选区时返回空字符串）。
    func selectedMarkdown() -> String {
        guard let textView, let storage = textView.textStorage else { return "" }
        let range = textView.selectedRange()
        guard range.length > 0, NSMaxRange(range) <= storage.length else { return "" }
        let slice = storage.attributedSubstring(from: range)
        return MarkdownImageSupport.markdownString(from: slice)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 设置选区文字色；`hex == nil` 表示清除文字色。
    func applyForegroundColor(_ hex: String?) {
        mutateSelectionStyle(foreground: .some(hex), background: nil)
    }

    /// 设置选区背景色；`hex == nil` 表示清除背景。
    func applyBackgroundColor(_ hex: String?) {
        mutateSelectionStyle(foreground: nil, background: .some(hex))
    }

    /// 去掉选区上的颜色 span。
    func clearTextStyle() {
        guard let textView, let storage = textView.textStorage else { return }
        let range = textView.selectedRange()
        guard range.length > 0 else { return }
        let slice = storage.attributedSubstring(from: range)
        let markdown = MarkdownImageSupport.markdownString(from: slice)
        let cleaned = MarkdownColorSupport.stripSpans(markdown)
        replaceSelection(range, with: cleaned, in: textView)
    }

    func requestAISearch() {
        let text = selectedMarkdown()
        onAISearchRequested?(text)
    }

    // MARK: - Tables

    struct DetectedTable {
        var table: MarkdownTableSupport.Table
        var range: NSRange
    }

    func detectTable(atCharacterIndex index: Int) -> DetectedTable? {
        guard let textView, textView.string.count > 0 else { return nil }
        let idx = max(0, min(index, (textView.string as NSString).length - 1))
        guard let found = MarkdownTableSupport.detect(in: textView.string, at: idx) else { return nil }
        return DetectedTable(table: found.table, range: found.range)
    }

    func insertTableRow(for detected: DetectedTable) {
        guard let textView else { return }
        let next = MarkdownTableSupport.insertingRow(detected.table, afterRow: detected.table.rows.count - 1)
        replaceSelection(detected.range, with: next.markdown() + "\n", in: textView)
    }

    func insertTableColumn(for detected: DetectedTable) {
        guard let textView else { return }
        let next = MarkdownTableSupport.insertingColumn(detected.table, afterColumn: detected.table.columnCount - 1)
        replaceSelection(detected.range, with: next.markdown() + "\n", in: textView)
    }

    func deleteTableRow(for detected: DetectedTable) {
        guard let textView,
              let next = MarkdownTableSupport.deletingRow(
                detected.table,
                at: max(0, detected.table.rows.count - 1)
              ) else { return }
        replaceSelection(detected.range, with: next.markdown() + "\n", in: textView)
    }

    func editTableSource(for detected: DetectedTable) {
        guard let textView, let window = textView.window else { return }
        let alert = NSAlert()
        alert.messageText = "编辑表格"
        alert.informativeText = "使用 Markdown 管道语法编辑（| 列 |）"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 160))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let field = NSTextView(frame: scroll.contentView.bounds)
        field.autoresizingMask = [.width, .height]
        field.isRichText = false
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.string = detected.table.markdown()
        scroll.documentView = field
        alert.accessoryView = scroll

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, let textView = self.textView else { return }
            let edited = field.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !edited.isEmpty else { return }
            let lines = edited.components(separatedBy: "\n")
            let body = MarkdownTableSupport.parse(lines)?.markdown() ?? edited
            self.replaceSelection(detected.range, with: body + "\n", in: textView)
        }
    }

    // MARK: - Link views

    /// 右键命中的链接（按点击字符索引）。
    func detectLink(atCharacterIndex index: Int) -> MoyanDetectedLink? {
        guard let textView else { return nil }
        return MarkdownLinkEmbed.detect(in: textView, at: index)
    }

    /// 切换链接视图；标题/卡片在缺元数据时会异步抓取。
    func setLinkView(_ view: MoyanLinkView, for link: MoyanDetectedLink) {
        guard let textView else { return }

        let needsFetch = (view == .title || view == .card)
            && link.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if !needsFetch {
            applySerializedLink(view: view, url: link.url, title: link.title, desc: link.desc, image: link.image, replacing: link, in: textView)
            return
        }

        // 先占位，再抓取补全
        applySerializedLink(
            view: view,
            url: link.url,
            title: "加载中…",
            desc: link.desc,
            image: link.image,
            replacing: link,
            in: textView
        )

        let url = link.url
        Task { [weak self] in
            let meta = await MarkdownLinkEmbed.fetchMetadata(for: url)
            await MainActor.run {
                guard let self, let textView = self.textView,
                      let latest = self.findLink(withURL: url, in: textView) else { return }
                self.applySerializedLink(
                    view: view,
                    url: url,
                    title: meta.title,
                    desc: meta.desc,
                    image: meta.image,
                    replacing: latest,
                    in: textView
                )
            }
        }
    }

    private func applySerializedLink(
        view: MoyanLinkView,
        url: String,
        title: String,
        desc: String,
        image: String,
        replacing link: MoyanDetectedLink,
        in textView: NSTextView
    ) {
        let body = MarkdownLinkEmbed.serialize(
            view: view,
            url: url,
            title: title,
            desc: desc,
            image: image
        )
        let replacement = (view == .card || view == .preview)
            ? ensureBlockLine(body, around: link, in: textView)
            : body
        replaceLink(link, with: replacement, in: textView)
    }

    func unlink(_ link: MoyanDetectedLink) {
        guard let textView else { return }
        let plain = link.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? link.url
            : link.title
        replaceLink(link, with: plain, in: textView)
    }

    func editLink(_ link: MoyanDetectedLink) {
        guard let textView, let window = textView.window else { return }
        let alert = NSAlert()
        alert.messageText = "编辑链接"
        alert.informativeText = "修改地址与显示文字（标题视图）"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")

        let urlField = NSTextField(string: link.url)
        urlField.placeholderString = "https://"
        let titleField = NSTextField(string: link.title)
        titleField.placeholderString = "显示文字（可选）"
        let stack = NSStackView(views: [
            NSTextField(labelWithString: "地址"),
            urlField,
            NSTextField(labelWithString: "标题"),
            titleField
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 90)
        urlField.frame.size.width = 320
        titleField.frame.size.width = 320
        alert.accessoryView = stack

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let newURL = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let newTitle = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newURL.isEmpty else { return }
            let view: MoyanLinkView = {
                if link.view == .card || link.view == .preview { return link.view }
                return newTitle.isEmpty ? .link : .title
            }()
            let body = MarkdownLinkEmbed.serialize(
                view: view,
                url: newURL,
                title: newTitle,
                desc: link.desc,
                image: link.image
            )
            let replacement = (view == .card || view == .preview)
                ? self.ensureBlockLine(body, around: link, in: textView)
                : body
            self.replaceLink(link, with: replacement, in: textView)
        }
    }

    private func replaceLink(_ link: MoyanDetectedLink, with text: String, in textView: NSTextView) {
        let range = link.range
        guard range.location != NSNotFound,
              NSMaxRange(range) <= (textView.string as NSString).length else { return }
        guard textView.shouldChangeText(in: range, replacementString: text) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: text)
        textView.didChangeText()
        onTextMutated?(markdownContent(from: textView))
        textView.setSelectedRange(NSRange(location: range.location, length: (text as NSString).length))
        focusEditor()
    }

    private func ensureBlockLine(_ body: String, around link: MoyanDetectedLink, in textView: NSTextView) -> String {
        let ns = textView.string as NSString
        let beforeOK = link.range.location == 0
            || ns.substring(with: NSRange(location: link.range.location - 1, length: 1)) == "\n"
        let end = NSMaxRange(link.range)
        let afterOK = end >= ns.length
            || ns.substring(with: NSRange(location: end, length: 1)) == "\n"
        var result = body
        if !beforeOK { result = "\n" + result }
        if !afterOK { result += "\n" }
        return result
    }

    private func findLink(withURL url: String, in textView: NSTextView) -> MoyanDetectedLink? {
        let ns = textView.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        for match in MarkdownLinkEmbed.blockRegex.matches(in: textView.string, options: [], range: full) {
            guard match.numberOfRanges >= 6 else { continue }
            let blockURL = MarkdownLinkEmbed.decode(ns.substring(with: match.range(at: 2)))
            guard blockURL == url else { continue }
            let v = MoyanLinkView(rawValue: ns.substring(with: match.range(at: 1))) ?? .card
            return MoyanDetectedLink(
                view: v,
                url: blockURL,
                title: MarkdownLinkEmbed.decode(ns.substring(with: match.range(at: 3))),
                desc: MarkdownLinkEmbed.decode(ns.substring(with: match.range(at: 4))),
                image: MarkdownLinkEmbed.decode(ns.substring(with: match.range(at: 5))),
                range: match.range
            )
        }
        let fullText = textView.string as NSString
        let fullRange = NSRange(location: 0, length: fullText.length)
        for match in MarkdownLinkEmbed.fenceRegex.matches(in: textView.string, options: [], range: fullRange) {
            if let link = MarkdownLinkEmbed.detect(in: textView, at: match.range.location),
               link.url == url {
                return link
            }
        }
        if let regex = try? NSRegularExpression(pattern: #"\[([^\]]*)\]\(([^)\s]+)\)"#) {
            for match in regex.matches(in: textView.string, options: [], range: full)
            where match.numberOfRanges >= 3 {
                let href = ns.substring(with: match.range(at: 2))
                guard href == url else { continue }
                let label = ns.substring(with: match.range(at: 1))
                return MoyanDetectedLink(
                    view: label == url || label.isEmpty ? .link : .title,
                    url: href,
                    title: label == url ? "" : label,
                    desc: "",
                    image: "",
                    range: match.range
                )
            }
        }
        if let regex = try? NSRegularExpression(pattern: MarkdownAutolink.pattern) {
            for match in regex.matches(in: textView.string, options: [], range: full) {
                let raw = ns.substring(with: match.range)
                let (href, trimmed) = MarkdownAutolink.trimTrailingPunctuation(raw)
                guard href == url else { continue }
                return MoyanDetectedLink(
                    view: .link,
                    url: href,
                    title: "",
                    desc: "",
                    image: "",
                    range: NSRange(location: match.range.location, length: match.range.length - trimmed)
                )
            }
        }
        return nil
    }

    private func mutateSelectionStyle(foreground: String??, background: String??) {
        guard let textView, let storage = textView.textStorage else { return }
        var range = textView.selectedRange()
        if range.length == 0 {
            // 无选区时插入占位，便于直接改色
            let placeholder = "高亮文字"
            guard textView.shouldChangeText(in: range, replacementString: placeholder) else { return }
            storage.replaceCharacters(in: range, with: placeholder)
            textView.didChangeText()
            range = NSRange(location: range.location, length: (placeholder as NSString).length)
            textView.setSelectedRange(range)
        }
        let slice = storage.attributedSubstring(from: range)
        let markdown = MarkdownImageSupport.markdownString(from: slice)
        let wrapped = MarkdownColorSupport.updateStyle(
            markdown,
            foreground: foreground,
            background: background
        )
        replaceSelection(range, with: wrapped, in: textView)
    }

    private func replaceSelection(_ range: NSRange, with text: String, in textView: NSTextView) {
        guard textView.shouldChangeText(in: range, replacementString: text) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: text)
        textView.didChangeText()
        onTextMutated?(markdownContent(from: textView))
        // didChangeText 已做所见即所得展开；选区按展开后的可视长度计算
        let displayLen = Self.displayLength(forMarkdownSnippet: text)
        let maxLen = (textView.string as NSString).length
        let loc = min(max(0, range.location), maxLen)
        let len = min(max(0, displayLen), max(0, maxLen - loc))
        textView.setSelectedRange(NSRange(location: loc, length: len))
        focusEditor()
    }

    /// 估算一段 Markdown 在编辑区展开后的字符长度。
    private static func displayLength(forMarkdownSnippet text: String) -> Int {
        let styled = NSMutableAttributedString(
            string: text,
            attributes: [.font: MarkdownHighlighter.bodyFont]
        )
        MarkdownColorSupport.embedStyledText(in: styled)
        var length = styled.length
        if let regex = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\([^)]+\)"#) {
            let ns = text as NSString
            let matches = regex.numberOfMatches(in: text, range: NSRange(location: 0, length: ns.length))
            let rawImgLen = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
                .reduce(0) { $0 + $1.range.length }
            length = length - rawImgLen + matches
        }
        return max(0, length)
    }

    // MARK: - Find / Replace

    /// 从当前选区之后（或之前）查找下一处，选中并滚动可见。
    @discardableResult
    func find(_ query: String, backwards: Bool = false) -> Bool {
        let trimmed = query
        guard !trimmed.isEmpty, let textView else { return false }
        let ns = textView.string as NSString
        let selected = textView.selectedRange()
        let options: NSString.CompareOptions = backwards
            ? [.caseInsensitive, .backwards]
            : [.caseInsensitive]

        let searchRange: NSRange
        if backwards {
            searchRange = NSRange(location: 0, length: selected.location)
        } else {
            let start = selected.location + selected.length
            searchRange = NSRange(location: start, length: max(0, ns.length - start))
        }

        var found = ns.range(of: trimmed, options: options, range: searchRange)
        if found.location == NSNotFound {
            // 绕回全文再搜一轮
            let wrap = backwards
                ? NSRange(location: 0, length: ns.length)
                : NSRange(location: 0, length: ns.length)
            found = ns.range(of: trimmed, options: options, range: wrap)
        }
        guard found.location != NSNotFound else { return false }
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(found)
        textView.scrollRangeToVisible(found)
        return true
    }

    /// 若当前选区正好是查找串则替换，并跳到下一处。
    @discardableResult
    func replace(_ query: String, with replacement: String) -> Bool {
        guard !query.isEmpty, let textView else { return false }
        let selected = textView.selectedRange()
        let selectedText = (textView.string as NSString).substring(with: selected)
        if selected.length > 0,
           selectedText.compare(query, options: .caseInsensitive) == .orderedSame {
            if textView.shouldChangeText(in: selected, replacementString: replacement) {
                textView.textStorage?.replaceCharacters(in: selected, with: replacement)
                textView.didChangeText()
                onTextMutated?(markdownContent(from: textView))
                let cursor = selected.location + (replacement as NSString).length
                textView.setSelectedRange(NSRange(location: cursor, length: 0))
            }
        }
        return find(query, backwards: false)
    }

    /// 全文替换，返回替换次数。
    @discardableResult
    func replaceAll(_ query: String, with replacement: String) -> Int {
        guard !query.isEmpty, let textView else { return 0 }
        let ns = textView.string as NSString
        var search = NSRange(location: 0, length: ns.length)
        var count = 0
        var ranges: [NSRange] = []
        while true {
            let found = (textView.string as NSString).range(
                of: query,
                options: .caseInsensitive,
                range: search
            )
            if found.location == NSNotFound { break }
            ranges.append(found)
            let next = found.location + max(found.length, 1)
            search = NSRange(location: next, length: max(0, (textView.string as NSString).length - next))
            count += 1
            if count > 100_000 { break }
        }
        guard !ranges.isEmpty else { return 0 }

        // 自后向前替换，避免偏移
        textView.textStorage?.beginEditing()
        for range in ranges.reversed() {
            if textView.shouldChangeText(in: range, replacementString: replacement) {
                textView.textStorage?.replaceCharacters(in: range, with: replacement)
            }
        }
        textView.textStorage?.endEditing()
        textView.didChangeText()
        onTextMutated?(markdownContent(from: textView))
        return count
    }

    /// 统计全文匹配数（不移动选区）。
    func matchCount(for query: String) -> Int {
        guard !query.isEmpty, let textView else { return 0 }
        let ns = textView.string as NSString
        var search = NSRange(location: 0, length: ns.length)
        var count = 0
        while true {
            let found = ns.range(of: query, options: .caseInsensitive, range: search)
            if found.location == NSNotFound { break }
            count += 1
            let next = found.location + max(found.length, 1)
            search = NSRange(location: next, length: max(0, ns.length - next))
            if count > 100_000 { break }
        }
        return count
    }
}
