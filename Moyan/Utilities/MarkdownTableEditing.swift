import AppKit
import Foundation

/// 表格源码编辑：Tab 移格、回车在表内增行（单元格文字始终可直接改）。
enum MarkdownTableEditing {
    @discardableResult
    static func moveCell(in textView: NSTextView, forward: Bool) -> Bool {
        let selected = textView.selectedRange()
        let ns = textView.string as NSString
        guard ns.length > 0 else { return false }
        let loc = min(selected.location, max(0, ns.length - 1))
        guard MarkdownTableSupport.detect(in: textView.string, at: loc) != nil else { return false }

        let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
        let line = ns.substring(with: lineRange)

        if MarkdownTableSupport.isSeparatorRow(line) {
            if forward {
                let nextLoc = NSMaxRange(lineRange)
                guard nextLoc < ns.length else { return false }
                return selectCell(in: textView, atLineContaining: nextLoc, preferLast: false)
            }
            let prev = max(0, lineRange.location - 1)
            return selectCell(in: textView, atLineContaining: prev, preferLast: true)
        }
        guard MarkdownTableSupport.isTableRow(line) else { return false }

        let cells = cellRanges(in: line, lineStart: lineRange.location)
        guard !cells.isEmpty else { return false }

        let caret = selected.location
        var current = 0
        for (idx, cell) in cells.enumerated() {
            if NSLocationInRange(caret, cell) || caret == NSMaxRange(cell) {
                current = idx
                break
            }
            if caret < cell.location {
                current = idx
                break
            }
            current = idx
        }

        if forward {
            if current + 1 < cells.count {
                textView.setSelectedRange(cells[current + 1])
                textView.scrollRangeToVisible(cells[current + 1])
                return true
            }
            let nextLoc = NSMaxRange(lineRange)
            guard nextLoc < ns.length else { return false }
            let nextLineRange = ns.lineRange(for: NSRange(location: nextLoc, length: 0))
            let nextText = ns.substring(with: nextLineRange)
            if MarkdownTableSupport.isSeparatorRow(nextText) {
                let afterSep = NSMaxRange(nextLineRange)
                guard afterSep < ns.length else { return false }
                return selectCell(in: textView, atLineContaining: afterSep, preferLast: false)
            }
            return selectCell(in: textView, atLineContaining: nextLoc, preferLast: false)
        }

        if current > 0 {
            textView.setSelectedRange(cells[current - 1])
            textView.scrollRangeToVisible(cells[current - 1])
            return true
        }
        let prev = max(0, lineRange.location - 1)
        return selectCell(in: textView, atLineContaining: prev, preferLast: true)
    }

    @discardableResult
    static func insertNewline(in textView: NSTextView) -> Bool {
        let selected = textView.selectedRange()
        guard selected.length == 0 else { return false }
        let ns = textView.string as NSString
        guard ns.length > 0 else { return false }
        let loc = min(selected.location, max(0, ns.length - 1))
        guard let detected = MarkdownTableSupport.detect(in: textView.string, at: loc) else { return false }

        let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
        let line = ns.substring(with: lineRange)

        if MarkdownTableSupport.isSeparatorRow(line) {
            let next = NSMaxRange(lineRange)
            if next < ns.length {
                _ = selectCell(in: textView, atLineContaining: next, preferLast: false)
            }
            return true
        }
        guard MarkdownTableSupport.isTableRow(line) else { return false }

        let relative = max(0, loc - detected.range.location)
        let tableText = ns.substring(with: detected.range)
        let lineIndex = (tableText as NSString).substring(to: min(relative, (tableText as NSString).length))
            .components(separatedBy: "\n").count - 1

        // 表头：跳到首个数据行
        if lineIndex == 0 {
            var scan = NSMaxRange(lineRange)
            if scan < ns.length {
                scan = NSMaxRange(ns.lineRange(for: NSRange(location: scan, length: 0)))
            }
            if scan < ns.length {
                _ = selectCell(in: textView, atLineContaining: scan, preferLast: false)
            }
            return true
        }

        let cols = max(detected.table.columnCount, 1)
        let blankLine = "| " + Array(repeating: "  ", count: cols).joined(separator: "| ") + "|"
        let lineText = ns.substring(with: lineRange)
        let insertAt = NSMaxRange(lineRange)
        let insertion = lineText.hasSuffix("\n") ? blankLine + "\n" : "\n" + blankLine
        guard textView.shouldChangeText(
            in: NSRange(location: insertAt, length: 0),
            replacementString: insertion
        ) else { return false }
        textView.textStorage?.replaceCharacters(
            in: NSRange(location: insertAt, length: 0),
            with: insertion
        )
        textView.didChangeText()
        let jump = insertAt + (insertion.hasPrefix("\n") ? 1 : 0)
        _ = selectCell(in: textView, atLineContaining: jump, preferLast: false)
        return true
    }

    private static func selectCell(
        in textView: NSTextView,
        atLineContaining index: Int,
        preferLast: Bool
    ) -> Bool {
        let ns = textView.string as NSString
        guard ns.length > 0 else { return false }
        let loc = min(max(0, index), ns.length - 1)
        let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
        let line = ns.substring(with: lineRange)
        guard MarkdownTableSupport.isTableRow(line), !MarkdownTableSupport.isSeparatorRow(line) else {
            return false
        }
        let cells = cellRanges(in: line, lineStart: lineRange.location)
        guard !cells.isEmpty else { return false }
        let target = preferLast ? cells[cells.count - 1] : cells[0]
        textView.setSelectedRange(target)
        textView.scrollRangeToVisible(target)
        return true
    }

    private static func cellRanges(in line: String, lineStart: Int) -> [NSRange] {
        let ns = line as NSString
        var ranges: [NSRange] = []
        var i = 0
        while i < ns.length {
            let ch = ns.character(at: i)
            if ch == 32 || ch == 9 { i += 1; continue }
            break
        }
        if i < ns.length, ns.character(at: i) == 124 { i += 1 }

        while i < ns.length {
            while i < ns.length {
                let ch = ns.character(at: i)
                if ch == 32 || ch == 9 { i += 1; continue }
                break
            }
            if i >= ns.length || ns.character(at: i) == 10 { break }

            let contentStart = i
            while i < ns.length {
                let ch = ns.character(at: i)
                if ch == 124 || ch == 10 { break }
                i += 1
            }
            var contentEnd = i
            while contentEnd > contentStart {
                let ch = ns.character(at: contentEnd - 1)
                if ch == 32 || ch == 9 { contentEnd -= 1; continue }
                break
            }
            ranges.append(NSRange(
                location: lineStart + contentStart,
                length: max(0, contentEnd - contentStart)
            ))
            if i < ns.length, ns.character(at: i) == 124 {
                i += 1
            } else {
                break
            }
        }
        return ranges
    }
}
