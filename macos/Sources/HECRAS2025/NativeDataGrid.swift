import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NativeDataGridAddress: Hashable, Sendable {
    let rowID: String
    let columnID: String
}

struct NativeDataGridRange: Hashable, Sendable {
    let anchor: NativeDataGridAddress
    let extent: NativeDataGridAddress
}

struct NativeDataGridSelection: Equatable, Sendable {
    var range: NativeDataGridRange?
    var additionalRanges: [NativeDataGridRange] = []
    var additionalCells: Set<NativeDataGridAddress> = []

    var focus: NativeDataGridAddress? { range?.extent ?? additionalRanges.last?.extent ?? additionalCells.first }
    var isEmpty: Bool { range == nil && additionalRanges.isEmpty && additionalCells.isEmpty }

    mutating func select(_ address: NativeDataGridAddress, extending: Bool, adding: Bool) {
        if extending, adding {
            if let range {
                additionalRanges.append(range)
                self.range = .init(anchor: range.extent, extent: address)
            } else {
                range = .init(anchor: address, extent: address)
            }
            return
        }
        if extending, let range {
            self.range = .init(anchor: range.anchor, extent: address)
            return
        }
        if adding {
            if let range, range.anchor == address, range.extent == address, additionalRanges.isEmpty {
                self.range = nil
                return
            }
            guard range != nil else {
                range = .init(anchor: address, extent: address)
                return
            }
            if additionalCells.remove(address) == nil {
                additionalCells.insert(address)
            }
            return
        }
        range = .init(anchor: address, extent: address)
        additionalCells.removeAll()
    }

    mutating func selectAll(rowIDs: [String], columnIDs: [String]) {
        guard let firstRow = rowIDs.first, let lastRow = rowIDs.last,
              let firstColumn = columnIDs.first, let lastColumn = columnIDs.last else {
            range = nil
            additionalRanges.removeAll()
            additionalCells.removeAll()
            return
        }
        range = .init(anchor: .init(rowID: firstRow, columnID: firstColumn),
                      extent: .init(rowID: lastRow, columnID: lastColumn))
        additionalRanges.removeAll()
        additionalCells.removeAll()
    }

    mutating func prune(rowIDs: Set<String>, columnIDs: Set<String>) {
        if let range, !rowIDs.contains(range.anchor.rowID) || !rowIDs.contains(range.extent.rowID)
            || !columnIDs.contains(range.anchor.columnID) || !columnIDs.contains(range.extent.columnID) {
            self.range = nil
        }
        additionalRanges = additionalRanges.filter { range in
            rowIDs.contains(range.anchor.rowID) && rowIDs.contains(range.extent.rowID)
                && columnIDs.contains(range.anchor.columnID) && columnIDs.contains(range.extent.columnID)
        }
        additionalCells = Set(additionalCells.filter { rowIDs.contains($0.rowID) && columnIDs.contains($0.columnID) })
    }

    func bounds(rowIDs: [String], columnIDs: [String]) -> NativeDataGridBounds? {
        let rowIndexes = Dictionary(uniqueKeysWithValues: rowIDs.enumerated().map { ($0.element, $0.offset) })
        let columnIndexes = Dictionary(uniqueKeysWithValues: columnIDs.enumerated().map { ($0.element, $0.offset) })
        var rowBounds: ClosedRange<Int>?
        var columnBounds: ClosedRange<Int>?

        func include(_ first: NativeDataGridAddress, _ last: NativeDataGridAddress) {
            guard let firstRow = rowIndexes[first.rowID], let lastRow = rowIndexes[last.rowID],
                  let firstColumn = columnIndexes[first.columnID], let lastColumn = columnIndexes[last.columnID] else { return }
            let rows = min(firstRow, lastRow)...max(firstRow, lastRow)
            let columns = min(firstColumn, lastColumn)...max(firstColumn, lastColumn)
            rowBounds = rowBounds.map { min($0.lowerBound, rows.lowerBound)...max($0.upperBound, rows.upperBound) } ?? rows
            columnBounds = columnBounds.map { min($0.lowerBound, columns.lowerBound)...max($0.upperBound, columns.upperBound) } ?? columns
        }

        if let range { include(range.anchor, range.extent) }
        for range in additionalRanges { include(range.anchor, range.extent) }
        for address in additionalCells { include(address, address) }
        guard let rows = rowBounds, let columns = columnBounds else { return nil }
        return .init(rows: rows, columns: columns)
    }

