import AppKit
import Foundation

/// GFM 管道表格：解析、插入、预览 HTML、编辑区附件。
enum MarkdownTableSupport {
    struct Table {
        var headers: [String]
        var alignments: [NSTextAlignment]
        var rows: [[String]]

        var columnCount: Int {
            max(headers.count, rows.map(\.count).max() ?? 0, 1)
        }

        func markdown() -> String {
            let cols = columnCount
            func pad(_ cells: [String]) -> [String] {
                var c = cells
                while c.count < cols { c.append("") }
                return Array(c.prefix(cols))
            }
            func line(_ cells: [String]) -> String {
                "| " + pad(cells).map(escapeCell).joined(separator: " | ") + " |"
            }
            var aligns = alignments
            while aligns.count < cols { aligns.append(.left) }
            let sep = aligns.prefix(cols).map { align -> String in
                switch align {
                case .center: return ":---:"
                case .right: return "---:"
                default: return "---"
                }
            }
            var lines = [
                line(pad(headers)),
                "| " + sep.joined(separator: " | ") + " |"
            ]
            for row in rows {
                lines.append(line(pad(row)))
            }
            return lines.joined(separator: "\n")
        }
    }

    static func template(columns: Int = 3, bodyRows: Int = 2) -> String {
        Table(
            headers: (1...columns).map { "列\($0)" },
            alignments: Array(repeating: .left, count: columns),
            rows: (0..<bodyRows).map { _ in Array(repeating: "", count: columns) }
        ).markdown() + "\n"
    }

    static func escapeCell(_ text: String) -> String {
        text
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }

    static func unescapeCell(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\\|", with: "|")
    }

