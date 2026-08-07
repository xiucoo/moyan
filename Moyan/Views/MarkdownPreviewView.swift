import AppKit
import SwiftUI
import WebKit

/// 右侧预览：WKWebView 渲染 Markdown HTML；本地图片以 data URI 嵌入。
struct MarkdownPreviewView: View {
    let content: String
    /// 笔记库根目录，用于解析 `assets/...` 图片。
    var baseURL: URL? = nil
    /// 点击 `moyan-child://` 子文件链接时回调。
    var onOpenChildNote: ((UUID) -> Void)? = nil
    /// 点击 `moyan-wps://` 时回调。
    var onOpenWPSFile: ((UUID) -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        MarkdownWebView(
            html: MarkdownRenderer.previewDocument(
                markdown: content,
                accentHex: accentHex,
                darkMode: colorScheme == .dark,
                libraryURL: baseURL
            ),
            libraryURL: baseURL,
            onOpenChildNote: onOpenChildNote,
            onOpenWPSFile: onOpenWPSFile
        )
        .background(Color(nsColor: .textBackgroundColor))
        // 内容或库路径变化时强制刷新 WebView
        .id(previewIdentity)
    }

    private var previewIdentity: String {
        "\(baseURL?.path ?? "")|\(content.hashValue)|\(colorScheme == .dark ? "d" : "l")"
    }

    private var accentHex: String {
        let ns = NSColor(settings.accent.color).usingColorSpace(.sRGB) ?? .systemGreen
        return String(
            format: "#%02X%02X%02X",
            Int(ns.redComponent * 255),
            Int(ns.greenComponent * 255),
            Int(ns.blueComponent * 255)
        )
    }
}

private struct MarkdownWebView: NSViewRepresentable {
    let html: String
    var libraryURL: URL? = nil
    var onOpenChildNote: ((UUID) -> Void)?
    var onOpenWPSFile: ((UUID) -> Void)?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        // 允许加载 data URI / file URL 本地图
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        #if DEBUG
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        #endif
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onOpenChildNote = onOpenChildNote
        context.coordinator.onOpenWPSFile = onOpenWPSFile
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        // baseURL 指向笔记库，相对路径 / file:// 回退时可加载
        webView.loadHTMLString(html, baseURL: libraryURL)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpenChildNote: onOpenChildNote, onOpenWPSFile: onOpenWPSFile)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String?
        var onOpenChildNote: ((UUID) -> Void)?
        var onOpenWPSFile: ((UUID) -> Void)?

        init(onOpenChildNote: ((UUID) -> Void)?, onOpenWPSFile: ((UUID) -> Void)?) {
            self.onOpenChildNote = onOpenChildNote
            self.onOpenWPSFile = onOpenWPSFile
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                if let childID = ChildNoteMarkerSupport.childNoteID(from: url) {
                    onOpenChildNote?(childID)
                    return .cancel
                }
                if let wpsID = WPSLinkSupport.fileID(from: url) {
                    onOpenWPSFile?(wpsID)
                    return .cancel
                }
                NSWorkspace.shared.open(url)
                return .cancel
            }
            return .allow
        }
    }
}
