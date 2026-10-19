import SwiftUI

// RasterCalculatorEditor has independent input/constant collections, expression,
// NoData policy, keyframe information, preview, add-to-map and save-existing.
// Every operation carries the current editor draft through the tool contract.
struct RasterCalculatorContent: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var state: DataToolSession
    @ObservedObject var editor: ModelEditorSession
    let current: Bool
    let prepare: () -> Void
    let perform: (DataToolOperation, String?) -> Void
    @State private var inputID: String?
    @State private var constantID: String?
    private let inputTable = "RasterCalculatorEditor/Inputs"
    private let constantTable = "RasterCalculatorEditor/Constants"
    private let expressionID = "RasterCalculatorEditor/Expression"
    private var inputColumns: [SourceTableColumn] {
        editor.tablePresentations[inputTable]?.columns.filter { $0.visible != false } ?? [
            .init(id: "VariableName", title: "Variable", sourceType: "string"),
            .init(id: "SelectedLayerName", title: "Layer", sourceType: "string", readOnly: true),
            .init(id: "NdvSummary", title: "NoData", sourceType: "string", readOnly: true)]
    }
    private var constants: [SourceTableColumn] {
        editor.tablePresentations[constantTable]?.columns.filter { $0.visible != false } ?? [
            .init(id: "Name", title: "Name", sourceType: "string"), .init(id: "Value", title: "Value", sourceType: "string")]
    }
    private var selectedInput: EditorRow? { editor.rows[inputTable]?.first { $0.id == inputID } }
    private var noDataChoices: [EditorChoice] { editor.choiceOptions["RasterCalculatorEditor/NdvBehavior"] ?? [] }
    private var noDataValue: String { editor.fields["RasterCalculatorEditor/NdvBehavior"] ?? "" }
    private var enabled: Bool { editor.canEdit && !state.busy && store.toolProvider != nil }
    var body: some View {
        HSplitView {
            VSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    collectionHeader("Input Layers", table: inputTable, selection: inputID, add: .addInput, remove: .removeInput)
                    Table(editor.rows[inputTable] ?? [], selection: $inputID) {
                        TableColumnForEach(inputColumns) { column in
                            TableColumn(column.titleIsUserData == true ? column.title : L10n.text(column.title)) { (row: EditorRow) in
                                TableCell(column: column, rowID: row.id, tableID: inputTable, session: editor, store: store)
                            }.width(min: 80, ideal: column.width ?? 150)
                        }
                    }
                    if let row = selectedInput {
                        RasterCalculatorInputOptionsView(row: row, editor: editor, store: store, tableID: inputTable)
                    }
                }.frame(minHeight: 190)
                VStack(alignment: .leading, spacing: 0) {
                    collectionHeader("Named Constants", table: constantTable, selection: constantID, add: .addConstant, remove: .removeConstant)
                    Table(editor.rows[constantTable] ?? [], selection: $constantID) {
                        TableColumnForEach(constants) { column in
                            TableColumn(L10n.text(column.title)) { (row: EditorRow) in
                                TableCell(column: column, rowID: row.id, tableID: constantTable, session: editor, store: store)
                            }
                        }
                    }
                    Text("Built-in: ndv, pi, e, tau. Inputs with a non-default NoData also expose <var>_ndv.")
                        .font(.caption).foregroundStyle(.secondary).padding(12)
                }.frame(minHeight: 150)
            }.frame(minWidth: 320, idealWidth: 440)
            VSplitView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Expression").font(.headline)
                    TextEditor(text: Binding(get: { editor.fields[expressionID] ?? "" }, set: { editor.set(expressionID, $0) }))
                        .font(.system(.body, design: .monospaced)).frame(minHeight: 90)
                        .disabled(!enabled || editor.fields[expressionID] == nil).accessibilityLabel("Expression")
                    Form {
                        Picker("NoData Behavior", selection: Binding(get: { noDataValue }, set: { editor.set("RasterCalculatorEditor/NdvBehavior", $0) })) {
                            ForEach(noDataChoices) { choice in Text(L10n.text(choice.title)).tag(choice.id) }
                            if !noDataChoices.contains(where: { $0.id == noDataValue }) {
                                Text(noDataValue.isEmpty ? L10n.text("None") : noDataValue).tag(noDataValue)
                            }
                        }.disabled(!enabled || editor.choiceOptions["RasterCalculatorEditor/NdvBehavior"] == nil)
                    }.formStyle(.columns)
                    if let information = editor.fields["RasterCalculatorEditor/KeyFrameInfo"], !information.isEmpty {
                        Label(information, systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = editor.fields["RasterCalculatorEditor/ErrorMessage"], !error.isEmpty {
                        Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                    HStack {
                        Button("Preview", action: prepare).disabled(!enabled)
                        Spacer()
                        if editor.fields["RasterCalculatorEditor/IsEditingExisting"] == "true" {
                            Button("Save to Existing") { perform(.saveExisting, nil) }.disabled(!enabled || !state.presentation.canExecute || !current)
                        } else {
                            Button("Add to Map") { perform(.addToMap, nil) }.buttonStyle(.glassProminent).disabled(!enabled || !state.presentation.canExecute || !current)
                        }
                    }
                }.padding(16).frame(minHeight: 230)
                DataToolPreviewView(preview: state.presentation.preview, loading: state.preparing, isCurrent: current).frame(minHeight: 180)
            }.frame(minWidth: 360)
        }
        .onChange(of: editor.rows[inputTable]?.map(\.id)) { _, ids in if let inputID, !(ids ?? []).contains(inputID) { self.inputID = nil } }
        .onChange(of: editor.rows[constantTable]?.map(\.id)) { _, ids in if let constantID, !(ids ?? []).contains(constantID) { self.constantID = nil } }
    }
    private func collectionHeader(_ title: String, table: String, selection: String?, add: DataToolOperation, remove: DataToolOperation) -> some View {
        HStack {
            Text(LocalizedStringKey(title)).font(.headline)
            Spacer()
            ControlGroup {
                Button { perform(add, nil) } label: { Label("Add", systemImage: "plus") }.disabled(!enabled || editor.tablePresentations[table]?.canAddRows != true)
                Button(role: .destructive) { if let selection { perform(remove, selection) } } label: { Label("Remove", systemImage: "minus") }
                    .disabled(!enabled || selection == nil || editor.tablePresentations[table]?.canDeleteRows != true)
            }.labelStyle(.iconOnly)
        }.padding(12)
    }
}

