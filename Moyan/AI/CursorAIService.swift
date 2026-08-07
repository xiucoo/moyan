import Foundation

/// 通过本地 Node 桥接调用 Cursor SDK，对当前笔记做 AI 分析。
@MainActor
final class CursorAIService: ObservableObject {
    @Published var isRunning = false
    @Published var output = ""
    @Published var lastError: String?

    private var process: Process?

    enum Preset: String, CaseIterable, Identifiable {
        case summarize
        case todos
        case polish
        case risks
        case free

        var id: String { rawValue }

        var label: String {
            switch self {
            case .summarize: return "总结要点"
            case .todos: return "提取待办"
            case .polish: return "润色改写"
            case .risks: return "风险与问题"
            case .free: return "自定义提问"
            }
        }

        func prompt(title: String, content: String, extra: String) -> String {
            let isFolder = title.hasPrefix("文件夹「")
            let body = """
            你是笔记助手。下面是用户的 Markdown \(isFolder ? "文件夹内容汇总" : "笔记")。

            标题：\(title)

            ---
            \(content)
            ---
            """
            switch self {
            case .summarize:
                return body + (isFolder
                    ? "\n请用中文总结该文件夹下各笔记的核心要点，可按笔记分组，简洁清晰。"
                    : "\n请用中文总结核心要点，列出 3-7 条，简洁清晰。")
            case .todos:
                return body + "\n请提取所有待办/任务，输出 Markdown 任务列表（`- [ ]`），并按优先级分组。"
            case .polish:
                return body + (isFolder
                    ? "\n请基于文件夹内容整理一份结构清晰的 Markdown 综述（不要机械拼接原文）。"
                    : "\n请润色正文，保持原意，输出润色后的完整 Markdown。")
            case .risks:
                return body + "\n请指出内容中的风险、遗漏、含糊之处，并给出可执行建议。"
            case .free:
                let q = extra.trimmingCharacters(in: .whitespacesAndNewlines)
                return body + "\n用户问题：\(q.isEmpty ? (isFolder ? "请分析这个文件夹并给出建议。" : "请分析这篇笔记并给出建议。") : q)"
            }
        }
    }

    /// 桥接脚本与依赖所在目录（仓库 Tools/cursor-bridge）。
    static var bridgeDirectory: URL {
        // 开发时：相对工程源码；发布时可改为 Bundle 资源
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AI
            .deletingLastPathComponent() // Moyan
            .deletingLastPathComponent() // project root
            .appendingPathComponent("Tools/cursor-bridge", isDirectory: true)
    }

    static var analyzeScript: URL {
        bridgeDirectory.appendingPathComponent("analyze.mjs")
    }

    static var searchStreamScript: URL {
        bridgeDirectory.appendingPathComponent("search-stream.mjs")
    }

    var isBridgeInstalled: Bool {
        let nodeModules = Self.bridgeDirectory.appendingPathComponent("node_modules/@cursor/sdk")
        return FileManager.default.fileExists(atPath: Self.analyzeScript.path)
            && FileManager.default.fileExists(atPath: nodeModules.path)
    }

    func cancel() {
        process?.terminate()
        process = nil
        isRunning = false
    }

    /// 针对选中文本做 AI 检索/解释，stdout NDJSON 流式更新 `output`。
    func searchStreaming(
        apiKey: String,
        selection: String,
        noteTitle: String,
        noteContext: String,
        workDirectory: URL,
        modelID: String = CursorAIService.defaultModelID
    ) async {
        cancel()
        lastError = nil
        output = ""
        isRunning = true

        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            lastError = "请先在设置中填写 Cursor API Key"
            isRunning = false
            return
        }
        guard !query.isEmpty else {
            lastError = "请先选中要搜索的文字"
            isRunning = false
            return
        }
        guard FileManager.default.fileExists(atPath: Self.searchStreamScript.path) else {
            lastError = "找不到流式桥接脚本：\(Self.searchStreamScript.path)"
            isRunning = false
            return
        }
        guard isBridgeInstalled else {
            lastError = "尚未安装 Cursor SDK 依赖。请在设置中点击「安装 AI 依赖」。"
            isRunning = false
            return
        }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("moyan-ai-search-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try noteContext.write(to: work.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
            try query.write(to: work.appendingPathComponent("selection.txt"), atomically: true, encoding: .utf8)
        } catch {
            lastError = "准备临时文件失败：\(error.localizedDescription)"
            isRunning = false
            return
        }

