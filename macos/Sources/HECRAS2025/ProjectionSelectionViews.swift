import MapKit
import SwiftUI

// NewProjectPage and the project projection sheet share source evaluation,
// EPSG search and the geographic finder; editing text alone never validates it.
struct ProjectProjectionFields: View {
    @Binding var definition: ProjectionDefinitionDraft
    @ObservedObject var session: ProjectProjectionSession
    @ObservedObject var store: WorkspaceStore
    @State private var finding = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Definition", selection: Binding(get: { definition.type }, set: { definition.selectType($0) })) {
                ForEach(["Local", "EPSG", "Proj", "WKT", "ESRI"], id: \.self) { Text(L10n.text($0)).tag($0) }
            }
            if definition.type == "Local" {
                Picker("Unit System", selection: $definition.value) { Text("SI (metric)").tag("SI"); Text("US Customary").tag("USC") }
            } else if definition.type == "EPSG" {
                TextField("EPSG code", text: $definition.value)
            } else if definition.type == "ESRI" {
                TextField("PRJ File", text: $definition.value)
                    .dropDestination(for: URL.self) { urls, _ in _ = acceptFile(urls.first) }
            } else {
                TextEditor(text: $definition.value).font(.system(.body, design: .monospaced)).frame(minHeight: 100, maxHeight: 180).accessibilityLabel("Projection definition")
            }
            HStack {
                Button("Find Coordinate System…") { finding = true }.disabled(store.projectionProvider == nil)
                Button("Read PRJ File…") { _ = acceptFile(store.system.chooseProjectionFile()) }
            }
            ProjectionEvaluationView(definition: definition, session: session)
        }
        .sheet(isPresented: $finding) {
            ProjectionSearchView(provider: store.projectionProvider) { match in
                definition = .init(type: "EPSG", value: String(match.code)); finding = false
            }
        }
        .task(id: definition) { await session.evaluate(definition, provider: store.projectionProvider) }
        .onDisappear { session.invalidate() }
    }
    private func acceptFile(_ url: URL?) -> Bool {
        guard let url, url.isFileURL else { return false }
        definition = .init(type: "ESRI", value: url.path)
        return true
    }
}

