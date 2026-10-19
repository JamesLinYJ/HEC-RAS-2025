import Foundation
import SwiftUI

// Stable original object identities scope fields, rows and chart samples.
// Source adapters supply the actual collection, names, types and capabilities.
struct BoundaryPayloadPresentation: Identifiable, Sendable {
    let id: String
    let scope: String
    let name: String
    let friendlyName: String
    let editorSchemaID: String
    let isHydraulic: Bool
    let isEnabled: Bool
    var valueUnits: DisplayUnitData? = nil
    var canDelete = false
    func field(_ suffix: String) -> SourceEditorField? {
        SourceEditorLibrary.shared.schema("PayloadListItem")?.fields.first { $0.id.hasSuffix(suffix) }?.inScope(scope)
    }
    var page: ModelEditorPage? {
        let chartSchemas = ["RegularTimeSeriesPayloadEditor", "IrregularTimeSeriesPayloadEditor", "RegularSpatiallyVariableTimeSeriesPayloadEditor"]
        if editorSchemaID == "RatingCurvePayloadEditor" { return ModelEditorPage(title: "Time Series", schemaIDs: [], layout: .timeSeries, scopePrefix: scope) }
        guard chartSchemas.contains(editorSchemaID) || ["ConstantPayloadEditor", "ExternalPayloadEditor"].contains(editorSchemaID) else { return nil }
        return ModelEditorPage(title: chartSchemas.contains(editorSchemaID) ? "Time Series" : "Properties", schemaIDs: [editorSchemaID], layout: chartSchemas.contains(editorSchemaID) ? .timeSeries : .form, scopePrefix: scope)
    }
}

struct NewPayloadPresentation: Sendable {
    let fields: [String: String]
    var choices: [String: [EditorChoice]] = [:]
    var constantUnits: [String: String] = [:]
    var constantValueUnits: [String: DisplayUnitData] = [:]
}

struct BoundaryLinePresentation: Identifiable, Sendable {
    let id: String
    let scope: String
    let name: String
    let payloads: [BoundaryPayloadPresentation]
    var selectedPayloadID: String? = nil
    var activeHydraulicPayloadID: String? = nil
    var newPayload: NewPayloadPresentation? = nil
    var geometry: [BoundaryLineCoordinate]? = nil
    var nameField: SourceEditorField? {
        SourceEditorLibrary.shared.schema("DetailedBCLineHeaderControl")?.fields.first { $0.id.hasSuffix("_Name") }?.inScope(scope)
    }
}

struct BoundaryLinesPresentation: Sendable {
    let lines: [BoundaryLinePresentation]
    var selectedLineID: String? = nil
    func validate() throws {
        let scopes = lines.flatMap { [$0.scope] + $0.payloads.map(\.scope) }
        guard Set(lines.map(\.id)).count == lines.count,
              Set(scopes).count == scopes.count, scopes.allSatisfy({ !$0.isEmpty }),
              selectedLineID == nil || lines.contains(where: { $0.id == selectedLineID }),
              lines.allSatisfy({ line in
                  Set(line.payloads.map(\.id)).count == line.payloads.count &&
                  (line.selectedPayloadID == nil || line.payloads.contains { $0.id == line.selectedPayloadID }) &&
                  (line.activeHydraulicPayloadID == nil || line.payloads.contains { $0.id == line.activeHydraulicPayloadID && $0.isHydraulic })
              }) else { throw BoundaryPresentationError.ambiguousIdentity }
    }
    func selecting(lineID: String?, payloadIDs: [String: String]) -> Self {
        var result = self; result.selectedLineID = lineID
        result = Self(lines: lines.map { line in
            var result = line; result.selectedPayloadID = payloadIDs[line.id]; return result
        }, selectedLineID: lineID)
        return result
    }
}

private enum BoundaryPresentationError: LocalizedError {
    case ambiguousIdentity
    var errorDescription: String? { "Boundary line data contains ambiguous object identities." }
}

