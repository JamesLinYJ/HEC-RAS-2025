import SwiftUI

// BoundaryConditionsEditor.xaml has General Options, Lines and Spatial.
// BoundaryConditionsSummary/SpatialDataSummary bind the other three summary
// navigation items to WindowManager.IsDebugMode.
enum SpatialBoundaryLayer: String, CaseIterable, Identifiable {
    case precipitation, evapotranspiration, wind, airPressure, airDensity
    var id: String { rawValue }
    var title: String {
        switch self {
        case .precipitation: "Precipitation"
        case .evapotranspiration: "Evapotranspiration"
        case .wind: "Wind Forces"
        case .airPressure: "Air Pressure"
        case .airDensity: "Air Density"
        }
    }
    var symbol: String {
        switch self {
        case .precipitation: "cloud.rain"
        case .evapotranspiration: "sun.haze"
        case .wind: "wind"
        case .airPressure: "barometer"
        case .airDensity: "aqi.medium"
        }
    }
    var schemaID: String {
        switch self {
        case .precipitation: "PrecipitationControl"
        case .evapotranspiration: "EvapotranspirationControl"
        case .wind: "WindForcesControl"
        case .airPressure: "AirPressureControl"
        case .airDensity: "AirDensityControl"
        }
    }
    var fields: [SourceEditorField] { SourceEditorLibrary.shared.schema(schemaID)?.fields ?? [] }
    var enabledField: SourceEditorField? { fields.first { $0.id.hasSuffix("_IsEnabled") } }
    var typeField: SourceEditorField? { fields.first { $0.id.hasSuffix("_SpatialDataType") } }
    // Order and restrictions are the original controls' SpatialDataTypes,
    // which are narrower than the SpatialDataType enum for evaporation.
    var defaultTypeIDs: [String] { self == .evapotranspiration ? ["Constant", "Point"] : ["Constant", "Gridded", "Point"] }
    static func visible(debug: Bool) -> [Self] { debug ? [.precipitation, .evapotranspiration, .wind, .airPressure] : [.precipitation] }
    static func available(debug: Bool, fields: [String: String]) -> [Self] {
        var result = visible(debug: debug)
        // AirDensity has a separate source page and no Debug visibility rule.
        // Show its route only when the model snapshot supplies its source field.
        if let field = Self.airDensity.enabledField, fields[field.storageID] != nil { result.append(.airDensity) }
        return result
    }
    func enabled(in values: [String: String]) -> Bool {
        enabledField.map { values[$0.storageID]?.lowercased() == "true" } ?? false
    }
    func selectedType(in values: [String: String]) -> String? {
        typeField.flatMap { values[$0.storageID] }
    }
    func typeChoices(_ supplied: [EditorChoice]?) -> [EditorChoice] {
        // An explicitly empty source option list is authoritative.
        if let supplied { return supplied }
        return defaultTypeIDs.map { EditorChoice(id: $0, title: $0 == "Gridded" ? "Grid" : $0) }
    }
    func contentFields(type: String?) -> [SourceEditorField] {
        fields.filter {
            $0.id != enabledField?.id && $0.id != typeField?.id &&
            (!$0.id.hasSuffix("_ConstantValue") || type == "Constant")
        }
    }
    @MainActor func setEnabled(_ value: Bool, session: ModelEditorSession) {
        guard session.canEdit, !session.isBusy, let field = enabledField, session.fields[field.storageID] != nil else { return }
        session.set(field.storageID, String(value))
    }
    @MainActor func selectType(_ value: String, session: ModelEditorSession) {
        guard session.canEdit, !session.isBusy, let field = typeField, session.fields[field.storageID] != nil,
              typeChoices(session.choiceOptions[field.storageID]).contains(where: { $0.id == value }) else { return }
        session.set(field.storageID, value)
    }
}

struct BoundaryGeneralPage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    let navigateToLines: () -> Void
    let navigateToSpatial: (SpatialBoundaryLayer) -> Void
    private var fields: [SourceEditorField] { SourceEditorLibrary.shared.schema("BoundaryConditionsSummary")?.fields ?? [] }
    var body: some View {
        Form {
            Section("Boundary Condition") { BoundaryCatalogFields(session: session, store: store) }
            Section("Time Window") { BoundaryTimeWindowField(session: session, store: store) }
            Section("Warm Up") { field("_WarmupTime") }
            Section("Description") {
                if let description = BoundaryFieldReferences.find(suffix: "_Description", schemas: ["BoundaryConditionCatalogSummary", "BoundaryConditionsSummary"], values: session.fields) {
                    SourceField(field: description, session: session, store: store)
                }
                field("_EmbeddedImages")
            }
            Section("Boundary Lines") {
                Button(action: navigateToLines) { Label("Boundary Lines", systemImage: "point.topleft.down.curvedto.point.bottomright.up") }
            }
            Section("Spatial") {
                ForEach(SpatialBoundaryLayer.available(debug: store.isDebugMode, fields: session.fields)) { layer in
                    HStack {
                        Button { navigateToSpatial(layer) } label: {
                            Label(LocalizedStringKey(layer.title), systemImage: layer.symbol)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        SpatialEnabledToggle(layer: layer, session: session)
                    }
                }
            }
        }.formStyle(.grouped)
    }
    @ViewBuilder private func field(_ suffix: String) -> some View {
        if let field = fields.first(where: { $0.id.hasSuffix(suffix) }) {
            SourceField(field: field, session: session, store: store)
        }
    }
}