private struct ProjectionEvaluationView: View {
    let definition: ProjectionDefinitionDraft
    @ObservedObject var session: ProjectProjectionSession
    var body: some View {
        if session.loading { ProgressView("Checking coordinate system…").controlSize(.small) }
        if let evaluation = session.current(definition) {
            if evaluation.isValid {
                Label("Coordinate system is valid", systemImage: "checkmark.circle").foregroundStyle(.green)
            } else {
                Label("This coordinate system cannot be used by the project.", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                if let error = evaluation.error { Text(L10n.text(error)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            if let validity = evaluation.validity {
                LabeledContent("Validity", value: localizedProjectionValidity(validity)).textSelection(.enabled)
            }
            LabeledContent("Name", value: definition.type == "Local" ? L10n.text("Local") : evaluation.name).textSelection(.enabled)
            if let unitName = evaluation.unitName {
                LabeledContent("Units", value: unitName).textSelection(.enabled)
            }
            if let isProjected = evaluation.isProjected {
                LabeledContent("Projected", value: L10n.text(isProjected ? "Yes" : "No"))
            }
            if let isVertical = evaluation.isVertical {
                LabeledContent("Vertical", value: L10n.text(isVertical ? "Yes" : "No"))
            }
            if let code = evaluation.epsgCode { LabeledContent("EPSG Code", value: String(code)).textSelection(.enabled) }
            if let zone = evaluation.utmZone { LabeledContent("UTM Zone", value: String(abs(zone)) + (zone > 0 ? " N" : " S")) }
            if evaluation.validity != nil || evaluation.areaOfUse != nil {
                ProjectionAreaOfUseSummary(areaOfUse: evaluation.areaOfUse, projectedUnitName: evaluation.unitName)
            }
            if evaluation.isValid, let wkt = evaluation.wkt {
                DisclosureGroup("Definition Details") { ScrollView { Text(wkt).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 130) }
            }
        }
        if let error = session.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
    }
}

@MainActor
func localizedProjectionValidity(_ value: String?) -> String {
    guard let value else { return "—" }
    switch value {
    case "Valid", "Unsupported", "Corrupt":
        return L10n.text(value)
    default:
        return value
    }
}

struct ProjectionAreaOfUseSummary: View {
    let areaOfUse: ProjectionAreaOfUse?
    let projectedUnitName: String?

    var body: some View {
        GroupBox(L10n.text("Area of Use")) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("Geographic Area of Use"))
                        .font(.subheadline.weight(.semibold))
                    boundsRows(areaOfUse?.geographic, unit: L10n.text("Deg"))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("Projected Area of Use"))
                        .font(.subheadline.weight(.semibold))
                    boundsRows(areaOfUse?.projected, unit: projectedUnitName)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func boundsRows(_ bounds: ProjectionAreaBounds?, unit: String?) -> some View {
        boundRow("Left", value: bounds?.left, unit: unit)
        boundRow("Right", value: bounds?.right, unit: unit)
        boundRow("Top", value: bounds?.top, unit: unit)
        boundRow("Bottom", value: bounds?.bottom, unit: unit)
    }

    private func boundRow(_ label: String, value: Double?, unit: String?) -> some View {
        let valueText: String
        if let value, value.isFinite {
            let number = String(value).replacingOccurrences(of: ".", with: Locale.current.decimalSeparator ?? ".")
            if let unit, !unit.isEmpty {
                valueText = "\(number) \(unit)"
            } else {
                valueText = number
            }
        } else {
            valueText = L10n.text("Could not establish")
        }
        return LabeledContent(L10n.text(label), value: valueText)
            .font(.caption)
            .textSelection(.enabled)
    }
}

struct ProjectionSearchView: View {
    let provider: (any ProjectionProvider)?
    let choose: (ProjectionMatch) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = ProjectionSearchSession()
    @State private var mode = "Name"
    @State private var text = ""
    @State private var longitude = "-121.74"
    @State private var latitude = "38.55"
    @State private var position: MapCameraPosition = .region(.init(center: .init(latitude: 38.55, longitude: -121.74), span: .init(latitudeDelta: 0.1, longitudeDelta: 0.1)))
    private var request: ProjectionSearchQuery? {
        if mode == "Name" { return .init(query: text) }
        guard let lon = Double(longitude), let lat = Double(latitude), lon.isFinite, lat.isFinite else { return nil }
        return .init(longitude: lon, latitude: lat)
    }
    private var matches: [ProjectionMatch] { state.results(for: request) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Find Coordinate System").font(.title2.weight(.semibold))
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Picker("Search Method", selection: $mode) { Text("Code or Name").tag("Name"); Text("Map Location").tag("Location") }
                .pickerStyle(.segmented).frame(maxWidth: 400).padding(.bottom, 16)
            Divider()
            HSplitView {
                if mode == "Location" {
                    VStack(spacing: 12) {
                        Map(position: $position, interactionModes: [.pan, .zoom])
                            .mapStyle(.standard(elevation: .flat))
                            .mapControls { MapCompass(); MapScaleView(); MapZoomStepper() }
                            .overlay { Image(systemName: "plus").font(.title2).allowsHitTesting(false).accessibilityHidden(true) }
                            .onMapCameraChange(frequency: .onEnd) { context in
                                longitude = String(format: "%.6f", context.region.center.longitude)
                                latitude = String(format: "%.6f", context.region.center.latitude)
                            }
                        HStack {
                            TextField("Longitude", text: $longitude).onSubmit(recenter)
                            TextField("Latitude", text: $latitude).onSubmit(recenter)
                            Button("Go", action: recenter).disabled(request?.validLocation != true)
                        }.textFieldStyle(.roundedBorder).padding(.horizontal, 12)
                        Text("Move the map to find projected coordinate systems covering its center.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
                    }.padding(.bottom, 12).frame(minWidth: 350, idealWidth: 420)
                }
                VStack(spacing: 12) {
                    if mode == "Name" { TextField("Search EPSG code or name", text: $text).textFieldStyle(.roundedBorder).padding([.horizontal, .top], 16) }
                    if state.loading { ProgressView("Searching coordinate systems…").controlSize(.small) }
                    List(matches) { match in
                        Button { choose(match) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(match.name).font(.headline)
                                Text(match.authority + ":" + String(match.code)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                if let area = match.area { Text(area).font(.caption).foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }.overlay {
                        if !state.loading, matches.isEmpty {
                            ContentUnavailableView("No matching coordinate systems", systemImage: "globe", description: Text(mode == "Name" ? "Search by EPSG code or coordinate system name." : "Enter valid longitude and latitude."))
                        }
                    }
                    if let error = state.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal, 16) }
                }.frame(minWidth: 330, maxWidth: .infinity)
            }
        }.frame(width: mode == "Location" ? 920 : 620, height: 600)
        .task(id: request) { await state.search(request, provider: provider) }
        .onDisappear { state.invalidate() }
    }
    private func recenter() {
        guard let request, request.validLocation, let lon = request.longitude, let lat = request.latitude else { return }
        position = .region(.init(center: .init(latitude: lat, longitude: lon), span: .init(latitudeDelta: 0.1, longitudeDelta: 0.1)))
    }
}
