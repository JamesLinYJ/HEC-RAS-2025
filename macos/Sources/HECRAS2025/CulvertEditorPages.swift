import Charts
import SwiftUI

struct GeometryCulvertEditDraftState: Equatable {
    var values: [String: String] = [:]
    var editedMixedCoefficientFields: Set<String> = []
    var clearCommandFieldIDs: Set<String> = []
    var forceSetCommandFieldIDs: Set<String> = []

    mutating func load(_ values: [String: String]) {
        self.values = values
        editedMixedCoefficientFields = []
        clearCommandFieldIDs = []
        forceSetCommandFieldIDs = []
    }

    mutating func acceptCoefficientReset(fieldID: String, baselineValue: String) {
        values[fieldID] = baselineValue
        editedMixedCoefficientFields.remove(fieldID)
        clearCommandFieldIDs.remove(fieldID)
    }

    mutating func acceptSourceCommand(fieldID: String, value: String) {
        values[fieldID] = value
        editedMixedCoefficientFields.remove(fieldID)
        clearCommandFieldIDs.remove(fieldID)
        forceSetCommandFieldIDs.remove(fieldID)
    }

    mutating func stageClearCommand(fieldID: String) {
        values[fieldID] = ""
        clearCommandFieldIDs.insert(fieldID)
        forceSetCommandFieldIDs.remove(fieldID)
        editedMixedCoefficientFields.remove(fieldID)
    }

    mutating func stageForceSetCommand(fieldID: String, value: String) {
        values[fieldID] = value
        forceSetCommandFieldIDs.insert(fieldID)
        clearCommandFieldIDs.remove(fieldID)
    }
}

/// Native counterpart to GeometryCulvertsPage: the source barrel table,
/// selected-barrel editor, property-set routes, and source terrain profile.
struct GeometryCulvertsPage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    let navigate: (String) -> Void
    @State private var detailTab = "Properties"

    private let resultProfilePage = ModelEditorPage.table(
        "Culverts", "CulvertsEditor", "CulvertEditor"
    )

    private var detailTabSelection: Binding<String> {
        Binding(get: { detailTab }, set: { proposed in
            guard session.geometryCulvert?.hasActiveSketch != true || proposed == detailTab else { return }
            detailTab = proposed
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Culverts", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.headline)
                Spacer()
                Button("Barrel Properties") { navigate("Barrel Properties") }
                    .disabled(session.geometryCulvert == nil || session.geometryCulvert?.hasActiveSketch == true)
                Button("Opening Properties") { navigate("Opening Properties") }
                    .disabled(session.geometryCulvert == nil || session.geometryCulvert?.hasActiveSketch == true)
            }
            .padding(12)
            Divider()

            if let child = session.geometryCulvert {
                GeometryCulvertStatusBanner(child: child)
                if child.snapshot == nil && child.isLoading {
                    ProgressView("Loading culvert source data…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VSplitView {
                        GeometryCulvertTablePane(featureKind: "barrel", child: child,
                            title: "Culverts", allowsAdd: false)
                            .frame(minHeight: 180)
                        TabView(selection: detailTabSelection) {
                            GeometryCulvertEditForm(featureKind: "barrel", child: child)
                                .disabled(child.hasActiveSketch)
                                .tabItem { Text("Properties") }.tag("Properties")
                            GeometryCulvertMapView(
                                child: child,
                                lineStyle: store.effectiveGeometryVectorStyle(definitionID: "Culvert_Barrel_Symbology", session: session, nodeType: "CulvertBarrelLayer"),
                                vertexStyle: store.effectiveGeometryVectorStyle(definitionID: "Culvert_Barrel_Vertex_Symbology", session: session, nodeType: "CulvertBarrelLayer")
                            )
                                .tabItem { Text(L10n.text("Barrel Map")) }.tag("Barrel Map")
                            GeometryCulvertTerrainProfileView(child: child)
                                .tabItem { Text("Terrain Profile") }.tag("Terrain Profile")
                            GeometryDynamicProfilePlotView(
                                samples: session.samples[resultProfilePage.id] ?? [],
                                chartPresentation: session.seriesPresentations[resultProfilePage.id]?.chart,
                                selectedFeatureIDs: child.selectedFeatureIDs["barrel", default: []],
                                selectedFeatureLabel: "culvert barrels",
                                mapTypeFieldID: session.seriesPresentations[resultProfilePage.id]?.chart?.mapTypeFieldID,
                                session: session, store: store, lineSourceKind: .barrels
                            )
                            .tabItem { Text("Result Profile") }.tag("Result Profile")
                        }
                        .frame(minHeight: 240)
                    }
                }
            } else {
                ContentUnavailableView("Culvert editing is unavailable",
                    systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                    description: Text("The geometry culvert source provider is not connected."))
            }
        }
        .task(id: store.geometryVectorStyleContextIdentity) {
            await store.refreshVectorSymbologyContexts(mapID: store.lastActiveMapID)
        }
        .task(id: session.geometryCulvertIdentity) {
            await session.ensureGeometryCulvertLoaded()
        }
        .onChange(of: session.modelAssetID) { _, _ in
            guard session.geometryCulvert?.hasActiveSketch != true else { return }
            detailTab = "Properties"
        }
    }
}

