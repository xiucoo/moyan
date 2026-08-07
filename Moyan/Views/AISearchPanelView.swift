import SwiftUI

/// 编辑区右侧 Cursor 提问面板：问题可自行编辑，结果流式输出。
struct AISearchPanelView: View {
    @ObservedObject var ai: CursorAIService
    @Binding var query: String
    var accent: Color
    var onClose: () -> Void
    var onInsert: (String) -> Void
    var onRerun: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            queryBlock
            Divider()
            // minHeight: 0 才能在 VStack 里被压缩，否则 ScrollView 按内容撑开把底部按钮顶出可视区
            resultBlock
                .frame(minHeight: 0, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(accent)
            Text("Cursor 提问")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
            if ai.isRunning {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var queryBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("问题 / 选中内容（可编辑）")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $query)
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: .labelColor))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 80)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.8), lineWidth: 1)
                )
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("在此输入要问 Cursor 的内容，或先在正文选中一段再点工具栏图标。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var resultBlock: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let err = ai.lastError, !err.isEmpty {
                    Text(err)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if ai.output.isEmpty, ai.isRunning {
                    Text("正在提问…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } else if ai.output.isEmpty, ai.lastError == nil {
                    Text("编辑上方问题后点「提问」，结果会实时显示在这里。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } else {
                    Text(ai.output)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                onRerun()
            } label: {
                Label(ai.isRunning ? "提问中…" : "提问", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .controlSize(.large)
            .disabled(ai.isRunning || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if ai.isRunning {
                Button("停止") { ai.cancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }

            Spacer(minLength: 8)

            Button {
                onInsert(ai.output)
            } label: {
                Label("插入到笔记", systemImage: "text.append")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(ai.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
