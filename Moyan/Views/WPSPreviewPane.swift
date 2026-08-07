import AppKit
import SwiftUI

/// WPS 文件预览面板：表格走网格，文档走 Quick Look；编辑交给 WPS。
struct WPSPreviewPane: View {
    @EnvironmentObject private var store: NoteStore
    let fileID: UUID

    @State private var workbook: XLSXWorkbook.Workbook?
    @State private var loadError: String?
    @State private var fileURL: URL?
    @State private var mtime: Date?
    @State private var refreshTick = 0

    private var file: WPSLinkedFile? {
        store.wpsFiles.first { $0.id == fileID }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { reload(force: true) }
        .onChange(of: fileID) { _, _ in reload(force: true) }
        .onChange(of: refreshTick) { _, _ in reload(force: false) }
        .onReceive(Timer.publish(every: 2.5, on: .main, in: .common).autoconnect()) { _ in
            refreshTick &+= 1
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: file?.kind == .spreadsheet ? "tablecells" : "doc.richtext")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(file?.title ?? "WPS 文件")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let url = fileURL {
                    Text(url.path)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button("用 WPS 打开") {
                store.openWPSFile(fileID)
            }
            .disabled(fileURL == nil)
            Button("Finder") {
                store.revealWPSFile(fileID)
            }
            .disabled(fileURL == nil)
            Button {
                store.dismissWPSPreview()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭预览")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if let loadError {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text(loadError)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if fileURL != nil {
                    Button("用 WPS 打开") { store.openWPSFile(fileID) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if let workbook {
            SpreadsheetGridView(workbook: workbook)
        } else if let url = fileURL, shouldUseQuickLook(url) {
            QLPreviewContainer(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if fileURL != nil {
            ProgressView("加载中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "文件不可用",
                systemImage: "questionmark.folder",
                description: Text("外链可能已移动或删除，请重新关联")
            )
        }
    }

    private func shouldUseQuickLook(_ url: URL) -> Bool {
        let ext = url.pathExtension
        if WPSLinkSupport.supportsGridPreview(ext: ext) { return false }
        return true
    }

    private func reload(force: Bool) {
        guard let resolved = store.resolveWPSFileURL(fileID) else {
            fileURL = nil
            workbook = nil
            loadError = "找不到文件（可能已被移动或删除）"
            return
        }
        fileURL = resolved
        let attrs = try? FileManager.default.attributesOfItem(atPath: resolved.path)
        let newMtime = attrs?[.modificationDate] as? Date
        if !force, newMtime == mtime {
            // 网格已加载且文件未变，或走 QL 时无需重载
            if workbook != nil || !WPSLinkSupport.supportsGridPreview(ext: resolved.pathExtension) {
                return
            }
        }
        mtime = newMtime
        loadError = nil

        let ext = resolved.pathExtension.lowercased()
        if WPSLinkSupport.supportsGridPreview(ext: ext) {
            do {
                workbook = try XLSXWorkbook.load(from: resolved)
            } catch {
                workbook = nil
                loadError = "无法解析表格：\(error.localizedDescription)\n可改用 WPS 打开"
            }
        } else {
            workbook = nil
        }
    }
}
