import SwiftUI

/// 编辑器上方 Markdown 格式工具条。
struct MarkdownToolbarView: View {
    @EnvironmentObject private var bridge: EditorBridge
    @EnvironmentObject private var settings: AppSettings
    var onAISearch: (() -> Void)? = nil

    @State private var showColorPicker = false

    private let actions: [MarkdownFormatAction] = [
        .heading1, .heading2, .heading3,
        .bold, .italic, .strikethrough,
        .inlineCode, .codeBlock,
        .quote, .bulletList, .numberedList, .taskList,
        .link, .horizontalRule, .table
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                    if shouldInsertDivider(before: index) {
                        Divider()
                            .frame(height: 16)
                            .padding(.horizontal, 4)
                    }
                    Button {
                        bridge.perform(action)
                    } label: {
                        Image(systemName: action.systemImage)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 28, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .help(action.help)
                }

                Divider()
                    .frame(height: 16)
                    .padding(.horizontal, 4)

                Button {
                    showColorPicker.toggle()
                } label: {
                    VStack(spacing: 1) {
                        Text("A")
                            .font(.system(size: 12, weight: .bold))
                        Capsule()
                            .fill(settings.accent.color)
                            .frame(width: 14, height: 3)
                    }
                    .frame(width: 28, height: 24)
                    .background(showColorPicker ? Color.accentColor.opacity(0.15) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.borderless)
                .help("文字颜色 / 背景色")
                .popover(isPresented: $showColorPicker, arrowEdge: .bottom) {
                    ColorStylePickerView(
                        onForeground: { hex in
                            bridge.applyForegroundColor(hex)
                            showColorPicker = false
                        },
                        onBackground: { hex in
                            bridge.applyBackgroundColor(hex)
                            showColorPicker = false
                        },
                        onReset: {
                            bridge.clearTextStyle()
                            showColorPicker = false
                        }
                    )
                }

                Button {
                    if let onAISearch {
                        onAISearch()
                    } else {
                        bridge.requestAISearch()
                    }
                } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(.borderless)
                .help("Cursor 提问")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.9))
        .overlay(alignment: .bottom) {
            Divider().opacity(0.5)
        }
        .tint(settings.accent.color)
    }

    private func shouldInsertDivider(before index: Int) -> Bool {
        // 分组：标题 | 强调 | 代码 | 列表 | 其它
        [3, 6, 8, 12, 14].contains(index)
    }
}
