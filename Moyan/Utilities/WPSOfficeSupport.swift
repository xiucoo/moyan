import AppKit
import Foundation

/// 定位本机 WPS、用 WPS 打开文件、创建安全书签。
enum WPSOfficeSupport {
    static let knownBundleIDs = [
        "com.kingsoft.wpsoffice.mac",
        "com.kingsoft.WPOffice"
    ]

    static let knownAppPaths = [
        "/Applications/wpsoffice.app",
        "/Applications/WPS Office.app",
        "/Applications/金山文档.app"
    ]

    /// 本机 WPS 应用 URL；找不到返回 nil。
    static func applicationURL() -> URL? {
        let workspace = NSWorkspace.shared
        for id in knownBundleIDs {
            if let url = workspace.urlForApplication(withBundleIdentifier: id) {
                return url
            }
        }
        for path in knownAppPaths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    static var isInstalled: Bool { applicationURL() != nil }

    /// 用 WPS 打开文件；无 WPS 时回退系统默认应用。
    @discardableResult
    static func open(_ fileURL: URL) -> Bool {
        let workspace = NSWorkspace.shared
        if let app = applicationURL() {
            let config = NSWorkspace.OpenConfiguration()
            workspace.open([fileURL], withApplicationAt: app, configuration: config) { _, error in
                if error != nil {
                    workspace.open(fileURL)
                }
            }
            return true
        }
        return workspace.open(fileURL)
    }

    /// 为外链文件创建 security-scoped bookmark（沙盒关时仍可用）。
    static func bookmarkData(for url: URL) -> Data? {
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            return try? url.bookmarkData(
                options: [.minimalBookmark],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
    }

    /// 解析 bookmark；失败时回退 `fallbackPath`。
    static func resolveURL(bookmark: Data, fallbackPath: String) -> URL? {
        var isStale = false
        if let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            _ = url.startAccessingSecurityScopedResource()
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        let fallback = URL(fileURLWithPath: fallbackPath)
        if FileManager.default.fileExists(atPath: fallback.path) {
            return fallback
        }
        return nil
    }
}