struct GeometryCulvertPropertiesPage: View {
    let page: ModelEditorPage
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    let navigate: (String) -> Void

    private var featureKind: String {
        page.title == "Barrel Properties" ? "barrelProperties" : "openingProperties"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { navigate("Culverts") } label: {
                    Label("Culverts", systemImage: "chevron.backward")
                }
                .disabled(session.geometryCulvert?.hasActiveSketch == true)
                Spacer()
                Button(LocalizedStringKey(page.title == "Barrel Properties" ? "Opening Properties" : "Barrel Properties")) {
                    navigate(page.title == "Barrel Properties" ? "Opening Properties" : "Barrel Properties")
                }
                .disabled(session.geometryCulvert?.hasActiveSketch == true)
            }
            .padding(12)
            Divider()

            if let child = session.geometryCulvert {
                GeometryCulvertStatusBanner(child: child)
                GeometryCulvertTablePane(featureKind: featureKind, child: child,
                    title: page.title, allowsAdd: true)
                    .frame(minHeight: 240)
                Divider()
                GeometryCulvertEditForm(featureKind: featureKind, child: child)
                    .disabled(child.hasActiveSketch)
                    .frame(minHeight: 210)
            } else {
                ContentUnavailableView("Culvert properties are unavailable",
                    systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                    description: Text("The geometry culvert source provider is not connected."))
            }
        }
        .task(id: session.geometryCulvertIdentity) {
            await session.ensureGeometryCulvertLoaded()
        }
    }
}

private struct GeometryCulvertStatusBanner: View {
    @ObservedObject var child: GeometryCulvertSession

    var body: some View {
        if child.isLoading || child.isEditing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(child.isEditing ? "Applying culvert draft…" : "Reading geometry and terrain…")
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.quaternary)
        } else if let error = child.error {
            Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.orange.opacity(0.08))
                .textSelection(.enabled)
        } else if child.hasActiveSketch {
            Label(L10n.text("Finish or cancel the culvert map preview before saving, switching, or discarding geometry."),
                systemImage: "pencil.and.outline")
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 7)
        } else if child.isDirty {
            Label("Culvert changes are staged with the geometry model. Save the model to write them.",
                systemImage: "pencil.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 7)
        }
    }
}

private struct GeometryCulvertTablePane: View {
    let featureKind: String
    @ObservedObject var child: GeometryCulvertSession
    let title: String
    let allowsAdd: Bool

