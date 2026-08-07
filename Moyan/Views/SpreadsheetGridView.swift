import AppKit
import SwiftUI

/// 只读表格网格：Sheet 页签 + 行列展示。
struct SpreadsheetGridView: View {
    let workbook: XLSXWorkbook.Workbook
    @State private var selectedSheetIndex = 0

    var body: some View {
        VStack(spacing: 0) {
            if workbook.sheets.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(workbook.sheets.enumerated()), id: \.offset) { index, sheet in
                            Button {
                                selectedSheetIndex = index
                            } label: {
                                Text(sheet.name)
                                    .font(.system(size: 12, weight: selectedSheetIndex == index ? .semibold : .regular))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(selectedSheetIndex == index
                                                  ? Color.accentColor.opacity(0.18)
                                                  : Color(nsColor: .controlBackgroundColor))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                Divider()
            }

            if workbook.sheets.indices.contains(selectedSheetIndex) {
                let sheet = workbook.sheets[selectedSheetIndex]
                if sheet.rows.isEmpty {
                    ContentUnavailableView("空表", systemImage: "tablecells", description: Text("此工作表没有单元格数据"))
                } else {
                    SpreadsheetTableRepresentable(sheet: sheet)
                }
            }
        }
    }
}

/// AppKit NSTableView 承载大表滚动。
private struct SpreadsheetTableRepresentable: NSViewRepresentable {
    let sheet: XLSXWorkbook.Sheet

    func makeCoordinator() -> Coordinator {
        Coordinator(sheet: sheet)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let table = NSTableView()
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnResizing = true
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 1, height: 1)
        table.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]

        rebuildColumns(table, columnCount: max(sheet.columnCount, 1))
        scroll.documentView = table
        context.coordinator.tableView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.sheet = sheet
        guard let table = scroll.documentView as? NSTableView else { return }
        if table.numberOfColumns != max(sheet.columnCount, 1) {
            while table.numberOfColumns > 0 {
                table.removeTableColumn(table.tableColumns[0])
            }
            rebuildColumns(table, columnCount: max(sheet.columnCount, 1))
        }
        table.reloadData()
    }

    private func rebuildColumns(_ table: NSTableView, columnCount: Int) {
        // 行号列
        let rowCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row#"))
        rowCol.title = ""
        rowCol.width = 44
        rowCol.minWidth = 36
        rowCol.maxWidth = 64
        table.addTableColumn(rowCol)

        for i in 0..<columnCount {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(i)"))
            col.title = columnLetter(i)
            col.width = 110
            col.minWidth = 60
            table.addTableColumn(col)
        }
    }

    private func columnLetter(_ index: Int) -> String {
        var n = index
        var s = ""
        repeat {
            s = String(UnicodeScalar(65 + n % 26)!) + s
            n = n / 26 - 1
        } while n >= 0
        return s
    }

    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var sheet: XLSXWorkbook.Sheet
        weak var tableView: NSTableView?

        init(sheet: XLSXWorkbook.Sheet) {
            self.sheet = sheet
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            sheet.rowCount
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = tableColumn?.identifier.rawValue ?? ""
            let text: String
            if id == "row#" {
                text = "\(row + 1)"
            } else if id.hasPrefix("c"), let idx = Int(id.dropFirst()),
                      sheet.rows.indices.contains(row),
                      sheet.rows[row].indices.contains(idx) {
                text = sheet.rows[row][idx]
            } else {
                text = ""
            }

            let cellID = NSUserInterfaceItemIdentifier("cell")
            let label: NSTextField
            if let reused = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTextField {
                label = reused
            } else {
                label = NSTextField(labelWithString: "")
                label.identifier = cellID
                label.font = .systemFont(ofSize: 12)
                label.lineBreakMode = .byTruncatingTail
            }
            label.stringValue = text
            label.alignment = id == "row#" ? .right : .left
            label.textColor = id == "row#" ? .secondaryLabelColor : .labelColor
            return label
        }
    }
}