struct BoundaryLinesPage: View {
    let page: ModelEditorPage
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @State private var creating: BoundaryLinePresentation?
    @State private var quickEditingLineID: String?
    @State private var boundaryVisualContext: BoundaryLineVisualContext?
    @State private var boundaryVisualContextError: String?
    @State private var visualSettingsRoute: BoundaryLineVisualSettingsRoute?
    private var line: BoundaryLinePresentation? { session.selectedBoundaryLine }
    private var payload: BoundaryPayloadPresentation? { session.selectedBoundaryPayload }
    private var boundaryVisualIdentity: String { store.boundaryLineVisualSettingsIdentity(for: session) }
    private var boundaryVisualLoadIdentity: String {
        "\(boundaryVisualIdentity)|global-style-\(store.vectorStyleRevision)"
    }
    private var boundaryMapStyle: BoundaryLineMapStyle {
        boundaryVisualContext.flatMap { BoundaryLineMapStyle(settings: $0.settings) } ?? .sourceDefault
    }
    private var boundaryStyleHelp: String {
        boundaryVisualContextError ?? (boundaryVisualContext == nil
            ? "Boundary line styling is available only for the active Project or Buildable map."
            : "Edit boundary line symbology for the current map.")
    }
    var body: some View {
        HSplitView {
            VSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    Label("Lines", systemImage: "point.topleft.down.curvedto.point.bottomright.up").font(.headline).padding(12)
                    List(session.boundaryLines?.lines ?? [], selection: Binding(get: { session.selectedBoundaryLineID }, set: { value in
                        session.selectBoundaryLine(value)
                        quickEditingLineID = nil
                    })) { line in
                        HStack(spacing: 8) {
                            Text(session.boundaryLineName(line))
                            Spacer(minLength: 4)
                            Button {
                                session.selectBoundaryLine(line.id)
                                quickEditingLineID = line.id
                            } label: {
                                Image(systemName: "slider.horizontal.3")
                            }
                            .buttonStyle(.borderless)
                            .help(L10n.text("Quick Edit"))
                            .disabled((line.geometry?.count ?? 0) < 2 || !session.canEdit || session.isBusy)
                        }
                        .tag(line.id)
                    }.listStyle(.inset)
                }.frame(minHeight: 120)
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Label("Conditions", systemImage: "water.waves").font(.headline)
                        Spacer()
                        Button { creating = line } label: { Label("Add Payload", systemImage: "plus") }
                            .labelStyle(.iconOnly).disabled(line?.newPayload == nil || !session.canEdit || session.isBusy)
                    }.padding(12)
                    if let line {
                        List(selection: Binding(get: { session.selectedBoundaryPayloadIDs[line.id] }, set: { session.selectBoundaryPayload($0, lineID: line.id) })) {
                            Section("Hydraulic") {
                                ForEach(line.payloads.filter(\.isHydraulic)) { payload in
                                    HStack(alignment: .top, spacing: 8) {
                                        Toggle("Enabled", isOn: Binding(get: { session.boundaryPayloadEnabled(payload) }, set: { session.setBoundaryPayloadEnabled($0, lineID: line.id, payloadID: payload.id) }))
                                            .labelsHidden().toggleStyle(.checkbox).disabled(!session.canEdit || session.isBusy)
                                        VStack(alignment: .leading, spacing: 3) {
                                            DoubleClickText(title: "Name", text: Binding(get: { session.boundaryPayloadName(payload) }, set: { session.renameBoundaryPayload($0, lineID: line.id, payloadID: payload.id) }), prompt: Text("—"), showsLabel: false)
                                                .disabled(!session.canEdit || session.isBusy)
                                            Text(L10n.text(payload.friendlyName)).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }.tag(payload.id)
                                }
                            }
                        }.listStyle(.inset)
                    } else {
                        ContentUnavailableView("No Line Selected", systemImage: "cursorarrow.click")
                    }
                }.frame(minHeight: 160)
            }.frame(minWidth: 160, idealWidth: 190, maxWidth: 240)
            VSplitView {
                BoundaryLineMapWorkspace(
                    lines: session.boundaryLines?.lines ?? [],
                    selectedLineID: session.selectedBoundaryLineID,
                    quickEditingLineID: $quickEditingLineID,
                    session: session,
                    onCreate: { target in
                        creating = target
                        quickEditingLineID = nil
                    },
                    onViewPayload: { target, payloadID in
                        session.selectBoundaryLine(target.id)
                        session.selectBoundaryPayload(payloadID, lineID: target.id)
                        quickEditingLineID = nil
                    },
                    style: boundaryMapStyle,
                    canEditStyle: boundaryVisualContext != nil && boundaryVisualContextError == nil,
                    styleButtonHelp: boundaryStyleHelp,
                    styleContextError: boundaryVisualContextError,
                    onEditStyle: openBoundaryLineStyleEditor
                )
                .frame(minHeight: 190, idealHeight: 265)
                VStack(spacing: 0) {
                    if let line {
                        Form {
                            BoundaryLineNameField(line: line, session: session)
                        }.formStyle(.columns).padding(12).fixedSize(horizontal: false, vertical: true)
                        Divider()
                        if let payload {
                            HStack {
                                if let name = payload.field("_Name") {
                                    TextField("Name", text: Binding(get: { session.boundaryPayloadName(payload) }, set: { session.set(name.storageID, $0) }))
                                        .textFieldStyle(.plain).font(.headline).disabled(!session.canEdit || session.isBusy)
                                } else { Text(payload.name).font(.headline) }
                                Spacer()
                                Button(role: .destructive) { Task { await session.perform(.removeBoundaryPayload(lineID: line.id, payloadID: payload.id)) } } label: { Label("Delete Payload", systemImage: "trash") }
                                    .labelStyle(.iconOnly).disabled(!payload.canDelete || !session.canEdit || session.isBusy)
                            }.padding(12)
                            if session.fields[payload.scope + "/PayloadDetails/Variable"] != nil {
                                DisclosureGroup("Payload Details") {
                                    Form {
                                        LabeledContent("Variable", value: session.fields[payload.scope + "/PayloadDetails/Variable"] ?? "")
                                        TextField("Description", text: Binding(get: { session.fields[payload.scope + "/PayloadDetails/Description"] ?? "" }, set: { session.set(payload.scope + "/PayloadDetails/Description", $0) }), axis: .vertical)
                                            .lineLimit(2...4).disabled(!session.canEdit || session.isBusy)
                                    }.formStyle(.grouped).frame(minHeight: 100, idealHeight: 150, maxHeight: 180)
                                }.padding(.horizontal, 12).padding(.bottom, 8)
                            }
                            if let page = payload.page {
                                if page.layout == .timeSeries {
                                    TimeSeriesPage(page: page, session: session, store: store, boundaryInspectorLayout: true)
                                        .id(payload.scope)
                                } else if payload.editorSchemaID == "ConstantPayloadEditor",
                                          let field = SourceEditorLibrary.shared.schema("ConstantPayloadEditor")?.fields.first,
                                          let units = payload.valueUnits {
                                    Form {
                                        SpatialValueField(title: field.title, field: field.inScope(payload.scope).storageID,
                                            units: units, session: session, showUnitPicker: false)
                                    }
                                    .formStyle(.grouped)
                                    .id(payload.scope)
                                } else {
                                    SourceForm(page: page, session: session, store: store).id(payload.scope)
                                }
                            } else if payload.friendlyName == "Functional" {
                                FunctionalPayloadEditor(payload: payload)
                            } else { ContentUnavailableView("No editor available for this payload", systemImage: "doc.badge.questionmark") }
                        } else { ContentUnavailableView("No Condition Selected", systemImage: "cursorarrow.click") }
                    } else {
                        ContentUnavailableView(session.boundaryLines == nil ? "Model data unavailable" : "No Line Selected", systemImage: "cursorarrow.click")
                    }
                }.frame(maxWidth: .infinity, minHeight: 210, maxHeight: .infinity)
            }.frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(item: $creating) { line in
            if let presentation = line.newPayload { NewBoundaryPayloadSheet(line: line, presentation: presentation, session: session, store: store) }
        }
        .sheet(item: $visualSettingsRoute) { route in
            BoundaryLineVisualSettingsEditor(
                store: store,
                session: session,
                context: route.context,
                settings: route.settings,
                globalDefaults: route.context.globalDefaults,
                onSaved: loadBoundaryVisualContext
            )
        }
        .task(id: boundaryVisualLoadIdentity) { loadBoundaryVisualContext() }
        .onChange(of: boundaryVisualIdentity) { _, _ in visualSettingsRoute = nil }
    }

    private func openBoundaryLineStyleEditor() {
        guard boundaryVisualContextError == nil, let context = boundaryVisualContext else { return }
        visualSettingsRoute = .init(id: boundaryVisualIdentity, context: context, settings: context.settings)
    }

    private func loadBoundaryVisualContext() {
        do {
            let context = try store.boundaryLineVisualContext(for: session)
            if let context, BoundaryLineMapStyle(settings: context.settings) == nil {
                boundaryVisualContext = nil
                boundaryVisualContextError = "The current map contains an invalid boundary line symbology value."
            } else {
                boundaryVisualContext = context
                boundaryVisualContextError = nil
            }
        } catch {
            boundaryVisualContext = nil
            boundaryVisualContextError = error.localizedDescription
        }
    }
}

