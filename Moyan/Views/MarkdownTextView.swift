import AppKit
import SwiftUI

/// AppKit 文本编辑器：语法高亮 + 本地图片附件预览 + 强化粘贴。
struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    var onChange: (String) -> Void
    var bridge: EditorBridge?
    var onPasteImage: ((NSImage) -> String?)?
    /// 笔记库根目录，用于把 `assets/...` 显示成图片。
    var libraryURL: URL? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let old = scrollView.documentView as? NSTextView
        let textView = PasteAwareTextView(frame: old?.frame ?? .zero)
        textView.minSize = old?.minSize ?? .zero
        textView.maxSize = old?.maxSize ?? NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView

        textView.delegate = context.coordinator
        textView.pasteImageHandler = { [weak coordinator = context.coordinator] image in
            coordinator?.handlePasteImage(image)
        }
        // 需要富文本才能显示图片附件
        textView.isRichText = true
        textView.importsGraphics = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = MarkdownHighlighter.bodyFont
        textView.textContainerInset = NSSize(width: 28, height: 20)
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .labelColor
        textView.registerForDraggedTypes([
            .png, .tiff, .fileURL,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic")
        ])
        context.coordinator.textView = textView
        context.coordinator.applyHighlight(text)
        bridge?.register(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? PasteAwareTextView else { return }
        textView.pasteImageHandler = { [weak coordinator = context.coordinator] image in
            coordinator?.handlePasteImage(image)
        }
        bridge?.register(textView)
        textView.backgroundColor = .textBackgroundColor
        // 输入法组字中禁止从 SwiftUI 回写，否则候选会断、字符「消失」
        if textView.hasMarkedText() { return }
        // 用户正在输入 / 高亮待执行时，不要用 Binding 旧值覆盖 NSTextView
        if context.coordinator.isSyncSuspended { return }
        let current = context.coordinator.currentMarkdown()
        if current != text {
            context.coordinator.applyHighlight(text)
            // 保持光标：applyHighlight 内部已恢复 selectedRanges
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.cancelPendingWork()
        if let textView = scrollView.documentView as? NSTextView {
            coordinator.parent.bridge?.unregister(textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextView
        weak var textView: NSTextView?
        private var isApplying = false
        private var pendingHighlightAfterIME = false
        /// 高亮防抖：避免每键整篇 setAttributedString 掉帧
        private var highlightTask: Task<Void, Never>?
        /// 写回 Store 防抖：减少 @Published 引发的 SwiftUI 重绘
        private var storeTask: Task<Void, Never>?
        private var latestMarkdown: String = ""
        /// 有未刷完的高亮/写回时，暂停 SwiftUI → NSTextView 回写
        private(set) var isSyncSuspended = false

        init(_ parent: MarkdownTextView) {
            self.parent = parent
            self.latestMarkdown = parent.text
        }

        func cancelPendingWork() {
            highlightTask?.cancel()
            storeTask?.cancel()
            isSyncSuspended = false
        }

        func currentMarkdown() -> String {
            guard let storage = textView?.textStorage else { return parent.text }
            // 无图片/颜色 span 时直接取 string，避免每键扫描整篇属性串
            if usesPlainSerialize {
                return storage.string
            }
            return MarkdownImageSupport.markdownString(from: storage)
        }

        /// 源码不含图片与颜色标签时可走快速序列化。
        private var usesPlainSerialize = true

        func applyHighlight(_ string: String) {
            guard let textView else { return }
            if textView.hasMarkedText() {
                pendingHighlightAfterIME = true
                return
            }
            usesPlainSerialize = !string.contains("![")
                && !string.contains("<span")
                && !string.contains("assets/")
            isApplying = true
            let selected = textView.selectedRanges
            let styled = NSMutableAttributedString(attributedString: MarkdownHighlighter.highlight(string))
            // 图片仍用附件；链接卡片/表格保持可编辑源码
            MarkdownImageSupport.embedAttachments(in: styled, libraryRoot: parent.libraryURL)
            MarkdownTableSupport.highlightEditableTables(in: styled)
            MarkdownLinkEmbed.highlightEditableBlocks(in: styled)
            // 颜色：隐藏 <span>，只显示着色文字（可继续输入）
            MarkdownColorSupport.embedStyledText(in: styled)
            // 「📎子文件」挂上可点击跳转链接
            ChildNoteMarkerSupport.embedClickableMarkers(in: styled) { [weak self] taskText in
                self?.parent.bridge?.resolveChildNoteID?(taskText)
            }
            textView.textStorage?.beginEditing()
            textView.textStorage?.setAttributedString(styled)
            textView.textStorage?.endEditing()
            textView.selectedRanges = selected
            syncTypingAttributes(in: textView)
            isApplying = false
            pendingHighlightAfterIME = false
            latestMarkdown = string
        }

        func syncTypingAttributes(in textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            textView.typingAttributes = MarkdownColorSupport.typingAttributes(
                at: textView.selectedRange().location,
                in: storage
            )
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplying, let textView else { return }
            let markdown = currentMarkdown()
            latestMarkdown = markdown
            isSyncSuspended = true

            if textView.hasMarkedText() {
                pendingHighlightAfterIME = true
                // 组字期间也轻量写回，保证不丢字；不做高亮
                scheduleStoreUpdate(markdown, delayNanoseconds: 80_000_000)
                return
            }

            // 只同步 typingAttributes，立即高亮会整篇重绘导致掉帧
            syncTypingAttributes(in: textView)
            scheduleStoreUpdate(markdown, delayNanoseconds: 180_000_000)
            scheduleHighlight(markdown, delayNanoseconds: 140_000_000)
        }

        private func scheduleStoreUpdate(_ markdown: String, delayNanoseconds: UInt64) {
            storeTask?.cancel()
            storeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: delayNanoseconds)
                guard let self, !Task.isCancelled else { return }
                // 只走 onChange，避免 Binding 再写一次造成双重更新
                self.parent.onChange(self.latestMarkdown)
                if self.highlightTask == nil {
                    self.isSyncSuspended = false
                }
            }
        }

        private func scheduleHighlight(_ markdown: String, delayNanoseconds: UInt64) {
            highlightTask?.cancel()
            highlightTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: delayNanoseconds)
                guard let self, !Task.isCancelled else { return }
                guard let textView = self.textView, !textView.hasMarkedText() else {
                    self.pendingHighlightAfterIME = true
                    return
                }
                // 用最新正文高亮，避免连打时用过期快照
                self.applyHighlight(self.latestMarkdown)
                self.highlightTask = nil
                if self.storeTask == nil {
                    self.isSyncSuspended = false
                }
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            if !isApplying {
                syncTypingAttributes(in: textView)
            }
            guard pendingHighlightAfterIME, !isApplying, !textView.hasMarkedText() else { return }
            latestMarkdown = currentMarkdown()
            scheduleHighlight(latestMarkdown, delayNanoseconds: 50_000_000)
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let childID = ChildNoteMarkerSupport.childNoteID(from: link) {
                parent.bridge?.onOpenChildNote?(childID)
                return true
            }
            if let wpsID = WPSLinkSupport.fileID(from: link) {
                parent.bridge?.onOpenWPSFile?(wpsID)
                return true
            }
            if let url = link as? URL {
                NSWorkspace.shared.open(url)
                return true
            }
            if let string = link as? String, let url = URL(string: string) {
                NSWorkspace.shared.open(url)
                return true
            }
            return false
        }

        /// 系统构建右键菜单时的二次注入，确保「新建子任务」一定出现。
        func textView(
            _ textView: NSTextView,
            menu: NSMenu,
            for event: NSEvent,
            at charIndex: Int
        ) -> NSMenu? {
            if let pasteView = textView as? PasteAwareTextView {
                pasteView.ensureMoyanMenuItems(into: menu, event: event, characterIndex: charIndex)
            }
            return menu
        }

        func handlePasteImage(_ image: NSImage) {
            guard let markdown = parent.onPasteImage?(image),
                  let textView else { return }
            let range = textView.selectedRange()
            if textView.shouldChangeText(in: range, replacementString: markdown) {
                textView.textStorage?.replaceCharacters(in: range, with: markdown)
                textView.didChangeText()
                let location = range.location + (markdown as NSString).length
                textView.setSelectedRange(NSRange(location: location, length: 0))
            }
        }
    }
}

