import AppKit
import SwiftUI

/// 妙言式三栏主界面：侧栏始终显示。
struct ContentView: View {
    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var settings: AppSettings
    @State private var isExporting = false
    @State private var exportMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                FolderSidebarView()
                    .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 280)
            } content: {
                NoteListView()
                    .navigationSplitViewColumnWidth(
                        min: settings.notesBrowseMode == .gallery ? 320 : 200,
                        ideal: settings.notesBrowseMode == .gallery ? 480 : 240,
                        max: settings.notesBrowseMode == .gallery ? 720 : 360
                    )
            } detail: {
                EditorPaneView()
            }
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    // 与系统备忘录一致：列表 / 画廊切换
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

                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        NotificationCenter.default.post(name: .moyanCursorAsk, object: nil)
                    } label: {
                        Image(systemName: "sparkles")
                    }
                    .help("Cursor 提问")
                    .disabled(store.selectedNote == nil || store.selectedNote?.isTrashed == true)

                    Button {
                        store.presentAIAnalyzeForSelection()
                    } label: {
                        Image(systemName: "wand.and.stars")
                    }
                    .help("Cursor AI 分析")
                    .disabled(
                        (store.selectedNote == nil || store.selectedNote?.isTrashed == true)
                            && store.selectedFolder == nil
                    )

                    Button {
                        Task { await exportCurrentNote() }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .help("导出 PDF")
                    .disabled(store.selectedNote == nil || store.selectedNote?.isTrashed == true || isExporting)
                }
            }

            // 独立底栏：不用 safeAreaInset，避免叠在提问面板按钮上把按钮裁掉
            statusBar
        }
        .sheet(isPresented: Binding(
            get: { store.showAIAnalyze },
            set: { newValue in
                if newValue {
                    store.showAIAnalyze = true
                } else {
                    store.dismissAIAnalyze()
                }
            }
        )) {
            AIAnalyzeView()
                .environmentObject(store)
                .environmentObject(settings)
        }
        .preferredColorScheme(settings.appearance.colorScheme)
        .tint(settings.accent.color)
        .alert("导出", isPresented: Binding(
            get: { exportMessage != nil },
            set: { if !$0 { exportMessage = nil } }
        )) {
            Button("好", role: .cancel) { exportMessage = nil }
        } message: {
            Text(exportMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .moyanExportNote)) { _ in
            Task { await exportCurrentNote() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .moyanExportFolder)) { _ in
            Task { await exportCurrentFolder() }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: settings.storageMode == .iCloudDrive ? "icloud" : "internaldrive")
                .foregroundStyle(settings.accent.color)
            Text(store.syncStatusText)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if store.trashCount > 0 {
                Text("回收站 \(store.trashCount)")
                    .foregroundStyle(.tertiary)
            }
            Text(settings.storageMode.label)
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            Divider()
        }
    }

    @MainActor
    func exportCurrentNote() async {
        guard let note = store.selectedNote, !note.isTrashed else { return }
        isExporting = true
        defer { isExporting = false }
        do {
            let accent = accentHex(settings.accent.color)
            if let url = try await PDFExporter.exportNote(note, accentHex: accent) {
                exportMessage = "已导出到\n\(url.path)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            exportMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    func exportCurrentFolder() async {
        guard let folder = store.selectedFolder else { return }
        let notes = store.notesInSelectedFolder
        guard !notes.isEmpty else {
            exportMessage = "当前文件夹没有笔记"
            return
        }
        isExporting = true
        defer { isExporting = false }
        do {
            let accent = accentHex(settings.accent.color)
            if let url = try await PDFExporter.exportFolder(name: folder.name, notes: notes, accentHex: accent) {
                exportMessage = "已导出到\n\(url.path)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            exportMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    private func accentHex(_ color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .systemGreen
        return String(
            format: "#%02X%02X%02X",
            Int(ns.redComponent * 255),
            Int(ns.greenComponent * 255),
            Int(ns.blueComponent * 255)
        )
    }
}

#Preview {
    ContentView()
        .environmentObject(NoteStore())
        .environmentObject(AppSettings())
        .environmentObject(EditorBridge())
        .frame(width: 1100, height: 700)
}
