import Charts
import SwiftUI

struct SpatialPointPresentation: Decodable, Sendable {
    struct Station: Decodable, Identifiable, Sendable {
        let id: String
        let scope: String
        let name: String
        let x: Double
        let y: Double
    }
    struct Input: Decodable, Identifiable, Sendable {
        let id: String
        let scope: String
        let stationId: String?
        let pageId: String?
    }
    let stations: [Station]
    let inputs: [Input]
    let unit: String
    let isVector: Bool
    var valueUnits: DisplayUnitData? = nil
    var heightUnits: DisplayUnitData? = nil
    var intervalUnits: DisplayUnitData? = nil
    var defaultHeight: Double? = nil
}

// The five source spatial layers share station objects. Their input records
// and series remain distinct, even when they refer to the same named station.
struct SpatialPointEditor: View {
    let layer: SpatialBoundaryLayer
    let data: SpatialPointPresentation
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @State private var stationID: String?
    @State private var inputID: String?
    @State private var removeStation = false
    @State private var removeInput = false
    private var editable: Bool { session.canEdit && !session.isBusy && !session.loadingSelection && !store.isSavingAll }
    private var station: SpatialPointPresentation.Station? { data.stations.first { $0.id == stationID } }
    private var input: SpatialPointPresentation.Input? { data.inputs.first { $0.id == inputID } }
    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Shared Stations").font(.headline)
                    Spacer()
                    Button { mutate("addStation") } label: { Label("Add Station", systemImage: "plus") }.disabled(!editable)
                    Button { removeStation = true } label: { Label("Remove Station", systemImage: "minus") }.disabled(!editable || station == nil)
                }.labelStyle(.iconOnly).padding(12)
                List(selection: $stationID) {
                    ForEach(data.stations) { station in
                        Text(session.fields[station.scope + "/Name"] ?? station.name).tag(station.id)
                    }
                }.frame(minHeight: 120)
                Divider()
                HStack {
                    Text("Station Inputs").font(.headline)
                    Spacer()
                    Button { mutate("addGauge", stationID) } label: { Label("Add Input", systemImage: "plus") }.disabled(!editable || station == nil)
                    Button { removeInput = true } label: { Label("Remove Input", systemImage: "minus") }.disabled(!editable || input == nil)
                }.labelStyle(.iconOnly).padding(12)
                List(selection: $inputID) {
                    ForEach(data.inputs) { input in
                        HStack {
                            Image(systemName: session.fields[input.scope + "/IsEnabled"] == "true" ? "checkmark.circle" : "circle").foregroundStyle(.secondary)
                            Text(inputName(input))
                        }.tag(input.id)
                    }
                }.frame(minHeight: 120)
            }.frame(minWidth: 220, idealWidth: 260, maxWidth: 350)
            VSplitView {
                Form {
                    if let station {
                        Section("Shared Station") {
                            text("Name", station.scope, "Name")
                            text("X Coordinate", station.scope, "X")
                            text("Y Coordinate", station.scope, "Y")
                            if let units = data.heightUnits {
                                SpatialValueField(title: "Height Above Ground", field: station.scope + "/ElevationOffGround", units: units, session: session, unitPickerEnabled: !store.isSavingAll)
                                if session.fields[station.scope + "/ElevationOffGround"]?.isEmpty == true, let height = data.defaultHeight, let unit = session.displayUnit(units) {
                                    LabeledContent("Project Default Height", value: unit.displayed(height).formatted(.number.precision(.significantDigits(1...8))) + " " + unit.id)
                                }
                            } else { text("Height Above Ground", station.scope, "ElevationOffGround") }
                            Text("An empty height uses the project default. Coordinates use the project coordinate system.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let input { inputProperties(input) }
                    if station == nil && input == nil { Text("Add a station, then add an input for this layer.").foregroundStyle(.secondary) }
                }.formStyle(.grouped).frame(minHeight: 220, idealHeight: 290)
                if let input, input.pageId != nil {
                    TimeSeriesPage(page: .init(title: "Time Series", schemaIDs: [], layout: .timeSeries, scopePrefix: input.scope), session: session, store: store)
                        .id(input.id).frame(minHeight: 240)
                } else if !data.stations.isEmpty {
                    Chart(data.stations) { station in
                        PointMark(x: .value(L10n.text("X Coordinate"), number(station.scope, "X", station.x)), y: .value(L10n.text("Y Coordinate"), number(station.scope, "Y", station.y)))
                            .annotation(position: .top) { Text(session.fields[station.scope + "/Name"] ?? station.name).font(.caption) }
                    }.chartXAxisLabel("X Coordinate").chartYAxisLabel("Y Coordinate").padding(24).frame(minHeight: 200)
                } else {
                    Chart(data.stations) { station in
                        PointMark(x: .value(L10n.text("X Coordinate"), number(station.scope, "X", station.x)), y: .value(L10n.text("Y Coordinate"), number(station.scope, "Y", station.y)))
                    }
                    .chartXAxisLabel("X Coordinate").chartYAxisLabel("Y Coordinate")
                    .frame(minHeight: 200)
                    .overlay {
                        Label("The model source has no shared stations to plot.", systemImage: "mappin.and.ellipse")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }.frame(minWidth: 460)
        }
        .onAppear { stationID = stationID ?? data.stations.first?.id; inputID = inputID ?? data.inputs.first?.id }
        .onChange(of: data.stations.map(\.id)) { _, ids in if !ids.contains(stationID ?? "") { stationID = ids.first } }
        .onChange(of: data.inputs.map(\.id)) { _, ids in if !ids.contains(inputID ?? "") { inputID = ids.first } }
        .confirmationDialog("Remove this shared station?", isPresented: $removeStation) {
            Button("Remove Station", role: .destructive) { mutate("removeStation", stationID) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Inputs in all spatial layers will lose their station association. Their values are retained until you save or discard the draft.") }
        .confirmationDialog("Remove this station input?", isPresented: $removeInput) {
            Button("Remove Input", role: .destructive) { mutate("removeGauge", inputID) }
            Button("Cancel", role: .cancel) {}
        }
    }
    @ViewBuilder private func inputProperties(_ input: SpatialPointPresentation.Input) -> some View {
        Section("Station Input") {
            Toggle("Enabled", isOn: Binding(get: { session.fields[input.scope + "/IsEnabled"] == "true" }, set: { session.set(input.scope + "/IsEnabled", String($0)) })).disabled(!editable)
            Picker("Station", selection: binding(input.scope, "Station")) {
                Text("None").tag("")
                ForEach(data.stations) { Text(session.fields[$0.scope + "/Name"] ?? $0.name).tag($0.id) }
            }.disabled(!editable)
            options("Data Location", input.scope, "DataLocation", ["Local", "Remote"], refresh: true)
            if session.fields[input.scope + "/DataLocation"] == "Remote" {
                let connectionName = session.fields[input.scope + "/ConnectionName"] ?? ""
                let connectionIsAvailable = !connectionName.isEmpty
                    && store.document?.connections.contains(where: { $0.name == connectionName }) == true
                Picker("External Connection", selection: binding(input.scope, "ConnectionName")) {
                    Text("None").tag("")
                    ForEach(store.document?.connections ?? []) { Text($0.name).tag($0.name) }
                    if !connectionName.isEmpty && !connectionIsAvailable { Text(connectionName).tag(connectionName) }
                }.disabled(!editable)
                if connectionName.isEmpty {
                    Label("No external connection is configured; remote data cannot be read.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                } else if !connectionIsAvailable {
                    Label("The saved external connection is unavailable; remote data cannot be read. Choose another connection to repair this input.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                text("External Path", input.scope, "ConnectionPath")
                Text("The source stores this connection reference; remote station evaluation is not available.").font(.caption).foregroundStyle(.secondary)
            } else {
                let mode = session.fields[input.scope + "/LocalDataType"] ?? "Constant"
                options("Input Type", input.scope, "LocalDataType", mode == "Functional" ? ["Constant", "Table", "Functional"] : ["Constant", "Table"], refresh: true)
                if let units = data.valueUnits { LabeledContent("Display Units") { DisplayUnitPicker(units: units, session: session, isEnabled: editable) } }
                else { LabeledContent("Units", value: data.unit) }
                if mode == "Constant" {
                    constant(data.isVector ? "X Wind Velocity" : "Value", input.scope, "Constant")
                    if data.isVector { constant("Y Wind Velocity", input.scope, "Constant2") }
                } else if mode == "Table" {
                    options("Time Series Type", input.scope, "TimeSeriesType", ["Regular", "Irregular"], refresh: true)
                    if session.fields[input.scope + "/TimeSeriesType"] == "Regular" {
                        if let units = data.intervalUnits {
                            SpatialValueField(title: "Interval", field: input.scope + "/Interval", units: units, session: session, unitPickerEnabled: !store.isSavingAll, onSubmit: { mutate("refresh") })
                        } else { text("Interval (seconds)", input.scope, "Interval", refresh: true) }
                    } else { options("Time Expressed As", input.scope, "ExpressedTimeType", ["Absolute", "Relative"], refresh: true) }
                    Toggle("Use Fixed Start Time", isOn: Binding(get: { session.fields[input.scope + "/UseFixedStartTime"] == "true" }, set: {
                        session.set(input.scope + "/UseFixedStartTime", String($0)); mutate("refresh")
                    })).disabled(!editable)
                    if session.fields[input.scope + "/UseFixedStartTime"] == "true", let date = SourceTimestamp.parse(session.fields[input.scope + "/FixedStartTime"] ?? "") {
                        DatePicker("Fixed Start Time", selection: Binding(get: { date }, set: { if $0 != date { session.set(input.scope + "/FixedStartTime", ISO8601DateFormatter().string(from: $0)); mutate("refresh") } }), displayedComponents: [.date, .hourAndMinute]).disabled(!editable)
                    }
                } else {
                    Label("Functional input is not evaluated by the source. Existing saved values are retained unchanged.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func inputName(_ input: SpatialPointPresentation.Input) -> String {
        guard let id = session.fields[input.scope + "/Station"], let station = data.stations.first(where: { $0.id == id }) else { return L10n.text("Unassigned Station") }
        return session.fields[station.scope + "/Name"] ?? station.name
    }
    private func number(_ scope: String, _ key: String, _ fallback: Double) -> Double { Double(session.fields[scope + "/" + key] ?? "") ?? fallback }
    @ViewBuilder private func constant(_ title: String, _ scope: String, _ key: String) -> some View {
        if let units = data.valueUnits { SpatialValueField(title: title, field: scope + "/" + key, units: units, session: session, showUnitPicker: false) }
        else { text(title, scope, key) }
    }
    private func binding(_ scope: String, _ key: String, refresh: Bool = false) -> Binding<String> {
        Binding(get: { session.fields[scope + "/" + key] ?? "" }, set: { value in
            guard session.fields[scope + "/" + key] != value else { return }
            session.set(scope + "/" + key, value)
            if refresh { mutate("refresh") }
        })
    }
    private func text(_ title: String, _ scope: String, _ key: String, refresh: Bool = false) -> some View {
        TextField(LocalizedStringKey(title), text: binding(scope, key)).disabled(!editable)
            .onSubmit { if refresh { mutate("refresh") } }
    }
    private func options(_ title: String, _ scope: String, _ key: String, _ values: [String], refresh: Bool = false) -> some View {
        Picker(LocalizedStringKey(title), selection: binding(scope, key, refresh: refresh)) {
            ForEach(values, id: \.self) { value in
                Text(LocalizedStringKey(key == "DataLocation" ? (value == "Local" ? "Local Data" : "Remote Data") : value)).tag(value)
            }
        }.disabled(!editable)
    }
    private func mutate(_ operation: String, _ itemID: String? = nil) {
        Task {
            let oldStations = Set(data.stations.map(\.id)), oldInputs = Set(data.inputs.map(\.id))
            guard await session.perform(.editSpatial(layerID: layer.id, operation: operation, itemID: itemID)), let updated = session.spatialPresentations[layer.id]?.pointData else { return }
            if operation == "addStation" { stationID = updated.stations.first { !oldStations.contains($0.id) }?.id }
            if operation == "addGauge" { inputID = updated.inputs.first { !oldInputs.contains($0.id) }?.id }
        }
    }
}

enum SourceTimestamp {
    static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
}
