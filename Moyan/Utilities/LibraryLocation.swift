import Foundation

/// 解析本机 / iCloud Drive 笔记库路径，并提供可用性探测。
enum LibraryLocation {
    static let folderName = "墨言"

    static func url(for mode: StorageMode) -> URL {
        switch mode {
        case .local:
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            return docs.appendingPathComponent(folderName, isDirectory: true)
        case .iCloudDrive:
            if let drive = iCloudDriveRoot {
                return drive.appendingPathComponent(folderName, isDirectory: true)
            }
            // iCloud 不可用时退回本机，避免启动失败
            return url(for: .local)
        }
    }

    /// Finder「iCloud Drive」根目录；未登录 iCloud 时通常不存在。
    static var iCloudDriveRoot: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return url
    }

    static var isICloudDriveAvailable: Bool {
        iCloudDriveRoot != nil
    }

    /// 将源库目录递归复制到目标（覆盖同名文件）。
    static func copyLibrary(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let enumerator = fm.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let fileURL as URL in enumerator {
            let relative = fileURL.path.replacingOccurrences(of: source.path, with: "")
            let trimmed = relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
            guard !trimmed.isEmpty else { continue }
            let target = destination.appendingPathComponent(trimmed)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: fileURL.path, isDirectory: &isDir)
            if isDir.boolValue {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) {
                    try fm.removeItem(at: target)
                }
                try fm.copyItem(at: fileURL, to: target)
            }
        }

        // 隐藏 meta 文件也复制
        let metaName = ".moyan-meta.json"
        let metaSource = source.appendingPathComponent(metaName)
        if fm.fileExists(atPath: metaSource.path) {
            let metaDest = destination.appendingPathComponent(metaName)
            if fm.fileExists(atPath: metaDest.path) { try fm.removeItem(at: metaDest) }
            try fm.copyItem(at: metaSource, to: metaDest)
        }
    }
}