struct PayloadCreationRoute: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var session: ModelEditorSession
    var body: some View {
        if session.canEdit, let line = session.selectedBoundaryLine, let presentation = line.newPayload {
            NewBoundaryPayloadSheet(line: line, presentation: presentation, session: session, store: store)
        } else {
            VStack(spacing: 18) {
                ContentUnavailableView("Select a boundary line first", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                Button("Open Boundary Conditions") { store.activeTool = nil; store.openEditor(.boundaryCondition) }.buttonStyle(.glassProminent)
                Button("Cancel", role: .cancel) { store.activeTool = nil }.keyboardShortcut(.cancelAction)
            }.padding(24).frame(width: 550, height: 330)
        }
    }
}

private struct NewBoundaryPayloadSheet: View {
    @State private var line: BoundaryLinePresentation
    @State private var presentation: NewPayloadPresentation
    @State private var sourceAssetID: String?
    @State private var addingExternalConnection = false
    @State private var connectionNamesBeforeAdd: Set<String> = []
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @StateObject private var draft: ModelEditorSession
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    init(line: BoundaryLinePresentation, presentation: NewPayloadPresentation, session: ModelEditorSession, store: WorkspaceStore) {
        _line = State(initialValue: line); _presentation = State(initialValue: presentation)
        self.session = session; self.store = store
        _sourceAssetID = State(initialValue: session.modelAssetID)
        let draft = ModelEditorSession()
        var choices = presentation.choices
        if choices["NewPayloadPage/ViewModel_HydraulicType"] == nil {
            // WellKnownPayloadVariables.HydraulicPayloadVariables, source order.
            choices["NewPayloadPage/ViewModel_HydraulicType"] = ["Flow", "Stage", "StageVelocityVelocity", "Normal Depth"].map { EditorChoice(id: $0, title: $0) }
        }
        let dataTypeKey = "NewPayloadPage/ViewModel_HydraulicDataType"
        var dataTypes = choices[dataTypeKey] ?? ["Constant", "Tabular", "SpatiallyVariableTabular", "Remote"].map { EditorChoice(id: $0, title: $0) }
        if !dataTypes.contains(where: { $0.id == "Functional" }) {
            dataTypes.append(EditorChoice(id: "Functional", title: "Functional"))
        }
        choices[dataTypeKey] = dataTypes
        draft.startDraft(EditorSnapshot(fields: presentation.fields, rows: [:], samples: [:], canEdit: true, images: [:], choiceOptions: choices))
        _draft = StateObject(wrappedValue: draft)
    }
    private var hydraulicType: String { draft.fields["NewPayloadPage/ViewModel_HydraulicType"] ?? "" }
    private var dataType: String { draft.fields["NewPayloadPage/ViewModel_HydraulicDataType"] ?? "" }
    private var variable: String { draft.fields["NewPayloadPage/ViewModel_PayloadVariable"] ?? "" }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("New Payload").font(.title2.weight(.semibold)); Spacer(); Text(session.boundaryLineName(line)).foregroundStyle(.secondary) }.padding(20)
            Form {
                field("ViewModel_PayloadName")
                field("ViewModel_PayloadVariable")
                if variable == "Hydraulic" {
                    field("ViewModel_HydraulicType")
                    if hydraulicType != "Normal Depth", hydraulicType != "StageVelocityVelocity" { field("ViewModel_HydraulicDataType") }
                    switch dataType {
                    case "Constant":
                        constantValueField
                        if let unit = presentation.constantUnits[hydraulicType] { LabeledContent("Units", value: unit) }
                    case "Tabular", "SpatiallyVariableTabular": field("ViewModel_TimeSeriesType")
                    case "Remote": field("ViewModel_SelectedExternalConnection"); field("ViewModel_Path")
                    case "Functional":
                        FunctionalPayloadCreationNotice()
                    default: EmptyView()
                    }
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }.formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    Task {
                        guard dataType != "Functional" else { return }
                        guard session.modelAssetID == sourceAssetID,
                              session.boundaryLines?.lines.first(where: { $0.id == line.id })?.scope == line.scope else {
                            error = L10n.text("The model changed. Reopen the new payload window for the current model."); return
                        }
                        if dataType == "Remote", (draft.fields["NewPayloadPage/ViewModel_SelectedExternalConnection"] ?? "").isEmpty {
                            error = L10n.text("Pick (or add) an external connection before creating this payload."); return
                        }
                        if await session.perform(.createBoundaryPayload(lineID: line.id, fields: draft.fields)) { dismiss() }
                        else {
                            error = session.error ?? L10n.text("This payload operation is unavailable.")
                            session.error = nil
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(variable == "Hydraulic" && dataType == "Functional")
            }.padding(16).disabled(session.isBusy)
        }.frame(minWidth: 560, minHeight: 450).disabled(session.isBusy)
        .sheet(isPresented: $addingExternalConnection, onDismiss: selectConnectionAddedInSheet) {
            ConnectionEditorSheet(store: store)
        }
        .onChange(of: hydraulicType) { _, value in
            if value == "Normal Depth" { draft.set("NewPayloadPage/ViewModel_HydraulicDataType", "Constant") }
            else if value == "StageVelocityVelocity" { draft.set("NewPayloadPage/ViewModel_HydraulicDataType", "SpatiallyVariableTabular") }
        }
    }
    @ViewBuilder private func field(_ id: String) -> some View {
        if id == "ViewModel_SelectedExternalConnection" {
            externalConnectionField
        } else if id == "ViewModel_Path" {
            TextField("Path", text: Binding(get: { draft.fields["NewPayloadPage/" + id] ?? "" }, set: { draft.set("NewPayloadPage/" + id, $0) }))
        } else if let field = SourceEditorLibrary.shared.schema("NewPayloadPage")?.fields.first(where: { $0.id == id }) {
            SourceField(field: field, session: draft, store: store)
        }
    }

    @ViewBuilder private var constantValueField: some View {
        let id = "ViewModel_HydraulicConstantValue"
        let storageID = "NewPayloadPage/" + id
        if let field = SourceEditorLibrary.shared.schema("NewPayloadPage")?.fields.first(where: { $0.id == id }),
           let units = presentation.constantValueUnits[hydraulicType] {
            SpatialValueField(title: field.title, field: storageID, units: units, session: draft, showUnitPicker: false)
        } else {
            field(id)
        }
    }

    private var externalConnectionField: some View {
        let storageID = "NewPayloadPage/ViewModel_SelectedExternalConnection"
        let sourceChoices = presentation.choices[storageID] ?? []
        let sourceChoiceNames = Set(sourceChoices.map(\.id))
        let current = draft.fields[storageID] ?? ""
        return HStack {
            Picker(L10n.text("External Connection"), selection: Binding(get: { draft.fields[storageID] ?? "" }, set: { draft.set(storageID, $0) })) {
                Text(L10n.text("None")).tag("")
                ForEach(sourceChoices) { choice in Text(choice.title).tag(choice.id) }
                ForEach((store.document?.connections ?? []).filter { !sourceChoiceNames.contains($0.name) }) { connection in
                    Text(connection.name).tag(connection.name)
                }
                if !current.isEmpty, !sourceChoiceNames.contains(current), store.document?.connections.contains(where: { $0.name == current }) != true {
                    Text(current).tag(current)
                }
            }
            Button {
                connectionNamesBeforeAdd = Set((store.document?.connections ?? []).map(\.name))
                addingExternalConnection = true
            } label: {
                Label(L10n.text("Add Connection…"), systemImage: "plus")
            }
            .disabled(!store.hasProject || session.isBusy)
        }
    }

    private func selectConnectionAddedInSheet() {
        guard let connection = store.document?.connections.reversed().first(where: { !connectionNamesBeforeAdd.contains($0.name) }) else { return }
        draft.set("NewPayloadPage/ViewModel_SelectedExternalConnection", connection.name)
        connectionNamesBeforeAdd = []
    }
}
