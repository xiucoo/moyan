import AppKit
import Combine
import SwiftUI

/// 外观：跟随系统 / 浅色 / 深色。
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// 笔记库落盘位置。
enum StorageMode: String, CaseIterable, Identifiable {
    case local
    case iCloudDrive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local: return "本机 Documents"
        case .iCloudDrive: return "iCloud Drive"
        }
    }

    var detail: String {
        switch self {
        case .local: return "~/Documents/墨言"
        case .iCloudDrive: return "iCloud Drive/墨言（多设备自动同步）"
        }
    }
}

/// 主题强调色（侧栏品牌、按钮、高亮）。
enum AccentOption: String, CaseIterable, Identifiable {
    case green
    case teal
    case blue
    case purple
    case orange

    var id: String { rawValue }

    var label: String {
        switch self {
        case .green: return "叶绿"
        case .teal: return "青石"
        case .blue: return "雾蓝"
        case .purple: return "藤紫"
        case .orange: return "琥珀"
        }
    }

    var color: Color {
        switch self {
        case .green: return Color(red: 0.22, green: 0.68, blue: 0.42)
        case .teal: return Color(red: 0.15, green: 0.62, blue: 0.58)
        case .blue: return Color(red: 0.24, green: 0.48, blue: 0.82)
        case .purple: return Color(red: 0.52, green: 0.34, blue: 0.78)
        case .orange: return Color(red: 0.90, green: 0.48, blue: 0.22)
        }
    }

    var nsColor: NSColor {
        NSColor(color)
    }
}

/// 中间栏浏览方式：列表 / 画廊（贴近系统备忘录）。
enum NotesBrowseMode: String, CaseIterable, Identifiable {
    case list
    case gallery

    var id: String { rawValue }

    var label: String {
        switch self {
        case .list: return "列表"
        case .gallery: return "画廊"
        }
    }

    var systemImage: String {
        switch self {
        case .list: return "list.bullet"
        case .gallery: return "square.grid.2x2"
        }
    }
}

/// 用户偏好：主题、强调色、存储位置（UserDefaults 持久化）。
@MainActor
final class AppSettings: ObservableObject {
    @Published var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    @Published var accent: AccentOption {
        didSet { defaults.set(accent.rawValue, forKey: Keys.accent) }
    }

    @Published var storageMode: StorageMode {
        didSet { defaults.set(storageMode.rawValue, forKey: Keys.storageMode) }
    }

    /// 笔记浏览方式：列表或备忘录式画廊。
    @Published var notesBrowseMode: NotesBrowseMode {
        didSet { defaults.set(notesBrowseMode.rawValue, forKey: Keys.notesBrowseMode) }
    }

    /// Cursor API Key（用于墨言内 AI 分析）。
    @Published var cursorAPIKey: String {
        didSet { defaults.set(cursorAPIKey, forKey: Keys.cursorAPIKey) }
    }

    /// Cursor 模型 ID，默认 Grok 4.5。
    @Published var cursorModelID: String {
        didSet { defaults.set(cursorModelID, forKey: Keys.cursorModelID) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let appearance = "moyan.appearance"
        static let accent = "moyan.accent"
        static let storageMode = "moyan.storageMode"
        static let notesBrowseMode = "moyan.notesBrowseMode"
        static let cursorAPIKey = "moyan.cursorAPIKey"
        static let cursorModelID = "moyan.cursorModelID"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.appearance = AppAppearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        self.accent = AccentOption(rawValue: defaults.string(forKey: Keys.accent) ?? "") ?? .green
        self.storageMode = StorageMode(rawValue: defaults.string(forKey: Keys.storageMode) ?? "") ?? .local
        self.notesBrowseMode = NotesBrowseMode(rawValue: defaults.string(forKey: Keys.notesBrowseMode) ?? "") ?? .list
        self.cursorAPIKey = defaults.string(forKey: Keys.cursorAPIKey)
            ?? ProcessInfo.processInfo.environment["CURSOR_API_KEY"]
            ?? ""
        let savedModel = defaults.string(forKey: Keys.cursorModelID) ?? ""
        self.cursorModelID = savedModel.isEmpty ? "grok-4.5" : savedModel
    }
}
