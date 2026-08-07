import Foundation

/// 轻量 Markdown → HTML，供预览与 PDF 共用。
enum MarkdownRenderer {
    /// 生成完整 HTML 文档（预览用，支持深浅色）。
    /// - Parameter libraryURL: 笔记库根目录；用于把 `assets/...` 本地图片嵌入为 data URI（WKWebView 无法直接读相对路径）。
    static func previewDocument(
        markdown: String,
        accentHex: String = "#38AD6B",
        darkMode: Bool = false,
        libraryURL: URL? = nil
    ) -> String {
        var body = markdownToHTML(markdown)
        if let libraryURL {
            body = embedLocalImages(in: body, libraryRoot: libraryURL)
        }
        let bg = darkMode ? "#1c1c1e" : "#ffffff"
        let fg = darkMode ? "#e8e8ed" : "#1f2328"
        let heading = darkMode ? "#d4b8ff" : "#2b2140"
        let muted = darkMode ? "#a1a1a6" : "#57606a"
        let codeBg = darkMode ? "#2c2c2e" : "#f4f5f7"
        let codeFg = darkMode ? "#ff8a80" : "#b42318"
        let preBg = darkMode ? "#2c2c2e" : "#f6f8fa"
        let border = darkMode ? "#3a3a3c" : "#e5e7eb"
        let hr = darkMode ? "#48484a" : "#d0d7de"

        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <style>
          html, body {
            margin: 0;
            padding: 0;
            background: \(bg);
            color: \(fg);
          }
          body {
            font-family: -apple-system, "PingFang SC", "Helvetica Neue", sans-serif;
            font-size: 15px;
            line-height: 1.7;
            padding: 28px 32px 48px;
            word-wrap: break-word;
          }
          h1, h2, h3, h4 {
            color: \(heading);
            font-weight: 650;
            line-height: 1.35;
            margin: 1.35em 0 0.55em;
          }
          h1 { font-size: 1.85em; margin-top: 0.2em; }
          h2 { font-size: 1.45em; }
          h3 { font-size: 1.2em; }
          p { margin: 0.55em 0; }
          ul, ol { padding-left: 1.45em; margin: 0.55em 0; }
          li { margin: 0.25em 0; }
          li input[type="checkbox"] { margin-right: 6px; }
          strong { font-weight: 700; }
          em { font-style: italic; }
          del { opacity: 0.7; }
          a { color: \(accentHex); text-decoration: none; }
          a:hover { text-decoration: underline; }
          img {
            max-width: 100%;
            height: auto;
            border-radius: 8px;
            margin: 12px 0;
            display: block;
            background: \(codeBg);
          }
          img.broken {
            min-height: 48px;
            border: 1px dashed \(border);
            padding: 12px;
            color: \(muted);
            font-size: 12px;
          }
          code, pre {
            font-family: ui-monospace, "SF Mono", Menlo, monospace;
            font-size: 13px;
          }
          code {
            background: \(codeBg);
            color: \(codeFg);
            padding: 1px 6px;
            border-radius: 4px;
          }
          pre {
            background: \(preBg);
            padding: 12px 14px;
            border-radius: 8px;
            overflow-x: auto;
            border: 1px solid \(border);
          }
          pre code {
            background: transparent;
            color: inherit;
            padding: 0;
          }
          blockquote {
            margin: 12px 0;
            padding: 4px 14px;
            border-left: 3px solid \(accentHex);
            color: \(muted);
          }
          hr {
            border: none;
            border-top: 1px solid \(hr);
            margin: 24px 0;
          }
          table { border-collapse: collapse; width: 100%; margin: 12px 0; }
          th, td { border: 1px solid \(border); padding: 6px 10px; }
          th { background: \(codeBg); }
          a.moyan-link-card {
            display: flex;
            gap: 12px;
            align-items: stretch;
            margin: 12px 0;
            padding: 12px 14px;
            border: 1px solid \(border);
            border-radius: 10px;
            text-decoration: none !important;
            color: inherit;
            background: \(codeBg);
            overflow: hidden;
          }
          a.moyan-link-card:hover { border-color: \(accentHex); }
          .moyan-card-body { flex: 1; min-width: 0; }
          .moyan-card-title {
            font-weight: 650;
            font-size: 14px;
            margin-bottom: 4px;
            color: \(fg);
          }
          .moyan-card-desc {
            font-size: 12px;
            color: \(muted);
            line-height: 1.45;
            margin-bottom: 6px;
            display: -webkit-box;
            -webkit-line-clamp: 2;
            -webkit-box-orient: vertical;
            overflow: hidden;
          }
          .moyan-card-host { font-size: 11px; color: \(muted); }
          .moyan-card-thumb {
            width: 96px;
            height: 72px;
            object-fit: cover;
            border-radius: 6px;
            margin: 0 !important;
            flex-shrink: 0;
          }
          .moyan-link-preview {
            margin: 12px 0;
            border: 1px solid \(border);
            border-radius: 10px;
            overflow: hidden;
            background: \(codeBg);
          }
          .moyan-preview-bar {
            padding: 8px 12px;
            font-size: 12px;
            border-bottom: 1px solid \(border);
          }
          .moyan-link-preview iframe {
            width: 100%;
            height: 280px;
            border: 0;
            display: block;
            background: #fff;
          }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    /// 将相对路径图片读入并改成 data URI，绕过 WKWebView 对本地相对路径的限制。
    private static func embedLocalImages(in html: String, libraryRoot: URL) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"src="([^"]+)""#) else { return html }
        let ns = html as NSString
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return html }

        let mutable = NSMutableString(string: html)
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2 else { continue }
            let srcRange = match.range(at: 1)
            let src = ns.substring(with: srcRange)
            if src.hasPrefix("http://") || src.hasPrefix("https://")
                || src.hasPrefix("data:") || src.hasPrefix("file:") {
                continue
            }

            if let dataURI = MarkdownImageSupport.dataURI(forRelativePath: src, libraryRoot: libraryRoot) {
                mutable.replaceCharacters(in: srcRange, with: dataURI)
            } else if let fileURL = MarkdownImageSupport.resolveFile(relativePath: src, libraryRoot: libraryRoot) {
                mutable.replaceCharacters(in: srcRange, with: fileURL.absoluteString)
            }
            // 仍找不到则保留原 src，CSS 的 img.broken 便于辨认
        }
        return mutable as String
    }

