import Foundation

/// 轻量 xlsx / csv 只读解析：多 sheet、共享字符串、数字/公式缓存值。
enum XLSXWorkbook {
    struct Workbook {
        var sheets: [Sheet]
    }

    struct Sheet: Identifiable {
        var id: String { name }
        var name: String
        var rows: [[String]]
        var columnCount: Int { rows.map(\.count).max() ?? 0 }
        var rowCount: Int { rows.count }
    }

    enum ParseError: LocalizedError {
        case unreadable
        case missingWorkbook

        var errorDescription: String? {
            switch self {
            case .unreadable: return "表格内容无法解析"
            case .missingWorkbook: return "缺少 workbook.xml"
            }
        }
    }

    static func load(from url: URL) throws -> Workbook {
        let ext = url.pathExtension.lowercased()
        if ext == "csv" {
            return try loadCSV(from: url)
        }
        return try loadXLSX(from: url)
    }

    // MARK: - CSV

    private static func loadCSV(from url: URL) throws -> Workbook {
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let rows = lines.map { parseCSVLine($0) }
        let name = url.deletingPathExtension().lastPathComponent
        return Workbook(sheets: [Sheet(name: name.isEmpty ? "Sheet1" : name, rows: rows)])
    }

    private static func parseCSVLine(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var inQuotes = false
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if ch == "\"" {
                let next = line.index(after: i)
                if inQuotes, next < line.endIndex, line[next] == "\"" {
                    current.append("\"")
                    i = line.index(after: next)
                    continue
                }
                inQuotes.toggle()
                i = line.index(after: i)
                continue
            }
            if ch == ",", !inQuotes {
                cells.append(current)
                current = ""
                i = line.index(after: i)
                continue
            }
            current.append(ch)
            i = line.index(after: i)
        }
        cells.append(current)
        return cells
    }

    // MARK: - XLSX via /usr/bin/unzip

    private static func loadXLSX(from url: URL) throws -> Workbook {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("moyan-xlsx-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-qq", "-o", url.path, "-d", temp.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw ParseError.unreadable }

        let workbookURL = temp.appendingPathComponent("xl/workbook.xml")
        guard let workbookXML = try? String(contentsOf: workbookURL, encoding: .utf8) else {
            throw ParseError.missingWorkbook
        }
        let sharedXML = (try? String(
            contentsOf: temp.appendingPathComponent("xl/sharedStrings.xml"),
            encoding: .utf8
        )) ?? ""
        let shared = parseSharedStrings(sharedXML)
        let sheetRefs = parseSheetRefs(workbookXML)
        let relsXML = (try? String(
            contentsOf: temp.appendingPathComponent("xl/_rels/workbook.xml.rels"),
            encoding: .utf8
        )) ?? ""
        let rels = parseRelationships(relsXML)

        var sheets: [Sheet] = []
        for ref in sheetRefs {
            let target = rels[ref.rId] ?? "worksheets/sheet\(sheets.count + 1).xml"
            let trimmed = target.hasPrefix("/") ? String(target.dropFirst()) : target
            let relative = trimmed.hasPrefix("xl/") ? String(trimmed.dropFirst(3)) : trimmed
            let sheetURL = temp.appendingPathComponent("xl").appendingPathComponent(relative)
            guard let sheetXML = try? String(contentsOf: sheetURL, encoding: .utf8) else { continue }
            sheets.append(Sheet(name: ref.name, rows: parseSheetData(sheetXML, sharedStrings: shared)))
        }
        if sheets.isEmpty { throw ParseError.unreadable }
        return Workbook(sheets: sheets)
    }

    private struct SheetRef {
        var name: String
        var rId: String
    }

    private static func parseSheetRefs(_ xml: String) -> [SheetRef] {
        let patterns = [
            #"sheet[^>]*name="([^"]+)"[^>]*(?:r:id|rId)="([^"]+)""#,
            #"sheet[^>]*(?:r:id|rId)="([^"]+)"[^>]*name="([^"]+)""#
        ]
        for (idx, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let ns = xml as NSString
            let refs: [SheetRef] = regex.matches(in: xml, range: NSRange(location: 0, length: ns.length)).compactMap { m in
                guard m.numberOfRanges >= 3 else { return nil }
                if idx == 0 {
                    return SheetRef(name: ns.substring(with: m.range(at: 1)), rId: ns.substring(with: m.range(at: 2)))
                }
                return SheetRef(name: ns.substring(with: m.range(at: 2)), rId: ns.substring(with: m.range(at: 1)))
            }
            if !refs.isEmpty { return refs }
        }
        return []
    }

    private static func parseRelationships(_ xml: String) -> [String: String] {
        var map: [String: String] = [:]
        let patterns = [
            #"Relationship[^>]*Id="([^"]+)"[^>]*Target="([^"]+)""#,
            #"Relationship[^>]*Target="([^"]+)"[^>]*Id="([^"]+)""#
        ]
        for (idx, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let ns = xml as NSString
            regex.enumerateMatches(in: xml, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match, match.numberOfRanges >= 3 else { return }
                if idx == 0 {
                    map[ns.substring(with: match.range(at: 1))] = ns.substring(with: match.range(at: 2))
                } else {
                    let target = ns.substring(with: match.range(at: 1))
                    let id = ns.substring(with: match.range(at: 2))
                    if map[id] == nil { map[id] = target }
                }
            }
        }
        return map
    }

    private static func parseSharedStrings(_ xml: String) -> [String] {
        guard !xml.isEmpty,
              let siRegex = try? NSRegularExpression(pattern: #"<si>([\s\S]*?)</si>"#, options: []) else { return [] }
        let ns = xml as NSString
        var strings: [String] = []
        siRegex.enumerateMatches(in: xml, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges >= 2 else { return }
            strings.append(extractTextNodes(ns.substring(with: match.range(at: 1))))
        }
        return strings
    }

    private static func extractTextNodes(_ xml: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"<t(?:\s[^>]*)?>([\s\S]*?)</t>"#, options: []) else {
            return decodeXMLEntities(xml)
        }
        let ns = xml as NSString
        var parts: [String] = []
        regex.enumerateMatches(in: xml, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges >= 2 else { return }
            parts.append(decodeXMLEntities(ns.substring(with: match.range(at: 1))))
        }
        return parts.joined()
    }

    private static func parseSheetData(_ xml: String, sharedStrings: [String]) -> [[String]] {
        var cells: [Int: [Int: String]] = [:]
        var maxRow = 0
        var maxCol = 0
        guard let rowRegex = try? NSRegularExpression(
            pattern: #"<row[^>]*?(?:r="(\d+)")?[^>]*>([\s\S]*?)</row>"#,
            options: []
        ) else { return [] }
        let ns = xml as NSString
        var inferredRow = 0
        rowRegex.enumerateMatches(in: xml, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges >= 3 else { return }
            inferredRow += 1
            let rowNum: Int
            if match.range(at: 1).location != NSNotFound {
                rowNum = Int(ns.substring(with: match.range(at: 1))) ?? inferredRow
            } else {
                rowNum = inferredRow
            }
            parseCells(
                in: ns.substring(with: match.range(at: 2)),
                row: rowNum,
                sharedStrings: sharedStrings,
                into: &cells,
                maxCol: &maxCol
            )
            maxRow = max(maxRow, rowNum)
        }
        guard maxRow > 0 else { return [] }
        let rowLimit = min(maxRow, 500)
        let colLimit = min(max(maxCol, 1), 100)
        var rows: [[String]] = []
        for r in 1...rowLimit {
            let map = cells[r] ?? [:]
            rows.append((1...colLimit).map { map[$0] ?? "" })
        }
        while let width = rows.first?.count, width > 1, rows.allSatisfy({ ($0.last ?? "").isEmpty }) {
            for i in rows.indices where !rows[i].isEmpty {
                rows[i].removeLast()
            }
        }
        return rows
    }

    private static func parseCells(
        in rowXML: String,
        row: Int,
        sharedStrings: [String],
        into cells: inout [Int: [Int: String]],
        maxCol: inout Int
    ) {
        guard let regex = try? NSRegularExpression(
            pattern: #"<c([^>]*)>([\s\S]*?)</c>|<c([^>/]*)/>"#,
            options: []
        ) else { return }
        let ns = rowXML as NSString
        var inferredCol = 0
        regex.enumerateMatches(in: rowXML, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let attrs: String
            let body: String
            if match.range(at: 1).location != NSNotFound {
                attrs = ns.substring(with: match.range(at: 1))
                body = match.range(at: 2).location != NSNotFound ? ns.substring(with: match.range(at: 2)) : ""
            } else if match.numberOfRanges >= 4, match.range(at: 3).location != NSNotFound {
                attrs = ns.substring(with: match.range(at: 3))
                body = ""
            } else {
                return
            }
            inferredCol += 1
            let col: Int
            if let ref = attribute(named: "r", in: attrs), let parsed = cellReferenceColumn(ref) {
                col = parsed
            } else {
                col = inferredCol
            }
            maxCol = max(maxCol, col)
            let type = attribute(named: "t", in: attrs) ?? ""
            if cells[row] == nil { cells[row] = [:] }
            cells[row]?[col] = cellDisplayValue(type: type, body: body, sharedStrings: sharedStrings)
        }
    }

    private static func attribute(named name: String, in attrs: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\#(name)="([^"]*)""#, options: []) else { return nil }
        let ns = attrs as NSString
        guard let match = regex.firstMatch(in: attrs, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    private static func cellReferenceColumn(_ ref: String) -> Int? {
        var col = 0
        for ch in ref {
            guard ch.isLetter else { break }
            col = col * 26 + Int(ch.uppercased().unicodeScalars.first!.value - 64)
        }
        return col > 0 ? col : nil
    }

    private static func cellDisplayValue(type: String, body: String, sharedStrings: [String]) -> String {
        let inline = extractTextNodes(body)
        if type == "inlineStr", !inline.isEmpty { return inline }
        let v = firstTagContent("v", in: body) ?? ""
        switch type {
        case "s":
            if let idx = Int(v), sharedStrings.indices.contains(idx) {
                return sharedStrings[idx]
            }
            return v
        case "b":
            return (v == "1" || v.lowercased() == "true") ? "TRUE" : "FALSE"
        case "str", "e":
            return decodeXMLEntities(v)
        default:
            if v.isEmpty { return inline }
            if let num = Double(v), v.contains(".") {
                if num == floor(num), abs(num) < 1e15 {
                    return String(format: "%.0f", num)
                }
                return String(format: "%g", num)
            }
            return decodeXMLEntities(v)
        }
    }

    private static func firstTagContent(_ tag: String, in xml: String) -> String? {
        let pattern = "<\(tag)(?:\\s[^>]*)?>([\\s\\S]*?)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let ns = xml as NSString
        guard let match = regex.firstMatch(in: xml, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    private static func decodeXMLEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
