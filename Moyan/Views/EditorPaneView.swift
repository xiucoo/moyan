import SwiftUI

/// 右侧主编辑区：标题旁放显示方式，下方标签 / 工具栏 / 正文。
struct EditorPaneView: View {
    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var bridge: EditorBridge
    @EnvironmentObject private var settings: AppSettings

    @StateObject private var aiSearch = CursorAIService()
    @State private var showFindBar = false
    @State private var showReplaceFields = false
    @State private var findQuery = ""
    @State private var replaceQuery = ""
    @State private var findStatus = ""
    @State private var showAISearchPanel = false
    @State private var aiSearchQuery = ""

    var body: some View {
        Group {
            if let note = store.selectedNote {
                if note.isTrashed {
                    trashPreview(note)
                } else {
                    editor(for: note)
                }
            } else {
                emptyState
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            bridge.onTextMutated = { [weak store] text in
                guard let store, let id = store.selectedNoteID else { return }
                store.updateNoteContent(id, content: text)
            }
            bridge.onAISearchRequested = { selection in
                openCursorAsk(selection: selection)
            }
            // 先创建子文件拿到 ID，再回写父任务行可点击标记，并加固父子索引
            bridge.onCreateChildNoteFromTask = { [weak store] taskText in
                guard let store, let parentID = store.selectedNoteID,
                      let parent = store.notes.first(where: { $0.id == parentID }) else { return }
                guard let child = store.createChildNoteFromTask(taskText, parentNoteID: parentID) else { return }
                // create 后已选中子文件；用创建前的父正文打标再写回
                let annotated = ChildNoteMarkerSupport.annotatingTaskLine(
                    in: parent.content,
                    taskText: taskText,
                    childNoteID: child.id
                )
                if annotated != parent.content {
                    store.updateNoteContent(parentID, content: annotated)
                }
                _ = store.repairChildRelationships()
            }
            bridge.onOpenChildNote = { [weak store] childID in
                store?.openChildNote(id: childID)
            }
            bridge.onOpenWPSFile = { [weak store] id in
                store?.presentWPSPreview(id)
            }
            bridge.onCreateWPSFile = { [weak store] kind in
                _ = store?.createWPSFile(kind: kind)
            }
            bridge.onLinkExternalWPS = { [weak store] in
                store?.beginLinkExternalWPSFile()
            }
            bridge.onOpenWPSInApp = { [weak store] id in
                store?.openWPSFile(id)
            }
            bridge.onUnlinkWPS = { [weak store] id in
                store?.unlinkWPSFile(id)
            }
            bridge.resolveChildNoteID = { [weak store] taskText in
                guard let store, let parentID = store.selectedNoteID else { return nil }
                return store.childNoteID(forTaskText: taskText, parentNoteID: parentID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .moyanFind)) { _ in
            openFind(showReplace: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .moyanFindReplace)) { _ in
            openFind(showReplace: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .moyanFindNext)) { _ in
            if !showFindBar { openFind(showReplace: showReplaceFields) }
            findNext()
        }
        .onReceive(NotificationCenter.default.publisher(for: .moyanFindPrevious)) { _ in
            if !showFindBar { openFind(showReplace: showReplaceFields) }
            findPrevious()
        }
        .onReceive(NotificationCenter.default.publisher(for: .moyanCursorAsk)) { _ in
            openCursorAsk(selection: bridge.selectedMarkdown())
        }
    }

    @ViewBuilder
    private func editor(for note: Note) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                TextField(
                    store.isWorkLogFolder(note.folderID) ? "日期标题" : "标题",
                    text: Binding(
                        get: { store.notes.first(where: { $0.id == note.id })?.title ?? note.title },
                        set: { store.updateNoteTitle(note.id, title: $0) }
                    )
                )
                .font(.system(size: 26, weight: .semibold))
                .textFieldStyle(.plain)

                Spacer(minLength: 8)

                Button {
                    openFind(showReplace: false)
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("在正文中查找 ⌘F")
                .disabled(store.editorMode == .preview)

                Picker("", selection: $store.editorMode) {
                    ForEach(EditorMode.allCases) { mode in
                        Image(systemName: mode.systemImage)
                            .help(mode.label)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 118)
                .help("编辑 / 预览 / 分栏")
            }
            .padding(.horizontal, 28)
            .padding(.top, 16)
            .padding(.bottom, store.isWorkLogFolder(note.folderID) ? 2 : 4)

            if store.isWorkLogFolder(note.folderID) {
                TextField(
                    "工作简介（副标题）",
                    text: Binding(
                        get: { store.notes.first(where: { $0.id == note.id })?.subtitle ?? note.subtitle },
                        set: { store.updateNoteSubtitle(note.id, subtitle: $0) }
                    )
                )
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .textFieldStyle(.plain)
                .padding(.horizontal, 28)
                .padding(.bottom, 6)
            }

            if let parentID = note.parentNoteID,
               let parent = store.notes.first(where: { $0.id == parentID && !$0.isTrashed }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.up.left")
                        .font(.system(size: 11, weight: .semibold))
                    Button {
                        store.selectNote(parent)
                    } label: {
                        Text("父笔记：\(parent.title)")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    if let task = note.linkedTaskText, !task.isEmpty {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(task)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(settings.accent.color)
                .padding(.horizontal, 28)
                .padding(.bottom, 6)
                .help("返回关联的父笔记")
            }

            TagBarView(noteID: note.id)

            if store.editorMode != .preview {
                MarkdownToolbarView(onAISearch: {
                    openCursorAsk(selection: bridge.selectedMarkdown())
                })
            }

            if showFindBar, store.editorMode != .preview {
                EditorFindReplaceBar(
                    findText: $findQuery,
                    replaceText: $replaceQuery,
                    showReplace: $showReplaceFields,
                    statusText: findStatus,
                    onFindNext: findNext,
                    onFindPrevious: findPrevious,
                    onReplace: replaceOne,
                    onReplaceAll: replaceAll,
                    onClose: {
                        showFindBar = false
                        findStatus = ""
                        bridge.focusEditor()
                    }
                )
                .onChange(of: findQuery) { _, _ in
                    updateFindStatus()
                }
            }

            let contentBinding = Binding(
                get: { store.notes.first(where: { $0.id == note.id })?.content ?? note.content },
                set: { store.updateNoteContent(note.id, content: $0) }
            )

            if let wpsID = store.activeWPSPreviewID {
                WPSPreviewPane(fileID: wpsID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    Group {
                        switch store.editorMode {
                        case .editor:
                            markdownEditor(noteID: note.id, content: contentBinding)
                        case .preview:
                            MarkdownPreviewView(
                                content: previewMarkdown(for: note, content: contentBinding.wrappedValue),
                                baseURL: store.libraryURL,
                                onOpenChildNote: { store.openChildNote(id: $0) },
                                onOpenWPSFile: { store.presentWPSPreview($0) }
                            )
                        case .split:
                            HSplitView {
                                markdownEditor(noteID: note.id, content: contentBinding)
                                    .frame(minWidth: 200)
                                MarkdownPreviewView(
                                    content: previewMarkdown(for: note, content: contentBinding.wrappedValue),
                                    baseURL: store.libraryURL,
                                    onOpenChildNote: { store.openChildNote(id: $0) },
                                    onOpenWPSFile: { store.presentWPSPreview($0) }
                                )
                                .frame(minWidth: 200)
                            }
                        }
                    }
                    .frame(minWidth: 280)

                    if showAISearchPanel {
                        AISearchPanelView(
                            ai: aiSearch,
                            query: $aiSearchQuery,
                            accent: settings.accent.color,
                            onClose: {
                                aiSearch.cancel()
                                showAISearchPanel = false
                            },
                            onInsert: { text in
                                insertAIResult(text, into: note.id)
                            },
                            onRerun: {
                                runCursorAsk()
                            }
                        )
                        .frame(minWidth: 300, idealWidth: 360, maxWidth: 520)
                        .frame(maxHeight: .infinity)
                        .layoutPriority(1)
                    }
                }
            }
        }
        .id(note.id)
        .onChange(of: note.id) { _, _ in
            showFindBar = false
            findStatus = ""
            aiSearch.cancel()
            showAISearchPanel = false
            aiSearchQuery = ""
            store.dismissWPSPreview()
        }
    }

    /// 打开提问面板：有选区则填入，**不自动提问**，等用户点「提问」。
    private func openCursorAsk(selection: String) {
        guard let note = store.selectedNote, !note.isTrashed else { return }
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            aiSearchQuery = trimmed
        }
        showAISearchPanel = true
        if store.editorMode == .preview {
            store.editorMode = .editor
        }
        aiSearch.cancel()
        aiSearch.lastError = nil
        // 不清空已有回答，方便改完问题再问；若问题被换了可手动再点提问
        if aiSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            aiSearch.output = ""
        }
    }

    /// 面板「提问」按钮：用当前可编辑问题发起请求。
    private func runCursorAsk() {
        guard let note = store.selectedNote, !note.isTrashed else { return }
        let ask = aiSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ask.isEmpty else {
            aiSearch.lastError = "请先填写要问的内容"
            return
        }
        showAISearchPanel = true
        Task {
            await aiSearch.searchStreaming(
                apiKey: settings.cursorAPIKey,
                selection: ask,
                noteTitle: note.title,
                noteContext: note.content,
                workDirectory: store.libraryURL,
                modelID: settings.cursorModelID
            )
        }
    }

    private func insertAIResult(_ text: String, into noteID: UUID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let current = store.notes.first(where: { $0.id == noteID })?.content ?? ""
        let block = """


        ### Cursor 提问
        \(trimmed)
        """
        store.updateNoteContent(noteID, content: current + block)
    }

    private func openFind(showReplace: Bool) {
        guard store.selectedNote != nil, !(store.selectedNote?.isTrashed ?? true) else { return }
        if store.editorMode == .preview {
            store.editorMode = .editor
        }
        showReplaceFields = showReplace
        showFindBar = true
        updateFindStatus()
    }

    private func findNext() {
        guard !findQuery.isEmpty else {
            findStatus = "输入查找内容"
            return
        }
        findStatus = bridge.find(findQuery, backwards: false) ? matchStatus() : "未找到"
    }

    private func findPrevious() {
        guard !findQuery.isEmpty else {
            findStatus = "输入查找内容"
            return
        }
        findStatus = bridge.find(findQuery, backwards: true) ? matchStatus() : "未找到"
    }

    private func replaceOne() {
        guard !findQuery.isEmpty else { return }
        _ = bridge.replace(findQuery, with: replaceQuery)
        findStatus = matchStatus()
    }

    private func replaceAll() {
        guard !findQuery.isEmpty else { return }
        let count = bridge.replaceAll(findQuery, with: replaceQuery)
        findStatus = count > 0 ? "已替换 \(count) 处" : "未找到"
    }

    private func updateFindStatus() {
        guard !findQuery.isEmpty else {
            findStatus = ""
            return
        }
        findStatus = matchStatus()
    }

    private func matchStatus() -> String {
        let n = bridge.matchCount(for: findQuery)
        return n > 0 ? "\(n) 处" : "未找到"
    }

    private func markdownEditor(noteID: UUID, content: Binding<String>) -> some View {
        MarkdownTextView(
            text: content,
            onChange: { store.updateNoteContent(noteID, content: $0) },
            bridge: bridge,
            onPasteImage: { image in
                store.savePastedImage(image, for: noteID)
            },
            libraryURL: store.libraryURL
        )
    }

    /// 预览前把纯文本「📎子文件」解析成可点链接。
    private func previewMarkdown(for note: Note, content: String) -> String {
        ChildNoteMarkerSupport.markdownWithResolvedLinks(content) { taskText in
            store.childNoteID(forTaskText: taskText, parentNoteID: note.id)
        }
    }

    private func trashPreview(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(note.title)
                        .font(.system(size: 26, weight: .semibold))
                    if !note.subtitle.isEmpty {
                        Text(note.subtitle)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    Text("已在回收站 · \(note.formattedUpdatedAt)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("恢复") { store.restoreNote(note) }
                    .buttonStyle(.borderedProminent)
                    .tint(settings.accent.color)
                Button("永久删除", role: .destructive) {
                    store.permanentlyDeleteNote(note)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)

            Divider()
            MarkdownPreviewView(content: note.content, baseURL: store.libraryURL)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.plaintext")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text(store.isTrashSelected ? "回收站中没有选中的笔记" : "选择或新建一篇笔记")
                .font(.title3)
                .foregroundStyle(.secondary)
            if !store.isTrashSelected {
                Button {
                    store.createNote()
                } label: {
                    Label("新建笔记", systemImage: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(settings.accent.color)
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