    private var table: GeometryCulvertFeatureTable { child.table(for: featureKind) }
    private var selected: Set<String> { child.selectedFeatureIDs[featureKind, default: []] }
    private var rowIdentity: String { table.rows.map(\.id).joined(separator: "|") }
    private var selection: Binding<Set<String>> {
        Binding(get: { selected }, set: { value in
            Task { await child.select(value, featureKind: featureKind) }
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(L10n.text(title)).font(.headline)
                Text(table.rows.count.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if allowsAdd {
                    Button("Add Property Set", systemImage: "plus") {
                        Task { await child.addPropertySet(featureKind: featureKind) }
                    }
                    .disabled(!child.canEdit || child.hasActiveSketch)
                }
                Button("Delete Selected", systemImage: "trash", role: .destructive) {
                    Task { await child.deleteSelected(featureKind: featureKind) }
                }
                .disabled(!child.canEdit || child.hasActiveSketch || selected.isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)

            Table(table.rows, selection: selection) {
                TableColumn(L10n.text("FID")) { row in
                    Text(row.values["FID"] ?? row.fid.formatted())
                        .font(.caption.monospacedDigit())
                }
                .width(min: 45, ideal: 55, max: 70)
                TableColumn(L10n.text("Name")) { row in
                    Text(row.values["Name"] ?? "—")
                        .lineLimit(1).textSelection(.enabled)
                }
                if featureKind == "barrel" {
                    TableColumn(L10n.text("Barrel Properties")) { row in Text(row.values["BarrelPropertyName"] ?? "—").lineLimit(1) }
                    TableColumn(L10n.text("Upstream Invert")) { row in Text(row.values["UpstreamInvert"] ?? "—").monospacedDigit() }
                    TableColumn(L10n.text("Downstream Invert")) { row in Text(row.values["DownstreamInvert"] ?? "—").monospacedDigit() }
                    TableColumn(L10n.text("Length")) { row in Text(row.values["Length"] ?? "—").monospacedDigit() }
                } else if featureKind == "barrelProperties" {
                    TableColumn(L10n.text("Shape")) { row in Text(row.values["Shape"] ?? "—") }
                    TableColumn(L10n.text("Rise")) { row in Text(row.values["Rise"] ?? "—").monospacedDigit() }
                    TableColumn(L10n.text("Span")) { row in Text(row.values["Span"] ?? "—").monospacedDigit() }
                    TableColumn(L10n.text("Mannings")) { row in Text(row.values["Mannings"] ?? "—").monospacedDigit() }
                } else {
                    TableColumn(L10n.text("Opening Type")) { row in Text(row.values["OpeningType"] ?? "—").lineLimit(1) }
                    TableColumn(L10n.text("K Entrance")) { row in Text(row.values["KIn"] ?? "—").monospacedDigit() }
                    TableColumn(L10n.text("K Exit")) { row in Text(row.values["KOut"] ?? "—").monospacedDigit() }
                }
            }
            .overlay {
                if table.rows.isEmpty {
                    ContentUnavailableView("No source property sets", systemImage: "tablecells",
                        description: Text(allowsAdd
                            ? "Add a property set to create a source-backed definition."
                            : "This geometry contains no culvert barrels."))
                }
            }
        }
        .onChange(of: rowIdentity) { _, _ in
            let existing = Set(table.rows.map(\.id))
            if !selected.isSubset(of: existing) {
                Task { await child.select(selected.intersection(existing), featureKind: featureKind) }
            }
        }
    }
}

private struct GeometryCulvertEditForm: View {
    let featureKind: String
    @ObservedObject var child: GeometryCulvertSession
    @State private var drafts = GeometryCulvertEditDraftState()
    @State private var isApplyingChanges = false
    @State private var preserveDraftsForSnapshotWithSelection: String?

    private var table: GeometryCulvertFeatureTable { child.table(for: featureKind) }
    private var selectedRows: [GeometryCulvertFeatureRow] { child.selectedRows(for: featureKind) }
    private var selectionIdentity: String {
        selectedFeatureIdentity
            + "|" + (child.snapshot?.revision ?? "")
    }
    private var selectedFeatureIdentity: String {
        child.selectedFeatureIDs[featureKind, default: []].sorted().joined(separator: "|")
    }
    private var hasPendingValues: Bool {
        guard let first = selectedRows.first else { return false }
        return table.editableFields.contains { hasPendingValue(for: $0, comparedTo: first) }
    }

    var body: some View {
        Group {
            if selectedRows.isEmpty {
                ContentUnavailableView("Select a source row to edit",
                    systemImage: "cursorarrow.click",
                    description: Text("Changes apply to the selected source rows and remain staged until the geometry is saved."))
            } else {
                ScrollView {
                    Form {
                        Section {
                            ForEach(table.editableFields) { field in
                                fieldEditor(field)
                            }
                        } header: {
                            HStack {
                                Text(L10n.text(featureKind == "barrel" ? "Culvert Properties" : "Property Set"))
                                Spacer()
                                Text(L10n.format("%d selected", selectedRows.count))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            Spacer()
                            Button("Apply Changes", systemImage: "checkmark") {
                                Task { await applyChanges() }
                            }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!child.canEdit || child.hasActiveSketch || !hasPendingValues)
                        }
                    }
                    .formStyle(.grouped)
                    .padding(12)
                }
            }
        }
        .onAppear(perform: loadValues)
        .onChange(of: selectionIdentity) { _, _ in
            if let preservedSelection = preserveDraftsForSnapshotWithSelection {
                preserveDraftsForSnapshotWithSelection = nil
                if preservedSelection == selectedFeatureIdentity { return }
            }
            if !isApplyingChanges { loadValues() }
        }
    }

    @ViewBuilder private func fieldEditor(_ field: GeometryCulvertField) -> some View {
        let value = drafts.values[field.id] ?? selectedRows.first?.values[field.id] ?? ""
        let isOpeningCoefficient = featureKind == "openingProperties" && (field.id == "KIn" || field.id == "KOut")
        let hasMismatch = isOpeningCoefficient && child.openingCoefficientHasMismatch(fieldID: field.id)
        let hasMixedOpeningType = featureKind == "openingProperties" && field.id == "OpeningType"
            && child.fieldHasMismatch(featureKind: featureKind, fieldID: field.id)
            && !drafts.forceSetCommandFieldIDs.contains(field.id)
        if field.readOnly {
            LabeledContent(L10n.text(field.title)) {
                Text(value.isEmpty ? "—" : value)
                    .font(.body.monospacedDigit()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } else if !field.choices.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Picker(L10n.text(field.title), selection: Binding(
                    get: { hasMixedOpeningType ? "" : (drafts.values[field.id] ?? value) },
                    set: { proposed in
                        guard !proposed.isEmpty else { return }
                        if hasMixedOpeningType, field.forceSetCommand != nil {
                            drafts.stageForceSetCommand(fieldID: field.id, value: proposed)
                        } else {
                            drafts.values[field.id] = proposed
                        }
                    }
                )) {
                    if hasMixedOpeningType {
                        Text("Mixed values").tag("")
                    }
                    if field.id == "BarrelPropertyName" || field.id == "UpstreamOpeningName" || field.id == "DownstreamOpeningName" {
                        Text("None").tag("")
                    }
                    ForEach(field.choices, id: \.self) { choice in
                        Text(choiceTitle(choice)).tag(choice)
                    }
                    if !value.isEmpty && !field.choices.contains(value) {
                        Text(L10n.format("Missing: %@", value)).tag(value)
                    }
                }
                sourceValidation(for: field)
            }
            .disabled(!child.canEdit)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    TextField(L10n.text(field.title), text: Binding(
                        get: {
                            if hasMismatch && !drafts.editedMixedCoefficientFields.contains(field.id) { return "" }
                            return drafts.values[field.id] ?? value
                        },
                        set: { proposed in
                            drafts.values[field.id] = proposed
                            drafts.clearCommandFieldIDs.remove(field.id)
                            if isOpeningCoefficient { drafts.editedMixedCoefficientFields.insert(field.id) }
                        }
                    ), prompt: Text(LocalizedStringKey(hasMismatch ? "Mixed values" : "")))
                    .disabled(!child.canEdit)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospacedDigit())

                    if hasMismatch && field.showClearButton && field.clearCommand == "resetOpeningCoefficient"
                        && !drafts.clearCommandFieldIDs.contains(field.id) {
                        Button {
                            drafts.stageClearCommand(fieldID: field.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.text("Clear"))
                        .accessibilityLabel(Text("Clear"))
                        .disabled(!child.canEdit || child.isEditing || child.hasActiveSketch)
                    }
                }
                sourceValidation(for: field)
            }
        }
    }

