import AppKit
import SwiftUI

/// 墨言 — 参考妙言的轻量 Markdown 笔记 macOS 应用入口。
@main
struct MoyanApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var store: NoteStore
    @StateObject private var editorBridge: EditorBridge

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _store = StateObject(wrappedValue: NoteStore(storageMode: settings.storageMode))
        _editorBridge = StateObject(wrappedValue: EditorBridge())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(editorBridge)
                .frame(minWidth: 960, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .appInfo) {
                Button("重启") {
                    AppRelaunch.restart()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
            }

            CommandGroup(replacing: .newItem) {
                Button("新建笔记") {
                    store.createNote()
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("新建文件夹…") {
                    store.beginCreateFolder()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }

            CommandMenu("文件夹") {
                Button("从磁盘刷新") {
                    store.refreshFolder(store.selectedFolder)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("新建文件夹…") {
                    store.beginCreateFolder()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("重命名所选文件夹…") {
                    store.beginRenameSelectedFolder()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("打开所选文件夹位置") {
                    store.revealSelectedFolderInFinder()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("打开笔记库位置") {
                    store.revealLibraryInFinder()
                }
            }

            CommandMenu("导出") {
                Button("导出当前笔记为 PDF…") {
                    NotificationCenter.default.post(name: .moyanExportNote, object: nil)
                }
                .keyboardShortcut("e", modifiers: .command)

                Button("导出当前文件夹为 PDF…") {
                    NotificationCenter.default.post(name: .moyanExportFolder, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }

            CommandMenu("格式") {
                ForEach(MarkdownFormatAction.allCases) { action in
                    Button(action.help) {
                        editorBridge.perform(action)
                    }
                }
            }

            CommandGroup(after: .textEditing) {
                Button("查找…") {
                    NotificationCenter.default.post(name: .moyanFind, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("查找与替换…") {
                    NotificationCenter.default.post(name: .moyanFindReplace, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .option])

                Button("查找下一个") {
                    NotificationCenter.default.post(name: .moyanFindNext, object: nil)
                }
                .keyboardShortcut("g", modifiers: .command)

                Button("查找上一个") {
                    NotificationCenter.default.post(name: .moyanFindPrevious, object: nil)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(settings)
        }
    }
}

extension Notification.Name {
    static let moyanExportNote = Notification.Name("moyan.export.note")
    static let moyanExportFolder = Notification.Name("moyan.export.folder")
    static let moyanFind = Notification.Name("moyan.find")
    static let moyanFindReplace = Notification.Name("moyan.findReplace")
    static let moyanFindNext = Notification.Name("moyan.findNext")
    static let moyanFindPrevious = Notification.Name("moyan.findPrevious")
    /// 打开编辑区右侧 Cursor 提问面板（问题可自行编辑）。
    static let moyanCursorAsk = Notification.Name("moyan.cursor.ask")
}

/// 手动重启：先打开新实例，再退出当前进程。
enum AppRelaunch {
    static func restart() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}
