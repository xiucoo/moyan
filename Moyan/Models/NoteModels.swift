import Foundation

/// 左侧栏中的笔记文件夹（对应磁盘上的一个子目录）。
struct NoteFolder: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    /// SF Symbol 名称，贴近妙言的线框图标风格。
    var symbolName: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, symbolName: String = "folder", createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.createdAt = createdAt
    }
}

/// 一篇 Markdown 笔记；正文以 `.md` 文件持久化。
struct Note: Identifiable, Hashable, Codable {
    let id: UUID
    var folderID: UUID
    var title: String
    /// 工作简介等短摘要；工作日志中同步到正文 H1 下的 `> 副标题`。
    var subtitle: String
    var content: String
    var createdAt: Date
    var updatedAt: Date
    /// 相对所属笔记夹的文件名（可含一层子目录），用于磁盘同步。
    var fileName: String
    /// 用户标签（去重、有序）。
    var tags: [String]
    /// 非空表示已在回收站。
    var deletedAt: Date?
    /// 父笔记 ID；非空表示由父笔记中的某条子任务拆出的子文件。
    var parentNoteID: UUID?
    /// 创建子文件时对应的任务原文（去列表前缀），用于中间栏关联展示。
    var linkedTaskText: String?

    init(
        id: UUID = UUID(),
        folderID: UUID,
        title: String,
        subtitle: String = "",
        content: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        fileName: String? = nil,
        tags: [String] = [],
        deletedAt: Date? = nil,
        parentNoteID: UUID? = nil,
        linkedTaskText: String? = nil
    ) {
        self.id = id
        self.folderID = folderID
        self.title = title
        self.subtitle = subtitle
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.fileName = fileName ?? "\(id.uuidString).md"
        self.tags = tags
        self.deletedAt = deletedAt
        self.parentNoteID = parentNoteID
        self.linkedTaskText = linkedTaskText
    }

    var isTrashed: Bool { deletedAt != nil }

    /// 是否为挂在父笔记下的子文件。
    var isChildNote: Bool { parentNoteID != nil }

    /// 列表时间格式，贴近妙言 `yyyy/MM/dd HH:mm`。
    var formattedUpdatedAt: String {
        Self.listDateFormatter.string(from: deletedAt ?? updatedAt)
    }

    private static let listDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter
    }()

    enum CodingKeys: String, CodingKey {
        case id, folderID, title, subtitle, content, createdAt, updatedAt, fileName, tags, deletedAt
        case parentNoteID, linkedTaskText
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        folderID = try c.decode(UUID.self, forKey: .folderID)
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        content = try c.decode(String.self, forKey: .content)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        fileName = try c.decode(String.self, forKey: .fileName)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        parentNoteID = try c.decodeIfPresent(UUID.self, forKey: .parentNoteID)
        linkedTaskText = try c.decodeIfPresent(String.self, forKey: .linkedTaskText)
    }
}

/// 左侧导航选中态：文件夹 / 标签 / 回收站。
enum SidebarDestination: Hashable {
    case folder(UUID)
    case tag(String)
    case trash
}

/// Cursor AI 分析范围：单篇笔记或整个文件夹。
enum AIAnalyzeTarget: Equatable {
    case note(UUID)
    case folder(UUID)
}

/// 编辑区展示：纯编辑 / 纯预览 / 左右分栏。
enum EditorMode: String, CaseIterable, Identifiable {
    case editor
    case preview
    case split

    var id: String { rawValue }

    var label: String {
        switch self {
        case .editor: return "编辑"
        case .preview: return "预览"
        case .split: return "分栏"
        }
    }

    var systemImage: String {
        switch self {
        case .editor: return "square.and.pencil"
        case .preview: return "eye"
        case .split: return "rectangle.split.2x1"
        }
    }
}

// MARK: - WPS 链接文件

/// WPS / Office 文件类型（表格或文档）。
enum WPSFileKind: String, Codable, Hashable {
    case spreadsheet
    case document

    var markdownEmoji: String {
        switch self {
        case .spreadsheet: return "📊"
        case .document: return "📄"
        }
    }

    var defaultExtension: String {
        switch self {
        case .spreadsheet: return "xlsx"
        case .document: return "docx"
        }
    }

    var templateResourceName: String {
        switch self {
        case .spreadsheet: return "Empty.xlsx"
        case .document: return "Empty.docx"
        }
    }

    var label: String {
        switch self {
        case .spreadsheet: return "表格"
        case .document: return "文档"
        }
    }
}

/// 库内相对路径，或外链 bookmark + 最近已知路径。
enum WPSStorage: Codable, Hashable {
    case library(relativePath: String)
    case external(bookmark: Data, path: String)

    enum CodingKeys: String, CodingKey {
        case type, relativePath, bookmark, path
    }

    enum StorageType: String, Codable {
        case library, external
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(StorageType.self, forKey: .type)
        switch type {
        case .library:
            self = .library(relativePath: try c.decode(String.self, forKey: .relativePath))
        case .external:
            self = .external(
                bookmark: try c.decode(Data.self, forKey: .bookmark),
                path: try c.decode(String.self, forKey: .path)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .library(let relativePath):
            try c.encode(StorageType.library, forKey: .type)
            try c.encode(relativePath, forKey: .relativePath)
        case .external(let bookmark, let path):
            try c.encode(StorageType.external, forKey: .type)
            try c.encode(bookmark, forKey: .bookmark)
            try c.encode(path, forKey: .path)
        }
    }
}

/// 挂在笔记上的 WPS/Office 文件（库内新建或外链）。
struct WPSLinkedFile: Identifiable, Hashable, Codable {
    let id: UUID
    var title: String
    var kind: WPSFileKind
    var storage: WPSStorage
    /// 所属笔记；解除链接后可为空。
    var noteID: UUID?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        kind: WPSFileKind,
        storage: WPSStorage,
        noteID: UUID? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.storage = storage
        self.noteID = noteID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 正文 Markdown 链：`[📊 标题](moyan-wps://UUID)`。
    var markdownLink: String {
        "[\(kind.markdownEmoji) \(title)](moyan-wps://\(id.uuidString))"
    }
}
