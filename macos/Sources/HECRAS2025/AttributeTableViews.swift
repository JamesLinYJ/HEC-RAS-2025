import AppKit
import SwiftUI

struct AttributeTableSort: SortComparator {
    var order: SortOrder = .forward
    let columnID: String
    let numeric: Bool
    func compare(_ lhs: AttributeRow, _ rhs: AttributeRow) -> ComparisonResult {
        let left = lhs.value(columnID), right = rhs.value(columnID)
        let result: ComparisonResult
        if left == nil || right == nil { result = left == right ? .orderedSame : left == nil ? .orderedAscending : .orderedDescending }
        else if numeric, let a = Double(left!), let b = Double(right!), a.isFinite, b.isFinite { result = a == b ? .orderedSame : a < b ? .orderedAscending : .orderedDescending }
        else { result = left!.localizedStandardCompare(right!) }
        return order == .forward || result == .orderedSame ? result : result == .orderedAscending ? .orderedDescending : .orderedAscending
    }
}
struct AttributeTableWindow: View {
    @ObservedObject var store: WorkspaceStore
    let route: AttributeTableRoute?
    @StateObject private var session: AttributeTableSession
    @State private var initialized = false
    @State private var selection: Set<String> = []
    @State private var cellSelection = NativeDataGridSelection()
    @State private var filter = ""
    @State private var showsFilterBar = true
    @State private var expressionMode = false
    @StateObject private var expressionFilter = TableExpressionFilterSession()
    @State private var sort: [AttributeTableSort] = []
    @State private var columnEdit: AttributeColumnEdit?
    @State private var columnsShown = Set<String>()
    init(store: WorkspaceStore, route: AttributeTableRoute?) {
        self.store = store; self.route = route
        _session = StateObject(wrappedValue: AttributeTableSession(provider: store.attributeTableProvider))
    }
    private var columns: [AttributeColumn] { session.data?.columns.filter { columnsShown.contains($0.id) } ?? [] }
    private var rows: [AttributeRow] {
        let filtered = (session.data?.rows ?? []).filter { row in
            if expressionMode { return expressionFilter.matchingRowIDs?.contains(row.id) ?? true }
            return filter.isEmpty || columns.contains { session.text(row: row, column: $0).localizedCaseInsensitiveContains(filter) }
        }
        let valid = sort.filter { order in columns.contains { $0.id == order.columnID } }
        return valid.isEmpty ? filtered : filtered.sorted(using: valid)
    }
    private var filterCapture: TableFilterCapture {
        let definitions = session.data?.columns ?? []
        return .init(owner: session.id.uuidString + "|" + (session.data?.sourcePath ?? ""),
            columns: definitions.map { .init(id: $0.id, name: $0.name, sourceType: $0.type, filterable: true) },
            rows: (session.data?.rows ?? []).map { row in
                .init(id: row.id, values: Dictionary(uniqueKeysWithValues: definitions.map {
                    ($0.id, session.text(row: row, column: $0))
                }))
            })
    }
    var body: some View {
        VStack(spacing: 0) {
            if let data = session.data {
                HStack {
                    Label(session.name, systemImage: "tablecells").font(.headline).textSelection(.enabled)
                    if session.modified { Text("Table draft").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Picker("Filter Mode", selection: $expressionMode) {
                        Text("Search").tag(false); Text("Expression").tag(true)
                    }.pickerStyle(.segmented).frame(maxWidth: 180)
                    if !expressionMode && showsFilterBar { TextField("Filter rows", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 260) }
                    Menu("Columns") {
                        Button("Add Column…") { columnEdit = .init(column: nil) }
                        Menu("Rename Column") { ForEach(data.columns) { column in Button(column.name) { columnEdit = .init(column: column) } } }
                        Menu("Remove Column") {
                            ForEach(data.columns) { column in Button(column.name, role: .destructive) { mutate(.init(operation: "removeColumn", columnId: column.id)) } }
                        }
                        Divider()
                        ForEach(data.columns) { column in
                            Toggle(column.name, isOn: Binding(get: { columnsShown.contains(column.id) }, set: { if $0 { columnsShown.insert(column.id) } else { columnsShown.remove(column.id) } }))
                        }
                    }.disabled(session.isBusy)
                    Button { copy(selection.isEmpty ? rows : rows.filter { selection.contains($0.id) }) } label: { Label("Copy Table", systemImage: "doc.on.clipboard") }.disabled(session.isBusy || data.rows.isEmpty)
                }.padding(12)
                if expressionMode { TableExpressionFilterBar(session: expressionFilter, capture: filterCapture) }
                if columns.isEmpty { ContentUnavailableView("No visible columns", systemImage: "tablecells", description: Text("Choose columns from the Columns menu.")) }
                else {
                    NativeDataGrid(
                        identity: session.id.uuidString + "|" + data.sourcePath,
                        rows: rows,
                        columns: columns,
                        selectionRowIDs: data.rows.map(\.id),
                        selectionColumnIDs: data.columns.map(\.id),
                        selection: $cellSelection,
                        rowSelection: $selection,
                        initialWidth: { _ in 160 },
                        isReadOnly: \.readOnly,
                        value: { row, column in session.text(row: row, column: column) },
                        header: { column in
                            AnyView(Button {
                                if let current = sort.first(where: { $0.columnID == column.id }) {
                                    sort = [.init(order: current.order == .forward ? .reverse : .forward, columnID: column.id, numeric: column.numeric)]
                                } else {
                                    sort = [.init(columnID: column.id, numeric: column.numeric)]
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Text(column.name).lineLimit(1)
                                    if let current = sort.first(where: { $0.columnID == column.id }) {
                                        Image(systemName: current.order == .forward ? "arrow.up" : "arrow.down").font(.caption2)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain))
                        },
                        cell: { row, column in AnyView(AttributeTableCell(row: row, column: column, session: session)) },
                        contextMenu: { context in
                            AnyView(Group {
                                if let columnID = context.columnID, let column = data.columns.first(where: { $0.id == columnID }) {
                                    Button("Sort Ascending") { setSort(column, ascending: true) }
                                    Button("Sort Descending") { setSort(column, ascending: false) }
                                    if sort.contains(where: { $0.columnID == column.id }) {
                                        Button("Clear Sort") { sort = [] }
                                    }
                                    Button(showsFilterBar ? "Hide Filter Bar" : "Show Filter Bar") { showsFilterBar.toggle() }
                                    if !filter.isEmpty || !expressionFilter.appliedExpression.isEmpty {
                                        Button("Clear Filter") { filter = ""; expressionFilter.clear() }
                                    }
                                    Divider()
                                    Button("Add Column…") { columnEdit = .init(column: nil) }
                                    Button("Rename Column") { columnEdit = .init(column: column) }
                                        .disabled(session.isBusy)
                                    Button("Remove Column", role: .destructive) {
                                        mutate(.init(operation: "removeColumn", columnId: column.id))
                                    }.disabled(session.isBusy)
                                    Divider()
                                }
                                if let rowID = context.rowID, let columnID = context.columnID,
                                   let column = data.columns.first(where: { $0.id == columnID }), !column.readOnly {
                                    Button("Set NULL") {
                                        session.setDraft(row: rowID, column: columnID, value: nil)
                                        Task { await session.flushDrafts() }
                                    }.disabled(session.isBusy)
                                    Button("Revert Cell Edit") { session.clearDraft(row: rowID, column: columnID) }
                                        .disabled(session.isBusy)
                                    Divider()
                                }
                                if let rowID = context.rowID {
                                    Button("Copy Table") { copy(rows.filter { $0.id == rowID || selection.contains($0.id) }) }
                                }
                            })
                        },
                        onPaste: { edits in Task { _ = await session.applyPaste(edits) } }
                    )
                }
                HStack {
                    Text(L10n.format("%d features · %d attributes", data.rows.count, data.columns.count)).font(.caption)
                    Text(L10n.text(data.shapeType)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let exported = session.exportedURL { Button(exported.lastPathComponent) { store.system.reveal(exported) }.buttonStyle(.link) }
                    if !session.drafts.isEmpty { Button("Apply Cell Edits") { Task { await session.flushDrafts() } }.disabled(session.isBusy) }
                }.padding(12)
            } else {
                ContentUnavailableView("Attribute Table", systemImage: "tablecells", description: Text("Open a point, polyline or polygon Shapefile to inspect its attributes."))
                Button("Open Shapefile…") { open() }.buttonStyle(.borderedProminent).disabled(session.isBusy)
                Spacer()
            }
            if let error = session.error {
                HStack { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled); Spacer(); Button("Dismiss") { session.error = nil } }.padding(12)
            }
        }.frame(minWidth: 820, minHeight: 500)
            .toolbar {
                ToolbarItemGroup {
                    Button("Open Shapefile…") { open() }.disabled(session.isBusy)
                    Button("Export Table…") { Task { await session.export(using: store.system) } }.disabled(session.isBusy || session.data == nil)
                    if session.isBusy { Button("Cancel", action: session.cancelCurrentWork); ProgressView().controlSize(.small) }
                }
            }
            .navigationTitle(session.name)
            .focusedSceneValue(\.workspaceDocumentActions, .init(canCloseTab: false, closeTab: {}, openDocument: open,
                saveDocument: { Task { await session.export(using: store.system) } }, canSaveDocument: !session.isBusy && session.data != nil, documentSaveTitle: "Export Table…"))
            .environment(\.locale, store.interfaceLocale)
            .preferredColorScheme(store.theme == "Dark" ? .dark : store.theme == "Light" ? .light : nil)
            .background(WindowLifecycleGuard(store: store, beforeClose: { await session.confirmClose(using: store.system) }, guardsProjectChanges: false).frame(width: 0, height: 0))
            .onAppear { store.registerAttributeTable(session) }
            .onDisappear { session.invalidate(); store.unregisterAttributeTable(session) }
            .task {
                guard !initialized else { return }; initialized = true
                if let path = route?.path, !path.isEmpty, let authorized = store.system.authorizeAttributeTableFolder(for: URL(filePath: path)) { await session.load(authorized) }
            }
            .onChange(of: session.data?.sourcePath) { _, _ in selection = []; cellSelection = .init(); filter = ""; showsFilterBar = true; expressionFilter.clear(); sort = []; columnsShown = Set(session.data?.columns.map(\.id) ?? []) }
            .onChange(of: session.data?.columns.map(\.id)) { old, new in
                let oldIDs = Set(old ?? []), newIDs = Set(new ?? [])
                columnsShown.formIntersection(newIDs); columnsShown.formUnion(newIDs.subtracting(oldIDs))
                sort = sort.filter { newIDs.contains($0.columnID) }
            }
            .sheet(item: $columnEdit) { edit in AttributeColumnSheet(session: session, column: edit.column) }
    }
    private func open() {
        Task {
            guard await session.confirmClose(using: store.system), let url = store.system.chooseAttributeTableFile(), let authorized = store.system.authorizeAttributeTableFolder(for: url) else { return }
            await session.load(authorized)
        }
    }
    private func mutate(_ mutation: AttributeMutation) { Task { if await session.flushDrafts() { await session.perform(mutation) } } }
    private func copy(_ rows: [AttributeRow]) { if let data = session.data { store.system.copy(data.text(rows: rows, delimiter: "\t")) } }
    private func setSort(_ column: AttributeColumn, ascending: Bool) {
        sort = [.init(order: ascending ? .forward : .reverse, columnID: column.id, numeric: column.numeric)]
    }
}
private struct AttributeColumnEdit: Identifiable { var id = UUID(); let column: AttributeColumn? }
private struct AttributeColumnSheet: View {
    @ObservedObject var session: AttributeTableSession
    let column: AttributeColumn?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var type = "String"
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 16) {
            Text(L10n.text(column == nil ? "Add Column" : "Rename Column")).font(.title2)
            Form {
                if let column { LabeledContent("Original Column Name", value: column.name) }
                TextField("Column Name", text: $name).focused($focused)
                if column == nil { Picker("Column Type", selection: $type) { ForEach(["String", "Integer", "Numeric", "Boolean"], id: \.self) { Text(L10n.text($0)).tag($0) } } }
                if !name.isEmpty, !session.nameIsValid(name, excluding: column?.id) { Text("A column with this name already exists.").foregroundStyle(.red) }
                if let error = session.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }.formStyle(.grouped)
            HStack {
                Spacer(); Button("Cancel", role: .cancel) { session.cancelCurrentWork(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text(column == nil ? "Add Column" : "Rename")) {
                    Task {
                        guard await session.flushDrafts() else { return }
                        if await session.perform(.init(operation: column == nil ? "addColumn" : "renameColumn", columnId: column?.id, name: name, type: type)) { dismiss() }
                    }
                }.keyboardShortcut(.defaultAction).disabled(session.isBusy || !session.nameIsValid(name, excluding: column?.id))
            }
        }.padding(20).frame(width: 470, height: 330).interactiveDismissDisabled(session.isBusy)
            .onAppear { name = column?.name ?? ""; focused = true; session.error = nil }
    }
}
private struct AttributeTableCell: View {
    let row: AttributeRow
    let column: AttributeColumn
    @ObservedObject var session: AttributeTableSession
    @FocusState private var focused: Bool
    var body: some View {
        if column.readOnly { Text(row.value(column.id) ?? L10n.text("NULL")).textSelection(.enabled) }
        else if column.type == "Boolean" {
            Picker("Cell value", selection: Binding(get: { session.value(row: row, column: column) ?? "__null" }, set: { value in
                session.setDraft(row: row.id, column: column.id, value: value == "__null" ? nil : value)
                Task { await session.flushDrafts() }
            })) {
                Text("NULL").tag("__null"); Text("Yes").tag("True"); Text("No").tag("False")
            }.labelsHidden().disabled(session.isBusy).accessibilityLabel(column.name)
        } else {
            TextField("Cell value", text: Binding(get: { session.text(row: row, column: column) }, set: { session.setDraft(row: row.id, column: column.id, value: $0) }), prompt: row.value(column.id) == nil ? Text("NULL") : nil)
                .textFieldStyle(.plain).focused($focused).disabled(session.isBusy)
                .onSubmit { Task { await session.flushDrafts() } }
                .onExitCommand { session.clearDraft(row: row.id, column: column.id); focused = false }
                .accessibilityLabel(column.name)
        }
    }
}
