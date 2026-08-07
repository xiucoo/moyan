import AppKit
import Combine
import Foundation
import SwiftUI

/// 笔记库：文件夹 / 标签 / 回收站 / 图片资源，同步到本机或 iCloud Drive。
@MainActor
final class NoteStore: ObservableObject {
    /// 左侧固定默认夹：知识积累 / 当日工作记录（缺失时自动创建并置顶）。
    static let defaultFolderSpecs: [(name: String, symbolName: String)] = [
        ("知识库", "books.vertical"),
        ("工作日志", "calendar"),
    ]

    static func isDefaultFolderName(_ name: String) -> Bool {
        defaultFolderSpecs.contains { $0.name == name }
    }
    @Published var folders: [NoteFolder] = []
    @Published var notes: [Note] = []
    @Published var destination: SidebarDestination?
    @Published var selectedNoteID: UUID?
    @Published var searchText: String = ""
    @Published var editorMode: EditorMode = .editor
    @Published var isCreatingFolder: Bool = false
    @Published var newFolderName: String = ""
    @Published var isRenamingFolder: Bool = false
    @Published var renamingFolderID: UUID?
    @Published var renameFolderName: String = ""
    @Published var storageMode: StorageMode
    @Published var syncStatusText: String = "已同步"
    @Published var lastErrorMessage: String?
    /// 是否展示 Cursor AI 分析面板。
    @Published var showAIAnalyze = false
    /// 当前 AI 分析目标（笔记或文件夹）；关闭面板时清空。
    @Published var aiAnalyzeTarget: AIAnalyzeTarget?
    /// 工作日志：进入夹内时若无覆盖今日的篇，询问是否延续昨日（改名，不新建）。
    @Published var showContinueYesterdayPrompt = false
    /// 延续昨日弹窗文案（含建议标题）。
    @Published var continueYesterdayPromptMessage = ""
    /// 待处理工作日志的文件夹；用户确认后消费。
    private var pendingWorkLogFolderID: UUID?
    /// 被延续的昨日（或最近一篇）工作日志。
    private var pendingPreviousWorkLogID: UUID?
    /// 防止确认弹窗按钮 + dismiss 双触发。
    private var continueYesterdayResolved = true
    /// 挂在笔记上的 WPS / Office 文件。
    @Published var wpsFiles: [WPSLinkedFile] = []
    /// 当前打开的 WPS 预览；非空时编辑区展示预览面板。
    @Published var activeWPSPreviewID: UUID?

    @Published private(set) var libraryURL: URL

    private var metaURL: URL { libraryURL.appendingPathComponent(".moyan-meta.json") }
    private var trashDirectory: URL { libraryURL.appendingPathComponent(".Trash", isDirectory: true) }
    private var assetsDirectory: URL { libraryURL.appendingPathComponent("assets", isDirectory: true) }
    private var wpsDirectory: URL { libraryURL.appendingPathComponent("wps", isDirectory: true) }

    private var saveTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var watcherDebounceTask: Task<Void, Never>?
    private var isWriting = false
    private var lastKnownMetaModified: Date?
    /// 磁盘笔记指纹（路径+mtime），用于发现 Finder 增删改，而不仅依赖 meta。
    private var lastLibraryFingerprint: String?
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var watchFileDescriptor: CInt = -1
    /// 跨日 / 回前台时检查「继续昨日」的通知观察者。
    nonisolated(unsafe) private var calendarDayObserver: NSObjectProtocol?
    nonisolated(unsafe) private var becomeActiveObserver: NSObjectProtocol?

    init(storageMode: StorageMode = .local, libraryURL: URL? = nil) {
        var mode = storageMode
        if mode == .iCloudDrive && !LibraryLocation.isICloudDriveAvailable {
            mode = .local
        }
        self.storageMode = mode
        self.libraryURL = libraryURL ?? LibraryLocation.url(for: mode)
        loadOrSeed()
        lastLibraryFingerprint = libraryFingerprint()
        startWatching()
        startWorkLogDayObservers()
    }

    deinit {
        // DispatchSource 需在非隔离上下文关闭；尽量取消轮询任务。
        watchTask?.cancel()
        watcherDebounceTask?.cancel()
        // 观察者用非隔离句柄移除，避免 @MainActor deinit 报错
        if let calendarDayObserver {
            NotificationCenter.default.removeObserver(calendarDayObserver)
        }
        if let becomeActiveObserver {
            NotificationCenter.default.removeObserver(becomeActiveObserver)
        }
    }

    // MARK: - Derived

    var selectedFolderID: UUID? {
        if case .folder(let id) = destination { return id }
        return nil
    }

    var selectedFolder: NoteFolder? {
        guard let id = selectedFolderID else { return nil }
        return folders.first { $0.id == id }
    }

    var selectedNote: Note? {
        notes.first { $0.id == selectedNoteID && !$0.isTrashed }
            ?? notes.first { $0.id == selectedNoteID }
    }

    var isTrashSelected: Bool {
        if case .trash = destination { return true }
        return false
    }

    var selectedTag: String? {
        if case .tag(let name) = destination { return name }
        return nil
    }

    /// 全部未删除笔记上的标签（去重排序）。
    var allTags: [String] {
        var set = Set<String>()
        for note in notes where !note.isTrashed {
            for tag in note.tags { set.insert(tag) }
        }
        return set.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var trashCount: Int {
        notes.filter(\.isTrashed).count
    }

    var notesInSelectedFolder: [Note] {
        guard let folderID = selectedFolderID else { return [] }
        return sortNotes(notes.filter { !$0.isTrashed && $0.folderID == folderID }, inFolderID: folderID)
    }

    /// 当前选中是否为「工作日志」默认夹（标题=日期，副标题=工作简介）。
    var isWorkLogFolderSelected: Bool {
        selectedFolder?.name == "工作日志"
    }

    func isWorkLogFolder(_ folderID: UUID) -> Bool {
        folders.first(where: { $0.id == folderID })?.name == "工作日志"
    }

    var filteredNotes: [Note] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [Note]
        let folderIDForSort: UUID?
        switch destination {
        case .folder(let id):
            base = notes.filter { !$0.isTrashed && $0.folderID == id }
            folderIDForSort = id
        case .tag(let tag):
            base = notes.filter { !$0.isTrashed && $0.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) }
            folderIDForSort = nil
        case .trash:
            base = notes.filter(\.isTrashed)
            folderIDForSort = nil
        case .none:
            base = []
            folderIDForSort = nil
        }
        let filtered = query.isEmpty
            ? base
            : base.filter { noteMatchesSearch($0, query: query) }

