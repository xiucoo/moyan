import SwiftUI

/// 笔记标题下方的标签编辑条：可选已有标签、新建、删除。
struct TagBarView: View {
    let noteID: UUID
    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var settings: AppSettings
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var tags: [String] {
        store.notes.first(where: { $0.id == noteID })?.tags ?? []
    }

    /// 尚未打在当前笔记上的已有标签。
    private var availableTags: [String] {
        store.allTags.filter { candidate in
            !tags.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame })
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "tag")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text(tag)
                                .font(.system(size: 11, weight: .medium))
                            Button {
                                store.removeTag(tag, from: noteID)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(settings.accent.color.opacity(0.18))
                        .foregroundStyle(settings.accent.color)
                        .clipShape(Capsule())
                    }

                    Menu {
                        if availableTags.isEmpty {
                            Text("暂无其它已有标签")
                        } else {
                            ForEach(availableTags, id: \.self) { tag in
                                Button(tag) {
                                    store.addTag(tag, to: noteID)
                                }
                            }
                        }
                        Divider()
                        Button("输入新标签…") {
                            focused = true
                        }
                    } label: {
                        Label("选择标签", systemImage: "plus")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    TextField("或输入新标签", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .frame(minWidth: 88)
                        .focused($focused)
                        .onSubmit { commit() }

                    if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // 输入时顺带提示可匹配的已有标签
                        ForEach(matchingSuggestions.prefix(4), id: \.self) { tag in
                            Button(tag) {
                                store.addTag(tag, to: noteID)
                                draft = ""
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(settings.accent.color)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 8)
    }

    private var matchingSuggestions: [String] {
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return availableTags.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    private func commit() {
        store.addTag(draft, to: noteID)
        draft = ""
    }
}
