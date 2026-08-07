import AppKit
import UniformTypeIdentifiers
import WebKit

/// 将 Markdown 笔记渲染为 PDF（HTML → WKWebView → PDF）。
@MainActor
enum PDFExporter {
    /// 导出单篇笔记；弹出保存面板，成功返回目标 URL。
    static func exportNote(_ note: Note, accentHex: String = "#38AD6B") async throws -> URL? {
        let body = MarkdownRenderer.articleSection(title: note.title, markdown: note.content)
        let html = MarkdownRenderer.printDocument(title: note.title, bodyHTML: body, accentHex: accentHex)
        let data = try await renderPDF(html: html)
        return try await presentSavePanel(defaultName: sanitize(note.title) + ".pdf", data: data)
    }

    /// 导出文件夹内全部笔记为一份合并 PDF。
    static func exportFolder(name: String, notes: [Note], accentHex: String = "#38AD6B") async throws -> URL? {
        let body = notes
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { MarkdownRenderer.articleSection(title: $0.title, markdown: $0.content) }
            .joined(separator: #"<div class="page-break"></div>"#)
        let html = MarkdownRenderer.printDocument(title: name, bodyHTML: body, accentHex: accentHex)
        let data = try await renderPDF(html: html)
        return try await presentSavePanel(defaultName: sanitize(name) + ".pdf", data: data)
    }

    private static func renderPDF(html: String) async throws -> Data {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 794, height: 1123))
        let delegate = LoadWaiter()
        webView.navigationDelegate = delegate

        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 794, height: 1123),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.orderOut(nil)

        defer {
            webView.navigationDelegate = nil
            window.contentView = nil
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            delegate.continuation = cont
            webView.loadHTMLString(html, baseURL: nil)
        }

        try await Task.sleep(nanoseconds: 200_000_000)
        return try await webView.pdf(configuration: WKPDFConfiguration())
    }

    private static func presentSavePanel(defaultName: String, data: Data) async throws -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = defaultName
        panel.title = "导出 PDF"
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return nil }
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class LoadWaiter: NSObject, WKNavigationDelegate {
    var continuation: CheckedContinuation<Void, Error>?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