/// 拦截图片粘贴 / 拖入；兼容飞书截图等非标准剪贴板；回车延续列表。
final class PasteAwareTextView: NSTextView {
    var pasteImageHandler: ((NSImage) -> Void)?
    weak var bridge: EditorBridge?

    override func insertNewline(_ sender: Any?) {
        if MarkdownTableEditing.insertNewline(in: self) { return }
        if MarkdownListContinuation.insertNewline(in: self) { return }
        super.insertNewline(sender)
    }

    override func insertTab(_ sender: Any?) {
        if MarkdownTableEditing.moveCell(in: self, forward: true) { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if MarkdownTableEditing.moveCell(in: self, forward: false) { return }
        super.insertBacktab(sender)
    }

    /// 右键菜单：子任务 / 链接视图 / 颜色 / AI 搜索 + 系统编辑项。
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu(title: "")
        ensureMoyanMenuItems(into: menu, event: event, characterIndex: nil)
        return menu
    }

    /// 确保墨言自定义项在菜单顶部；「新建子任务」始终可见。
    fileprivate func ensureMoyanMenuItems(
        into menu: NSMenu,
        event: NSEvent?,
        characterIndex hintIndex: Int?
    ) {
        let charIndex = hintIndex ?? characterIndex(for: event)
        let taskText = MarkdownListContinuation.taskTextForChildNote(
            visibleText: string,
            characterIndex: charIndex,
            selectedRange: selectedRange()
        ) ?? "未命名子任务"

        var index = 0

        if let existing = menu.items.first(where: { $0.action == #selector(createChildNoteFromMenu(_:)) }) {
            existing.representedObject = taskText
            index = menu.index(of: existing) + 1
            // 跳过紧随的分隔线
            if index < menu.numberOfItems, menu.items[index].isSeparatorItem {
                index += 1
            }
        } else {
            let child = NSMenuItem(
                title: "新建子任务",
                action: #selector(createChildNoteFromMenu(_:)),
                keyEquivalent: ""
            )
            child.target = self
            child.representedObject = taskText
            child.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
            child.toolTip = "从当前任务行创建关联子文件"
            menu.insertItem(child, at: 0)
            menu.insertItem(.separator(), at: 1)
            index = 2
        }

        if let link = bridge?.detectLink(atCharacterIndex: charIndex),
           !menu.items.contains(where: { $0.title == "链接" }) {
            menu.insertItem(makeLinkMenu(for: link), at: index); index += 1
            menu.insertItem(.separator(), at: index); index += 1
        }
        if let table = bridge?.detectTable(atCharacterIndex: charIndex),
           !menu.items.contains(where: { $0.title == "表格" }) {
            menu.insertItem(makeTableMenu(for: table), at: index); index += 1
            menu.insertItem(.separator(), at: index); index += 1
        }

        if !menu.items.contains(where: { $0.title == "WPS" }) {
            menu.insertItem(makeWPSMenu(atCharacterIndex: charIndex), at: index); index += 1
            menu.insertItem(.separator(), at: index); index += 1
        }

        if !menu.items.contains(where: { $0.title == "字体颜色" }) {
            menu.insertItem(makeForegroundMenu(), at: index); index += 1
            menu.insertItem(makeBackgroundMenu(), at: index); index += 1
            menu.insertItem(.separator(), at: index); index += 1
            let ai = NSMenuItem(
                title: "Cursor 提问",
                action: #selector(aiSearchFromMenu(_:)),
                keyEquivalent: ""
            )
            ai.target = self
            ai.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: nil)
            menu.insertItem(ai, at: index); index += 1
            menu.insertItem(.separator(), at: index)
        }
    }