        let prompt = """
        你是笔记助手，请围绕用户选中的内容做检索式解答。

        笔记标题：\(noteTitle)

        选中内容：
        ---
        \(query)
        ---

        要求：
        1. 用中文回答，结构清晰，可含要点列表。
        2. 解释选中内容的含义、背景或用途；若像专有名词/接口/报错，补充常见用法或排查方向。
        3. 不要编造与笔记无关的事实；不确定时明确说明。
        4. 原文也在工作区 note.md / selection.txt，可参考。
        """

        let resolvedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultModelID
            : modelID.trimmingCharacters(in: .whitespacesAndNewlines)

        let payload: [String: Any] = [
            "apiKey": key,
            "prompt": prompt,
            "cwd": work.path,
            "model": resolvedModel
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonText = String(data: jsonData, encoding: .utf8) else {
            lastError = "无法编码请求"
            isRunning = false
            return
        }

        let inputFile = work.appendingPathComponent("request.json")
        do {
            try jsonText.write(to: inputFile, atomically: true, encoding: .utf8)
        } catch {
            lastError = "写入请求失败：\(error.localizedDescription)"
            isRunning = false
            return
        }

        let node = resolveNodePath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [Self.searchStreamScript.path, inputFile.path]
        process.currentDirectoryURL = Self.bridgeDirectory
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CURSOR_API_KEY": key,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        ]) { _, new in new }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        self.process = process

        let handle = stdout.fileHandleForReading
        let state = StreamReadState()

        do {
            try process.run()
        } catch {
            lastError = "无法启动 Node：\(error.localizedDescription)。请确认已安装 Node.js。"
            isRunning = false
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            state.continuation = continuation

            handle.readabilityHandler = { [weak self] file in
                let chunk = file.availableData
                if chunk.isEmpty {
                    file.readabilityHandler = nil
                    return
                }
                let lines = state.appendAndSplit(chunk)
                DispatchQueue.main.async {
                    for line in lines {
                        self?.consumeStreamLine(line)
                    }
                }
            }

            process.terminationHandler = { [weak self] proc in
                handle.readabilityHandler = nil
                let rest = handle.readDataToEndOfFile()
                let trailing = state.appendAndSplit(rest) + state.flushRemainder()
                let errText = String(
                    data: stderr.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                DispatchQueue.main.async {
                    for line in trailing {
                        self?.consumeStreamLine(line)
                    }
                    if self?.isRunning == true {
                        self?.isRunning = false
                    }
                    if (self?.output.isEmpty ?? true),
                       self?.lastError == nil,
                       proc.terminationStatus != 0 {
                        self?.lastError = errText.isEmpty
                            ? "搜索失败（exit \(proc.terminationStatus)）"
                            : errText
                    }
                    self?.process = nil
                    state.resumeOnce()
                }
            }
        }
    }

    private func consumeStreamLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "delta":
            if let text = obj["text"] as? String {
                output += text
            }
        case "done":
            isRunning = false
            if let ok = obj["ok"] as? Bool, ok {
                if let text = obj["text"] as? String, !text.isEmpty {
                    if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        output = text
                    } else if text.count > output.count {
                        output = text
                    }
                }
            } else {
                lastError = (obj["error"] as? String) ?? "搜索失败"
            }
        default:
            break
        }
    }

    /// 默认模型：Cursor Grok 4.5（与当前对话一致）
    static let defaultModelID = "grok-4.5"

    func analyze(
        apiKey: String,
        preset: Preset,
        title: String,
        content: String,
        extraQuestion: String,
        workDirectory: URL,
        modelID: String = CursorAIService.defaultModelID
    ) async {
        cancel()
        lastError = nil
        output = ""
        isRunning = true
        defer { isRunning = false }

        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            lastError = "请先在设置中填写 Cursor API Key"
            return
        }
        guard FileManager.default.fileExists(atPath: Self.analyzeScript.path) else {
            lastError = "找不到桥接脚本：\(Self.analyzeScript.path)"
            return
        }
        guard isBridgeInstalled else {
            lastError = "尚未安装 Cursor SDK 依赖。请在设置中点击「安装 AI 依赖」。"
            return
        }

        // 把笔记落到临时工作区，供 local agent 读取
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("moyan-ai-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try content.write(to: work.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        } catch {
            lastError = "准备临时文件失败：\(error.localizedDescription)"
            return
        }

        let prompt = preset.prompt(title: title, content: content, extra: extraQuestion)
            + "\n\n（笔记原文也写在工作区 note.md，可直接阅读该文件。）"

        let resolvedModel = modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultModelID
            : modelID.trimmingCharacters(in: .whitespacesAndNewlines)

        let payload: [String: Any] = [
            "apiKey": key,
            "prompt": prompt,
            "cwd": work.path,
            "model": resolvedModel
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonText = String(data: jsonData, encoding: .utf8) else {
            lastError = "无法编码请求"
            return
        }

        let inputFile = work.appendingPathComponent("request.json")
        do {
            try jsonText.write(to: inputFile, atomically: true, encoding: .utf8)
        } catch {
            lastError = "写入请求失败：\(error.localizedDescription)"
            return
        }

        let node = resolveNodePath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [Self.analyzeScript.path, inputFile.path]
        process.currentDirectoryURL = Self.bridgeDirectory
        process.environment = ProcessInfo.processInfo.environment.merging([
            "CURSOR_API_KEY": key,
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        ]) { _, new in new }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        self.process = process

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            lastError = "无法启动 Node：\(error.localizedDescription)。请确认已安装 Node.js。"
            return
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let outText = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let data = outText.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let ok = obj["ok"] as? Bool, ok {
                output = (obj["text"] as? String) ?? ""
                if output.isEmpty { output = "(模型未返回文本)" }
            } else {
                lastError = (obj["error"] as? String) ?? errText
                if lastError?.isEmpty == true { lastError = "分析失败（exit \(process.terminationStatus)）" }
            }
        } else {
            lastError = errText.isEmpty ? (outText.isEmpty ? "分析失败（无输出）" : outText) : errText
        }
    }

    /// 在 Tools/cursor-bridge 执行 npm install。
    func installDependencies() async -> String {
        let dir = Self.bridgeDirectory
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("package.json").path) else {
            return "找不到 \(dir.path)/package.json"
        }
        let npm = resolveNpmPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: npm)
        process.arguments = ["install", "--no-fund", "--no-audit"]
        process.currentDirectoryURL = dir
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "无法运行 npm：\(error.localizedDescription)"
        }
        let log = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus == 0 {
            return "安装成功"
        }
        return "安装失败：\n\(log)"
    }

    private func resolveNodePath() -> String {
        let candidates = [
            ProcessInfo.processInfo.environment["NODE_BINARY"],
            "/Users/ld/.nvm/versions/node/v22.23.1/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node"
        ].compactMap { $0 }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return which("node") ?? "/usr/local/bin/node"
    }

    private func resolveNpmPath() -> String {
        let candidates = [
            "/Users/ld/.nvm/versions/node/v22.23.1/bin/npm",
            "/opt/homebrew/bin/npm",
            "/usr/local/bin/npm"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return which("npm") ?? "/usr/local/bin/npm"
    }

}

/// 跨线程拼接 stdout，并保证 continuation 只 resume 一次。
private final class StreamReadState: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var resumed = false
    var continuation: CheckedContinuation<Void, Never>?

    func appendAndSplit(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        var lines: [String] = []
        while let range = buffer.range(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
        }
        return lines
    }

    func flushRemainder() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard !buffer.isEmpty else { return [] }
        let line = String(data: buffer, encoding: .utf8)
        buffer.removeAll()
        return line.map { [$0] } ?? []
    }

    func resumeOnce() {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation?.resume()
        continuation = nil
    }
}

extension CursorAIService {
    private func which(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(command)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return path
    }
}