    func contains(_ address: NativeDataGridAddress, rowIDs: [String], columnIDs: [String]) -> Bool {
        guard let row = rowIDs.firstIndex(of: address.rowID), let column = columnIDs.firstIndex(of: address.columnID) else { return false }
        let rowIndexes = Dictionary(uniqueKeysWithValues: rowIDs.enumerated().map { ($0.element, $0.offset) })
        let columnIndexes = Dictionary(uniqueKeysWithValues: columnIDs.enumerated().map { ($0.element, $0.offset) })
        return contains(address, rowIndex: row, columnIndex: column, rowIndexes: rowIndexes, columnIndexes: columnIndexes)
    }

    func contains(_ address: NativeDataGridAddress, rowIndex: Int, columnIndex: Int,
                  rowIndexes: [String: Int], columnIndexes: [String: Int]) -> Bool {
        if additionalCells.contains(address) { return true }
        for range in additionalRanges {
            guard let firstRow = rowIndexes[range.anchor.rowID], let lastRow = rowIndexes[range.extent.rowID],
                  let firstColumn = columnIndexes[range.anchor.columnID], let lastColumn = columnIndexes[range.extent.columnID] else { continue }
            if (min(firstRow, lastRow)...max(firstRow, lastRow)).contains(rowIndex)
                && (min(firstColumn, lastColumn)...max(firstColumn, lastColumn)).contains(columnIndex) { return true }
        }
        guard let range,
              let firstRow = rowIndexes[range.anchor.rowID],
              let lastRow = rowIndexes[range.extent.rowID],
              let firstColumn = columnIndexes[range.anchor.columnID],
              let lastColumn = columnIndexes[range.extent.columnID] else { return false }
        return (min(firstRow, lastRow)...max(firstRow, lastRow)).contains(rowIndex)
            && (min(firstColumn, lastColumn)...max(firstColumn, lastColumn)).contains(columnIndex)
    }
}

struct NativeDataGridBounds: Equatable, Sendable {
    let rows: ClosedRange<Int>
    let columns: ClosedRange<Int>
}

struct NativeDataGridPasteCell: Equatable, Sendable {
    let rowID: String
    let columnID: String
    let value: String
}

struct NativeDataGridContext: Sendable {
    let rowID: String?
    let columnID: String?
    let rowIndex: Int?
    let columnIndex: Int?
    var isOverRow: Bool { rowID != nil }
}

enum NativeDataGridContextSelection {
    /// Mirrors the retained source right-click rule, ordered by the complete
    /// source row list so selected rows hidden by a filter remain in the action.
    static func rowIDs(clickedRowID: String, selectedRowIDs: Set<String>, sourceRowIDs: [String],
                       addsToSelection: Bool) -> [String] {
        let contextIDs: Set<String>
        if selectedRowIDs.contains(clickedRowID) {
            contextIDs = selectedRowIDs
        } else if addsToSelection {
            contextIDs = selectedRowIDs.union([clickedRowID])
        } else {
            contextIDs = [clickedRowID]
        }
        return sourceRowIDs.filter(contextIDs.contains)
    }
}

enum NativeDataGridClipboard {
    static func encode(_ rows: [[String]]) -> String {
        rows.map { row in row.map(quote).joined(separator: "\t") }.joined(separator: "\n")
    }