    @ViewBuilder private func sourceValidation(for field: GeometryCulvertField) -> some View {
        let messages = sourceValidationMessages(for: field)
        if !messages.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                    Text(L10n.text(message))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func sourceValidationMessages(for field: GeometryCulvertField) -> [String] {
        guard field.errorValidationSource != nil,
              let propertyName = field.errorValidationPropertyName else { return [] }
        return selectedRows.flatMap { $0.errors?[propertyName] ?? [] }
            .reduce(into: [String]()) { result, message in
                if !result.contains(message) { result.append(message) }
            }
    }

    private func loadValues() {
        preserveDraftsForSnapshotWithSelection = nil
        guard let first = selectedRows.first else { drafts.load([:]); return }
        drafts.load(first.values)
    }

    private func hasPendingValue(for field: GeometryCulvertField, comparedTo first: GeometryCulvertFeatureRow) -> Bool {
        guard !field.readOnly else { return false }
        if drafts.clearCommandFieldIDs.contains(field.id), field.clearCommand == "resetOpeningCoefficient" { return true }
        if drafts.forceSetCommandFieldIDs.contains(field.id), field.forceSetCommand == "forceSetOpeningType" { return true }
        if featureKind == "openingProperties", (field.id == "KIn" || field.id == "KOut"),
           child.openingCoefficientHasMismatch(fieldID: field.id), drafts.editedMixedCoefficientFields.contains(field.id) {
            return true
        }
        return drafts.values[field.id] != (first.values[field.id] ?? "")
    }

    private func choiceTitle(_ value: String) -> String {
        let suffix = value.split(separator: "_", maxSplits: 1).last.map(String.init) ?? value
        return suffix
            .replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
    }

    private func applyChanges() async {
        guard let first = selectedRows.first else { return }
        let pending = table.editableFields.filter { hasPendingValue(for: $0, comparedTo: first) }
            .map { ($0, drafts.values[$0.id] ?? "") }
        isApplyingChanges = true
        defer { isApplyingChanges = false }
        for (field, value) in pending {
            var commandSucceeded = true
            if drafts.clearCommandFieldIDs.contains(field.id), field.clearCommand == "resetOpeningCoefficient" {
                commandSucceeded = await child.resetSelectedOpeningCoefficient(fieldID: field.id)
            } else if drafts.forceSetCommandFieldIDs.contains(field.id), field.forceSetCommand == "forceSetOpeningType" {
                commandSucceeded = await child.forceSetChoice(field, value: value)
            } else {
                await child.setField(featureKind: featureKind, fieldID: field.id, value: value)
            }
            if !commandSucceeded || child.error != nil { return }
        }
        loadValues()
    }
}

private struct GeometryCulvertTerrainProfileView: View {
    @ObservedObject var child: GeometryCulvertSession

