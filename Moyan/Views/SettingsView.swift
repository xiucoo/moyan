import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: NoteStore
    @EnvironmentObject private var settings: AppSettings
    @State private var pendingStorage: StorageMode?
    @State private var confirmMigrate = false
    @State private var aiInstallLog: String?
    @State private var isInstallingAI = false

    var body: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { item in
                        Text(item.label).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                Picker("强调色", selection: $settings.accent) {
                    ForEach(AccentOption.allCases) { item in
                        HStack {
                            Circle().fill(item.color).frame(width: 10, height: 10)
                            Text(item.label)
                        }
                        .tag(item)
                    }
                }

                Picker("列表 / 画廊", selection: $settings.notesBrowseMode) {
                    ForEach(NotesBrowseMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("应用") {
                Button("重启墨言") {
                    AppRelaunch.restart()
                }
                .help("重新启动应用，用于图标或资源未刷新时")
            }

            Section("同步与存储") {
                Picker("笔记库位置", selection: Binding(
                    get: { settings.storageMode },
                    set: { newValue in
                        guard newValue != settings.storageMode else { return }
                        pendingStorage = newValue
                        confirmMigrate = true
                    }
                )) {
                    ForEach(StorageMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }

                LabeledContent("当前路径") {
                    Text(store.libraryURL.path)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }

                LabeledContent("iCloud Drive") {
                    Text(LibraryLocation.isICloudDriveAvailable ? "可用" : "未检测到")
                        .foregroundStyle(LibraryLocation.isICloudDriveAvailable ? .green : .secondary)
                }

                LabeledContent("状态") {
                    Text(store.syncStatusText)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("在 Finder 中显示") {
                        store.revealLibraryInFinder()
                    }
                    Button("立即刷新") {
                        store.reloadFromDisk()
                    }
                    .help("扫描磁盘上的 .md，自动导入新文件并去掉失效索引")
                }

                Text("应用会监听笔记库目录变化；若仍对不上，点刷新或按 ⌘R。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("扫描导入磁盘上的 Markdown") {
                    let n = store.importUntrackedFilesFromDisk()
                    if n == 0 {
                        store.lastErrorMessage = "没有发现尚未导入的 .md 文件，或索引已与磁盘一致。路径：\(store.libraryURL.path)"
                    }
                }

                Button("按磁盘重建索引（导入妙言后用）") {
                    store.rebuildIndexFromDisk()
                }
                .help("以文件夹和 .md 文件为准重建列表：标题优先用文件名（与 Finder 一致），清掉已无文件的旧索引；工作日志会导入日期篇与副标题")
            }

            Section("Cursor AI") {
                SecureField("Cursor API Key", text: $settings.cursorAPIKey)
                TextField("模型 ID", text: $settings.cursorModelID)
                Text("默认 grok-4.5（Cursor Grok 4.5）。API Key 在 cursor.com 账户设置中创建。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(isInstallingAI ? "正在安装…" : "安装 AI 依赖（npm install）") {
                    isInstallingAI = true
                    Task {
                        let service = CursorAIService()
                        aiInstallLog = await service.installDependencies()
                        isInstallingAI = false
                    }
                }
                .disabled(isInstallingAI)

                if let aiInstallLog {
                    Text(aiInstallLog)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("关于") {
                Text("从妙言复制笔记时：请复制到「文稿/墨言」（不是「秒言」）。复制后点「按磁盘重建索引」。工作日志以日期为标题、`> 简介` 为副标题；根目录 .md 归入「未分类」。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 560)
        .padding()
        .alert("切换存储位置", isPresented: $confirmMigrate) {
            Button("取消", role: .cancel) {
                pendingStorage = nil
            }
            Button("仅切换（不迁移）") {
                if let mode = pendingStorage {
                    settings.storageMode = mode
                    store.switchStorage(to: mode, migrate: false)
                }
                pendingStorage = nil
            }
            Button("迁移并切换") {
                if let mode = pendingStorage {
                    settings.storageMode = mode
                    store.switchStorage(to: mode, migrate: true)
                }
                pendingStorage = nil
            }
        } message: {
            Text(pendingStorage?.detail ?? "")
        }
        .alert("提示", isPresented: Binding(
            get: { store.lastErrorMessage != nil },
            set: { if !$0 { store.lastErrorMessage = nil } }
        )) {
            Button("好", role: .cancel) { store.lastErrorMessage = nil }
        } message: {
            Text(store.lastErrorMessage ?? "")
        }
    }
}