    static func decode(_ text: String) -> [[String]]? {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var justClosedQuote = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if quoted {
                if character == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = text.index(after: next)
                    } else {
                        quoted = false
                        justClosedQuote = true
                        index = next
                    }
                } else {
                    field.append(character)
                    index = text.index(after: index)
                }
                continue
            }

            if justClosedQuote {
                if character == "\t" {
                    row.append(field)
                    field = ""
                    justClosedQuote = false
                    index = text.index(after: index)
                } else if Self.isRecordSeparator(character) {
                    row.append(field)
                    rows.append(row)
                    row = []
                    field = ""
                    justClosedQuote = false
                    index = text.index(after: index)
                    if character == "\r", index < text.endIndex, text[index] == "\n" {
                        index = text.index(after: index)
                    }
                } else {
                    return nil
                }
            } else if character == "\"", field.isEmpty {
                quoted = true
                index = text.index(after: index)
            } else if character == "\"" {
                return nil
            } else if character == "\t" {
                row.append(field)
                field = ""
                index = text.index(after: index)
            } else if Self.isRecordSeparator(character) {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
                index = text.index(after: index)
                if character == "\r", index < text.endIndex, text[index] == "\n" {
                    index = text.index(after: index)
                }
            } else {
                field.append(character)
                index = text.index(after: index)
            }
        }
        guard !quoted else { return nil }
        let endsWithRecordSeparator = text.last.map(Self.isRecordSeparator) ?? false
        if !field.isEmpty || !row.isEmpty || rows.isEmpty || !endsWithRecordSeparator {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    private static func isRecordSeparator(_ character: Character) -> Bool {
        character == "\r" || character == "\n" || character == "\r\n"
    }

    static func copiedText(selection: NativeDataGridSelection, rowIDs: [String], columnIDs: [String], value: (String, String) -> String?) -> String? {
        guard let bounds = selection.bounds(rowIDs: rowIDs, columnIDs: columnIDs),
              bounds.rows.upperBound < rowIDs.count, bounds.columns.upperBound < columnIDs.count else { return nil }
        let matrix = bounds.rows.map { row in
            bounds.columns.map { column in value(rowIDs[row], columnIDs[column]) ?? "" }
        }
        return encode(matrix)
    }

    static func copiedRowsText(selectedRowIDs: Set<String>, rowIDs: [String], columnIDs: [String], value: (String, String) -> String?) -> String? {
        let selectedRows = rowIDs.filter(selectedRowIDs.contains)
        guard !selectedRows.isEmpty, !columnIDs.isEmpty else { return nil }
        return encode(selectedRows.map { rowID in columnIDs.map { value(rowID, $0) ?? "" } })
    }

    static func pasteCells(_ text: String, selection: NativeDataGridSelection, rowIDs: [String], columnIDs: [String], readOnlyColumnIDs: Set<String> = []) -> [NativeDataGridPasteCell] {
        guard let matrix = decode(text), !matrix.isEmpty, !rowIDs.isEmpty, !columnIDs.isEmpty else { return [] }
        let selectedBounds = selection.bounds(rowIDs: rowIDs, columnIDs: columnIDs)
        guard selectedBounds != nil || selection.focus != nil else { return [] }
        let startRow = selectedBounds?.rows.lowerBound ?? selection.focus.flatMap { rowIDs.firstIndex(of: $0.rowID) } ?? 0
        let startColumn = selectedBounds?.columns.lowerBound ?? selection.focus.flatMap { columnIDs.firstIndex(of: $0.columnID) } ?? 0
        guard startRow < rowIDs.count, startColumn < columnIDs.count else { return [] }

        let fillsSelection = matrix.count == 1 && matrix[0].count == 1 && selectedBounds != nil
        let rowRange: ClosedRange<Int>
        let columnRange: ClosedRange<Int>
        if fillsSelection, let selectedBounds {
            rowRange = selectedBounds.rows
            columnRange = selectedBounds.columns
        } else {
            let rowCount = matrix.count
            let columnCount = min(matrix[0].count, columnIDs.count - startColumn)
            guard columnCount > 0 else { return [] }
            rowRange = startRow...min(rowIDs.count - 1, startRow + rowCount - 1)
            columnRange = startColumn...(startColumn + columnCount - 1)
        }

        var edits: [NativeDataGridPasteCell] = []
        for targetRow in rowRange {
            let sourceRow = fillsSelection ? matrix[0] : matrix[targetRow - startRow]
            for targetColumn in columnRange where !readOnlyColumnIDs.contains(columnIDs[targetColumn]) {
                let valueIndex = fillsSelection ? 0 : targetColumn - startColumn
                guard sourceRow.indices.contains(valueIndex) else { continue }
                edits.append(.init(rowID: rowIDs[targetRow], columnID: columnIDs[targetColumn], value: sourceRow[valueIndex]))
            }
        }
        return edits
    }

    private static func quote(_ value: String) -> String {
        guard value.contains("\t") || value.contains("\"") || value.contains(where: \.isNewline) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

struct NativeDataGrid<Row, Column>: View
where Row: Identifiable, Row.ID == String, Column: Identifiable, Column.ID == String {
    let identity: String
    let rows: [Row]
    let columns: [Column]
    var selectionRowIDs: [String]? = nil
    var selectionColumnIDs: [String]? = nil
    @Binding var selection: NativeDataGridSelection
    var rowSelection: Binding<Set<String>>?
    /// A stable row ID to bring into view after a route such as "View Attributes".
    var focusRowID: String? = nil
    let initialWidth: (Column) -> CGFloat?
    let isReadOnly: (Column) -> Bool
    let value: (Row, Column) -> String
    let header: (Column) -> AnyView
    let cell: (Row, Column) -> AnyView
    let contextMenu: (NativeDataGridContext) -> AnyView
    let onPaste: ([NativeDataGridPasteCell]) -> Void
    @State private var widths: [String: CGFloat] = [:]
    @State private var resizingColumnID: String?
    @State private var resizeStartWidth: CGFloat = 0

    private var rowHeaderWidth: CGFloat { 48 }

    var body: some View {
        let rowIDs = rows.map(\.id)
        let columnIDs = columns.map(\.id)
        let stableRowIDs = selectionRowIDs ?? rowIDs
        let stableColumnIDs = selectionColumnIDs ?? columnIDs
        let rowIndexes = Dictionary(uniqueKeysWithValues: rowIDs.enumerated().map { ($0.element, $0.offset) })
        let columnIndexes = Dictionary(uniqueKeysWithValues: columnIDs.enumerated().map { ($0.element, $0.offset) })
        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let columnsByID = Dictionary(uniqueKeysWithValues: columns.map { ($0.id, $0) })
        ScrollView(.horizontal) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("#").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: rowHeaderWidth, height: 32).background(.quaternary)
                    ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                        headerCell(column, index: index, rowIDs: rowIDs, columnIDs: columnIDs, columnIndexes: columnIndexes)
                    }
                }
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                HStack(spacing: 0) {
                                    rowHeader(index: index, row: row)
                                    ForEach(Array(columns.enumerated()), id: \.element.id) { columnIndex, column in
                                        cellView(row: row, rowIndex: index, column: column, columnIndex: columnIndex,
                                                 rowIndexes: rowIndexes, columnIndexes: columnIndexes)
                                    }
                                }
                                .id(row.id)
                            }
                        }
                    }
                    .onAppear {
                        if let focusRowID, rowIndexes[focusRowID] != nil {
                            proxy.scrollTo(focusRowID, anchor: .center)
                        }
                    }
                    .onChange(of: focusRowID) { _, rowID in
                        if let rowID, rowIndexes[rowID] != nil {
                            proxy.scrollTo(rowID, anchor: .center)
                        }
                    }
                }
            }
        }
        .onCopyCommand {
            let cellText = NativeDataGridClipboard.copiedText(selection: selection, rowIDs: rowIDs, columnIDs: columnIDs, value: { rowID, columnID in
                guard let row = rowsByID[rowID], let column = columnsByID[columnID] else { return nil }
                return value(row, column)
            })
            let rowText = rowSelection.flatMap { selected in
                NativeDataGridClipboard.copiedRowsText(selectedRowIDs: selected.wrappedValue, rowIDs: rowIDs, columnIDs: columnIDs) { rowID, columnID in
                    guard let row = rowsByID[rowID], let column = columnsByID[columnID] else { return nil }
                    return value(row, column)
                }
            }
            guard let text = cellText ?? rowText else { return [] }
            return [NSItemProvider(object: text as NSString)]
        }
        .onPasteCommand(of: [.plainText]) { _ in
            if let text = NSPasteboard.general.string(forType: .string) { applyPaste(text) }
        }
        .onChange(of: stableRowIDs) { _, ids in pruneSelection(rowIDs: ids, columnIDs: stableColumnIDs) }
        .onChange(of: stableColumnIDs) { _, ids in pruneSelection(rowIDs: stableRowIDs, columnIDs: ids) }
        .onChange(of: identity) { _, _ in
            selection = .init()
            rowSelection?.wrappedValue = []
            widths = [:]
        }
        .onChange(of: stableColumnIDs) { _, ids in
            let active = Set(ids)
            widths = widths.filter { active.contains($0.key) }
        }
        .onAppear { initializeWidths() }
    }

    @ViewBuilder private func headerCell(_ column: Column, index: Int, rowIDs: [String], columnIDs: [String],
                                         columnIndexes: [String: Int]) -> some View {
        let width = width(for: column)
        HStack(spacing: 0) {
            header(column)
                .frame(width: max(0, width - 12), height: 32, alignment: .leading)
                .padding(.leading, 8)
                .background(.quaternary)
                .contentShape(Rectangle())
                .contextMenu {
                    contextMenu(.init(rowID: nil, columnID: column.id, rowIndex: nil, columnIndex: columnIndexes[column.id] ?? index))
                    Divider()
                    if !selection.isEmpty { Button("Copy Cell Selection") { copyCellSelection() } }
                    Button("Paste Cells") { pasteFromClipboard() }
                    Button("Select All Cells") {
                        var updated = selection
                        updated.selectAll(rowIDs: rowIDs, columnIDs: columnIDs)
                        selection = updated
                        rowSelection?.wrappedValue = Set(rowIDs)
                    }.disabled(rowIDs.isEmpty || columnIDs.isEmpty)
                }
            Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 4, height: 32)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if resizingColumnID != column.id {
                            resizingColumnID = column.id
                            resizeStartWidth = width
                        }
                        widths[column.id] = min(1200, max(48, resizeStartWidth + gesture.translation.width))
                    }
                    .onEnded { _ in resizingColumnID = nil })
                .help(L10n.text("Drag to resize column"))
        }
        .frame(width: width, height: 32, alignment: .leading)
    }

    @ViewBuilder private func rowHeader(index: Int, row: Row) -> some View {
        Text(String(index + 1)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .frame(width: rowHeaderWidth, height: 32)
            .background(rowSelection?.wrappedValue.contains(row.id) == true ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .trailing) { Rectangle().fill(Color.secondary.opacity(0.18)).frame(width: 1) }
            .contentShape(Rectangle())
            .onTapGesture { selectRow(row) }
            .contextMenu { contextMenu(.init(rowID: row.id, columnID: nil, rowIndex: index, columnIndex: nil)) }
    }

    @ViewBuilder private func cellView(row: Row, rowIndex: Int, column: Column, columnIndex: Int,
                                       rowIndexes: [String: Int], columnIndexes: [String: Int]) -> some View {
        let address = NativeDataGridAddress(rowID: row.id, columnID: column.id)
        let selected = selection.contains(address, rowIndex: rowIndex, columnIndex: columnIndex,
                                          rowIndexes: rowIndexes, columnIndexes: columnIndexes)
        cell(row, column)
            .padding(.horizontal, 7)
            .frame(width: max(48, width(for: column)), height: 32, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.16) : Color.clear)
            .overlay(Rectangle().stroke(selected ? Color.accentColor.opacity(0.72) : Color.secondary.opacity(0.16), lineWidth: selected ? 1 : 0.5))
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { selectCell(address) })
            .contextMenu {
                contextMenu(.init(rowID: row.id, columnID: column.id,
                                  rowIndex: rowIndexes[row.id], columnIndex: columnIndexes[column.id]))
                Divider()
                Button("Copy Cell") { copyCell(row: row, column: column) }
                if !selection.isEmpty { Button("Copy Cell Selection") { copyCellSelection() } }
                Button("Paste Cells") { pasteFromClipboard(at: address) }
                Button("Select All Cells") {
                    var updated = selection
                    updated.selectAll(rowIDs: rows.map(\.id), columnIDs: columns.map(\.id))
                    selection = updated
                    rowSelection?.wrappedValue = Set(rows.map(\.id))
                }.disabled(rows.isEmpty || columns.isEmpty)
            }
    }

    private func width(for column: Column) -> CGFloat { widths[column.id] ?? max(48, initialWidth(column) ?? 130) }

    private func initializeWidths() {
        for column in columns where widths[column.id] == nil {
            widths[column.id] = max(48, initialWidth(column) ?? 130)
        }
    }

    private func pruneSelection(rowIDs: [String], columnIDs: [String]) {
        var updated = selection
        updated.prune(rowIDs: Set(rowIDs), columnIDs: Set(columnIDs))
        selection = updated
    }

    private func selectCell(_ address: NativeDataGridAddress) {
        let flags = NSEvent.modifierFlags
        var updated = selection
        let visibleRows = rows.map(\.id)
        let visibleColumns = columns.map(\.id)
        let canExtend = selection.range.map {
            visibleRows.contains($0.anchor.rowID) && visibleRows.contains($0.extent.rowID)
                && visibleColumns.contains($0.anchor.columnID) && visibleColumns.contains($0.extent.columnID)
        } ?? false
        updated.select(address, extending: flags.contains(.shift) && canExtend,
                       adding: flags.contains(.command) || flags.contains(.control))
        selection = updated
        guard let bounds = selection.bounds(rowIDs: visibleRows, columnIDs: visibleColumns), let rowSelection else { return }
        rowSelection.wrappedValue = Set(bounds.rows.map { visibleRows[$0] })
    }

    private func selectRow(_ row: Row) {
        guard let rowSelection else { return }
        selection = .init()
        var selectedRows = rowSelection.wrappedValue
        if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.control) {
            if selectedRows.contains(row.id) { selectedRows.remove(row.id) }
            else { selectedRows.insert(row.id) }
        } else {
            selectedRows = [row.id]
        }
        rowSelection.wrappedValue = selectedRows
    }

    private func applyPaste(_ text: String, using targetSelection: NativeDataGridSelection? = nil) {
        let readOnly = Set(columns.filter(isReadOnly).map(\.id))
        let edits = NativeDataGridClipboard.pasteCells(text, selection: targetSelection ?? selection,
                                                        rowIDs: rows.map(\.id), columnIDs: columns.map(\.id),
                                                        readOnlyColumnIDs: readOnly)
        if !edits.isEmpty { onPaste(edits) }
    }

    private func copyCell(row: Row, column: Column) {
        writeClipboard(value(row, column))
    }

    private func copyCellSelection() {
        guard let text = NativeDataGridClipboard.copiedText(
            selection: selection,
            rowIDs: rows.map(\.id),
            columnIDs: columns.map(\.id),
            value: { rowID, columnID in
                guard let row = rows.first(where: { $0.id == rowID }),
                      let column = columns.first(where: { $0.id == columnID }) else { return nil }
                return value(row, column)
            }
        ) else { return }
        writeClipboard(text)
    }

    private func writeClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func pasteFromClipboard(at address: NativeDataGridAddress? = nil) {
        var targetSelection = selection
        if let address {
            targetSelection.select(address, extending: false, adding: false)
            selection = targetSelection
            if let bounds = targetSelection.bounds(rowIDs: rows.map(\.id), columnIDs: columns.map(\.id)) {
                rowSelection?.wrappedValue = Set(bounds.rows.map { rows[$0].id })
            }
        }
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        applyPaste(text, using: targetSelection)
    }
}