struct BoundarySpatialPage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @Binding var target: SpatialBoundaryLayer?
    var body: some View {
        ScrollViewReader { proxy in
            Form {
                ForEach(SpatialBoundaryLayer.available(debug: store.isDebugMode, fields: session.fields)) { layer in
                    SpatialBoundarySection(layer: layer, session: session, store: store).id(layer.id)
                }
            }
            .formStyle(.grouped)
            .onAppear { scrollToTarget(proxy) }
            .onChange(of: target) { _, _ in scrollToTarget(proxy) }
        }
    }
    private func scrollToTarget(_ proxy: ScrollViewProxy) {
        guard let target, SpatialBoundaryLayer.available(debug: store.isDebugMode, fields: session.fields).contains(target) else { return }
        proxy.scrollTo(target.id, anchor: .top)
    }
}

struct SpatialBoundaryControlPage: View {
    let layer: SpatialBoundaryLayer
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    var body: some View { Form { SpatialBoundarySection(layer: layer, session: session, store: store) }.formStyle(.grouped) }
}

private struct SpatialEnabledToggle: View {
    let layer: SpatialBoundaryLayer
    @ObservedObject var session: ModelEditorSession
    var body: some View {
        Toggle(LocalizedStringKey(layer.title), isOn: Binding(get: { layer.enabled(in: session.fields) }, set: {
            layer.setEnabled($0, session: session)
        }))
        .labelsHidden().toggleStyle(.switch)
        .disabled(!session.canEdit || session.isBusy || layer.enabledField.flatMap { session.fields[$0.storageID] } == nil)
    }
}

private struct SpatialBoundarySection: View {
    let layer: SpatialBoundaryLayer
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    private var type: String? { layer.selectedType(in: session.fields) }
    @State private var editDataset = false
    @State private var pendingImport: ToolKind?
    @State private var importProjectID: UUID?
    @State private var importAssetID: String?
    var body: some View {
        Section {
            HStack {
                Label(LocalizedStringKey(layer.title), systemImage: layer.symbol).font(.headline)
                Spacer()
                SpatialEnabledToggle(layer: layer, session: session)
            }
            if let field = layer.typeField {
                let choices = layer.typeChoices(session.choiceOptions[field.storageID])
                if layer == .airPressure {
                    AirPressureHeaderView(
                        choices: choices,
                        selectedType: Binding(get: { type ?? "" }, set: { layer.selectType($0, session: session) }),
                        isEnabled: layer.enabled(in: session.fields) && session.canEdit && !session.isBusy && session.fields[field.storageID] != nil
                    )
                } else {
                    Picker("Spatial Data Type", selection: Binding(get: { type ?? "" }, set: { layer.selectType($0, session: session) })) {
                        if type == nil { Text("None").tag("") }
                        ForEach(choices) { choice in
                            Text(choice.titleIsUserData == true ? choice.title : L10n.text(choice.title)).tag(choice.id)
                        }
                        if let type, !choices.contains(where: { $0.id == type }) { Text(type).tag(type) }
                    }
                    .disabled(!layer.enabled(in: session.fields) || !session.canEdit || session.isBusy || choices.isEmpty || session.fields[field.storageID] == nil)
                }
            }
            ForEach(layer.contentFields(type: type)) { field in
                if field.id.hasSuffix("_ConstantValue"), let units = session.spatialPresentations[layer.id]?.pointData?.valueUnits {
                    SpatialValueField(title: field.title, field: field.storageID, units: units, session: session,
                        minimum: field.minimum, maximum: field.maximum,
                        sourceFieldCanEdit: { field.canEditDraft(in: session) && !store.isSavingAll })
                        .disabled(store.isSavingAll)
                } else { SourceField(field: field, session: session, store: store) }
            }
            if layer == .wind, type == "Constant" {
                WindConstantControlView(session: session, store: store, layer: layer)
            }
            if type == "Point" {
                GeometryPointControlWorkspaceView(layer: layer, session: session, store: store)
                    .frame(minHeight: 420)
                HStack {
                    Label("Spatial Data Browser", systemImage: "map")
                    Spacer()
                    Button("Edit Spatial Data…") { editDataset = true }
                }
            } else if type == "Gridded" {
                HStack {
                    Label("Gridded Data", systemImage: "square.grid.3x3")
                    Spacer()
                    Button("Edit Spatial Data…") { editDataset = true }
                }
            }
        }
        .sheet(isPresented: $editDataset, onDismiss: {
            defer { pendingImport = nil; importProjectID = nil; importAssetID = nil }
            guard let tool = pendingImport, importProjectID == store.projectSessionID, importAssetID == session.modelAssetID else { return }
            store.startSpatialImport(layerID: layer.id, assetID: importAssetID, tool: tool, editorID: session.id)
        }) {
            SpatialDatasetPage(layer: layer, session: session, store: store, showsPointEditor: false, requestImport: { tool in
                pendingImport = tool; importProjectID = store.projectSessionID; importAssetID = session.modelAssetID; editDataset = false
            }).frame(minWidth: 900, minHeight: 580)
        }
    }
}

