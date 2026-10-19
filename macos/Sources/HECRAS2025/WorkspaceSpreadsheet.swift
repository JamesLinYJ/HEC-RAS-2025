import AppKit
import SwiftUI

private struct WorkspaceSpreadsheetActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var workspaceSpreadsheetAction: (() -> Void)? {
        get { self[WorkspaceSpreadsheetActionKey.self] }
        set { self[WorkspaceSpreadsheetActionKey.self] = newValue }
    }
}

/// The retained debug Spreadsheet is a standalone 1,000 by 1,000 string grid.
/// Values are implicit until edited so opening it does not allocate a million
/// strings; the native table view asks only for cells in its visible region.
@MainActor
final class WorkspaceSpreadsheetModel: ObservableObject {
    @Published private(set) var rowCount = 1_000
    @Published private(set) var columnCount = 1_000
    private var editedValues: [Cell: String] = [:]

    private struct Cell: Hashable {
        let row: Int
        let column: Int
    }

    var materializedCellCount: Int { editedValues.count }

    func value(row: Int, column: Int) -> String {
        guard row >= 0, row < rowCount, column >= 0, column < columnCount else { return "" }
        return editedValues[Cell(row: row, column: column)] ?? "0"
    }

    func setValue(_ value: String, row: Int, column: Int) {
        guard row >= 0, row < rowCount, column >= 0, column < columnCount else { return }
        let cell = Cell(row: row, column: column)
        if value == "0" { editedValues.removeValue(forKey: cell) }
        else { editedValues[cell] = value }
    }

    func addColumn() {
        columnCount += 1
    }

    /// Matches the source string column behavior: each new cell is the prior
    /// last-row text followed by the integer `1` (string concatenation).
    func addRow() {
        let newRow = rowCount
        for column in 0..<columnCount {
            editedValues[Cell(row: newRow, column: column)] = value(row: rowCount - 1, column: column) + "1"
        }
        rowCount += 1
    }
}

@MainActor
struct WorkspaceSpreadsheetView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = WorkspaceSpreadsheetModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("Spreadsheet", systemImage: "tablecells")
                    .font(.headline)
                Text(L10n.format("%d rows × %d columns", model.rowCount, model.columnCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add Row", systemImage: "plus") { model.addRow() }
                Button("Add Column", systemImage: "plus") { model.addColumn() }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            WorkspaceSpreadsheetTable(model: model)
        }
        .frame(minWidth: 760, idealWidth: 1_100, minHeight: 480, idealHeight: 720)
    }
}

@MainActor
private struct WorkspaceSpreadsheetTable: NSViewRepresentable {
    @ObservedObject var model: WorkspaceSpreadsheetModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.rowHeight = 24
        table.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        table.usesAlternatingRowBackgroundColors = true
        table.allowsColumnReordering = false
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        context.coordinator.installColumns(in: table)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = false
        scroll.borderType = .noBorder
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.model = model
        guard let table = scroll.documentView as? NSTableView else { return }
        context.coordinator.installColumns(in: table)
        table.reloadData()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        var model: WorkspaceSpreadsheetModel
        private let rowColumnID = NSUserInterfaceItemIdentifier("workspace-spreadsheet-row")

        init(model: WorkspaceSpreadsheetModel) { self.model = model }

        func installColumns(in table: NSTableView) {
            if table.tableColumns.first?.identifier != rowColumnID {
                for column in table.tableColumns { table.removeTableColumn(column) }
                let rowColumn = NSTableColumn(identifier: rowColumnID)
                rowColumn.title = L10n.text("Row")
                rowColumn.width = 58
                rowColumn.minWidth = 58
                rowColumn.maxWidth = 58
                rowColumn.isEditable = false
                table.addTableColumn(rowColumn)
            }

            while table.tableColumns.count - 1 > model.columnCount {
                if let column = table.tableColumns.last { table.removeTableColumn(column) }
            }
            while table.tableColumns.count - 1 < model.columnCount {
                let index = table.tableColumns.count - 1
                let column = NSTableColumn(identifier: Self.columnIdentifier(index))
                column.title = L10n.format("Column %d", index)
                column.width = 100
                column.minWidth = 70
                column.maxWidth = 320
                column.isEditable = true
                table.addTableColumn(column)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { model.rowCount }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn else { return nil }
            if tableColumn.identifier == rowColumnID {
                let identifier = rowColumnID
                let field = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField)
                    ?? NSTextField(labelWithString: "")
                field.identifier = identifier
                field.alignment = .right
                field.textColor = .secondaryLabelColor
                field.font = .systemFont(ofSize: 11, weight: .regular)
                field.stringValue = String(row + 1)
                field.tag = row
                return field
            }
            guard let columnIndex = Self.columnIndex(tableColumn.identifier) else { return nil }
            let identifier = Self.cellIdentifier(columnIndex)
            let field = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField)
                ?? NSTextField(string: "")
            field.identifier = identifier
            field.delegate = self
            field.isEditable = true
            field.isSelectable = true
            field.isBordered = false
            field.drawsBackground = false
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.stringValue = model.value(row: row, column: columnIndex)
            field.tag = row
            return field
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let identifier = field.identifier,
                  let column = Self.cellIndex(identifier) else { return }
            model.setValue(field.stringValue, row: field.tag, column: column)
        }

        private static func columnIdentifier(_ index: Int) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("workspace-spreadsheet-column-\(index)")
        }

        private static func cellIdentifier(_ index: Int) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("workspace-spreadsheet-cell-\(index)")
        }

        private static func columnIndex(_ identifier: NSUserInterfaceItemIdentifier) -> Int? {
            let prefix = "workspace-spreadsheet-column-"
            guard identifier.rawValue.hasPrefix(prefix) else { return nil }
            return Int(identifier.rawValue.dropFirst(prefix.count))
        }

        private static func cellIndex(_ identifier: NSUserInterfaceItemIdentifier) -> Int? {
            let prefix = "workspace-spreadsheet-cell-"
            guard identifier.rawValue.hasPrefix(prefix) else { return nil }
            return Int(identifier.rawValue.dropFirst(prefix.count))
        }
    }
}
