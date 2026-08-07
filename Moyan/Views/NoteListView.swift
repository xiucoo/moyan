import AppKit
import SwiftUI

/// 中间笔记浏览：列表或备忘录式画廊；支持回收站操作与父子关联展示。
struct NoteListView: View {
    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var settings: AppSettings
    @State private var exportMessage: String?

    private var listTitle: String {
        switch store.destination {
        case .folder: return store.selectedFolder?.name ?? "笔记"
        case .tag(let tag): return "# \(tag)"
        case .trash: return "回收站"
        case .none: return "笔记"
        }
    }

    private var isGallery: Bool {
        settings.notesBrowseMode == .gallery && !store.isTrashSelected
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            if isGallery {
                galleryBody
            } else {
                listBody
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        .alert("导出", isPresented: Binding(
            get: { exportMessage != nil },
            set: { if !$0 { exportMessage = nil } }
        )) {
            Button("好", role: .cancel) { exportMessage = nil }
        } message: {
            Text(exportMessage ?? "")
        }
        .confirmationDialog(
            "继续昨日任务开发？",
            isPresented: $store.showContinueYesterdayPrompt,
            titleVisibility: .visible
        ) {
            Button("继续昨日") { store.respondContinueYesterday(true) }
            Button("新建今日", role: .cancel) { store.respondContinueYesterday(false) }
        } message: {
            Text(store.continueYesterdayPromptMessage)
        }
        .onChange(of: store.showContinueYesterdayPrompt) { _, isShowing in
            // Esc / 点外侧关闭时视为「新建今日」
            if !isShowing {
                store.respondContinueYesterday(false)
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if !store.isTrashSelected {
                    Button {
                        store.createNote()
                    } label: {
                        Label("新建", systemImage: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(settings.accent.color)
                    .disabled(store.selectedFolder == nil)
                    .help("新建笔记 ⌘N")
                } else if store.trashCount > 0 {
                    Button("清空回收站", role: .destructive) {
                        store.emptyTrash()
                    }
                    .buttonStyle(.bordered)
                }

                if !store.isTrashSelected {
                    Button {
                        store.refreshFolder(store.selectedFolder)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .help("从磁盘刷新当前文件夹（识别 Finder 新增文件）")

                    Picker("", selection: $settings.notesBrowseMode) {
                        ForEach(NotesBrowseMode.allCases) { mode in
                            Image(systemName: mode.systemImage)
                                .tag(mode)
                                .help(mode.label)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 72)
                    .help("列表 / 画廊")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    store.isTrashSelected ? "搜索回收站正文" : "搜索正文与标题",
                    text: $store.searchText
                )
                    .textFieldStyle(.plain)
                    .help("按笔记正文、副标题、标签与标题筛选（不只文件名）")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            Text(listTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
        }
    }

    // MARK: - List

    private var listBody: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { store.selectedNoteID },
                set: { id in
                    if let id, let note = store.notes.first(where: { $0.id == id }) {
                        store.selectNote(note)
                    }
                }
            )) {
                // 工作日志按今天/昨天/月份分区，其它夹仍平铺
                if store.isWorkLogFolderSelected {
                    ForEach(gallerySections) { section in
                        Section {
                            ForEach(section.notes) { note in
                                noteFamilyListRows(note)
                            }
                        } header: {
                            listSectionHeader(section.title)
                        }
                    }
                } else {
                    ForEach(store.filteredNotes) { note in
                        noteFamilyListRows(note)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            if store.filteredNotes.isEmpty {
                emptyPlaceholder
            }
        }
    }

    @ViewBuilder
    private func noteFamilyListRows(_ note: Note) -> some View {
        let children = store.childNotes(of: note.id)
        if children.isEmpty {
            noteListRow(note, isChild: note.isChildNote)
        } else {
            noteListRow(note, isChild: false)
            ForEach(children) { child in
                noteListRow(child, isChild: true)
            }
        }
    }

    private func listSectionHeader(_ title: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(settings.accent.color)
                .frame(width: 3, height: 12)
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.primary)
                .textCase(nil)
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func noteListRow(_ note: Note, isChild: Bool) -> some View {
        let isWorkLog = store.isWorkLogFolder(note.folderID)
        HStack(alignment: .top, spacing: 8) {
            if isChild {
                // 左侧竖线 + 折线，表达挂在父笔记下的子文件
                ChildRelationRail(accent: settings.accent.color)
                    .frame(width: 14)
                    .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if isChild {
                        Image(systemName: "doc.text")
                            .font(.system(size: 10))
                            .foregroundStyle(settings.accent.color.opacity(0.85))
                    }
                    Text(note.title)
                        .font(.system(size: isChild ? 12 : 13, weight: isChild ? .medium : .semibold))
                        .lineLimit(1)
                }
                if isChild, let task = note.linkedTaskText, !task.isEmpty {
                    Text("任务：\(task)")
                        .font(.system(size: 11))
                        .foregroundStyle(settings.accent.color.opacity(0.9))
                        .lineLimit(1)
                } else if isWorkLog, !note.subtitle.isEmpty {
                    Text(note.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(note.formattedUpdatedAt)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if !isChild {
                        let count = store.childNotes(of: note.id).count
                        if count > 0 {
                            Text("\(count) 个子文件")
                                .font(.system(size: 10))
                                .foregroundStyle(settings.accent.color.opacity(0.85))
                        }
                    }
                    if !isWorkLog && !isChild {
                        Text(note.fileName)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if !note.tags.isEmpty && !store.isTrashSelected {
                        Text(note.tags.prefix(2).joined(separator: " · "))
                            .font(.system(size: 10))
                            .foregroundStyle(settings.accent.color.opacity(0.9))
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, isChild ? 2 : 4)
        .padding(.leading, isChild ? 4 : 0)
        .tag(note.id)
        .contextMenu { noteMenu(note) }
        .help(
            isChild
                ? "子文件 · 关联任务：\(note.linkedTaskText ?? note.title)"
                : (isWorkLog
                    ? (note.subtitle.isEmpty ? note.fileName : "\(note.subtitle) · \(note.fileName)")
                    : (note.isTrashed ? note.fileName : "拖到左侧文件夹可移动 · \(note.fileName)"))
        )
        .modifier(NoteDragModifier(note: note, enabled: !note.isTrashed))
    }

    // MARK: - Gallery（备忘录画廊）

    private var galleryBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if store.filteredNotes.isEmpty {
                    emptyPlaceholder
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    ForEach(Array(gallerySections.enumerated()), id: \.element.id) { index, section in
                        VStack(alignment: .leading, spacing: 12) {
                            if index > 0 {
                                // 日期间硬分隔，避免区块糊在一起
                                Rectangle()
                                    .fill(Color.primary.opacity(0.08))
                                    .frame(height: 1)
                                    .padding(.bottom, 4)
                            }

                            gallerySectionHeader(section.title)

                            LazyVStack(alignment: .leading, spacing: 14) {
                                ForEach(section.notes) { note in
                                    noteFamilyCard(note)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    /// 日期分区标题：左侧色条 + 更大字重，强化「今天 / 昨天 / 某月」边界。
    private func gallerySectionHeader(_ title: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(settings.accent.color)
                .frame(width: 3, height: 16)
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
        .accessibilityAddTraits(.isHeader)
    }

    /// 大文件在上、子文件小卡片在下；整组包在关联框里，避免父子看起来像平级卡片。
    @ViewBuilder
    private func noteFamilyCard(_ note: Note) -> some View {
        let children = store.childNotes(of: note.id)
        let familySelected = store.selectedNoteID == note.id
            || children.contains(where: { $0.id == store.selectedNoteID })

        VStack(alignment: .leading, spacing: 0) {
            NoteGalleryCard(
                note: note,
                isSelected: store.selectedNoteID == note.id,
                accent: settings.accent.color,
                showsSubtitle: store.isWorkLogFolder(note.folderID),
                style: .parent
            )
            .onTapGesture { store.selectNote(note) }
            .contextMenu { noteMenu(note) }
            .modifier(NoteDragModifier(note: note, enabled: !note.isTrashed))

            if !children.isEmpty {
                HStack(alignment: .top, spacing: 0) {
                    // 从父卡片底部垂下的关联轴
                    VStack(spacing: 0) {
                        Rectangle()
                            .fill(settings.accent.color.opacity(0.55))
                            .frame(width: 2, height: 12)
                        Circle()
                            .fill(settings.accent.color)
                            .frame(width: 8, height: 8)
                        Rectangle()
                            .fill(settings.accent.color.opacity(0.4))
                            .frame(width: 2)
                            .frame(maxHeight: .infinity)
                    }
                    .frame(width: 18)
                    .padding(.leading, 16)

                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 4) {
                            Image(systemName: "link")
                                .font(.system(size: 9, weight: .bold))
                            Text("关联子文件 · \(children.count)")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(settings.accent.color)
                        .padding(.top, 6)

                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 128, maximum: 168), spacing: 8)],
                            spacing: 8
                        ) {
                            ForEach(children) { child in
                                NoteGalleryCard(
                                    note: child,
                                    isSelected: store.selectedNoteID == child.id,
                                    accent: settings.accent.color,
                                    showsSubtitle: false,
                                    style: .child
                                )
                                .onTapGesture { store.selectNote(child) }
                                .contextMenu { noteMenu(child) }
                                .modifier(NoteDragModifier(note: child, enabled: !child.isTrashed))
                            }
                        }
                    }
                    .padding(.bottom, 8)
                    .padding(.trailing, 8)
                }
            }
        }
        .padding(children.isEmpty ? 0 : 7)
        .background {
            if !children.isEmpty {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(settings.accent.color.opacity(familySelected ? 0.08 : 0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                settings.accent.color.opacity(familySelected ? 0.45 : 0.22),
                                lineWidth: familySelected ? 1.5 : 1
                            )
                    )
            }
        }
    }

    /// 按「今天 / 昨天 / 月份」分组，贴近系统备忘录画廊分区。
    private var gallerySections: [NoteGallerySection] {
        let calendar = Calendar.current
        var buckets: [String: [Note]] = [:]
        var order: [String] = []

        for note in store.filteredNotes {
            let key = gallerySectionKey(for: note, calendar: calendar)
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(note)
        }

        return order.compactMap { key in
            guard let notes = buckets[key], !notes.isEmpty else { return nil }
            return NoteGallerySection(id: key, title: key, notes: notes)
        }
    }

    private func gallerySectionKey(for note: Note, calendar: Calendar) -> String {
        let date = galleryDate(for: note) ?? note.updatedAt
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            formatter.dateFormat = "M月"
        } else {
            formatter.dateFormat = "yyyy年M月"
        }
        return formatter.string(from: date)
    }

    private func galleryDate(for note: Note) -> Date? {
        if store.isWorkLogFolder(note.folderID) {
            if let date = WorkLogTitle.sortDate(from: note.title) { return date }
        }
        return note.updatedAt
    }

    private var emptyPlaceholder: some View {
        ContentUnavailableView {
            Label(
                store.isTrashSelected ? "回收站为空" : "暂无笔记",
                systemImage: store.isTrashSelected ? "trash" : "doc"
            )
        } description: {
            Text(store.isTrashSelected ? "删除的笔记会出现在这里" : "按 ⌘N 新建一篇，或从其它夹拖入")
        }
        .frame(maxHeight: 160)
    }

    // MARK: - Menu

    @ViewBuilder
    private func noteMenu(_ note: Note) -> some View {
        if note.isTrashed {
            Button("恢复") { store.restoreNote(note) }
            Button("在 Finder 中显示") { store.revealNoteInFinder(note) }
            Button("永久删除", role: .destructive) { store.permanentlyDeleteNote(note) }
        } else {
            if let parentID = note.parentNoteID,
               let parent = store.notes.first(where: { $0.id == parentID && !$0.isTrashed }) {
                Button("打开父笔记") { store.selectNote(parent) }
                Divider()
            }
            Button("在 Finder 中显示") { store.revealNoteInFinder(note) }
            if store.folders.count > 1 {
                Menu("移动到") {
                    ForEach(store.folders.filter { $0.id != note.folderID }) { folder in
                        Button(folder.name) {
                            store.moveNote(withID: note.id, toFolderID: folder.id)
                        }
                    }
                }
            }
            Divider()
            Menu("WPS") {
                Button("新建表格") {
                    store.selectNote(note)
                    _ = store.createWPSFile(kind: .spreadsheet, inNote: note.id)
                }
                Button("新建文档") {
                    store.selectNote(note)
                    _ = store.createWPSFile(kind: .document, inNote: note.id)
                }
                Button("关联已有文件…") {
                    store.selectNote(note)
                    store.beginLinkExternalWPSFile(toNote: note.id)
                }
                let linked = store.wpsFiles(forNote: note.id)
                if !linked.isEmpty {
                    Divider()
                    ForEach(linked) { file in
                        Button("预览：\(file.title)") {
                            store.selectNote(note)
                            store.presentWPSPreview(file.id)
                        }
                    }
                }
            }
            Divider()
            Button {
                store.presentAIAnalyze(for: note)
            } label: {
                Label("AI 分析…", systemImage: "sparkles")
            }
            Button("导出为 PDF…") { Task { await export(note) } }
            Divider()
            Button("移到回收站", role: .destructive) { store.deleteNote(note) }
        }
    }

    private func export(_ note: Note) async {
        do {
            let ns = NSColor(settings.accent.color).usingColorSpace(.sRGB) ?? .systemGreen
            let hex = String(
                format: "#%02X%02X%02X",
                Int(ns.redComponent * 255),
                Int(ns.greenComponent * 255),
                Int(ns.blueComponent * 255)
            )
            if let url = try await PDFExporter.exportNote(note, accentHex: hex) {
                exportMessage = "已导出到\n\(url.path)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            exportMessage = "导出失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - Relation chrome

/// 列表子行左侧的关联导轨。
private struct ChildRelationRail: View {
    let accent: Color

    var body: some View {
        GeometryReader { geo in
            let midX = geo.size.width / 2
            Path { path in
                path.move(to: CGPoint(x: midX, y: 0))
                path.addLine(to: CGPoint(x: midX, y: geo.size.height * 0.45))
                path.addLine(to: CGPoint(x: geo.size.width - 1, y: geo.size.height * 0.45))
            }
            .stroke(accent.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - Gallery models / card

private struct NoteGallerySection: Identifiable {
    let id: String
    let title: String
    let notes: [Note]
}

private enum NoteGalleryCardStyle {
    case parent
    case child
}

/// 备忘录风格卡片：结构化正文预览 + 标题/简介/时间；子文件用更小尺寸。
private struct NoteGalleryCard: View {
    let note: Note
    let isSelected: Bool
    let accent: Color
    let showsSubtitle: Bool
    var style: NoteGalleryCardStyle = .parent

    private var maxPreviewLines: Int {
        style == .child ? 6 : 12
    }

    private var previewLines: [MarkdownPlainPreview.Line] {
        MarkdownPlainPreview.lines(from: note.content, maxLines: maxPreviewLines)
    }

    /// 按内容行数收缩，避免短笔记留下大块空洞。
    private var previewHeight: CGFloat {
        let lineH: CGFloat = style == .child ? 13 : 15
        let pad: CGFloat = style == .child ? 18 : 22
        let count = max(previewLines.count, 1)
        let codeBonus = CGFloat(previewLines.filter {
            if case .code = $0 { return true }
            return false
        }.count) * 4
        let computed = CGFloat(count) * lineH + pad + codeBonus
        let minH: CGFloat = style == .child ? 56 : 76
        let maxH: CGFloat = style == .child ? 96 : 176
        return min(max(computed, minH), maxH)
    }

    private var corner: CGFloat {
        style == .child ? 8 : 10
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style == .child ? 4 : 6) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))

                if previewLines.isEmpty {
                    Text("空白笔记")
                        .font(.system(size: style == .child ? 10 : 11))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: style == .child ? 2.5 : 3.5) {
                        ForEach(Array(previewLines.enumerated()), id: \.offset) { _, line in
                            previewRow(line)
                        }
                    }
                    .padding(style == .child ? 8 : 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                if style == .child {
                    Image(systemName: "link")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(accent)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .frame(height: previewHeight)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(
                        isSelected ? accent : (style == .child ? accent.opacity(0.28) : Color.primary.opacity(0.08)),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .shadow(color: .black.opacity(style == .child ? 0.06 : 0.12), radius: isSelected ? 6 : 2, y: 1)

            // 子文件标题常与关联任务同文；有任务文案时只保留绿色那一行，避免叠两行重复。
            if style == .child, let task = note.linkedTaskText, !task.isEmpty {
                Text(task)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.9))
                    .lineLimit(1)
            } else {
                Text(note.title)
                    .font(.system(size: style == .child ? 11 : 12, weight: .semibold))
                    .lineLimit(1)
                if showsSubtitle, !note.subtitle.isEmpty {
                    Text(note.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text(timeLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func previewRow(_ line: MarkdownPlainPreview.Line) -> some View {
        let baseSize: CGFloat = style == .child ? 9.5 : 10.5
        switch line {
        case .heading(let text):
            Text(text)
                .font(.system(size: baseSize + 0.5, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.92))
                .lineLimit(1)

        case .task(let done, let text, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(done ? "☑" : "☐")
                    .font(.system(size: baseSize))
                    .foregroundStyle(done ? AnyShapeStyle(accent.opacity(0.85)) : AnyShapeStyle(.secondary))
                Text(text)
                    .font(.system(size: baseSize))
                    .foregroundStyle(done ? Color.secondary : Color.primary.opacity(0.88))
                    .strikethrough(done, color: Color.secondary.opacity(0.55))
                    .lineLimit(1)
            }
            .padding(.leading, CGFloat(depth) * 8)

        case .bullet(let text, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("•")
                    .font(.system(size: baseSize, weight: .bold))
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.system(size: baseSize))
                    .foregroundStyle(.primary.opacity(0.88))
                    .lineLimit(1)
            }
            .padding(.leading, CGFloat(depth) * 8)

        case .numbered(let index, let text, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(index).")
                    .font(.system(size: baseSize, weight: .medium, design: .rounded))
                    .foregroundStyle(accent.opacity(0.85))
                    .frame(minWidth: 14, alignment: .trailing)
                Text(text)
                    .font(.system(size: baseSize))
                    .foregroundStyle(.primary.opacity(0.88))
                    .lineLimit(1)
            }
            .padding(.leading, CGFloat(depth) * 8)

        case .code(let text):
            HStack(spacing: 4) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: baseSize - 1.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.system(size: baseSize - 0.5, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.78))
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

        case .body(let text):
            Text(text)
                .font(.system(size: baseSize))
                .foregroundStyle(.primary.opacity(0.86))
                .lineLimit(2)
        }
    }

    private var timeLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        if Calendar.current.isDateInToday(note.updatedAt) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = "M月d日"
        }
        return formatter.string(from: note.updatedAt)
    }
}

/// 仅对未删除笔记启用拖拽，避免回收站误拖。
private struct NoteDragModifier: ViewModifier {
    let note: Note
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.draggable(note.id.uuidString) {
                Label(note.title, systemImage: "doc.text")
                    .padding(8)
            }
        } else {
            content
        }
    }
}
