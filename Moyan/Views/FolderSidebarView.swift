import AppKit
import SwiftUI

/// 左侧导航：文件夹 / 标签 / 回收站（无底部按钮条）。
struct FolderSidebarView: View {
    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var settings: AppSettings
    @State private var exportMessage: String?
    @State private var folderPendingDelete: NoteFolder?
    @State private var confirmEmptyTrash = false
    /// 拖拽笔记悬停的目标文件夹，用于高亮提示可放下。
    @State private var dropTargetFolderID: UUID?

    private var selection: Binding<SidebarDestination?> {
        Binding(
            get: { store.destination },
            set: { newValue in
                guard let newValue else { return }
                switch newValue {
                case .folder(let id):
                    if let folder = store.folders.first(where: { $0.id == id }) {
                        store.selectFolder(folder)
                    }
                case .tag(let tag):
                    store.selectTag(tag)
                case .trash:
                    store.selectTrash()
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(settings.accent.color)
                Text("墨言")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                if settings.storageMode == .iCloudDrive {
                    Image(systemName: "icloud.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(settings.accent.color.opacity(0.85))
                }
                Button {
                    store.refreshFolder(store.selectedFolder)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(settings.accent.color)
                .help("从磁盘刷新文件夹")

                Button {
                    store.beginCreateFolder()
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(settings.accent.color)
                .help("新建文件夹")
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 10)

            List(selection: selection) {
                Section {
                    ForEach(store.folders) { folder in
                        Label(folder.name, systemImage: folder.symbolName)
                            .tag(SidebarDestination.folder(folder.id))
                            .help(folderDropHelp(folder))
                            .listRowBackground(folderRowBackground(folder))
                            .contextMenu { folderMenu(folder) }
                            // 接收中间列表拖来的笔记 UUID，执行移动
                            .dropDestination(for: String.self) { items, _ in
                                guard let raw = items.first,
                                      let noteID = UUID(uuidString: raw) else { return false }
                                store.moveNote(withID: noteID, toFolderID: folder.id)
                                return true
                            } isTargeted: { targeted in
                                dropTargetFolderID = targeted ? folder.id : nil
                            }
                    }
                } header: {
                    HStack {
                        Text("文件夹")
                        Spacer()
                        Button {
                            store.refreshFolder(nil)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .help("从磁盘刷新全部文件夹")
                    }
                }

                if !store.allTags.isEmpty {
                    Section("标签") {
                        ForEach(store.allTags, id: \.self) { tag in
                            Label(tag, systemImage: "tag")
                                .tag(SidebarDestination.tag(tag))
                        }
                    }
                }

                Section {
                    Label {
                        HStack {
                            Text("回收站")
                            Spacer()
                            if store.trashCount > 0 {
                                Text("\(store.trashCount)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "trash")
                    }
                    .tag(SidebarDestination.trash)
                    .contextMenu {
                        Button("清空回收站", role: .destructive) {
                            confirmEmptyTrash = true
                        }
                        .disabled(store.trashCount == 0)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .alert("新建文件夹", isPresented: $store.isCreatingFolder) {
            TextField("文件夹名称", text: $store.newFolderName)
            Button("取消", role: .cancel) {}
            Button("创建") { store.createFolder(named: store.newFolderName) }
        } message: {
            Text("将创建在：\n\(store.libraryURL.path)")
        }
        .alert("重命名文件夹", isPresented: $store.isRenamingFolder) {
            TextField("新名称", text: $store.renameFolderName)
            Button("取消", role: .cancel) { store.renamingFolderID = nil }
            Button("保存") {
                if let id = store.renamingFolderID {
                    store.renameFolder(id: id, to: store.renameFolderName)
                }
            }
        } message: {
            Text("磁盘目录会一并重命名。")
        }
        .alert(
            "删除文件夹？",
            isPresented: Binding(
                get: { folderPendingDelete != nil },
                set: { if !$0 { folderPendingDelete = nil } }
            )
        ) {
            Button("取消", role: .cancel) { folderPendingDelete = nil }
            Button("删除", role: .destructive) {
                if let folder = folderPendingDelete {
                    store.deleteFolder(folder)
                }
                folderPendingDelete = nil
            }
        } message: {
            Text("「\(folderPendingDelete?.name ?? "")」内的笔记将移入回收站。")
        }
        .alert("清空回收站？", isPresented: $confirmEmptyTrash) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { store.emptyTrash() }
        } message: {
            Text("将永久删除 \(store.trashCount) 篇笔记，无法恢复。")
        }
        .alert("导出", isPresented: Binding(
            get: { exportMessage != nil },
            set: { if !$0 { exportMessage = nil } }
        )) {
            Button("好", role: .cancel) { exportMessage = nil }
        } message: {
            Text(exportMessage ?? "")
        }
        .alert("提示", isPresented: Binding(
            get: { store.lastErrorMessage != nil },
            set: { if !$0 { store.lastErrorMessage = nil } }
        )) {
            Button("好", role: .cancel) { store.lastErrorMessage = nil }
        } message: {
            Text(store.lastErrorMessage ?? "")
        }
    }

    private func folderDropHelp(_ folder: NoteFolder) -> String {
        let path = store.url(for: folder).path
        if NoteStore.isDefaultFolderName(folder.name) {
            return "默认文件夹 · 可拖入笔记 · \(path)"
        }
        return "可拖入笔记 · \(path)"
    }

    @ViewBuilder
    private func folderRowBackground(_ folder: NoteFolder) -> some View {
        if dropTargetFolderID == folder.id {
            settings.accent.color.opacity(0.22)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func folderMenu(_ folder: NoteFolder) -> some View {
        Button("刷新此文件夹") { store.refreshFolder(folder) }
        Button("从磁盘刷新全部") { store.reloadFromDisk() }
        Divider()
        Button("新建文件夹…") { store.beginCreateFolder() }
        Button("重命名…") { store.beginRenameFolder(folder) }
        Button("在 Finder 中显示") { store.revealFolderInFinder(folder) }
        Divider()
        Button {
            store.presentAIAnalyze(for: folder)
        } label: {
            Label("AI 分析…", systemImage: "sparkles")
        }
        Button("导出文件夹为 PDF…") { Task { await exportFolder(folder) } }
        if !NoteStore.isDefaultFolderName(folder.name) {
            Divider()
            Button("删除文件夹…", role: .destructive) { folderPendingDelete = folder }
        }
    }

    private func exportFolder(_ folder: NoteFolder) async {
        let notes = store.notes.filter { $0.folderID == folder.id && !$0.isTrashed }
        guard !notes.isEmpty else {
            exportMessage = "该文件夹没有笔记"
            return
        }
        do {
            let ns = NSColor(settings.accent.color).usingColorSpace(.sRGB) ?? .systemGreen
            let hex = String(
                format: "#%02X%02X%02X",
                Int(ns.redComponent * 255),
                Int(ns.greenComponent * 255),
                Int(ns.blueComponent * 255)
            )
            if let url = try await PDFExporter.exportFolder(name: folder.name, notes: notes, accentHex: hex) {
                exportMessage = "已导出到\n\(url.path)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            exportMessage = "导出失败：\(error.localizedDescription)"
        }
    }
}
