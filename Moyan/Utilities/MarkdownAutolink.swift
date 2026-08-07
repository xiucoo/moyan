import Foundation

/// 裸 URL（`https://...`）识别，供高亮与预览共用。
enum MarkdownAutolink {
    /// 匹配 http(s) URL；尾部标点需再 trim。
    static let pattern = #"https?://[^\s<>\[\]()`"'（）【】]+"#

    private static let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?)]}>'\"。，；：！？、）】」』》")

    /// 去掉 URL 末尾常见标点（句号、逗号、右括号等）。
    static func trimTrailingPunctuation(_ url: String) -> (url: String, trimmedCount: Int) {
        var s = url
        var trimmed = 0
        while let last = s.unicodeScalars.last, trailingPunctuation.contains(last) {
            s.removeLast()
            trimmed += 1
        }
        return (s, trimmed)
    }

    /// 在纯文本片段中把裸 URL 包成 `<a>`（已转义 HTML 的文本）。
    static func linkifyHTMLFragment(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            let raw = ns.substring(with: match.range)
            let (url, trimmed) = trimTrailingPunctuation(raw)
            guard !url.isEmpty else { continue }
            let range = NSRange(location: match.range.location, length: match.range.length - trimmed)
            let escapedHref = url
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
            mutable.replaceCharacters(in: range, with: "<a href=\"\(escapedHref)\">\(url)</a>")
        }
        return mutable as String
    }

    /// 只处理 HTML 标签之间的文本节点，避免破坏已有 `href` / `src`。
    static func linkifyHTML(_ html: String) -> String {
        var result = ""
        result.reserveCapacity(html.count + 32)
        var index = html.startIndex
        while index < html.endIndex {
            if html[index] == "<" {
                if let end = html[index...].firstIndex(of: ">") {
                    result.append(contentsOf: html[index...end])
                    index = html.index(after: end)
                    continue
                }
            }
            let next = html[index...].firstIndex(of: "<") ?? html.endIndex
            result.append(linkifyHTMLFragment(String(html[index..<next])))
            index = next
        }
        return result
    }
}
