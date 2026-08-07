import AppKit
import Foundation

/// `moyan-wps://UUID` 链接：正文挂链、点击预览、高亮可点。
enum WPSLinkSupport {
    static let scheme = "moyan-wps"

    static func fileURL(id: UUID) -> URL {
        URL(string: "\(scheme)://\(id.uuidString)")!
    }

    static func fileID(from link: Any) -> UUID? {
        if let url = link as? URL {
            return id(from: url)
        }
        if let string = link as? String, let url = URL(string: string) {
            return id(from: url)
        }
        return nil
    }

    static func id(from url: URL) -> UUID? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let host = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return UUID(uuidString: host)
    }

    /// 从扩展名推断表格 / 文档；无法识别返回 nil。
    static func kind(forExtension ext: String) -> WPSFileKind? {
        switch ext.lowercased() {
        case "xlsx", "xls", "et", "csv":
            return .spreadsheet
        case "docx", "doc", "wps", "rtf":
            return .document
        default:
            return nil
        }
    }

    /// 是否可用内嵌网格解析（xlsx / csv）。
    static func supportsGridPreview(ext: String) -> Bool {
        ["xlsx", "csv"].contains(ext.lowercased())
    }

    /// 是否优先走 Quick Look（Word 类，或无法网格解析的表格格式）。
    static func prefersQuickLook(ext: String) -> Bool {
        let e = ext.lowercased()
        if supportsGridPreview(ext: e) { return false }
        return kind(forExtension: e) != nil
    }

    /// 从正文移除指向该 UUID 的 markdown 链。
    static func removingLink(id: UUID, from content: String) -> String {
        let patterns = [
            #"\[[^\]]*\]\(moyan-wps://\#(id.uuidString)\)"#,
            #"moyan-wps://\#(id.uuidString)"#
        ]
        var result = content
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }
        // 清理多余空行
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result
    }

    /// 在正文末尾追加 WPS 链（前后保证换行）。
    static func appendingLink(_ link: String, to content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return link + "\n"
        }
        if trimmed.contains(link) { return content }
        let needsNewline = !content.hasSuffix("\n")
        return content + (needsNewline ? "\n\n" : "\n") + link + "\n"
    }
}
