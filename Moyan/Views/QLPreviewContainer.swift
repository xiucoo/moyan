import AppKit
import QuickLookUI
import SwiftUI

/// Quick Look 预览容器（Word / 无法网格解析的 Office 文件）。
struct QLPreviewContainer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = PreviewItem(url: url)
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? PreviewItem)?.previewItemURL != url {
            view.previewItem = PreviewItem(url: url)
            view.refreshPreviewItem()
        }
    }

    final class PreviewItem: NSObject, QLPreviewItem {
        let previewItemURL: URL?
        let previewItemTitle: String?

        init(url: URL) {
            previewItemURL = url
            previewItemTitle = url.lastPathComponent
        }
    }
}