    private var selectedBarrelIDs: Set<String> { child.selectedFeatureIDs["barrel", default: []] }
    private var selectedProfiles: [GeometryCulvertProfile] {
        GeometryCulvertProfilePresentation.selectedProfiles(child.snapshot?.profiles ?? [],
            barrelIDs: selectedBarrelIDs)
    }
    private var plottedProfiles: [GeometryCulvertProfile] {
        GeometryCulvertProfilePresentation.plotProfiles(selectedProfiles)
    }
    private var fallbackBarrelNames: [String: String] {
        Dictionary(uniqueKeysWithValues: child.table(for: "barrel").rows
            .filter { selectedBarrelIDs.contains($0.id) }
            .map { ($0.id, $0.values["Name"] ?? $0.id) })
    }
    private var legendLabels: [String: String] {
        GeometryCulvertProfilePresentation.labels(barrelIDs: selectedBarrelIDs,
            profiles: selectedProfiles, fallbackNames: fallbackBarrelNames)
    }
    private var unavailableBarrelLabels: [String] {
        let plottedIDs = Set(plottedProfiles.map(\.barrelID))
        return selectedBarrelIDs.subtracting(plottedIDs).sorted().map { legendLabels[$0] ?? $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Terrain Cross-Section", systemImage: "chart.xyaxis.line")
                    .font(.headline)
                Spacer()
                if let terrain = child.snapshot?.associatedTerrainName {
                    Label(terrain, systemImage: "mountain.2")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.top, 10)

            if child.isProfileContextStale {
                ContentUnavailableView("Terrain profile is out of date",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Resolve the project association or source change before using this profile."))
            } else if selectedBarrelIDs.isEmpty || plottedProfiles.isEmpty {
                ContentUnavailableView("No terrain profile samples",
                    systemImage: "chart.xyaxis.line",
                    description: Text(profileUnavailableReason))
            } else {
                Chart {
                    ForEach(plottedProfiles) { profile in
                        ForEach(profile.samples) { sample in
                            LineMark(x: .value("Distance", sample.distance),
                                     y: .value("Elevation", sample.elevation),
                                     series: .value("Barrel ID", profile.barrelID))
                            .foregroundStyle(by: .value("Barrel", legendLabels[profile.barrelID] ?? profile.barrelID))
                            PointMark(x: .value("Distance", sample.distance),
                                      y: .value("Elevation", sample.elevation))
                            .foregroundStyle(by: .value("Barrel", legendLabels[profile.barrelID] ?? profile.barrelID))
                        }
                    }
                }
                .chartXAxisLabel("Distance")
                .chartYAxisLabel("Elevation")
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(minHeight: 180)
                .padding(.horizontal, 14)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(plottedProfiles) { profile in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(legendLabels[profile.barrelID] ?? profile.barrelID)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Label(L10n.format("Length: %@", profile.length.formatted(
                                    .number.precision(.fractionLength(0...3)))), systemImage: "ruler")
                            }
                            HStack(spacing: 16) {
                                if let upstream = profile.samples.first {
                                    Text(L10n.format("Start: %@, %@", upstream.x.formatted(
                                        .number.precision(.fractionLength(0...4))), upstream.y.formatted(
                                        .number.precision(.fractionLength(0...4)))))
                                        .lineLimit(1)
                                }
                                if let downstream = profile.samples.last {
                                    Text(L10n.format("End: %@, %@", downstream.x.formatted(
                                        .number.precision(.fractionLength(0...4))), downstream.y.formatted(
                                        .number.precision(.fractionLength(0...4)))))
                                        .lineLimit(1)
                                }
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.bottom, 10)

                if !unavailableBarrelLabels.isEmpty {
                    Text(L10n.format("Terrain samples are unavailable for: %@",
                        unavailableBarrelLabels.joined(separator: ", ")))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.bottom, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var profileUnavailableReason: String {
        if selectedBarrelIDs.isEmpty {
            return "Select a culvert barrel to sample the associated terrain."
        }
        if child.snapshot?.associatedTerrainName == nil {
            return "No terrain is associated with this geometry in the current project draft."
        }
        return "The selected source line has no valid terrain samples."
    }
}