    /// PDF 导出用的浅色完整文档。
    static func printDocument(title: String, bodyHTML: String, accentHex: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8" />
        <title>\(escape(title))</title>
        <style>
          @page { margin: 48px 56px; }
          body {
            font-family: -apple-system, "PingFang SC", "Helvetica Neue", sans-serif;
            font-size: 14px;
            line-height: 1.65;
            color: #1f2328;
            margin: 0;
            padding: 24px 32px;
          }
          .doc-title {
            font-size: 28px;
            margin: 0 0 20px;
            color: \(accentHex);
            border-bottom: 2px solid \(accentHex)33;
            padding-bottom: 10px;
          }
          h1,h2,h3,h4 { color: #2b2140; margin-top: 1.4em; }
          code, pre {
            font-family: ui-monospace, "SF Mono", Menlo, monospace;
            font-size: 12.5px;
          }
          code {
            background: #f4f5f7;
            padding: 1px 5px;
            border-radius: 4px;
            color: #b42318;
          }
          pre {
            background: #f6f8fa;
            padding: 12px 14px;
            border-radius: 8px;
            overflow-x: auto;
            border: 1px solid #e5e7eb;
          }
          pre code { background: transparent; color: inherit; padding: 0; }
          blockquote {
            margin: 12px 0;
            padding: 4px 14px;
            border-left: 3px solid \(accentHex);
            color: #57606a;
          }
          ul, ol { padding-left: 1.4em; }
          a { color: \(accentHex); }
          hr { border: none; border-top: 1px solid #d0d7de; margin: 24px 0; }
          .page-break { break-after: page; height: 1px; }
          table { border-collapse: collapse; width: 100%; margin: 12px 0; }
          th, td { border: 1px solid #d0d7de; padding: 6px 10px; }
          th { background: #f6f8fa; }
        </style>
        </head>
        <body>
        \(bodyHTML)
        </body>
        </html>
        """
    }

    static func articleSection(title: String, markdown: String) -> String {
        """
        <article>
          <h1 class="doc-title">\(escape(title))</h1>
          \(markdownToHTML(markdown))
        </article>
        """
    }

    static func markdownToHTML(_ markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        var html: [String] = []
        var inCode = false
        var codeLang = ""
        var codeBuffer: [String] = []
        var inList = false
        var listTag = "ul"
        var index = 0

        func closeList() {
            if inList {
                html.append("</\(listTag)>")
                inList = false
            }
        }

        while index < lines.count {
            let line = lines[index]

            if line.hasPrefix("```") {
                if inCode {
                    html.append(
                        "<pre><code\(codeLang.isEmpty ? "" : " class=\"language-\(escape(codeLang))\"")>" +
                        codeBuffer.map(escape).joined(separator: "\n") +
                        "</code></pre>"
                    )
                    codeBuffer = []
                    inCode = false
                    codeLang = ""
                } else {
                    closeList()
                    inCode = true
                    codeLang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                index += 1
                continue
            }
            if inCode {
                codeBuffer.append(line)
                index += 1
                continue
            }

            // 可编辑链接围栏 :::moyan-card / :::moyan-preview
            if line.hasPrefix(":::moyan-card") || line.hasPrefix(":::moyan-preview") {
                var end = index + 1
                while end < lines.count, !lines[end].hasPrefix(":::") {
                    end += 1
                }
                if end < lines.count {
                    let block = lines[index...end].joined(separator: "\n")
                    let ns = block as NSString
                    let full = NSRange(location: 0, length: ns.length)
                    if let match = MarkdownLinkEmbed.fenceRegex.firstMatch(in: block, options: [], range: full),
                       let info = parseFenceLink(match, in: ns) {
                        closeList()
                        html.append(MarkdownLinkEmbed.html(for: info))
                        index = end + 1
                        continue
                    }
                }
            }

            // GFM 表格
            if index + 1 < lines.count,
               MarkdownTableSupport.isTableRow(line),
               MarkdownTableSupport.isSeparatorRow(lines[index + 1]) {
                var end = index + 2
                while end < lines.count {
                    let t = lines[end].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty { break }
                    if MarkdownTableSupport.isSeparatorRow(lines[end]) { break }
                    if !MarkdownTableSupport.isTableRow(lines[end]) { break }
                    end += 1
                }
                let block = Array(lines[index..<end])
                if let table = MarkdownTableSupport.parse(block) {
                    closeList()
                    html.append(MarkdownTableSupport.html(for: table, inline: inline))
                    index = end
                    continue
                }
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 链接卡片 / 预览块
            if trimmed.hasPrefix("{{moyan-link|"),
               let linkHTML = renderMoyanLinkLine(trimmed) {
                closeList()
                html.append(linkHTML)
                index += 1
                continue
            }

            if trimmed.hasPrefix("---"), trimmed.allSatisfy({ $0 == "-" }), trimmed.count >= 3 {
                closeList()
                html.append("<hr/>")
                index += 1
                continue
            }

            if let task = line.range(of: #"^\s*- \[([ xX])\] "#, options: .regularExpression) {
                let checked = line[task].contains("x") || line[task].contains("X")
                let content = String(line[task.upperBound...])
                if !inList || listTag != "ul" {
                    closeList()
                    html.append("<ul>")
                    inList = true
                    listTag = "ul"
                }
                html.append(
                    "<li><input type=\"checkbox\" disabled \(checked ? "checked" : "")/> \(inline(content))</li>"
                )
                index += 1
                continue
            }
            if let ul = line.range(of: #"^\s*[-*+] "#, options: .regularExpression) {
                let content = String(line[ul.upperBound...])
                if !inList || listTag != "ul" {
                    closeList()
                    html.append("<ul>")
                    inList = true
                    listTag = "ul"
                }
                html.append("<li>\(inline(content))</li>")
                index += 1
                continue
            }
            if let ol = line.range(of: #"^\s*\d+\. "#, options: .regularExpression) {
                let content = String(line[ol.upperBound...])
                if !inList || listTag != "ol" {
                    closeList()
                    html.append("<ol>")
                    inList = true
                    listTag = "ol"
                }
                html.append("<li>\(inline(content))</li>")
                index += 1
                continue
            }

            closeList()

            if line.hasPrefix("### ") {
                html.append("<h3>\(inline(String(line.dropFirst(4))))</h3>")
            } else if line.hasPrefix("## ") {
                html.append("<h2>\(inline(String(line.dropFirst(3))))</h2>")
            } else if line.hasPrefix("# ") {
                html.append("<h1>\(inline(String(line.dropFirst(2))))</h1>")
            } else if line.hasPrefix("> ") {
                html.append("<blockquote><p>\(inline(String(line.dropFirst(2))))</p></blockquote>")
            } else if trimmed.isEmpty {
                html.append("<br/>")
            } else {
                html.append("<p>\(inline(line))</p>")
            }
            index += 1
        }
        closeList()
        if inCode {
            html.append("<pre><code>\(codeBuffer.map(escape).joined(separator: "\n"))</code></pre>")
        }
        return html.joined(separator: "\n")
    }

    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func renderMoyanLinkLine(_ line: String) -> String? {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = MarkdownLinkEmbed.blockRegex.firstMatch(in: line, options: [], range: full),
              match.range.length == ns.length,
              match.numberOfRanges >= 6,
              let view = MoyanLinkView(rawValue: ns.substring(with: match.range(at: 1))) else {
            return nil
        }
        let info = MoyanDetectedLink(
            view: view,
            url: MarkdownLinkEmbed.decode(ns.substring(with: match.range(at: 2))),
            title: MarkdownLinkEmbed.decode(ns.substring(with: match.range(at: 3))),
            desc: MarkdownLinkEmbed.decode(ns.substring(with: match.range(at: 4))),
            image: MarkdownLinkEmbed.decode(ns.substring(with: match.range(at: 5))),
            range: match.range
        )
        return MarkdownLinkEmbed.html(for: info)
    }

    private static func parseFenceLink(_ match: NSTextCheckingResult, in ns: NSString) -> MoyanDetectedLink? {
        guard match.numberOfRanges >= 3 else { return nil }
        let kind = ns.substring(with: match.range(at: 1)).lowercased()
        let view: MoyanLinkView = kind == "preview" ? .preview : .card
        let body = ns.substring(with: match.range(at: 2))
        var url = ""
        var title = ""
        var desc = ""
        var image = ""
        for rawLine in body.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let lower = line.lowercased()
            if lower.hasPrefix("url:") {
                url = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("title:") {
                title = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("desc:") {
                desc = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("image:") {
                image = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if url.isEmpty, lower.hasPrefix("http://") || lower.hasPrefix("https://") {
                url = line
            }
        }
        guard !url.isEmpty else { return nil }
        return MoyanDetectedLink(
            view: view, url: url, title: title, desc: desc, image: image, range: match.range
        )
    }

    private static func inline(_ text: String) -> String {
        // 先抽出颜色 span，避免 escape 破坏标签；占位符再嵌回最终 HTML
        var tokens: [String] = []
        var work = text
        for _ in 0..<12 {
            let ns = work as NSString
            let matches = MarkdownColorSupport.spanRegex.matches(
                in: work,
                options: [],
                range: NSRange(location: 0, length: ns.length)
            )
            if matches.isEmpty { break }
            let mutable = NSMutableString(string: work)
            for match in matches.reversed() where match.numberOfRanges >= 3 {
                let style = ns.substring(with: match.range(at: 1))
                let (fg, bg) = MarkdownColorSupport.parseStyle(style)
                guard fg != nil || bg != nil else { continue }
                let inner = ns.substring(with: match.range(at: 2))
                var css: [String] = []
                if let fg { css.append("color: \(fg)") }
                if let bg { css.append("background-color: \(bg)") }
                let token = "@@MOYANSPAN\(tokens.count)@@"
                tokens.append("<span style=\"\(css.joined(separator: "; "))\">\(inlineCore(inner))</span>")
                mutable.replaceCharacters(in: match.range, with: token)
            }
            work = mutable as String
        }

        var html = inlineCore(work)
        for (index, spanHTML) in tokens.enumerated() {
            html = html.replacingOccurrences(of: "@@MOYANSPAN\(index)@@", with: spanHTML)
        }
        return html
    }

    private static func inlineCore(_ text: String) -> String {
        var s = escape(text)
        s = replace(s, pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#, template: #"<img alt="$1" src="$2"/>"#)
        // WPS 链接做成芯片样式
        s = replaceWPSLinks(s)
        s = replace(s, pattern: #"\[([^\]]+)\]\(([^)]+)\)"#, template: #"<a href="$2">$1</a>"#)
        s = replace(s, pattern: #"`([^`]+)`"#, template: "<code>$1</code>")
        s = replace(s, pattern: #"\*\*([^*]+)\*\*"#, template: "<strong>$1</strong>")
        s = replace(s, pattern: #"__([^_]+)__"#, template: "<strong>$1</strong>")
        s = replace(s, pattern: #"\*([^*]+)\*"#, template: "<em>$1</em>")
        s = replace(s, pattern: #"_([^_]+)_"#, template: "<em>$1</em>")
        s = replace(s, pattern: #"~~([^~]+)~~"#, template: "<del>$1</del>")
        s = MarkdownAutolink.linkifyHTML(s)
        return s
    }

    private static func replaceWPSLinks(_ text: String) -> String {
        let pattern = #"\[([^\]]+)\]\((moyan-wps://[0-9A-Fa-f-]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let ns = text as NSString
        var result = text
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed()
        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }
            let label = ns.substring(with: match.range(at: 1))
            let href = ns.substring(with: match.range(at: 2))
            let chip = #"<a class="moyan-wps" href="\#(href)" style="display:inline-block;padding:2px 8px;border-radius:6px;background:rgba(0,122,255,0.12);text-decoration:none;font-weight:600;">\#(label)</a>"#
            result = (result as NSString).replacingCharacters(in: match.range, with: chip)
        }
        return result
    }

    private static func replace(_ text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }
}
