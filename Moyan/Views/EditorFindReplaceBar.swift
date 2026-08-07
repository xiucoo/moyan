import SwiftUI

/// 编辑区查找 / 替换条：⌘F 打开，⌘⌥F 展开替换。
struct EditorFindReplaceBar: View {
    @Binding var findText: String
    @Binding var replaceText: String
    @Binding var showReplace: Bool
    var statusText: String
    var onFindNext: () -> Void
    var onFindPrevious: () -> Void
    var onReplace: () -> Void
    var onReplaceAll: () -> Void
    var onClose: () -> Void

    @FocusState private var focusFind: Bool
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("查找", text: $findText)
                    .textFieldStyle(.plain)
                    .focused($focusFind)
                    .onSubmit { onFindNext() }

                Button(action: onFindPrevious) {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .help("上一个 ⇧⌘G")

                Button(action: onFindNext) {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .help("下一个 ⌘G")

                Button {
                    showReplace.toggle()
                } label: {
                    Image(systemName: showReplace ? "chevron.up.square" : "rectangle.and.pencil.and.ellipsis")
                }
                .buttonStyle(.borderless)
                .help("显示替换 ⌘⌥F")

                if !statusText.isEmpty {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("关闭 ⌥⌘G / Esc")
            }

            if showReplace {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                    TextField("替换为", text: $replaceText)
                        .textFieldStyle(.plain)
                        .onSubmit { onReplace() }

                    Button("替换", action: onReplace)
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                    Button("全部替换", action: onReplaceAll)
                        .buttonStyle(.borderedProminent)
                        .tint(settings.accent.color)
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
        .overlay(alignment: .bottom) {
            Divider().opacity(0.5)
        }
        .onAppear {
            focusFind = true
        }
    }
}