private struct RasterCalculatorInputOptionsView: View {
    let row: EditorRow
    @ObservedObject var editor: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    let tableID: String
    @State private var localExpanded = false

    private var sourceExpanded: Bool? { row.values["OptionsExpanded"].map { $0.lowercased() == "true" } }
    private var isResultMap: Bool { row.values["IsResultMap"]?.lowercased() == "true" }
    private var isShown: Bool { row.values["ShowOptions"]?.lowercased() != "false" }
    private var optionColumns: [SourceTableColumn] {
        editor.tablePresentations[tableID]?.columns.filter { column in
            guard column.visible != false,
                  ["SelectedLayerType", "SelectedLayer", "SelectedMapType", "IsKeyFrame", "ForceHorizontal"].contains(column.id)
            else { return false }
            return isResultMap || !["SelectedMapType", "IsKeyFrame"].contains(column.id)
        } ?? []
    }

    var body: some View {
        if isShown {
            DisclosureGroup(isExpanded: Binding(get: { sourceExpanded ?? localExpanded }, set: setExpanded)) {
                Form {
                    ForEach(optionColumns) { column in
                        LabeledContent(LocalizedStringKey(column.title)) {
                            TableCell(column: column, rowID: row.id, tableID: tableID, session: editor, store: store)
                        }
                    }
                }.formStyle(.columns)
            } label: {
                Text("Input Options")
            }
            .padding(12)
        }
    }

    private func setExpanded(_ value: Bool) {
        localExpanded = value
        if let field = row.fieldBindings["OptionsExpanded"] {
            editor.set(field, String(value))
        } else if row.values["OptionsExpanded"] != nil {
            editor.setCell(table: tableID, rowID: row.id, column: "OptionsExpanded", value: String(value))
        }
    }
}