        // 非搜索时只列「大文件」（根笔记）；子文件挂在父笔记下展示。
        // 搜索命中子文件时仍露出，避免漏结果。
        let visible: [Note]
        if query.isEmpty {
            visible = filtered.filter { note in
                guard let parentID = note.parentNoteID else { return true }
                // 父仍在库中则子文件不单独占一行；孤儿子文件升格为可见根
                return !notes.contains(where: { $0.id == parentID && !$0.isTrashed })
            }
        } else {
            visible = filtered
        }
        return sortNotes(visible, inFolderID: folderIDForSort)
    }

    /// 某篇笔记下的子文件（未删除），按更新时间倒序。
    func childNotes(of parentID: UUID) -> [Note] {
        notes
            .filter { !$0.isTrashed && $0.parentNoteID == parentID }
            .sorted {
                let lhs = $0.updatedAt
                let rhs = $1.updatedAt
                return lhs > rhs
            }
    }

    /// 搜索以正文为主；内存无命中时再读磁盘，避免索引正文过期漏搜。
    private func noteMatchesSearch(_ note: Note, query: String) -> Bool {
        if note.content.localizedCaseInsensitiveContains(query) { return true }
        if note.subtitle.localizedCaseInsensitiveContains(query) { return true }
        if note.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }
        // 标题次之（工作日志标题常是日期文件名）
        if note.title.localizedCaseInsensitiveContains(query) { return true }
        if let disk = try? String(contentsOf: fileURL(for: note), encoding: .utf8),
           disk.localizedCaseInsensitiveContains(query) {
            return true
        }
        return false
    }

    /// 工作日志按日期/区间结束日倒序；其它夹按更新时间。
    private func sortNotes(_ list: [Note], inFolderID folderID: UUID?) -> [Note] {
        if let folderID, isWorkLogFolder(folderID) {
            return list.sorted { lhs, rhs in
                let ld = WorkLogTitle.sortDate(from: lhs.title) ?? .distantPast
                let rd = WorkLogTitle.sortDate(from: rhs.title) ?? .distantPast
                if ld != rd { return ld > rd }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedDescending
            }
        }
        return list.sorted {
            let lhs = $0.deletedAt ?? $0.updatedAt
            let rhs = $1.deletedAt ?? $1.updatedAt
            return lhs > rhs
        }
    }

    // MARK: - Navigation

    func selectFolder(_ folder: NoteFolder) {
        destination = .folder(folder.id)
        // 进入文件夹时先对齐磁盘，避免 Finder 新文件进不了列表
        syncFromDisk(quiet: true)
        // 进入工作日志：若当天还没有日志则自动新建并选中
        if folder.name == "工作日志" {
            _ = ensureTodayWorkLog(in: folder.id)
            return
        }
        selectedNoteID = filteredNotes.first?.id
    }

    /// 手动刷新当前（或指定）文件夹：按磁盘重建该夹可见笔记。
    func refreshFolder(_ folder: NoteFolder? = nil) {
        let target = folder ?? selectedFolder
        syncFromDisk(quiet: false)
        if let target, target.name == "工作日志" {
            _ = ensureTodayWorkLog(in: target.id)
        } else if let target {
            destination = .folder(target.id)
            selectedNoteID = filteredNotes.first?.id
        }
        let name = target?.name ?? "全部"
        let count = target.map { folder in
            notes.filter { !$0.isTrashed && $0.folderID == folder.id }.count
        } ?? notes.filter { !$0.isTrashed }.count
        syncStatusText = "「\(name)」已刷新（\(count) 篇）· \(Self.clock.string(from: .now))"
    }

    func selectTag(_ tag: String) {
        destination = .tag(tag)
        selectedNoteID = filteredNotes.first?.id
    }

    func selectTrash() {
        destination = .trash
        selectedNoteID = filteredNotes.first?.id
    }

    func selectNote(_ note: Note) {
        if activeWPSPreviewID != nil {
            activeWPSPreviewID = nil
        }
        selectedNoteID = note.id
    }

    // MARK: - AI Analyze

    /// 打开单篇笔记的 AI 分析（右键 / 工具栏）。
    func presentAIAnalyze(for note: Note) {
        guard !note.isTrashed else { return }
        if let folder = folders.first(where: { $0.id == note.folderID }) {
            destination = .folder(folder.id)
        }
        selectedNoteID = note.id
        aiAnalyzeTarget = .note(note.id)
        showAIAnalyze = true
    }

    /// 打开整个文件夹的 AI 分析（右键）。
    func presentAIAnalyze(for folder: NoteFolder) {
        selectFolder(folder)
        aiAnalyzeTarget = .folder(folder.id)
        showAIAnalyze = true
    }

    /// 按当前选中项打开 AI 分析（优先笔记）。
    func presentAIAnalyzeForSelection() {
        if let note = selectedNote, !note.isTrashed {
            presentAIAnalyze(for: note)
        } else if let folder = selectedFolder {
            presentAIAnalyze(for: folder)
        }
    }

    func dismissAIAnalyze() {
        showAIAnalyze = false
        aiAnalyzeTarget = nil
    }

    /// 组装文件夹下全部未删除笔记，供 AI 一次性阅读。
    func aiBundle(forFolderID folderID: UUID) -> (title: String, content: String, notes: [Note]) {
        let name = folders.first(where: { $0.id == folderID })?.name ?? "文件夹"
        let list = notes
            .filter { $0.folderID == folderID && !$0.isTrashed }
            .sorted { $0.updatedAt > $1.updatedAt }
        let body = list.map { "## \($0.title)\n\n\($0.content)" }
            .joined(separator: "\n\n---\n\n")
        let title = "文件夹「\(name)」（\(list.count) 篇）"
        return (title, body, list)
    }

    // MARK: - Folders

    func beginCreateFolder() {
        newFolderName = ""
        isCreatingFolder = true
    }

    func createFolder(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if folders.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            lastErrorMessage = "已存在同名文件夹「\(trimmed)」"
            return
        }
        let folder = NoteFolder(name: trimmed, symbolName: Self.symbol(for: trimmed))
        folders.append(folder)
        do {
            try FileManager.default.createDirectory(at: folderURL(for: folder), withIntermediateDirectories: true)
        } catch {
            lastErrorMessage = "创建失败：\(error.localizedDescription)"
            folders.removeAll { $0.id == folder.id }
            return
        }
        destination = .folder(folder.id)
        selectedNoteID = nil
        isCreatingFolder = false
        syncStatusText = "已新建文件夹"
        persistMeta()
    }

    func beginRenameFolder(_ folder: NoteFolder) {
        renamingFolderID = folder.id
        renameFolderName = folder.name
        isRenamingFolder = true
    }

    func beginRenameSelectedFolder() {
        guard let folder = selectedFolder else { return }
        beginRenameFolder(folder)
    }

    func renameFolder(id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = folders.firstIndex(where: { $0.id == id }) else { return }

        if folders.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            lastErrorMessage = "已存在同名文件夹「\(trimmed)」"
            return
        }

        let oldFolder = folders[index]
        if oldFolder.name == trimmed {
            isRenamingFolder = false
            renamingFolderID = nil
            return
        }

        let oldURL = folderURL(for: oldFolder)
        var updated = oldFolder
        updated.name = trimmed
        updated.symbolName = Self.symbol(for: trimmed)
        let newURL = folderURL(for: updated)

        if oldURL != newURL {
            do {
                if FileManager.default.fileExists(atPath: newURL.path) {
                    lastErrorMessage = "目标路径已存在：\(newURL.lastPathComponent)"
                    return
                }
                if FileManager.default.fileExists(atPath: oldURL.path) {
                    try FileManager.default.moveItem(at: oldURL, to: newURL)
                } else {
                    try FileManager.default.createDirectory(at: newURL, withIntermediateDirectories: true)
                }
            } catch {
                lastErrorMessage = "重命名失败：\(error.localizedDescription)"
                return
            }
        }

        folders[index] = updated
        isRenamingFolder = false
        renamingFolderID = nil
        syncStatusText = "已重命名为「\(trimmed)」"
        persistMeta()
    }

    /// 删除文件夹：笔记进回收站，再移除空目录。默认夹不可删。
    func deleteFolder(_ folder: NoteFolder) {
        if Self.isDefaultFolderName(folder.name) {
            lastErrorMessage = "「\(folder.name)」是默认文件夹，不能删除"
            return
        }
        let related = notes.filter { $0.folderID == folder.id && !$0.isTrashed }
        for note in related {
            moveNoteToTrash(note)
        }
        folders.removeAll { $0.id == folder.id }
        try? FileManager.default.removeItem(at: folderURL(for: folder))
        if case .folder(let id) = destination, id == folder.id {
            destination = folders.first.map { .folder($0.id) }
            selectedNoteID = filteredNotes.first?.id
        }
        syncStatusText = "文件夹已删除，笔记已移入回收站"
        persistMeta()
    }

    func revealFolderInFinder(_ folder: NoteFolder) {
        let url = folderURL(for: folder)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 在 Finder 中选中该笔记对应的 `.md` 文件。
    func revealNoteInFinder(_ note: Note) {
        let url = fileURL(for: note)
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastErrorMessage = "磁盘上找不到文件：\(note.fileName)"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// 将笔记移动到目标文件夹（拖拽或右键「移动到」）。
    func moveNote(withID noteID: UUID, toFolderID folderID: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == noteID && !$0.isTrashed }) else { return }
        guard let destFolder = folders.first(where: { $0.id == folderID }) else { return }
        guard notes[index].folderID != folderID else { return }
        guard let sourceFolder = folders.first(where: { $0.id == notes[index].folderID }) else {
            lastErrorMessage = "源文件夹不存在"
            return
        }

        let fm = FileManager.default
        let oldURL = noteFileURL(notes[index], folder: sourceFolder)
        // 跨文件夹移动时压平一层子路径，落到目标夹根目录
        let baseName = (notes[index].fileName as NSString).lastPathComponent
        var newFileName = baseName
        var destURL = folderURL(for: destFolder).appendingPathComponent(newFileName)

        if fm.fileExists(atPath: destURL.path) {
            let stem = (baseName as NSString).deletingPathExtension
            let ext = (baseName as NSString).pathExtension
            let suffix = String(UUID().uuidString.prefix(6))
            newFileName = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
            destURL = folderURL(for: destFolder).appendingPathComponent(newFileName)
        }

        do {
            try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: oldURL.path) {
                try fm.moveItem(at: oldURL, to: destURL)
            } else {
                try notes[index].content.write(to: destURL, atomically: true, encoding: .utf8)
            }
        } catch {
            lastErrorMessage = "移动失败：\(error.localizedDescription)"
            return
        }

        notes[index].folderID = folderID
        notes[index].fileName = newFileName
        notes[index].updatedAt = .now
        // 仍停在原列表时选中下一篇；若已在目标夹则保持该笔记
        if case .folder(let currentID) = destination, currentID != folderID, selectedNoteID == noteID {
            selectedNoteID = filteredNotes.first?.id
        }
        syncStatusText = "已移动到「\(destFolder.name)」"
        persistMeta()
    }

    func revealSelectedFolderInFinder() {
        if let folder = selectedFolder {
            revealFolderInFinder(folder)
        } else {
            revealLibraryInFinder()
        }
    }

    func url(for folder: NoteFolder) -> URL {
        folderURL(for: folder)
    }

    // MARK: - Notes

    func createNote() {
        guard case .folder(let folderID) = destination else {
            lastErrorMessage = "请先选择一个文件夹再新建笔记"
            return
        }
        if isWorkLogFolder(folderID) {
            _ = ensureTodayWorkLog(in: folderID)
            return
        }
        _ = createNote(in: folderID, title: "未命名笔记", content: "# 未命名笔记\n\n")
    }

    /// 确保工作日志夹内存在覆盖「今天」的篇；已有则选中，没有则询问是否延续昨日。
    @discardableResult
    func ensureTodayWorkLog(in folderID: UUID) -> Note? {
        let today = Date()
        let todayStamp = Self.dayStamp.string(from: today)
        let fileName = "\(todayStamp).md"

        // 索引未收录但磁盘已有时，先同步再选中
        if let folder = folders.first(where: { $0.id == folderID }) {
            let diskURL = folderURL(for: folder).appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: diskURL.path),
               !notes.contains(where: {
                   !$0.isTrashed && $0.folderID == folderID && !$0.isChildNote
                       && ($0.fileName == fileName || WorkLogTitle.covers($0.title, day: today))
               }) {
                syncFromDisk(quiet: true)
            }
        }

        destination = .folder(folderID)

        if let existing = workLogCoveringToday(in: folderID, day: today) {
            selectedNoteID = existing.id
            return existing
        }

        // 已有待确认弹窗时不重复打断
        if showContinueYesterdayPrompt, pendingWorkLogFolderID == folderID {
            return nil
        }

        if let previous = previousWorkLog(in: folderID, before: today) {
            let suggested = WorkLogTitle.continuedTitle(previousTitle: previous.title, today: today)
            pendingWorkLogFolderID = folderID
            pendingPreviousWorkLogID = previous.id
            continueYesterdayResolved = false
            continueYesterdayPromptMessage =
                "检测到昨日工作日志「\(previous.title)」。\n继续则将标题改为「\(suggested)」，保留正文与子文件。"
            showContinueYesterdayPrompt = true
            // 先选中昨日，避免中间栏空白
            selectedNoteID = previous.id
            return nil
        }

        return createFreshTodayWorkLog(in: folderID, day: today)
    }

    /// 跨日或回到前台时：若正停在工作日志且今日尚无覆盖篇，则弹出延续询问。
    /// 今日已有篇时直接返回，避免把当前选中（含子文件）抢回父篇。
    func checkWorkLogContinuationIfNeeded() {
        guard let folder = folders.first(where: { $0.name == "工作日志" }) else { return }
        guard case .folder(let id) = destination, id == folder.id else { return }
        if workLogCoveringToday(in: folder.id, day: Date()) != nil { return }
        _ = ensureTodayWorkLog(in: folder.id)
    }

    /// 用户确认「是否继续昨日任务开发」。
    func respondContinueYesterday(_ shouldContinue: Bool) {
        showContinueYesterdayPrompt = false
        // 弹窗按钮与 dismiss 可能连续回调，只处理一次
        guard !continueYesterdayResolved else { return }
        continueYesterdayResolved = true
        continueYesterdayPromptMessage = ""
        guard let folderID = pendingWorkLogFolderID else { return }
        let previousID = pendingPreviousWorkLogID
        pendingWorkLogFolderID = nil
        pendingPreviousWorkLogID = nil

        let today = Date()
        if let existing = workLogCoveringToday(in: folderID, day: today) {
            selectedNoteID = existing.id
            return
        }

        if shouldContinue, let previousID,
           let previous = notes.first(where: { $0.id == previousID && !$0.isTrashed }) {
            _ = continueWorkLogByRenaming(previous, day: today)
        } else {
            _ = createFreshTodayWorkLog(in: folderID, day: today)
        }
    }

    /// 从当前选中笔记的任务正文创建挂钩子文件，并选中它。
    @discardableResult
    func createChildNoteFromTask(_ taskText: String, parentNoteID: UUID? = nil) -> Note? {
        let parentID = parentNoteID ?? selectedNoteID
        guard let parentID,
              let parent = notes.first(where: { $0.id == parentID && !$0.isTrashed }) else {
            lastErrorMessage = "请先打开一篇笔记再创建子文件"
            return nil
        }
        // 子文件不再套娃：挂到根父笔记上
        let rootParentID = parent.parentNoteID ?? parent.id
        guard let rootParent = notes.first(where: { $0.id == rootParentID && !$0.isTrashed }) else {
            lastErrorMessage = "父笔记不存在"
            return nil
        }

        let cleaned = MarkdownListContinuation.strippedTaskText(taskText)
        guard !cleaned.isEmpty else {
            lastErrorMessage = "任务内容为空，无法创建子文件"
            return nil
        }

        // 同一任务已有子文件则直接打开（忽略空白 / span 差异）
        if let existing = notes.first(where: {
            !$0.isTrashed
                && $0.parentNoteID == rootParentID
                && (ChildNoteMarkerSupport.tasksMatch($0.linkedTaskText ?? "", cleaned)
                    || ChildNoteMarkerSupport.tasksMatch($0.title, cleaned))
        }) {
            selectedNoteID = existing.id
            syncStatusText = "已打开关联子文件 · \(existing.title)"
            return existing
        }

        let title = cleaned
        let content = """
        # \(title)

        > 关联任务：\(cleaned)

        """
        let created = createNote(
            in: rootParent.folderID,
            title: title,
            subtitle: "关联：\(cleaned)",
            content: content,
            fileName: nil,
            parentNoteID: rootParentID,
            linkedTaskText: cleaned
        )
        if created != nil {
            syncStatusText = "已创建子文件 · \(title)"
        }
        return created
    }

    /// 根据父笔记正文里的 `moyan-child://` / 📎标记、旧版隐藏注释与「关联任务」文案，修复丢失的父子关联，并清掉正文里的 parent 注释。
    @discardableResult
    func repairChildRelationships() -> Int {
        var inferred: [UUID: (parent: UUID, task: String?)] = [:]
        var parentContentPatches: [UUID: String] = [:]

        let linkRegex = try? NSRegularExpression(
            pattern: #"moyan-child://([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})"#,
            options: [.caseInsensitive]
        )

        func remember(childID: UUID, parent: UUID, task: String?) {
            if let existing = inferred[childID] {
                // 保留已有 task；仅在空时补上
                if existing.task == nil, let task, !task.isEmpty {
                    inferred[childID] = (parent, task)
                }
                return
            }
            inferred[childID] = (parent, task)
        }

        func childMatchingTask(_ task: String, preferredParent: UUID?) -> Note? {
            let key = ChildNoteMarkerSupport.normalizedTaskKey(task)
            guard !key.isEmpty else { return nil }
            let candidates = notes.filter { note in
                guard !note.isTrashed else { return false }
                if ChildNoteMarkerSupport.tasksMatch(note.linkedTaskText ?? "", task) { return true }
                if ChildNoteMarkerSupport.tasksMatch(note.title, task) { return true }
                if let associated = Self.associatedTaskText(from: note),
                   ChildNoteMarkerSupport.tasksMatch(associated, task) {
                    return true
                }
                return false
            }
            if let preferredParent,
               let hit = candidates.first(where: { $0.parentNoteID == preferredParent || $0.parentNoteID == nil }) {
                return hit
            }
            return candidates.first
        }

        // 1) 子文件隐藏注释 `<!-- moyan-parent: UUID -->`（最稳，不依赖父正文）
        for child in notes where !child.isTrashed {
            guard let parentID = ChildNoteMarkerSupport.parentNoteID(fromContent: child.content),
                  notes.contains(where: { $0.id == parentID && !$0.isTrashed }) else { continue }
            remember(childID: child.id, parent: parentID, task: Self.associatedTaskText(from: child))
        }

        for parent in notes where !parent.isTrashed && parent.parentNoteID == nil {
            let content = parent.content
            let ns = content as NSString
            let full = NSRange(location: 0, length: ns.length)

            // 2) 正文里的 moyan-child://UUID；UUID 失效时按同行任务文案重绑
            if let linkRegex {
                linkRegex.enumerateMatches(in: content, options: [], range: full) { match, _, _ in
                    guard let match, match.numberOfRanges >= 2,
                          let linkedID = UUID(uuidString: ns.substring(with: match.range(at: 1))) else { return }
                    let rawLine = ns.substring(with: ns.lineRange(for: match.range))
                    let line = rawLine.hasSuffix("\n") ? String(rawLine.dropLast()) : rawLine
                    let task = MarkdownListContinuation.parse(line).map {
                        MarkdownListContinuation.strippedTaskText(
                            MarkdownColorSupport.stripSpans($0.taskText)
                        )
                    }

                    if notes.contains(where: { $0.id == linkedID && !$0.isTrashed }) {
                        remember(childID: linkedID, parent: parent.id, task: task)
                        return
                    }
                    // 子笔记被重建了新 ID：按任务文案找回，并改写父行链接
                    guard let task, let child = childMatchingTask(task, preferredParent: parent.id) else { return }
                    remember(childID: child.id, parent: parent.id, task: task)
                    let base = parentContentPatches[parent.id] ?? content
                    let patched = ChildNoteMarkerSupport.annotatingTaskLine(
                        in: base,
                        taskText: task,
                        childNoteID: child.id
                    )
                    if patched != base {
                        parentContentPatches[parent.id] = patched
                    }
                }
            }

            // 3) 纯文本 / 链接形式的 📎子文件 标记
            let scanContent = parentContentPatches[parent.id] ?? content
            for rawLine in scanContent.components(separatedBy: .newlines) {
                guard rawLine.contains("📎子文件"),
                      let item = MarkdownListContinuation.parse(rawLine) else { continue }
                let task = MarkdownListContinuation.strippedTaskText(
                    MarkdownColorSupport.stripSpans(item.taskText)
                )
                guard !task.isEmpty,
                      let child = childMatchingTask(task, preferredParent: parent.id) else { continue }
                remember(childID: child.id, parent: parent.id, task: task)
            }
        }

        // 4) 子笔记「关联任务：xxx」→ 同夹内找回父笔记（忽略 span / 空白）
        // 含 parentNoteID 已失效（指向不存在的父）的孤儿，一并重绑
        for child in notes where !child.isTrashed && inferred[child.id] == nil {
            let parentOK = child.parentNoteID.map { pid in
                notes.contains(where: { $0.id == pid && !$0.isTrashed })
            } ?? false
            if parentOK { continue }
            guard let task = Self.associatedTaskText(from: child) else { continue }
            if let parent = notes.first(where: { candidate in
                !candidate.isTrashed
                    && candidate.parentNoteID == nil
                    && candidate.id != child.id
                    && candidate.folderID == child.folderID
                    && ChildNoteMarkerSupport.content(candidate.content, mentionsTask: task)
                    && (candidate.content.contains("📎子文件")
                        || WorkLogTitle.sortDate(from: candidate.title) != nil)
            }) {
                remember(childID: child.id, parent: parent.id, task: task)
            }
        }

        // 已恢复的关联：确保父任务行带有可点击的 moyan-child 链接（含曾因着色打标失败的行）
        for (childID, info) in inferred {
            guard let task = info.task, !task.isEmpty else { continue }
            let base = parentContentPatches[info.parent]
                ?? notes.first(where: { $0.id == info.parent })?.content
                ?? ""
            guard !base.isEmpty else { continue }
            let patched = ChildNoteMarkerSupport.annotatingTaskLine(
                in: base,
                taskText: task,
                childNoteID: childID
            )
            if patched != base {
                parentContentPatches[info.parent] = patched
            }
        }

        var fixed = 0
        for (parentID, patched) in parentContentPatches {
            guard let index = notes.firstIndex(where: { $0.id == parentID }) else { continue }
            if notes[index].content != patched {
                notes[index].content = patched
                notes[index].updatedAt = .now
                writeNoteToDisk(notes[index])
                fixed += 1
            }
        }

        for (childID, info) in inferred {
            guard let index = notes.firstIndex(where: { $0.id == childID && !$0.isTrashed }) else { continue }
            var needs = false
            if notes[index].parentNoteID != info.parent {
                notes[index].parentNoteID = info.parent
                needs = true
            }
            if let task = info.task, !task.isEmpty,
               notes[index].linkedTaskText != task {
                notes[index].linkedTaskText = task
                needs = true
            }
            // 旧子文件若仍带隐藏父标记：关联已写入 meta 后删掉注释，避免编辑区出现 HTML 垃圾
            let stripped = ChildNoteMarkerSupport.removingParentComment(from: notes[index].content)
            if stripped != notes[index].content {
                notes[index].content = stripped
                writeNoteToDisk(notes[index])
                needs = true
            }
            if needs { fixed += 1 }
        }

        // 已有正确关联但仍残留隐藏标记的子文件：清掉注释
        for index in notes.indices where !notes[index].isTrashed {
            guard notes[index].parentNoteID != nil else { continue }
            let stripped = ChildNoteMarkerSupport.removingParentComment(from: notes[index].content)
            if stripped != notes[index].content {
                notes[index].content = stripped
                writeNoteToDisk(notes[index])
                fixed += 1
            }
            if notes[index].linkedTaskText == nil || notes[index].linkedTaskText?.isEmpty == true,
               let task = Self.associatedTaskText(from: notes[index]) {
                notes[index].linkedTaskText = task
                fixed += 1
            }
        }

        if fixed > 0 {
            persistMeta()
            syncStatusText = "已恢复 \(fixed) 条子文件关联"
        }
        return fixed
    }

    /// 从子笔记标题/副标题/正文解析「关联任务」文案。
    private static func associatedTaskText(from note: Note) -> String? {
        if let linked = note.linkedTaskText, !linked.isEmpty { return linked }
        return associatedTaskText(subtitle: note.subtitle, content: note.content)
    }

    private static func associatedTaskText(subtitle: String, content: String) -> String? {
        let candidates = [subtitle] + content.components(separatedBy: .newlines)
        for line in candidates {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 跳过隐藏父标记，避免误解析
            if trimmed.hasPrefix("<!--") { continue }
            let body: String
            if trimmed.hasPrefix(">") {
                body = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else {
                body = trimmed
            }
            for prefix in ["关联任务：", "关联任务:", "关联：", "关联:"] {
                if body.hasPrefix(prefix) {
                    let task = String(body.dropFirst(prefix.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !task.isEmpty { return task }
                }
            }
        }
        return nil
    }

    /// 打开子笔记；不存在时提示。
    func openChildNote(id: UUID) {
        guard let note = notes.first(where: { $0.id == id && !$0.isTrashed }) else {
            lastErrorMessage = "关联的子文件不存在或已删除"
            return
        }
        destination = .folder(note.folderID)
        selectedNoteID = note.id
        syncStatusText = "已打开子文件 · \(note.title)"
    }

    /// 在指定父笔记下，按任务文案查找子笔记（忽略空白 / span 差异）。
    func childNoteID(forTaskText taskText: String, parentNoteID: UUID) -> UUID? {
        let key = ChildNoteMarkerSupport.normalizedTaskKey(taskText)
        guard !key.isEmpty else { return nil }
        let rootParentID = notes.first(where: { $0.id == parentNoteID })?.parentNoteID ?? parentNoteID
        // 先在已挂接的子文件里找
        if let id = notes.first(where: {
            !$0.isTrashed
                && $0.parentNoteID == rootParentID
                && (ChildNoteMarkerSupport.tasksMatch($0.linkedTaskText ?? "", taskText)
                    || ChildNoteMarkerSupport.tasksMatch($0.title, taskText))
        })?.id {
            return id
        }
        // 关联索引丢失时：同夹内按标题/关联任务兜底
        return notes.first(where: {
            !$0.isTrashed
                && $0.folderID == (notes.first(where: { $0.id == rootParentID })?.folderID)
                && $0.id != rootParentID
                && (ChildNoteMarkerSupport.tasksMatch($0.linkedTaskText ?? "", taskText)
                    || ChildNoteMarkerSupport.tasksMatch($0.title, taskText)
                    || ChildNoteMarkerSupport.tasksMatch(Self.associatedTaskText(from: $0) ?? "", taskText))
        })?.id
    }

    /// 在指定文件夹创建笔记并选中；供「新建」与 AI 结果落盘复用。
    @discardableResult
    func createNote(
        in folderID: UUID,
        title: String,
        subtitle: String = "",
        content: String,
        fileName: String? = nil,
        parentNoteID: UUID? = nil,
        linkedTaskText: String? = nil
    ) -> Note? {
        guard folders.contains(where: { $0.id == folderID }) else {
            lastErrorMessage = "目标文件夹不存在"
            return nil
        }
        destination = .folder(folderID)
        let note = Note(
            folderID: folderID,
            title: title,
            subtitle: subtitle,
            content: content,
            fileName: fileName,
            parentNoteID: parentNoteID,
            linkedTaskText: linkedTaskText
        )
        notes.insert(note, at: 0)
        selectedNoteID = note.id
        writeNoteToDisk(note)
        persistMeta()
        return note
    }

    // MARK: - Work log helpers

    /// 找到标题区间覆盖指定自然日的根工作日志。
    private func workLogCoveringToday(in folderID: UUID, day: Date) -> Note? {
        let todayStamp = Self.dayStamp.string(from: day)
        let fileName = "\(todayStamp).md"
        return notes.first(where: {
            !$0.isTrashed && $0.folderID == folderID && !$0.isChildNote
                && ($0.fileName == fileName
                    || $0.title == todayStamp
                    || WorkLogTitle.covers($0.title, day: day))
        })
    }

    /// 今日之前最近一篇根工作日志（按标题结束日）。
    private func previousWorkLog(in folderID: UUID, before day: Date) -> Note? {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        return notes
            .filter { !$0.isTrashed && $0.folderID == folderID && !$0.isChildNote }
            .compactMap { note -> (Note, Date)? in
                guard let end = WorkLogTitle.sortDate(from: note.title) else { return nil }
                let endDay = calendar.startOfDay(for: end)
                guard endDay < dayStart else { return nil }
                return (note, endDay)
            }
            .max(by: { $0.1 < $1.1 })?
            .0
    }

    private func createFreshTodayWorkLog(in folderID: UUID, day: Date) -> Note? {
        let today = Self.dayStamp.string(from: day)
        let fileName = "\(today).md"
        let content = "# \(today)\n\n> \n\n"
        let created = createNote(
            in: folderID,
            title: today,
            subtitle: "",
            content: content,
            fileName: fileName
        )
        if created != nil {
            lastLibraryFingerprint = libraryFingerprint()
            syncStatusText = "已创建今日工作日志 · \(today)"
        }
        return created
    }

    /// 延续昨日：把既有篇改名为区间标题（如 `2026-08-04` → `2026-08-04～06`），不新建文件。
    /// 正文、简介、子文件挂靠均保留在原笔记上。
    @discardableResult
    private func continueWorkLogByRenaming(_ previous: Note, day: Date) -> Note? {
        let title = WorkLogTitle.continuedTitle(previousTitle: previous.title, today: day)
        updateNoteTitle(previous.id, title: title)
        selectedNoteID = previous.id
        lastLibraryFingerprint = libraryFingerprint()
        syncStatusText = "已延续昨日 · \(title)"
        return notes.first(where: { $0.id == previous.id && !$0.isTrashed })
    }

    /// 软删除：移入 `.Trash`。
    func deleteNote(_ note: Note) {
        moveNoteToTrash(note)
        if selectedNoteID == note.id {
            selectedNoteID = filteredNotes.first?.id
        }
        syncStatusText = "已移入回收站"
        persistMeta()
    }

    // MARK: - WPS

    /// 库内新建 WPS 表格/文档，写入正文链并可选立即打开。
    @discardableResult
    func createWPSFile(
        kind: WPSFileKind,
        inNote noteID: UUID? = nil,
        title: String? = nil,
        openAfterCreate: Bool = true
    ) -> WPSLinkedFile? {
        let targetNoteID = noteID ?? selectedNoteID
        guard let targetNoteID,
              let noteIndex = notes.firstIndex(where: { $0.id == targetNoteID && !$0.isTrashed }) else {
            lastErrorMessage = "请先打开一篇笔记再新建 WPS 文件"
            return nil
        }

        let id = UUID()
        let displayTitle = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? "未命名\(kind.label)"
        let safe = sanitizeFileName(displayTitle)
        let relativePath = "wps/\(id.uuidString)/\(safe).\(kind.defaultExtension)"
        let destURL = libraryURL.appendingPathComponent(relativePath)

        do {
            try FileManager.default.createDirectory(
                at: destURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard let template = Bundle.main.url(forResource: "Empty", withExtension: kind.defaultExtension) else {
                throw NSError(
                    domain: "Moyan",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "缺少空模板 Empty.\(kind.defaultExtension)"]
                )
            }
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: template, to: destURL)
        } catch {
            lastErrorMessage = "创建 WPS 文件失败：\(error.localizedDescription)"
            return nil
        }

        let linked = WPSLinkedFile(
            id: id,
            title: displayTitle,
            kind: kind,
            storage: .library(relativePath: relativePath),
            noteID: targetNoteID
        )
        wpsFiles.append(linked)
        let updated = WPSLinkSupport.appendingLink(linked.markdownLink, to: notes[noteIndex].content)
        notes[noteIndex].content = updated
        notes[noteIndex].updatedAt = .now
        writeNoteToDisk(notes[noteIndex])
        persistMeta()
        presentWPSPreview(id)
        if openAfterCreate {
            openWPSFile(id)
        }
        syncStatusText = "已新建 WPS\(kind.label) · \(displayTitle)"
        return linked
    }

    /// 关联已有外部 WPS/Office 文件。
    @discardableResult
    func linkExternalWPSFile(url: URL, toNote noteID: UUID? = nil) -> WPSLinkedFile? {
        let targetNoteID = noteID ?? selectedNoteID
        guard let targetNoteID,
              let noteIndex = notes.firstIndex(where: { $0.id == targetNoteID && !$0.isTrashed }) else {
            lastErrorMessage = "请先打开一篇笔记再关联 WPS 文件"
            return nil
        }
        let ext = url.pathExtension
        guard let kind = WPSLinkSupport.kind(forExtension: ext) else {
            lastErrorMessage = "不支持的文件类型：.\(ext)"
            return nil
        }
        let bookmark = WPSOfficeSupport.bookmarkData(for: url) ?? Data()
        let title = url.deletingPathExtension().lastPathComponent
        let linked = WPSLinkedFile(
            title: title.isEmpty ? "未命名\(kind.label)" : title,
            kind: kind,
            storage: .external(bookmark: bookmark, path: url.path),
            noteID: targetNoteID
        )
        wpsFiles.append(linked)
        notes[noteIndex].content = WPSLinkSupport.appendingLink(linked.markdownLink, to: notes[noteIndex].content)
        notes[noteIndex].updatedAt = .now
        writeNoteToDisk(notes[noteIndex])
        persistMeta()
        presentWPSPreview(linked.id)
        syncStatusText = "已关联 WPS\(kind.label) · \(linked.title)"
        return linked
    }

    /// 弹出文件选择器关联外部文件。
    func beginLinkExternalWPSFile(toNote noteID: UUID? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["xlsx", "xls", "et", "csv", "docx", "doc", "wps", "rtf"]
        panel.title = "关联 WPS / Office 文件"
        panel.message = "选择表格或文档（xlsx / docx / et / wps 等）"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async {
                _ = self?.linkExternalWPSFile(url: url, toNote: noteID)
            }
        }
    }

    func resolveWPSFileURL(_ id: UUID) -> URL? {
        guard let file = wpsFiles.first(where: { $0.id == id }) else { return nil }
        switch file.storage {
        case .library(let relativePath):
            let url = libraryURL.appendingPathComponent(relativePath)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        case .external(let bookmark, let path):
            return WPSOfficeSupport.resolveURL(bookmark: bookmark, fallbackPath: path)
        }
    }

    func openWPSFile(_ id: UUID) {
        guard let url = resolveWPSFileURL(id) else {
            lastErrorMessage = "找不到 WPS 文件，可能已被移动或删除"
            return
        }
        if !WPSOfficeSupport.isInstalled {
            lastErrorMessage = "未检测到 WPS Office，将尝试用系统默认应用打开"
        }
        if !WPSOfficeSupport.open(url) {
            lastErrorMessage = "无法打开文件：\(url.lastPathComponent)"
        } else {
            syncStatusText = "已在 WPS 中打开 · \(url.lastPathComponent)"
        }
    }

    func revealWPSFile(_ id: UUID) {
        guard let url = resolveWPSFileURL(id) else {
            lastErrorMessage = "找不到 WPS 文件"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func presentWPSPreview(_ id: UUID) {
        guard wpsFiles.contains(where: { $0.id == id }) else { return }
        activeWPSPreviewID = id
    }

    func dismissWPSPreview() {
        activeWPSPreviewID = nil
    }

    /// 从笔记正文去掉链；库内文件可移入回收站。
    func unlinkWPSFile(_ id: UUID, removeLibraryFile: Bool = true) {
        guard let index = wpsFiles.firstIndex(where: { $0.id == id }) else { return }
        let file = wpsFiles[index]
        if let noteID = file.noteID,
           let noteIndex = notes.firstIndex(where: { $0.id == noteID }) {
            notes[noteIndex].content = WPSLinkSupport.removingLink(id: id, from: notes[noteIndex].content)
            notes[noteIndex].updatedAt = .now
            writeNoteToDisk(notes[noteIndex])
        }
        if removeLibraryFile, case .library(let relativePath) = file.storage {
            let url = libraryURL.appendingPathComponent(relativePath)
            let trashURL = trashDirectory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: url, to: trashURL)
            // 顺带删空目录
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        wpsFiles.remove(at: index)
        if activeWPSPreviewID == id {
            activeWPSPreviewID = nil
        }
        persistMeta()
        syncStatusText = "已解除 WPS 链接 · \(file.title)"
    }

    /// 当前笔记关联的 WPS 文件。
    func wpsFiles(forNote noteID: UUID) -> [WPSLinkedFile] {
        wpsFiles.filter { $0.noteID == noteID }
    }

    func restoreNote(_ note: Note) {
        guard note.isTrashed, let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        var restored = notes[index]
        restored.deletedAt = nil
        restored.updatedAt = .now

        // 原文件夹不存在时放入「已恢复」
        if folders.first(where: { $0.id == restored.folderID }) == nil {
            if let existing = folders.first(where: { $0.name == "已恢复" }) {
                restored.folderID = existing.id
            } else {
                let folder = NoteFolder(name: "已恢复", symbolName: "arrow.uturn.backward")
                folders.append(folder)
                try? FileManager.default.createDirectory(at: folderURL(for: folder), withIntermediateDirectories: true)
                restored.folderID = folder.id
            }
        }

        let trashURL = trashDirectory.appendingPathComponent(restored.fileName)
        notes[index] = restored
        if let folder = folders.first(where: { $0.id == restored.folderID }) {
            let dest = noteFileURL(restored, folder: folder)
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: trashURL.path) {
                try? FileManager.default.moveItem(at: trashURL, to: dest)
            } else {
                writeNoteToDisk(restored)
            }
        }
        if case .trash = destination {
            selectedNoteID = filteredNotes.first?.id
        } else {
            selectedNoteID = restored.id
            destination = .folder(restored.folderID)
        }
        syncStatusText = "已恢复笔记"
        persistMeta()
    }

    func permanentlyDeleteNote(_ note: Note) {
        let trashURL = trashDirectory.appendingPathComponent(note.fileName)
        try? FileManager.default.removeItem(at: trashURL)
        if let folder = folders.first(where: { $0.id == note.folderID }) {
            try? FileManager.default.removeItem(at: noteFileURL(note, folder: folder))
        }
        let assets = assetsDirectory.appendingPathComponent(note.id.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: assets)
        notes.removeAll { $0.id == note.id }
        if selectedNoteID == note.id {
            selectedNoteID = filteredNotes.first?.id
        }
        syncStatusText = "已永久删除"
        persistMeta()
    }

    func emptyTrash() {
        let trashed = notes.filter(\.isTrashed)
        for note in trashed {
            permanentlyDeleteNote(note)
        }
        syncStatusText = "回收站已清空"
    }

    func updateNoteContent(_ noteID: UUID, content: String) {
        guard let index = notes.firstIndex(where: { $0.id == noteID }), !notes[index].isTrashed else { return }
        // 内容未变则跳过，避免无意义的 @Published 刷新拖慢输入
        guard notes[index].content != content else { return }
        notes[index].content = content
        notes[index].updatedAt = .now
        // 标题/副标题不在每次按键时重算，避免中间栏与标题栏跟着抖
        scheduleContentMetadataUpdate(noteID: noteID)
        scheduleSave(noteID: noteID)
    }

    /// 输入停顿后再刷新标题/副标题（工作日志简介等）。
    private func scheduleContentMetadataUpdate(noteID: UUID) {
        metadataTask?.cancel()
        metadataTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            guard let index = notes.firstIndex(where: { $0.id == noteID }), !notes[index].isTrashed else { return }
            let content = notes[index].content
            let newTitle = Self.displayTitle(fileName: notes[index].fileName, content: content)
            let newSubtitle = Self.subtitle(from: content)
            if notes[index].title != newTitle {
                notes[index].title = newTitle
            }
            if notes[index].subtitle != newSubtitle {
                notes[index].subtitle = newSubtitle
            }
        }
    }

    func updateNoteTitle(_ noteID: UUID, title: String) {
        guard let index = notes.firstIndex(where: { $0.id == noteID }), !notes[index].isTrashed else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        notes[index].title = trimmed

        // 非 UUID 文件名：改标题即重命名 .md，与 Finder 保持一致
        let oldFileName = notes[index].fileName
        let oldStem = ((oldFileName as NSString).lastPathComponent as NSString).deletingPathExtension
        if !Self.isUUIDFileName(oldStem) {
            let parent = (oldFileName as NSString).deletingLastPathComponent
            let safe = sanitizeFileName(trimmed)
            let newFileName = parent.isEmpty ? "\(safe).md" : "\(parent)/\(safe).md"
            if newFileName != oldFileName,
               let folder = folders.first(where: { $0.id == notes[index].folderID }) {
                let oldURL = noteFileURL(notes[index], folder: folder)
                var renamed = notes[index]
                renamed.fileName = newFileName
                let newURL = noteFileURL(renamed, folder: folder)
                if !FileManager.default.fileExists(atPath: newURL.path) {
                    try? FileManager.default.createDirectory(
                        at: newURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if FileManager.default.fileExists(atPath: oldURL.path) {
                        try? FileManager.default.moveItem(at: oldURL, to: newURL)
                    }
                    notes[index].fileName = newFileName
                }
            }
        }

        var lines = notes[index].content.components(separatedBy: "\n")
        if let first = lines.first, first.hasPrefix("#") {
            lines[0] = "# \(trimmed)"
            notes[index].content = lines.joined(separator: "\n")
        }
        notes[index].updatedAt = .now
        scheduleSave(noteID: noteID)
    }

    /// 更新工作简介；写入正文 H1 后的 `> 副标题` 行。
    func updateNoteSubtitle(_ noteID: UUID, subtitle: String) {
        guard let index = notes.firstIndex(where: { $0.id == noteID }), !notes[index].isTrashed else { return }
        let trimmed = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        notes[index].subtitle = trimmed
        notes[index].content = Self.applyingSubtitle(trimmed, to: notes[index].content)
        notes[index].updatedAt = .now
        scheduleSave(noteID: noteID)
    }

    // MARK: - Tags

    func addTag(_ raw: String, to noteID: UUID) {
        let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty,
              let index = notes.firstIndex(where: { $0.id == noteID }),
              !notes[index].isTrashed else { return }
        if notes[index].tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { return }
        notes[index].tags.append(tag)
        notes[index].updatedAt = .now
        persistMeta()
    }

    func removeTag(_ tag: String, from noteID: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == noteID }) else { return }
        notes[index].tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
        notes[index].updatedAt = .now
        if case .tag(let selected) = destination,
           selected.caseInsensitiveCompare(tag) == .orderedSame,
           !allTags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            destination = folders.first.map { .folder($0.id) }
        }
        persistMeta()
    }

    // MARK: - Image paste

    /// 将剪贴板图片写入 `assets/<noteID>/`，返回可插入的 Markdown。
    func savePastedImage(_ image: NSImage, for noteID: UUID) -> String? {
        guard let data = Self.pngData(from: image) else {
            lastErrorMessage = "无法读取粘贴的图片（可再试一次，或先用预览打开后复制）"
            return nil
        }
        return saveUploadedImageData(data, suggestedName: "paste.png", for: noteID)
    }

    /// 原始图片数据写入 assets，返回 `![](assets/...)`。
    func saveUploadedImageData(_ data: Data, suggestedName: String, for noteID: UUID) -> String? {
        guard notes.contains(where: { $0.id == noteID && !$0.isTrashed }) else { return nil }
        guard !data.isEmpty else {
            lastErrorMessage = "图片数据为空"
            return nil
        }

        let noteAssets = assetsDirectory.appendingPathComponent(noteID.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: noteAssets, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
            let ext = (suggestedName as NSString).pathExtension.lowercased()
            let safeExt = ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(ext) ? ext : "png"
            let name = "img-\(formatter.string(from: .now)).\(safeExt)"
            let fileURL = noteAssets.appendingPathComponent(name)
            try data.write(to: fileURL, options: .atomic)
            let relative = "assets/\(noteID.uuidString)/\(name)"
            syncStatusText = "已插入图片"
            return "![](\(relative))\n"
        } catch {
            lastErrorMessage = "保存图片失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// 兼容飞书等来源：tiffRepresentation 可能为空，改为绘制到位图再导出 PNG。
    private static func pngData(from image: NSImage) -> Data? {
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let data = rep.representation(using: .png, properties: [:]) {
            return data
        }
        for rep in image.representations {
            if let bitmap = rep as? NSBitmapImageRep,
               let data = bitmap.representation(using: .png, properties: [:]) {
                return data
            }
        }
        var rect = CGRect(origin: .zero, size: image.size)
        guard rect.width >= 2, rect.height >= 2,
              let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: - Storage

    func switchStorage(to mode: StorageMode, migrate: Bool) {
        guard mode != storageMode || libraryURL != LibraryLocation.url(for: mode) else { return }
        if mode == .iCloudDrive && !LibraryLocation.isICloudDriveAvailable {
            lastErrorMessage = "未检测到 iCloud Drive。请先在「系统设置 → Apple ID」登录 iCloud，并开启 iCloud 云盘。"
            return
        }

        let destinationURL = LibraryLocation.url(for: mode)
        do {
            if migrate {
                try LibraryLocation.copyLibrary(from: libraryURL, to: destinationURL)
            }
            storageMode = mode
            libraryURL = destinationURL
            loadOrSeed()
            lastLibraryFingerprint = libraryFingerprint()
            startWatching()
            syncStatusText = mode == .iCloudDrive ? "iCloud Drive 已启用" : "本机存储"
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "迁移失败：\(error.localizedDescription)"
        }
    }

    func revealLibraryInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([libraryURL])
    }

    func reloadFromDisk() {
        let before = notes.filter { !$0.isTrashed }.count
        // 以磁盘为准对齐索引（Finder 新增 / 删除的 .md 都会进来）
        syncFromDisk(quiet: true)
        // 再读一遍正文，防止外部编辑器改过内容
        refreshOpenNoteContentsFromDisk()
        let after = notes.filter { !$0.isTrashed }.count
        let delta = after - before
        syncStatusText = delta == 0
            ? "已从磁盘刷新 · \(Self.clock.string(from: .now))"
            : "已对齐磁盘（\(delta > 0 ? "+" : "")\(delta)）· \(Self.clock.string(from: .now))"
    }

    /// 扫描磁盘并合并进索引；`quiet` 为 true 时不改状态栏文案（进入文件夹时用）。
    @discardableResult
    func syncFromDisk(quiet: Bool) -> (imported: Int, removed: Int) {
        guard !isWriting else { return (0, 0) }
        let result = reconcileDiskIntoIndex(rebuild: false)
        ensureDefaultFolders(persist: false)
        let repaired = repairChildRelationships()
        if result.imported > 0 || result.removed > 0 || repaired > 0 {
            persistMeta()
        } else {
            refreshMetaTimestamp()
        }
        lastLibraryFingerprint = libraryFingerprint()
        if case .folder(let id) = destination, !folders.contains(where: { $0.id == id }) {
            destination = folders.first.map { .folder($0.id) }
        }
        if let selectedNoteID, !notes.contains(where: { $0.id == selectedNoteID }) {
            self.selectedNoteID = filteredNotes.first?.id
        }
        if !quiet {
            if result.imported > 0 || result.removed > 0 {
                syncStatusText = "已同步磁盘（+\(result.imported)/-\(result.removed)）· \(Self.clock.string(from: .now))"
            } else if repaired == 0 {
                syncStatusText = "已与磁盘一致 · \(Self.clock.string(from: .now))"
            }
        }
        return result
    }

    /// 从磁盘重读各笔记正文（外部改 md 后保持编辑区最新）。
    private func refreshOpenNoteContentsFromDisk() {
        for i in notes.indices where !notes[i].isTrashed {
            let url = fileURL(for: notes[i])
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            notes[i].content = text
            notes[i].title = Self.displayTitle(fileName: notes[i].fileName, content: text)
            notes[i].subtitle = Self.subtitle(from: text)
        }
    }

    /// 扫描笔记库目录，把尚未进入索引的文件夹 / `.md` 导入（适合从妙言复制文件后）。
    @discardableResult
    func importUntrackedFilesFromDisk() -> Int {
        let result = reconcileDiskIntoIndex(rebuild: false)
        let repaired = repairChildRelationships()
        if result.imported > 0 || result.removed > 0 || repaired > 0 {
            persistMeta()
            syncStatusText = "已导入 \(result.imported) 篇，移除 \(result.removed) 篇失效索引"
        }
        return result.imported
    }

    /// 按磁盘实际文件重建索引：以文件夹与 `.md` 为准，丢掉索引里已无文件的示例笔记。
    func rebuildIndexFromDisk() {
        _ = reconcileDiskIntoIndex(rebuild: true)
        ensureDefaultFolders(persist: false)
        _ = repairChildRelationships()
        persistMeta()
        if case .folder(let id) = destination, folders.contains(where: { $0.id == id }) {
            selectedNoteID = filteredNotes.first?.id
        } else {
            destination = folders.first.map { .folder($0.id) }
            selectedNoteID = filteredNotes.first?.id
        }
        syncStatusText = "已按磁盘重建索引（\(notes.filter { !$0.isTrashed }.count) 篇笔记）"
    }

    // MARK: - Persistence

    private func loadOrSeed() {
        try? FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: metaURL.path) {
            loadFromDisk(keepSelection: false)
            ensureDefaultFolders(persist: true)
            return
        }
        // 若目录里已有从妙言等复制来的内容，直接扫描，不再写入示例库
        if libraryHasMarkdownContent() {
            folders = []
            notes = []
            reconcileDiskIntoIndex(rebuild: true)
            ensureDefaultFolders(persist: false)
            _ = repairChildRelationships()
            destination = folders.first.map { .folder($0.id) }
            selectedNoteID = filteredNotes.first?.id
            persistMeta()
            return
        }
        seedSampleLibrary()
    }

    /// 保证「知识库」「工作日志」存在并置顶；已有同名夹则只校正图标与顺序。
    private func ensureDefaultFolders(persist: Bool) {
        var changed = false
        for spec in Self.defaultFolderSpecs {
            if let index = folders.firstIndex(where: { $0.name == spec.name }) {
                if folders[index].symbolName != spec.symbolName {
                    folders[index].symbolName = spec.symbolName
                    changed = true
                }
                continue
            }
            let folder = NoteFolder(name: spec.name, symbolName: spec.symbolName)
            try? FileManager.default.createDirectory(at: folderURL(for: folder), withIntermediateDirectories: true)
            folders.append(folder)
            changed = true
        }
        let ordered = Self.orderedFolders(folders)
        if ordered.map(\.id) != folders.map(\.id) {
            folders = ordered
            changed = true
        }
        if changed && persist {
            persistMeta()
        }
    }

    /// 默认夹固定置顶，其余保持原有相对顺序。
    private static func orderedFolders(_ folders: [NoteFolder]) -> [NoteFolder] {
        let defaultNames = defaultFolderSpecs.map(\.name)
        var pinned: [NoteFolder] = []
        for name in defaultNames {
            if let folder = folders.first(where: { $0.name == name }) {
                pinned.append(folder)
            }
        }
        let rest = folders.filter { !defaultNames.contains($0.name) }
        return pinned + rest
    }

    private func loadFromDisk(keepSelection: Bool) {
        let previousDestination = destination
        let previousNote = selectedNoteID

        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(LibraryMeta.self, from: data) else {
            if folders.isEmpty {
                if libraryHasMarkdownContent() {
                    reconcileDiskIntoIndex(rebuild: true)
                    _ = repairChildRelationships()
                    destination = folders.first.map { .folder($0.id) }
                    selectedNoteID = filteredNotes.first?.id
                    persistMeta()
                } else {
                    seedSampleLibrary()
                }
            }
            return
        }

        folders = meta.folders
        notes = meta.notes
        wpsFiles = meta.wpsFiles
        for i in notes.indices {
            let url = fileURL(for: notes[i])
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                notes[i].content = text
                if !notes[i].isTrashed {
                    notes[i].title = Self.displayTitle(fileName: notes[i].fileName, content: text)
                    notes[i].subtitle = Self.subtitle(from: text)
                }
            }
        }

        // 合并磁盘上新文件，并清掉索引里已无对应 .md 的条目
        _ = reconcileDiskIntoIndex(rebuild: false)

        if keepSelection, let previousDestination {
            destination = previousDestination
            selectedNoteID = previousNote ?? filteredNotes.first?.id
        } else if let folderID = meta.selectedFolderID, folders.contains(where: { $0.id == folderID }) {
            destination = .folder(folderID)
            selectedNoteID = meta.selectedNoteID ?? filteredNotes.first?.id
        } else {
            destination = folders.first.map { .folder($0.id) }
            selectedNoteID = filteredNotes.first?.id
        }
        ensureDefaultFolders(persist: false)
        // 从正文标记恢复可能丢失的父子关联（中间栏嵌套依赖 parentNoteID）
        _ = repairChildRelationships()
        // 对齐后的标题 / 增删写回索引，避免下次启动又和 Finder 对不上
        persistMeta()
    }

    private static let ignoredDirectoryNames: Set<String> = [
        ".Trash", "assets", "wps", ".miaoyan-conflicts", ".git"
    ]

    private func libraryHasMarkdownContent() -> Bool {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: libraryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        for url in items {
            if url.pathExtension.lowercased() == "md" { return true }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let name = url.lastPathComponent
            if Self.ignoredDirectoryNames.contains(name) { continue }
            if let nested = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil),
               nested.contains(where: { $0.pathExtension.lowercased() == "md" }) {
                return true
            }
        }
        return false
    }

    /// 扫描库根：子文件夹 → 笔记夹；根目录 `.md` →「未分类」。
    /// - Returns: 新导入篇数、因磁盘上已无文件而移除的索引篇数。
    @discardableResult
    private func reconcileDiskIntoIndex(rebuild: Bool) -> (imported: Int, removed: Int) {
        let fm = FileManager.default
        let trashed = notes.filter(\.isTrashed)
        // folderName/fileName → 旧笔记，用于保留 id / tags
        var legacyByKey: [String: Note] = [:]
        for note in notes where !note.isTrashed {
            let folderName = folders.first(where: { $0.id == note.folderID })?.name ?? ""
            legacyByKey["\(folderName)/\(note.fileName)"] = note
        }

        var nextFolders: [NoteFolder] = rebuild ? [] : folders
        var nextNotes: [Note] = []
        var seenKeys = Set<String>()
        var imported = 0

        func folderNamed(_ name: String) -> NoteFolder {
            if let existing = nextFolders.first(where: { $0.name == name }) { return existing }
            if !rebuild, let existing = folders.first(where: { $0.name == name }) {
                nextFolders.append(existing)
                return existing
            }
            let folder = NoteFolder(name: name, symbolName: Self.symbol(for: name))
            nextFolders.append(folder)
            try? fm.createDirectory(at: folderURL(for: folder), withIntermediateDirectories: true)
            return folder
        }

        /// `relativeName` 相对所属笔记夹，支持一层子目录如 `工作日志/foo.md`。
        func track(fileURL: URL, folder: NoteFolder, relativeName: String) {
            let key = "\(folder.id)/\(relativeName)"
            guard !seenKeys.contains(key) else { return }
            seenKeys.insert(key)

            let content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            let legacyKey = "\(folder.name)/\(relativeName)"
            let legacy = legacyByKey[legacyKey]
            var modified = Date()
            if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
               let date = attrs[.modificationDate] as? Date {
                modified = date
            }

            // 正文隐藏标记可在 meta 丢失时带回父子关联
            let embeddedParent = ChildNoteMarkerSupport.parentNoteID(fromContent: content)
            let embeddedTask = Self.associatedTaskText(
                subtitle: Self.subtitle(from: content),
                content: content
            )

            if let legacy {
                var updated = legacy
                updated.folderID = folder.id
                updated.content = content
                updated.title = Self.displayTitle(fileName: relativeName, content: content)
                updated.subtitle = Self.subtitle(from: content)
                updated.updatedAt = modified
                updated.fileName = relativeName
                updated.deletedAt = nil
                // meta 里丢了 parentNoteID 时，用正文注释补回
                if updated.parentNoteID == nil, let embeddedParent {
                    updated.parentNoteID = embeddedParent
                }
                if (updated.linkedTaskText == nil || updated.linkedTaskText?.isEmpty == true),
                   let embeddedTask {
                    updated.linkedTaskText = embeddedTask
                }
                nextNotes.append(updated)
            } else {
                imported += 1
                nextNotes.append(Note(
                    id: UUID(),
                    folderID: folder.id,
                    title: Self.displayTitle(fileName: relativeName, content: content),
                    subtitle: Self.subtitle(from: content),
                    content: content,
                    createdAt: modified,
                    updatedAt: modified,
                    fileName: relativeName,
                    tags: [],
                    deletedAt: nil,
                    parentNoteID: embeddedParent,
                    linkedTaskText: embeddedTask
                ))
            }
        }

        /// 收录笔记夹内 `.md`，以及一层子文件夹里的 `.md`（Finder 常见结构）。
        func ingestFolderContents(at folderDir: URL, folder: NoteFolder) {
            guard let items = try? fm.contentsOfDirectory(
                at: folderDir,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            for item in items {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: item.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    let subName = item.lastPathComponent
                    if subName.hasPrefix(".") || Self.ignoredDirectoryNames.contains(subName) { continue }
                    guard let nested = try? fm.contentsOfDirectory(
                        at: item,
                        includingPropertiesForKeys: [.contentModificationDateKey],
                        options: [.skipsHiddenFiles]
                    ) else { continue }
                    for file in nested where file.pathExtension.lowercased() == "md" {
                        track(
                            fileURL: file,
                            folder: folder,
                            relativeName: "\(subName)/\(file.lastPathComponent)"
                        )
                    }
                } else if item.pathExtension.lowercased() == "md" {
                    track(fileURL: item, folder: folder, relativeName: item.lastPathComponent)
                }
            }
        }

        guard let rootItems = try? fm.contentsOfDirectory(
            at: libraryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            folders = nextFolders
            notes = nextNotes + trashed
            return (imported, 0)
        }

        // 根目录散落的 .md（妙言常见）→ 未分类
        let rootMarkdowns = rootItems.filter {
            $0.pathExtension.lowercased() == "md" && !$0.lastPathComponent.hasPrefix(".")
        }
        if !rootMarkdowns.isEmpty {
            let inbox = folderNamed("未分类")
            let inboxURL = folderURL(for: inbox)
            try? fm.createDirectory(at: inboxURL, withIntermediateDirectories: true)
            for url in rootMarkdowns {
                let dest = inboxURL.appendingPathComponent(url.lastPathComponent)
                if url.standardizedFileURL != dest.standardizedFileURL {
                    if fm.fileExists(atPath: dest.path) {
                        try? fm.removeItem(at: dest)
                    }
                    try? fm.moveItem(at: url, to: dest)
                    track(fileURL: dest, folder: inbox, relativeName: dest.lastPathComponent)
                } else {
                    track(fileURL: url, folder: inbox, relativeName: url.lastPathComponent)
                }
            }
        }

        for url in rootItems {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let name = url.lastPathComponent
            if name.hasPrefix(".") || Self.ignoredDirectoryNames.contains(name) { continue }
            let folder = folderNamed(name)
            ingestFolderContents(at: url, folder: folder)
        }

        let previousActive = notes.filter { !$0.isTrashed }.count
        folders = nextFolders
        notes = nextNotes + trashed
        // 移除数 = 旧活跃数 −（新列表中承袭旧索引的篇数）
        let removed = max(0, previousActive - (nextNotes.count - imported))
        return (imported, removed)
    }

    private func seedSampleLibrary() {
        let knowledge = NoteFolder(name: "知识库", symbolName: "books.vertical")
        let workLog = NoteFolder(name: "工作日志", symbolName: "calendar")
        let tools = NoteFolder(name: "投放工具", symbolName: "hammer")
        let music = NoteFolder(name: "音乐", symbolName: "music.note")
        let guide = NoteFolder(name: "Guide", symbolName: "book")
        folders = [knowledge, workLog, tools, music, guide]

        for folder in folders {
            try? FileManager.default.createDirectory(at: folderURL(for: folder), withIntermediateDirectories: true)
        }

        let knowledgeNote = Note(
            folderID: knowledge.id,
            title: "知识库",
            content: """
            # 知识库

            在这里沉淀常用知识、方案与备忘。可从其它文件夹拖笔记进来。
            """,
            fileName: "知识库.md",
            tags: ["知识"]
        )

        let today = Self.dayStamp.string(from: .now)
        let workLogNote = Note(
            folderID: workLog.id,
            title: today,
            subtitle: "今日工作简介",
            content: """
            # \(today)

            > 今日工作简介

            - [ ]
            """,
            fileName: "\(today).md",
            tags: ["工作"]
        )

        let diary = Note(
            folderID: tools.id,
            title: "工作日记",
            content: """
            # 工作日记

            ### 05-24 (下周一任务)

            - [ ] 整理本周投放脚本
            - [ ] 复查 SQL 慢查询

            ```bash
            grep -n "timeout" deploy.log
            ```
            """,
            updatedAt: date(2026, 5, 27, 13, 58),
            tags: ["工作", "待办"]
        )

        let sql = Note(
            folderID: tools.id,
            title: "sql 优化",
            content: """
            # sql 优化

            ## 目标
            降低核心报表查询延迟。
            """,
            updatedAt: date(2026, 5, 27, 11, 20),
            tags: ["SQL"]
        )

        let musicNote = Note(
            folderID: music.id,
            title: "歌单草稿",
            content: "# 歌单草稿\n\n- Night Drive\n- Quiet Hours\n",
            tags: ["音乐"]
        )

        let guideNote = Note(
            folderID: guide.id,
            title: "欢迎使用墨言",
            content: """
            # 欢迎使用墨言

            墨言是一款参考妙言体验的 Markdown 笔记应用。

            ## 快捷操作
            - `⌘N` 新建笔记
            - `⌘⇧N` 新建文件夹
            - `⌘V` 可直接粘贴图片到正文
            - 删除的笔记会进入左侧 **回收站**
            - 可将笔记拖到左侧文件夹以移动

            ## 标签
            在标题下方输入标签，左侧可按标签筛选。
            """,
            tags: ["指南"]
        )

        notes = [knowledgeNote, workLogNote, diary, sql, musicNote, guideNote]
        for note in notes { writeNoteToDisk(note) }
        destination = .folder(knowledge.id)
        selectedNoteID = knowledgeNote.id
        persistMeta()
    }

    private func moveNoteToTrash(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }), !notes[index].isTrashed else { return }
        try? FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        let currentURL = fileURL(for: notes[index])
        var trashed = notes[index]
        trashed.deletedAt = .now
        // 回收站扁平存放，避免把子目录路径带进去
        let trashName = (trashed.fileName as NSString).lastPathComponent
        let dest = trashDirectory.appendingPathComponent(trashName)
        if FileManager.default.fileExists(atPath: currentURL.path) {
            if FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.removeItem(at: dest)
            }
            try? FileManager.default.moveItem(at: currentURL, to: dest)
        } else {
            try? trashed.content.write(to: dest, atomically: true, encoding: .utf8)
        }
        trashed.fileName = trashName
        notes[index] = trashed
    }

    private func scheduleSave(noteID: UUID) {
        saveTask?.cancel()
        // 不在每次按键更新 syncStatusText，避免状态栏刷新抢主线程
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            guard let note = notes.first(where: { $0.id == noteID }) else { return }
            writeNoteToDisk(note)
            persistMeta()
            syncStatusText = storageMode == .iCloudDrive ? "已写入 iCloud Drive" : "已保存"
        }
    }

    private func writeNoteToDisk(_ note: Note) {
        isWriting = true
        defer { isWriting = false }
        let url = fileURL(for: note)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? note.content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func persistMeta() {
        isWriting = true
        defer {
            isWriting = false
            refreshMetaTimestamp()
            lastLibraryFingerprint = libraryFingerprint()
        }
        let full = LibraryMeta(
            folders: folders,
            notes: notes,
            wpsFiles: wpsFiles,
            selectedFolderID: selectedFolderID,
            selectedNoteID: selectedNoteID
        )
        if let data = try? JSONEncoder().encode(full) {
            try? data.write(to: metaURL, options: .atomic)
        }
    }

    private func refreshMetaTimestamp() {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: metaURL.path),
           let modified = attrs[.modificationDate] as? Date {
            lastKnownMetaModified = modified
        }
    }

    private func startWatching() {
        watchTask?.cancel()
        startDirectoryWatcher()
        // 轮询指纹作兜底：部分拷贝场景 DirectoryWatcher 可能漏事件
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                await MainActor.run { self?.pollDiskChanges() }
            }
        }
    }

    /// 监听自然日切换与应用回前台，避免一直停在工作日志时永远弹不出「继续昨日」。
    private func startWorkLogDayObservers() {
        stopWorkLogDayObservers()
        calendarDayObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkWorkLogContinuationIfNeeded()
        }
        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkWorkLogContinuationIfNeeded()
        }
    }

    private func stopWorkLogDayObservers() {
        if let calendarDayObserver {
            NotificationCenter.default.removeObserver(calendarDayObserver)
            self.calendarDayObserver = nil
        }
        if let becomeActiveObserver {
            NotificationCenter.default.removeObserver(becomeActiveObserver)
            self.becomeActiveObserver = nil
        }
    }

    /// 监听笔记库目录本身的增删改（Finder 拖入新 md 会触发）。
    private func startDirectoryWatcher() {
        stopDirectoryWatcher()
        let path = libraryURL.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchFileDescriptor = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .attrib],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleDiskSyncFromWatcher()
        }
        source.setCancelHandler { [weak self] in
            if let self, self.watchFileDescriptor >= 0 {
                close(self.watchFileDescriptor)
                self.watchFileDescriptor = -1
            }
        }
        directoryWatcher = source
        source.resume()
    }

    private func stopDirectoryWatcher() {
        directoryWatcher?.cancel()
        directoryWatcher = nil
        if watchFileDescriptor >= 0 {
            close(watchFileDescriptor)
            watchFileDescriptor = -1
        }
    }

    private func scheduleDiskSyncFromWatcher() {
        watcherDebounceTask?.cancel()
        watcherDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.pollDiskChanges() }
        }
    }

    /// 对比磁盘指纹；有变化则自动导入/剔除，解决「Finder 有文件、App 没有」的错位。
    private func pollDiskChanges() {
        guard !isWriting else { return }
        let fingerprint = libraryFingerprint()
        if let known = lastLibraryFingerprint, known == fingerprint {
            // meta 被其它实例改写时仍需合并
            pollMetaOnlyChanges()
            return
        }
        let result = syncFromDisk(quiet: true)
        if result.imported > 0 || result.removed > 0 {
            syncStatusText = "已自动同步新文件（+\(result.imported)/-\(result.removed)）· \(Self.clock.string(from: .now))"
        } else {
            refreshOpenNoteContentsFromDisk()
            lastLibraryFingerprint = fingerprint
        }
    }

    private func pollMetaOnlyChanges() {
        guard FileManager.default.fileExists(atPath: metaURL.path) else { return }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: metaURL.path),
              let modified = attrs[.modificationDate] as? Date else { return }
        if let known = lastKnownMetaModified, modified <= known { return }
        loadFromDisk(keepSelection: true)
        lastLibraryFingerprint = libraryFingerprint()
        syncStatusText = "已同步外部更改 · \(Self.clock.string(from: .now))"
    }

    /// 生成库内全部 `.md` 的路径+mtime 指纹（含子一层目录）。
    private func libraryFingerprint() -> String {
        let fm = FileManager.default
        var parts: [String] = []
        guard let rootItems = try? fm.contentsOfDirectory(
            at: libraryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return "" }

        for url in rootItems.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            let name = url.lastPathComponent
            if Self.ignoredDirectoryNames.contains(name) { continue }

            if isDir.boolValue {
                guard let children = try? fm.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    var childDir: ObjCBool = false
                    fm.fileExists(atPath: child.path, isDirectory: &childDir)
                    if childDir.boolValue {
                        let sub = child.lastPathComponent
                        if sub.hasPrefix(".") || Self.ignoredDirectoryNames.contains(sub) { continue }
                        if let nested = try? fm.contentsOfDirectory(
                            at: child,
                            includingPropertiesForKeys: [.contentModificationDateKey],
                            options: [.skipsHiddenFiles]
                        ) {
                            for file in nested where file.pathExtension.lowercased() == "md" {
                                parts.append(fingerprintEntry(relative: "\(name)/\(sub)/\(file.lastPathComponent)", url: file))
                            }
                        }
                    } else if child.pathExtension.lowercased() == "md" {
                        parts.append(fingerprintEntry(relative: "\(name)/\(child.lastPathComponent)", url: child))
                    }
                }
            } else if url.pathExtension.lowercased() == "md" {
                parts.append(fingerprintEntry(relative: name, url: url))
            }
        }
        return parts.joined(separator: ";")
    }

    private func fingerprintEntry(relative: String, url: URL) -> String {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        return "\(relative):\(Int(mtime))"
    }

    private func folderURL(for folder: NoteFolder) -> URL {
        libraryURL.appendingPathComponent(sanitize(folder.name), isDirectory: true)
    }

    private func noteFileURL(_ note: Note, folder: NoteFolder) -> URL {
        // fileName 可能含一层子目录（工作日志/a.md），需按路径分量拼接。
        relativeFileURL(in: folderURL(for: folder), relativePath: note.fileName)
    }

    private func fileURL(for note: Note) -> URL {
        if note.isTrashed {
            // 回收站内只用末段文件名，避免子目录结构
            return trashDirectory.appendingPathComponent((note.fileName as NSString).lastPathComponent)
        }
        if let folder = folders.first(where: { $0.id == note.folderID }) {
            return noteFileURL(note, folder: folder)
        }
        return trashDirectory.appendingPathComponent((note.fileName as NSString).lastPathComponent)
    }

    private func relativeFileURL(in base: URL, relativePath: String) -> URL {
        relativePath
            .split(separator: "/")
            .reduce(base) { $0.appendingPathComponent(String($1)) }
    }

    private func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-")
    }

    /// 文件名非法字符清理（保留中文与常见符号）。
    private func sanitizeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名笔记" : trimmed
    }

    /// 列表 / 标题栏用：可读文件名与 Finder 对齐；UUID 文件名则取正文首行。
    private static func displayTitle(fileName: String, content: String) -> String {
        let stem = ((fileName as NSString).lastPathComponent as NSString).deletingPathExtension
        if !stem.isEmpty && !isUUIDFileName(stem) {
            return stem
        }
        return title(from: content)
    }

    private static func isUUIDFileName(_ stem: String) -> Bool {
        UUID(uuidString: stem) != nil
    }

    private static func title(from content: String) -> String {
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            var text = trimmed
            while text.hasPrefix("#") { text.removeFirst() }
            text = text.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? "未命名笔记" : text
        }
        return "未命名笔记"
    }

    /// 从正文解析工作简介：优先 H1 后首条 `> …` 引用行。
    private static func subtitle(from content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        var seenTitle = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !seenTitle {
                if trimmed.hasPrefix("#") {
                    seenTitle = true
                } else if !trimmed.isEmpty {
                    // 无 H1 时也允许文件以引用开头
                    if trimmed.hasPrefix(">") {
                        return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                    }
                    break
                }
                continue
            }
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix(">") {
                return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            break
        }
        return ""
    }

    /// 将副标题写回正文：保证 `# 标题` 下有一行 `> 简介`（可为空占位）。
    private static func applyingSubtitle(_ subtitle: String, to content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        let quote = "> \(subtitle)"
        guard let titleIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
        }) else {
            let title = title(from: content)
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "# \(title)\n\n\(quote)\n\n"
            }
            return "# \(title)\n\n\(quote)\n\n\(content)"
        }

        // 跳过标题后空行，定位已有引用或正文起点
        var idx = titleIndex + 1
        while idx < lines.count, lines[idx].trimmingCharacters(in: .whitespaces).isEmpty {
            idx += 1
        }
        if idx < lines.count, lines[idx].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
            lines[idx] = quote
            return lines.joined(separator: "\n")
        }
        // 插入：标题后空行 + 引用 + 空行
        var insertAt = titleIndex + 1
        if insertAt >= lines.count || !lines[insertAt].trimmingCharacters(in: .whitespaces).isEmpty {
            lines.insert("", at: insertAt)
        }
        insertAt = titleIndex + 2
        lines.insert(quote, at: insertAt)
        if insertAt + 1 >= lines.count || !lines[insertAt + 1].trimmingCharacters(in: .whitespaces).isEmpty {
            lines.insert("", at: insertAt + 1)
        }
        return lines.joined(separator: "\n")
    }

    private static func symbol(for name: String) -> String {
        if let spec = defaultFolderSpecs.first(where: { $0.name == name }) {
            return spec.symbolName
        }
        let lower = name.lowercased()
        if lower.contains("音乐") || lower.contains("music") { return "music.note" }
        if lower.contains("guide") || lower.contains("指南") { return "book" }
        if lower.contains("工具") { return "hammer" }
        if lower.contains("恢复") { return "arrow.uturn.backward" }
        if lower.contains("知识") { return "books.vertical" }
        if lower.contains("日志") || lower.contains("日记") { return "calendar" }
        return "folder"
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        return Calendar.current.date(from: c) ?? .now
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let dayStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

private struct LibraryMeta: Codable {
    var folders: [NoteFolder]
    var notes: [Note]
    var wpsFiles: [WPSLinkedFile]
    var selectedFolderID: UUID?
    var selectedNoteID: UUID?

    enum CodingKeys: String, CodingKey {
        case folders, notes, wpsFiles, selectedFolderID, selectedNoteID
    }

    init(
        folders: [NoteFolder],
        notes: [Note],
        wpsFiles: [WPSLinkedFile] = [],
        selectedFolderID: UUID?,
        selectedNoteID: UUID?
    ) {
        self.folders = folders
        self.notes = notes
        self.wpsFiles = wpsFiles
        self.selectedFolderID = selectedFolderID
        self.selectedNoteID = selectedNoteID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folders = try c.decode([NoteFolder].self, forKey: .folders)
        notes = try c.decode([Note].self, forKey: .notes)
        wpsFiles = try c.decodeIfPresent([WPSLinkedFile].self, forKey: .wpsFiles) ?? []
        selectedFolderID = try c.decodeIfPresent(UUID.self, forKey: .selectedFolderID)
        selectedNoteID = try c.decodeIfPresent(UUID.self, forKey: .selectedNoteID)
    }
}
