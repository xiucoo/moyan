import AppKit

/// 笔记库内 `assets/...` 图片解析，供预览 data URI 与编辑区附件共用。
enum MarkdownImageSupport {
    /// 解析相对路径到真实文件（兼容首尾斜杠与大小写 UUID 目录）。
    static func resolveFile(relativePath: String, libraryRoot: URL) -> URL? {
        let cleaned = (relativePath.removingPercentEncoding ?? relativePath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleaned.isEmpty else { return nil }

        let direct = libraryRoot.appendingPathComponent(cleaned)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }

        // assets/<uuid>/file — UUID 大小写不一致时兜底
        let parts = cleaned.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0].lowercased() == "assets" else { return nil }
        let uuidPart = parts[1]
        let fileName = parts.dropFirst(2).joined(separator: "/")
        let assetsRoot = libraryRoot.appendingPathComponent("assets", isDirectory: true)
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: assetsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for dir in dirs where dir.lastPathComponent.compare(uuidPart, options: .caseInsensitive) == .orderedSame {
            let candidate = dir.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static func dataURI(forRelativePath path: String, libraryRoot: URL) -> String? {
        guard let fileURL = resolveFile(relativePath: path, libraryRoot: libraryRoot),
              let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return nil }
        let mime = mimeType(for: fileURL.pathExtension)
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    static func nsImage(forRelativePath path: String, libraryRoot: URL) -> NSImage? {
        guard let fileURL = resolveFile(relativePath: path, libraryRoot: libraryRoot),
              let image = NSImage(contentsOf: fileURL),
              image.size.width > 1 else { return nil }
        return image
    }

    static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "tif", "tiff": return "image/tiff"
        default: return "image/png"
        }
    }

    /// 把 Markdown 里的图片语法换成可显示的附件；底层写回时再还原。
    static func embedAttachments(
        in attributed: NSMutableAttributedString,
        libraryRoot: URL?
    ) {
        guard let libraryRoot else { return }
        let text = attributed.string as NSString
        let full = NSRange(location: 0, length: text.length)
        guard let regex = try? NSRegularExpression(
            pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#,
            options: []
        ) else { return }

        let matches = regex.matches(in: attributed.string, options: [], range: full)
        for match in matches.reversed() {
            let path = text.substring(with: match.range(at: 2))
            let alt = text.substring(with: match.range(at: 1))
            let attachment = LocalMarkdownImageAttachment(
                relativePath: path,
                alt: alt,
                libraryRoot: libraryRoot
            )
            let replacement = NSMutableAttributedString(attachment: attachment)
            // 附件后补一个换行，避免粘在后续文字上
            attributed.replaceCharacters(in: match.range, with: replacement)
        }
    }

    /// 将附件还原为 `![](assets/...)` Markdown。
    static func markdownString(from attributed: NSAttributedString) -> String {
        let out = NSMutableString()
        var index = 0
        let length = attributed.length
        while index < length {
            var effective = NSRange()
            if let box = attributed.attribute(.attachment, at: index, effectiveRange: &effective)
                as? LocalMarkdownImageAttachment {
                out.append("![\(box.alt)](\(box.relativePath))")
                index = NSMaxRange(effective)
                continue
            }
            if MarkdownColorSupport.appendSerializedStyleRuns(
                from: attributed,
                start: &index,
                into: out
            ) {
                continue
            }
            var run = NSRange()
            _ = attributed.attributes(at: index, effectiveRange: &run)
            // 附件占位符若未识别，跳过 U+FFFC，避免写脏 Markdown
            let chunk = (attributed.string as NSString).substring(with: run)
            if chunk == "\u{FFFC}" {
                index = NSMaxRange(run)
                continue
            }
            out.append(chunk)
            index = NSMaxRange(run)
        }
        return out as String
    }
}

/// 编辑区图片附件：显示缩略图，序列化仍走相对 `assets/` 路径。
final class LocalMarkdownImageAttachment: NSTextAttachment {
    let relativePath: String
    let alt: String

    init(relativePath: String, alt: String, libraryRoot: URL) {
        self.relativePath = relativePath
        self.alt = alt
        super.init(data: nil, ofType: nil)

        let maxWidth: CGFloat = 480
        if let image = MarkdownImageSupport.nsImage(forRelativePath: relativePath, libraryRoot: libraryRoot) {
            let size = image.size
            let scale = size.width > maxWidth ? maxWidth / size.width : 1
            let display = NSSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
            image.size = display
            self.image = image
            bounds = CGRect(origin: .zero, size: display)
        } else {
            // 缺失文件时显示占位
            let placeholder = Self.placeholderImage(text: "图片缺失\n\(relativePath)")
            self.image = placeholder
            bounds = CGRect(x: 0, y: 0, width: 280, height: 72)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func placeholderImage(text: String) -> NSImage {
        let size = NSSize(width: 280, height: 72)
        return NSImage(size: size, flipped: false) { rect in
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
            NSColor.separatorColor.setStroke()
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            border.lineWidth = 1
            border.stroke()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let ns = text as NSString
            let textSize = ns.size(withAttributes: attrs)
            let origin = NSPoint(
                x: rect.midX - textSize.width / 2,
                y: rect.midY - textSize.height / 2
            )
            ns.draw(at: origin, withAttributes: attrs)
            return true
        }
    }
}
