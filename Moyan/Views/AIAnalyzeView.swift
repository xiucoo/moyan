import SwiftUI

/// Cursor AI 分析面板：支持单篇笔记或整个文件夹。
struct AIAnalyzeView: View {
    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var ai = CursorAIService()
    @State private var preset: CursorAIService.Preset = .summarize
    @State private var question = ""
    @State private var installLog: String?

    private var resolvedTarget: AIAnalyzeTarget? {
        if let target = store.aiAnalyzeTarget { return target }
        if let note = store.selectedNote, !note.isTrashed {
            return .note(note.id)
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Cursor AI 分析", systemImage: "sparkles")
                    .font(.headline)
                Text(settings.cursorModelID.isEmpty ? "grok-4.5" : settings.cursorModelID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(Capsule())
                Spacer()
                if ai.isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Button("停止") { ai.cancel() }
                }
            }

            if let payload = analysisPayload {
                Text(payload.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Picker("任务", selection: $preset) {
                    ForEach(CursorAIService.Preset.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                if preset == .free {
                    TextField("输入你的问题", text: $question, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                }

                HStack {
                    Button(ai.isRunning ? "分析中…" : "开始分析") {
                        Task {
                            await ai.analyze(
                                apiKey: settings.cursorAPIKey,
                                preset: preset,
                                title: payload.title,
                                content: payload.content,
                                extraQuestion: question,
                                workDirectory: store.libraryURL,
                                modelID: settings.cursorModelID
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(settings.accent.color)
                    .disabled(
                        ai.isRunning
                            || settings.cursorAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || payload.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )

                    Button(payload.insertLabel) {
                        insertResult(payload)
                    }
                    .disabled(ai.output.isEmpty)

                    Spacer()
                    if !ai.isBridgeInstalled {
                        Button("安装 AI 依赖") {
                            Task {
                                installLog = await ai.installDependencies()
                            }
                        }
                    }
                }

                if let installLog {
                    Text(installLog)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if let err = ai.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                ScrollView {
                    Text(ai.output.isEmpty ? "分析结果会显示在这里。" : ai.output)
                        .font(.system(.body, design: .default))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Text("请先选择一篇笔记或一个文件夹。")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(16)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 420)
    }

    /// 把当前目标解析为可送进模型的标题与正文。
    private var analysisPayload: (
        title: String,
        content: String,
        subtitle: String,
        insertLabel: String,
        noteID: UUID?,
        folderID: UUID?
    )? {
        switch resolvedTarget {
        case .note(let id):
            guard let note = store.notes.first(where: { $0.id == id }), !note.isTrashed else { return nil }
            return (
                note.title,
                note.content,
                note.title,
                "插入到笔记末尾",
                note.id,
                nil
            )
        case .folder(let id):
            let bundle = store.aiBundle(forFolderID: id)
            guard !bundle.notes.isEmpty else {
                return (
                    bundle.title,
                    "",
                    "「\(store.folders.first(where: { $0.id == id })?.name ?? "")」暂无笔记",
                    "保存为新笔记",
                    nil,
                    id
                )
            }
            return (
                bundle.title,
                bundle.content,
                bundle.title,
                "保存为新笔记",
                nil,
                id
            )
        case .none:
            return nil
        }
    }

    private func insertResult(_ payload: (
        title: String,
        content: String,
        subtitle: String,
        insertLabel: String,
        noteID: UUID?,
        folderID: UUID?
    )) {
        let block = "\n\n---\n\n### AI 分析\n\n\(ai.output)\n"
        if let noteID = payload.noteID,
           let note = store.notes.first(where: { $0.id == noteID }) {
            store.updateNoteContent(noteID, content: note.content + block)
            return
        }
        // 文件夹分析：在该文件夹新建一篇结果笔记。
        if let folderID = payload.folderID {
            store.createNote(
                in: folderID,
                title: "AI 分析 · \(store.folders.first(where: { $0.id == folderID })?.name ?? "文件夹")",
                content: "# AI 分析\n\n\(ai.output)\n"
            )
        }
    }
}