    /// 将窗口点击转为字符下标；纠正「点在行下半部时落到下一行」的常见偏差。
    /// - Parameter preferSelection: 仅「新建子任务」菜单用选区；点击跳转必须用真实落点。
    private func characterIndex(for event: NSEvent?, preferSelection: Bool = false) -> Int {
        let selected = selectedRange()
        if preferSelection, selected.length > 0 {
            return selected.location
        }
        guard let event else { return selected.location }
        let point = convert(event.locationInWindow, from: nil)
        guard let layoutManager, let textContainer, layoutManager.numberOfGlyphs > 0 else {
            return characterIndexForInsertion(at: point)
        }

        var fraction: CGFloat = 0
        var glyphIndex = layoutManager.glyphIndex(
            for: point,
            in: textContainer,
            fractionOfDistanceThroughGlyph: &fraction
        )
        glyphIndex = min(max(glyphIndex, 0), layoutManager.numberOfGlyphs - 1)

        var fragmentGlyphRange = NSRange()
        let fragmentRect = layoutManager.lineFragmentRect(
            forGlyphAt: glyphIndex,
            effectiveRange: &fragmentGlyphRange
        )
        // 落点在该行碎片上方（或明显偏上）且命中的是行首字形 → 实际点的是上一行
        if glyphIndex == fragmentGlyphRange.location,
           glyphIndex > 0,
           point.y < fragmentRect.minY + min(fragmentRect.height * 0.35, 8) {
            glyphIndex -= 1
        }
        return layoutManager.characterIndexForGlyph(at: glyphIndex)
    }