    static func isTableRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.contains("|") && !t.isEmpty
    }

    static func isSeparatorRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-") else { return false }
        let stripped = t
            .replacingOccurrences(of: "|", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .trimmingCharacters(in: .whitespaces)
        return stripped.isEmpty
    }

    static func splitCells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.split(separator: "|", omittingEmptySubsequences: false)
            .map { unescapeCell(String($0)) }
    }

    static func parseAlignments(_ separator: String) -> [NSTextAlignment] {
        splitCells(separator).map { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            let left = c.hasPrefix(":")
            let right = c.hasSuffix(":")
            if left && right { return .center }
            if right { return .right }
            return .left
        }
    }

    static func parse(_ lines: [String]) -> Table? {
        guard lines.count >= 2,
              isTableRow(lines[0]),
              isSeparatorRow(lines[1]) else { return nil }
        let headers = splitCells(lines[0])
        guard !headers.isEmpty else { return nil }
        let alignments = parseAlignments(lines[1])
        let rows = lines.dropFirst(2).filter { isTableRow($0) && !isSeparatorRow($0) }.map(splitCells)
        return Table(headers: headers, alignments: alignments, rows: Array(rows))
    }

    /// 返回 Markdown 中所有表格的 UTF-16 范围。
    static func tableRanges(in markdown: String) -> [(range: NSRange, table: Table)] {
        let ns = markdown as NSString
        var result: [(NSRange, Table)] = []
        var lineStart = 0
        var i = 0
        let total = ns.length

        func nextLineEnd(from start: Int) -> Int {
            if start >= total { return total }
            let rest = NSRange(location: start, length: total - start)
            let found = ns.range(of: "\n", options: [], range: rest)
            return found.location == NSNotFound ? total : found.location
        }

        var lineStarts: [Int] = []
        var lineEnds: [Int] = []
        var lines: [String] = []
        while lineStart <= total {
            lineStarts.append(lineStart)
            if lineStart == total {
                lineEnds.append(total)
                lines.append("")
                break
            }
            let end = nextLineEnd(from: lineStart)
            lineEnds.append(end)
            lines.append(ns.substring(with: NSRange(location: lineStart, length: end - lineStart)))
            if end >= total {
                break
            }
            lineStart = end + 1
        }

        i = 0
        while i < lines.count {
            if i + 1 < lines.count,
               isTableRow(lines[i]),
               isSeparatorRow(lines[i + 1]) {
                var endIdx = i + 2
                while endIdx < lines.count {
                    let t = lines[endIdx].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty { break }
                    if isSeparatorRow(lines[endIdx]) { break }
                    if !isTableRow(lines[endIdx]) { break }
                    endIdx += 1
                }
                let block = Array(lines[i..<endIdx])
                if let table = parse(block) {
                    let start = lineStarts[i]
                    // 范围覆盖到最后一行末尾；若其后还有换行则吃掉一个 \n，便于块级替换
                    var end = lineEnds[endIdx - 1]
                    if end < total, ns.character(at: end) == 10 /* \n */ {
                        end += 1
                    }
                    result.append((NSRange(location: start, length: end - start), table))
                    i = endIdx
                    continue
                }
            }
            i += 1
        }
        return result.map { ($0.0, $0.1) }
    }

    static func detect(in text: String, at index: Int) -> (range: NSRange, table: Table)? {
        for item in tableRanges(in: text) {
            if NSLocationInRange(index, item.range)
                || index == NSMaxRange(item.range)
                || (index > 0 && NSLocationInRange(index - 1, item.range)) {
                return item
            }
        }
        return nil
    }

    /// - Parameter inline: 对单元格文本做 inline Markdown→HTML。
    static func html(for table: Table, inline: (String) -> String) -> String {
        let cols = table.columnCount
        func alignAttr(_ index: Int) -> String {
            let a = index < table.alignments.count ? table.alignments[index] : .left
            switch a {
            case .center: return " style=\"text-align:center\""
            case .right: return " style=\"text-align:right\""
            default: return ""
            }
        }

        var out = "<table>\n<thead>\n<tr>"
        for i in 0..<cols {
            let h = i < table.headers.count ? table.headers[i] : ""
            out += "<th\(alignAttr(i))>\(inline(h))</th>"
        }
        out += "</tr>\n</thead>\n<tbody>\n"
        for row in table.rows {
            out += "<tr>"
            for i in 0..<cols {
                let v = i < row.count ? row[i] : ""
                out += "<td\(alignAttr(i))>\(inline(v))</td>"
            }
            out += "</tr>\n"
        }
        out += "</tbody>\n</table>"
        return out
    }

    static func insertingRow(_ table: Table, afterRow rowIndex: Int) -> Table {
        var t = table
        let blank = Array(repeating: "", count: t.columnCount)
        let idx = min(max(rowIndex + 1, 0), t.rows.count)
        t.rows.insert(blank, at: idx)
        return t
    }

    static func insertingColumn(_ table: Table, afterColumn colIndex: Int) -> Table {
        var t = table
        let idx = min(max(colIndex + 1, 0), t.columnCount)
        t.headers.insert("列\(t.headers.count + 1)", at: min(idx, t.headers.count))
        while t.alignments.count < idx { t.alignments.append(.left) }
        t.alignments.insert(.left, at: min(idx, t.alignments.count))
        for r in 0..<t.rows.count {
            while t.rows[r].count < idx { t.rows[r].append("") }
            t.rows[r].insert("", at: min(idx, t.rows[r].count))
        }
        return t
    }

    static func deletingRow(_ table: Table, at rowIndex: Int) -> Table? {
        var t = table
        guard rowIndex >= 0, rowIndex < t.rows.count else { return nil }
        t.rows.remove(at: rowIndex)
        return t
    }

    /// 已废弃：表格不再转成附件，编辑区直接改 `| 单元格 |` 文本。
    static func embedAttachments(in attributed: NSMutableAttributedString) {}

    /// 表格行浅色底，方便辨认但仍可编辑。
    static func highlightEditableTables(in attributed: NSMutableAttributedString) {
        let bgHeader = NSColor.controlAccentColor.withAlphaComponent(0.12)
        let bgRow = NSColor.controlAccentColor.withAlphaComponent(0.05)
        let sepColor = NSColor.tertiaryLabelColor
        for item in tableRanges(in: attributed.string) {
            let block = (attributed.string as NSString).substring(with: item.range)
            var offset = item.range.location
            let lines = block.components(separatedBy: "\n")
            for (idx, line) in lines.enumerated() {
                let len = (line as NSString).length
                guard len > 0 || idx < lines.count - 1 else { continue }
                let range = NSRange(location: offset, length: len)
                if idx == 0 {
                    attributed.addAttribute(.backgroundColor, value: bgHeader, range: range)
                } else if isSeparatorRow(line) {
                    attributed.addAttributes([
                        .foregroundColor: sepColor,
                        .backgroundColor: bgRow
                    ], range: range)
                } else if isTableRow(line) {
                    attributed.addAttribute(.backgroundColor, value: bgRow, range: range)
                }
                offset += len + (idx < lines.count - 1 ? 1 : 0)
            }
        }
    }
}