    @objc fileprivate func createChildNoteFromMenu(_ sender: NSMenuItem) {
        let taskText: String
        if let text = sender.representedObject as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            taskText = text
        } else if let resolved = MarkdownListContinuation.taskTextForChildNote(
            visibleText: string,
            characterIndex: selectedRange().location,
            selectedRange: selectedRange()
        ) {
            taskText = resolved
        } else {
            taskText = "未命名子任务"
        }
        bridge?.onCreateChildNoteFromTask?(taskText)
    }

    /// 单击「📎子文件」/ WPS 链即可跳转（可编辑 NSTextView 默认要 ⌘+点击才跟链接）。
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1,
           !event.modifierFlags.contains(.command) {
            if let childID = childNoteIDAtMouse(event) {
                bridge?.onOpenChildNote?(childID)
                return
            }
            if let wpsID = wpsFileIDAtMouse(event) {
                bridge?.onOpenWPSFile?(wpsID)
                return
            }
        }
        super.mouseDown(with: event)
    }

    private func childNoteIDAtMouse(_ event: NSEvent) -> UUID? {
        guard let link = linkAttributeAtMouse(event) else { return nil }
        return ChildNoteMarkerSupport.childNoteID(from: link)
    }

    private func wpsFileIDAtMouse(_ event: NSEvent) -> UUID? {
        guard let link = linkAttributeAtMouse(event) else { return nil }
        return WPSLinkSupport.fileID(from: link)
    }

    private func linkAttributeAtMouse(_ event: NSEvent) -> Any? {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndex(for: event)
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let clamped = min(max(index, 0), storage.length - 1)
        if let layoutManager, let textContainer, layoutManager.numberOfGlyphs > 0 {
            let glyphIndex = min(
                layoutManager.glyphIndex(for: point, in: textContainer),
                layoutManager.numberOfGlyphs - 1
            )
            let glyphRect = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: glyphIndex, length: 1),
                in: textContainer
            )
            let offset = textContainerOrigin
            let hit = glyphRect.offsetBy(dx: offset.x, dy: offset.y).insetBy(dx: -3, dy: -3)
            guard hit.contains(point) else { return nil }
        }
        return storage.attribute(.link, at: clamped, effectiveRange: nil)
    }

    private func makeLinkMenu(for link: MoyanDetectedLink) -> NSMenuItem {
        let root = NSMenuItem(title: "链接", action: nil, keyEquivalent: "")
        let sub = NSMenu()

        let open = NSMenuItem(
            title: "打开链接",
            action: #selector(openLinkFromMenu(_:)),
            keyEquivalent: ""
        )
        open.target = self
        open.representedObject = link.url
        open.image = NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
        sub.addItem(open)

        let edit = NSMenuItem(
            title: "编辑链接…",
            action: #selector(editLinkFromMenu(_:)),
            keyEquivalent: ""
        )
        edit.target = self
        edit.representedObject = link
        edit.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        sub.addItem(edit)

        let unlink = NSMenuItem(
            title: "取消链接",
            action: #selector(unlinkFromMenu(_:)),
            keyEquivalent: ""
        )
        unlink.target = self
        unlink.representedObject = link
        unlink.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        sub.addItem(unlink)

        sub.addItem(.separator())

        for view in MoyanLinkView.allCases {
            let item = NSMenuItem(
                title: view.label,
                action: #selector(setLinkViewFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.image = NSImage(systemSymbolName: view.systemImage, accessibilityDescription: nil)
            item.state = (view == link.view) ? .on : .off
            item.representedObject = LinkViewCommand(view: view, link: link)
            sub.addItem(item)
        }

        root.submenu = sub
        return root
    }

    private struct LinkViewCommand {
        let view: MoyanLinkView
        let link: MoyanDetectedLink
    }

    private func makeTableMenu(for table: EditorBridge.DetectedTable) -> NSMenuItem {
        let root = NSMenuItem(title: "表格", action: nil, keyEquivalent: "")
        let sub = NSMenu()

        func item(_ title: String, image: String, action: Selector) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            i.representedObject = table
            i.image = NSImage(systemSymbolName: image, accessibilityDescription: nil)
            return i
        }

        sub.addItem(item("下方插入行", image: "plus.rectangle.on.rectangle", action: #selector(insertTableRowFromMenu(_:))))
        sub.addItem(item("右侧插入列", image: "rectangle.split.3x1", action: #selector(insertTableColumnFromMenu(_:))))
        if !table.table.rows.isEmpty {
            sub.addItem(item("删除末行", image: "minus.rectangle", action: #selector(deleteTableRowFromMenu(_:))))
        }
        sub.addItem(.separator())
        sub.addItem(item("用源码编辑器打开…", image: "pencil", action: #selector(editTableFromMenu(_:))))
        root.submenu = sub
        return root
    }

    private func makeWPSMenu(atCharacterIndex charIndex: Int) -> NSMenuItem {
        let root = NSMenuItem(title: "WPS", action: nil, keyEquivalent: "")
        let sub = NSMenu()

        let sheet = NSMenuItem(
            title: "新建表格",
            action: #selector(createWPSSpreadsheetFromMenu(_:)),
            keyEquivalent: ""
        )
        sheet.target = self
        sheet.image = NSImage(systemSymbolName: "tablecells", accessibilityDescription: nil)
        sub.addItem(sheet)

        let doc = NSMenuItem(
            title: "新建文档",
            action: #selector(createWPSDocumentFromMenu(_:)),
            keyEquivalent: ""
        )
        doc.target = self
        doc.image = NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: nil)
        sub.addItem(doc)

        let link = NSMenuItem(
            title: "关联已有文件…",
            action: #selector(linkExternalWPSFromMenu(_:)),
            keyEquivalent: ""
        )
        link.target = self
        link.image = NSImage(systemSymbolName: "link.badge.plus", accessibilityDescription: nil)
        sub.addItem(link)

        // 光标落在已有 WPS 链上时提供预览 / 打开 / 解除
        if let storage = textStorage, storage.length > 0 {
            let clamped = min(max(charIndex, 0), storage.length - 1)
            if let attr = storage.attribute(.link, at: clamped, effectiveRange: nil),
               let wpsID = WPSLinkSupport.fileID(from: attr) {
                sub.addItem(.separator())
                let preview = NSMenuItem(
                    title: "预览",
                    action: #selector(previewWPSFromMenu(_:)),
                    keyEquivalent: ""
                )
                preview.target = self
                preview.representedObject = wpsID
                preview.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
                sub.addItem(preview)

                let open = NSMenuItem(
                    title: "用 WPS 打开",
                    action: #selector(openWPSFromMenu(_:)),
                    keyEquivalent: ""
                )
                open.target = self
                open.representedObject = wpsID
                open.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
                sub.addItem(open)

                let unlink = NSMenuItem(
                    title: "解除链接",
                    action: #selector(unlinkWPSFromMenu(_:)),
                    keyEquivalent: ""
                )
                unlink.target = self
                unlink.representedObject = wpsID
                unlink.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
                sub.addItem(unlink)
            }
        }

        root.submenu = sub
        root.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        return root
    }

    @objc private func createWPSSpreadsheetFromMenu(_ sender: NSMenuItem) {
        bridge?.onCreateWPSFile?(.spreadsheet)
    }

    @objc private func createWPSDocumentFromMenu(_ sender: NSMenuItem) {
        bridge?.onCreateWPSFile?(.document)
    }

    @objc private func linkExternalWPSFromMenu(_ sender: NSMenuItem) {
        bridge?.onLinkExternalWPS?()
    }

    @objc private func previewWPSFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        bridge?.onOpenWPSFile?(id)
    }

    @objc private func openWPSFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        bridge?.onOpenWPSInApp?(id)
    }

    @objc private func unlinkWPSFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        bridge?.onUnlinkWPS?(id)
    }

    @objc private func editTableFromMenu(_ sender: NSMenuItem) {
        guard let table = sender.representedObject as? EditorBridge.DetectedTable else { return }
        bridge?.editTableSource(for: table)
    }

    @objc private func insertTableRowFromMenu(_ sender: NSMenuItem) {
        guard let table = sender.representedObject as? EditorBridge.DetectedTable else { return }
        bridge?.insertTableRow(for: table)
    }

    @objc private func insertTableColumnFromMenu(_ sender: NSMenuItem) {
        guard let table = sender.representedObject as? EditorBridge.DetectedTable else { return }
        bridge?.insertTableColumn(for: table)
    }

    @objc private func deleteTableRowFromMenu(_ sender: NSMenuItem) {
        guard let table = sender.representedObject as? EditorBridge.DetectedTable else { return }
        bridge?.deleteTableRow(for: table)
    }

    @objc private func openLinkFromMenu(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String,
              let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func editLinkFromMenu(_ sender: NSMenuItem) {
        guard let link = sender.representedObject as? MoyanDetectedLink else { return }
        bridge?.editLink(link)
    }

    @objc private func unlinkFromMenu(_ sender: NSMenuItem) {
        guard let link = sender.representedObject as? MoyanDetectedLink else { return }
        bridge?.unlink(link)
    }

    @objc private func setLinkViewFromMenu(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? LinkViewCommand else { return }
        bridge?.setLinkView(command.view, for: command.link)
    }

    private func makeForegroundMenu() -> NSMenuItem {
        let root = NSMenuItem(title: "字体颜色", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for color in MarkdownColorSupport.foregroundColors {
            let item = NSMenuItem(
                title: color.label,
                action: #selector(applyForegroundFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = color.hex
            item.image = colorSwatchImage(color.nsColor, glyph: "A")
            sub.addItem(item)
        }
        root.submenu = sub
        return root
    }

    private func makeBackgroundMenu() -> NSMenuItem {
        let root = NSMenuItem(title: "背景颜色", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let none = NSMenuItem(
            title: "无填充",
            action: #selector(applyBackgroundFromMenu(_:)),
            keyEquivalent: ""
        )
        none.target = self
        none.representedObject = ""
        none.image = emptySwatchImage()
        sub.addItem(none)
        for color in MarkdownColorSupport.backgroundLightColors + MarkdownColorSupport.backgroundSolidColors {
            let item = NSMenuItem(
                title: color.label,
                action: #selector(applyBackgroundFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = color.hex
            // 只显示色块，文字用系统默认黑/白，避免「彩色文字」
            item.image = colorSwatchImage(color.nsColor, glyph: nil)
            sub.addItem(item)
        }
        sub.addItem(NSMenuItem.separator())
        let clear = NSMenuItem(
            title: "恢复默认",
            action: #selector(clearStyleFromMenu(_:)),
            keyEquivalent: ""
        )
        clear.target = self
        sub.addItem(clear)
        root.submenu = sub
        return root
    }

    private func colorSwatchImage(_ color: NSColor, glyph: String?) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        return NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
            NSColor.secondaryLabelColor.withAlphaComponent(0.35).setStroke()
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
            border.lineWidth = 1
            border.stroke()
            if let glyph {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: self.contrastingGlyphColor(for: color)
                ]
                let ns = glyph as NSString
                let ts = ns.size(withAttributes: attrs)
                ns.draw(
                    at: NSPoint(x: (rect.width - ts.width) / 2, y: (rect.height - ts.height) / 2),
                    withAttributes: attrs
                )
            }
            return true
        }
    }

    private func emptySwatchImage() -> NSImage {
        let size = NSSize(width: 16, height: 16)
        return NSImage(size: size, flipped: false) { rect in
            NSColor.textBackgroundColor.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
            NSColor.systemBlue.setStroke()
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: 3, y: 3))
            slash.line(to: NSPoint(x: rect.width - 3, y: rect.height - 3))
            slash.lineWidth = 1.5
            slash.stroke()
            NSColor.secondaryLabelColor.withAlphaComponent(0.4).setStroke()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).stroke()
            return true
        }
    }

    private func contrastingGlyphColor(for color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return .white }
        let luma = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luma > 0.65 ? .black : .white
    }

    @objc private func applyForegroundFromMenu(_ sender: NSMenuItem) {
        guard let hex = sender.representedObject as? String else { return }
        bridge?.applyForegroundColor(hex)
    }

    @objc private func applyBackgroundFromMenu(_ sender: NSMenuItem) {
        let hex = (sender.representedObject as? String) ?? ""
        bridge?.applyBackgroundColor(hex.isEmpty ? nil : hex)
    }

    @objc private func clearStyleFromMenu(_ sender: Any?) {
        bridge?.clearTextStyle()
    }

    @objc private func aiSearchFromMenu(_ sender: Any?) {
        bridge?.requestAISearch()
    }

    override func paste(_ sender: Any?) {
        if tryPasteImage(from: .general) { return }
        super.paste(sender)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if tryPasteImage(from: .general) { return }
        super.pasteAsPlainText(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if tryPasteImage(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        var types = super.readablePasteboardTypes
        let extras: [NSPasteboard.PasteboardType] = [
            .png, .tiff, .fileURL,
            .init("public.jpeg"),
            .init("public.jpg"),
            .init("public.heic"),
            .init("public.html"),
            .html
        ]
        for t in extras where !types.contains(t) {
            types.insert(t, at: 0)
        }
        return types
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if tryPasteImage(from: pboard) { return true }
        return super.readSelection(from: pboard, type: type)
    }

    @discardableResult
    private func tryPasteImage(from pasteboard: NSPasteboard) -> Bool {
        if let image = PasteboardImageReader.image(from: pasteboard) {
            pasteImageHandler?(image)
            return true
        }
        return false
    }
}

enum PasteboardImageReader {
    static func image(from pasteboard: NSPasteboard) -> NSImage? {
        let rawTypes: [NSPasteboard.PasteboardType] = [
            .png, .tiff,
            .init("public.jpeg"),
            .init("public.jpg"),
            .init("public.heic"),
            .init("com.apple.pict"),
            .init("public.webp")
        ]
        for type in rawTypes {
            if let data = pasteboard.data(forType: type),
               let image = NSImage(data: data),
               isUsable(image) {
                return image
            }
        }

        for item in pasteboard.pasteboardItems ?? [] {
            for type in item.types {
                let raw = type.rawValue.lowercased()
                let looksImage = raw.contains("png") || raw.contains("tiff") || raw.contains("jpeg")
                    || raw.contains("jpg") || raw.contains("heic") || raw.contains("image")
                guard looksImage, let data = item.data(forType: type) else { continue }
                if let image = NSImage(data: data), isUsable(image) {
                    return image
                }
            }
        }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL] {
            for url in urls {
                let ext = url.pathExtension.lowercased()
                if ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp"].contains(ext),
                   let image = NSImage(contentsOf: url),
                   isUsable(image) {
                    return image
                }
            }
        }

        if let html = pasteboard.string(forType: .html)
            ?? pasteboard.string(forType: .init("public.html")),
           let image = imageFromHTML(html) {
            return image
        }

        if let image = NSImage(pasteboard: pasteboard), isUsable(image) {
            return image
        }

        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] {
            return images.first(where: isUsable)
        }

        return nil
    }

    private static func isUsable(_ image: NSImage) -> Bool {
        image.size.width >= 2 && image.size.height >= 2
    }

    private static func imageFromHTML(_ html: String) -> NSImage? {
        guard let regex = try? NSRegularExpression(
            pattern: #"data:image/(png|jpeg|jpg|gif|webp);base64,([A-Za-z0-9+/=]+)"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              match.numberOfRanges >= 3,
              let dataRange = Range(match.range(at: 2), in: html) else { return nil }
        let b64 = String(html[dataRange])
        guard let data = Data(base64Encoded: b64, options: [.ignoreUnknownCharacters]),
              let image = NSImage(data: data),
              isUsable(image) else { return nil }
        return image
    }
}
