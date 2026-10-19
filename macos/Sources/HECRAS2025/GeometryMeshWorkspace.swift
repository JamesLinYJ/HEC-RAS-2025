import SwiftUI
import RASWorkspaceCore

/// Source-backed mesh workspace. Flow-area identity, conceptual-mesh rows,
/// patch side data and diagnostics all come from the geometry mesh service.
struct GeometryMeshWorkspacePage: View {
    @ObservedObject var session: GeometryMeshSession
    @ObservedObject var store: WorkspaceStore
    var navigate: ((String) -> Void)? = nil
    var selectTopologyFeatures: ((String, [String]) -> Void)? = nil
    var prepareAndSave: (@MainActor () async -> Bool)? = nil
    var persistDiagnosticsPreferences: (@MainActor (GeometryMeshDiagnosticsPreferencesCapture) async throws -> String)? = nil
    @State private var section = "Flow Areas"
    @State private var isPreparingAndSaving = false

    private let sections = ["Flow Areas", "Mesh Map", "Mesh Tools", "Regions", "Mesh Diagnostics", "Prepare Summary"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("Geometry Mesh", systemImage: "square.grid.3x3")
                    .font(.headline)
                if let snapshot = session.snapshot {
                    Text(snapshot.flowAreas.count.formatted())
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                if session.isLoading || session.isEditing { ProgressView().controlSize(.small) }
                if session.isDirty {
                    Label("Unsaved mesh changes", systemImage: "pencil.circle.fill")
                        .foregroundStyle(.orange)
                        .help("Mesh edits and generated previews are included with the geometry Save action.")
                }
                if session.hasUnsavedDiagnosticsPreferences {
                    Label(L10n.text("Unsaved mesh diagnostics settings"), systemImage: "slider.horizontal.3")
                        .foregroundStyle(.orange)
                    if session.diagnosticsPreferencesScopeMismatch,
                       let scope = session.diagnosticsPreferencesScope {
                        Text(L10n.format("These settings still belong to %@.", scope.mapName))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button(L10n.text("Save diagnostics settings"), systemImage: "externaldrive") {
                        Task {
                            guard let capture = session.beginDiagnosticsPreferencesSave(),
                                  let persistDiagnosticsPreferences else { return }
                            do {
                                let revision = try await persistDiagnosticsPreferences(capture)
                                session.acceptDiagnosticsPreferencesSave(capture, newSourceRevision: revision)
                            } catch {
                                session.diagnosticsPreferencesSaveFailed(capture, message: error.localizedDescription)
                            }
                        }
                    }
                    .disabled(!session.canBeginDiagnosticsPreferencesSave || persistDiagnosticsPreferences == nil)
                    Button(L10n.text("Discard settings"), systemImage: "arrow.uturn.backward") {
                        session.discardDiagnosticsPreferences()
                    }
                    .disabled(session.isSavingDiagnosticsPreferences)
                }
                if let navigate {
                    Button("Topology") { navigate("Topology") }
                }
                if section == "Prepare Summary" {
                    Button("Prepare and Save Geometry", systemImage: "checkmark.seal") {
                        Task {
                            isPreparingAndSaving = true
                            defer { isPreparingAndSaving = false }
                            guard await session.requestPrepare(), let prepareAndSave else { return }
                            _ = await prepareAndSave()
                        }
                    }
                    .disabled(!session.canRequestPrepare || prepareAndSave == nil || isPreparingAndSaving)
                }
                Button("Discard mesh draft", systemImage: "arrow.uturn.backward") {
                    Task { await session.discardDraft() }
                }
                .disabled(!session.isDirty || session.parentSaveInProgress || session.isEditing || isPreparingAndSaving)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Picker("Mesh workspace", selection: $section) {
                ForEach(sections, id: \.self) { Text(LocalizedStringKey($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            if let error = session.error {
                Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            if let error = session.diagnosticsPreferencesError {
                Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            Divider()

            if session.isLoading && session.snapshot == nil {
                ProgressView("Loading source mesh data…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.snapshot == nil {
                ContentUnavailableView("Mesh data unavailable", systemImage: "square.grid.3x3",
                    description: Text(L10n.text(session.error ?? "The geometry mesh has not loaded.")))
            } else {
                switch section {
                case "Flow Areas": GeometryMeshFlowAreasView(session: session)
                case "Mesh Map": GeometryMeshMapWorkspaceView(session: session, store: store, navigate: navigate,
                    selectTopologyFeatures: selectTopologyFeatures,
                    showDiagnostics: { section = "Mesh Diagnostics" })
                case "Mesh Tools": GeometryMeshToolsWorkspaceView(session: session, store: store,
                    onFindCompleted: { section = "Mesh Map" })
                case "Regions": GeometryMeshRegionsView(session: session)
                case "Mesh Diagnostics": GeometryMeshDiagnosticsView(session: session, store: store, section: $section)
                default: GeometryMeshPrepareSummaryView(session: session, store: store)
                }
            }
        }
        .background(.background)
        .task(id: store.geometryVectorStyleContextIdentity) {
            await store.refreshVectorSymbologyContexts(mapID: store.lastActiveMapID)
        }
    }
}

private struct GeometryMeshFlowAreasView: View {
    @ObservedObject var session: GeometryMeshSession
    private var selection: Binding<Set<String>> {
        Binding(get: { session.selectedFlowAreaIDs }, set: { session.selectFlowAreas($0) })
    }

    var body: some View {
        HSplitView {
            Table(session.flowAreas, selection: selection) {
                TableColumn("Flow Area", value: \.name)
                    .width(min: 130, ideal: 190)
                TableColumn("Cells") { row in Text(row.cellCount.formatted()).monospacedDigit() }
                    .width(min: 65, ideal: 85)
                TableColumn("Faces") { row in Text(row.faceCount.formatted()).monospacedDigit() }
                    .width(min: 65, ideal: 85)
                TableColumn("Nodes") { row in Text(row.nodeCount.formatted()).monospacedDigit() }
                    .width(min: 65, ideal: 85)
                TableColumn("Status") { row in
                    Label(row.hasMeshErrors ? "Errors" : (row.hasMesh ? "Mesh available" : "No mesh"),
                        systemImage: row.hasMeshErrors ? "exclamationmark.triangle" : (row.hasMesh ? "checkmark.circle" : "circle.dashed"))
                        .foregroundStyle(row.hasMeshErrors ? .orange : .secondary)
                }
                .width(min: 105, ideal: 130)
            }
            .overlay {
                if session.flowAreas.isEmpty {
                    ContentUnavailableView("No flow areas", systemImage: "square.grid.3x3",
                        description: Text("The source geometry contains no flow-area rows."))
                        .allowsHitTesting(false)
                }
            }
            .frame(minWidth: 420, idealWidth: 620, maxWidth: .infinity, maxHeight: .infinity)

            Group {
                if let row = session.selectedFlowArea {
                    GeometryMeshFlowAreaInspector(row: row, session: session)
                        .id(row.id)
                } else if session.selectedFlowAreaIDs.count > 1 {
                    ContentUnavailableView(L10n.text("Multiple flow areas selected"), systemImage: "square.grid.3x3",
                        description: Text(L10n.text("Select one flow area to edit its properties.")))
                } else {
                    ContentUnavailableView("Select a flow area", systemImage: "cursorarrow.click",
                        description: Text("Choose one source row to inspect its mesh and metadata."))
                }
            }
            .frame(minWidth: 300, idealWidth: 390, maxWidth: 480, maxHeight: .infinity)
        }
    }
}

private struct GeometryMeshFlowAreaInspector: View {
    let row: GeometryMeshFlowAreaRow
    @ObservedObject var session: GeometryMeshSession
    @State private var name = ""
    @State private var spacing = ""

    private var spacingIsValid: Bool { spacing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Double(spacing)?.isFinite == true }
    private var extentText: String? {
        guard let extent = row.extent else { return nil }
        return "X: \(extent.minX.formatted()) … \(extent.maxX.formatted())   Y: \(extent.minY.formatted()) … \(extent.maxY.formatted())"
    }

    var body: some View {
        Form {
            Section("Flow Area") {
                LabeledContent("Source Row", value: "\(row.rowIndex + 1)")
                HStack {
                    TextField("Flow area name", text: $name)
                    Button("Apply") {
                        Task { await session.setFlowAreaField(row, fieldID: "Name", value: name) }
                    }
                    .disabled(!session.canEdit || name == row.name)
                }
                HStack {
                    TextField("Targeted cell spacing", text: $spacing)
                        .monospacedDigit()
                    Button("Apply") {
                        let value = spacing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "NaN" : spacing
                        Task { await session.setFlowAreaField(row, fieldID: "TargetedCellSpacing", value: value) }
                    }
                    .disabled(!session.canEdit || !spacingIsValid || spacing == (row.targetedCellSpacing.map { String($0) } ?? ""))
                }
                Text("Leave the spacing blank to use the source-derived value.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Mesh Information") {
                LabeledContent("Cell Count", value: row.cellCount.formatted())
                LabeledContent("Face Count", value: row.faceCount.formatted())
                LabeledContent("Node Count", value: row.nodeCount.formatted())
                LabeledContent("Property Tables", value: row.propertyTablesQueuedForParentSave
                    ? L10n.text("Computed in geometry draft")
                    : (row.hasPropertyTables ? L10n.text("Available") : L10n.text("Not available")))
                if row.propertyTablesQueuedForParentSave {
                    Text("Property tables will be recomputed in the staged geometry and written when you save the parent Geometry.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Property Tables Pinned", value: row.propertyTablesPinned ? "Yes" : "No")
                LabeledContent("Mesh Errors", value: row.hasMeshErrors ? "Yes" : "No")
                if let extentText { LabeledContent("Mesh Extent", value: extentText).textSelection(.enabled) }
                else { LabeledContent("Mesh Extent", value: "Unavailable") }
            }
            if !row.metadata.isEmpty {
                Section("Metadata") {
                    ForEach(row.metadata) { item in
                        LabeledContent(L10n.text(item.title), value: item.value).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: restore)
        .onChange(of: row.name) { _, _ in restore() }
        .onChange(of: row.targetedCellSpacing) { _, _ in restore() }
    }

    private func restore() {
        name = row.name
        spacing = row.targetedCellSpacing.map { String($0) } ?? ""
    }
}

private struct GeometryMeshRegionsView: View {
    @ObservedObject var session: GeometryMeshSession
    private var selection: Binding<Set<String>> {
        Binding(get: { Set(session.selectedRegions.map(\.id)) }, set: { ids in
            let fids = session.regions.rows.filter { ids.contains($0.id) }.map(\.fid)
            Task { await session.selectRegions(Set(fids)) }
        })
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Label("Regions", systemImage: "point.3.connected.trianglepath.dotted").font(.headline)
                    Text(session.regions.rows.count.formatted()).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    if session.selectedRegions.count > 1 {
                        Text("\(session.selectedRegions.count) selected")
                            .foregroundStyle(.secondary).font(.caption)
                    }
                }.padding(12)
                Table(session.regions.rows, selection: selection) {
                    TableColumn("FID") { row in Text(row.fid.formatted()).monospacedDigit() }
                        .width(min: 55, ideal: 70)
                    TableColumn("Patch Type") { row in Text(row.values["PatchType"] ?? "—") }
                        .width(min: 100, ideal: 130)
                    TableColumn("X") { row in Text(row.values["X"] ?? "—").monospacedDigit() }
                        .width(min: 95, ideal: 115)
                    TableColumn("Y") { row in Text(row.values["Y"] ?? "—").monospacedDigit() }
                        .width(min: 95, ideal: 115)
                    TableColumn("Cell Size") { row in
                        Text(row.values["ConstantSize"] ?? "—").monospacedDigit()
                    }
                    .width(min: 80, ideal: 100)
                }
                .overlay {
                    if session.regions.rows.isEmpty {
                        ContentUnavailableView("No regions", systemImage: "point.3.connected.trianglepath.dotted",
                            description: Text("The source conceptual mesh contains no control-point regions."))
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(minWidth: 430, idealWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
            GeometryMeshPatchSizingInspector(session: session)
                .frame(minWidth: 340, idealWidth: 430, maxWidth: 520, maxHeight: .infinity)
        }
    }
}

struct GeometryMeshPatchSizingInspector: View {
    @ObservedObject var session: GeometryMeshSession
    var requiredRegionIDs: Set<Int>? = nil
    @State private var hoveredSideAxis: String?
    private var sizing: GeometryMeshPatchSizing? { session.snapshot?.patchSizing }
    private var selected: [GeometryTopologyFeatureRow] { session.selectedRegions }
    private var selectedFIDs: [Int] { session.selectedRegionFIDsInSourceOrder }
    private var editable: Bool { session.canEdit && !selected.isEmpty }
    private var snapshotMatchesSelection: Bool {
        guard let snapshot = session.snapshot, let sizing = snapshot.patchSizing else { return false }
        return Set(snapshot.selectedRegionIDs) == session.selectedRegionIDs
            && Set(sizing.selectedRegionIDs) == session.selectedRegionIDs
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Patch Sizing").font(.title2.weight(.semibold))
                if let requiredRegionIDs, session.selectedRegionIDs != requiredRegionIDs {
                    ContentUnavailableView("Topology selection changed while Patch Sizing was open.",
                        systemImage: "cursorarrow.click",
                        description: Text("Close this editor and open Patch Sizing again for the currently selected region."))
                        .frame(minHeight: 220)
                } else if session.isLoading || !snapshotMatchesSelection {
                    VStack(alignment: .leading, spacing: 10) {
                        if let error = session.error {
                            Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        } else {
                            ProgressView("Loading source patch-side data…")
                        }
                        Button("Retry side data load", systemImage: "arrow.clockwise") {
                            retrySideDataLoad()
                        }
                        .disabled(session.isLoading || session.isEditing || session.parentSaveInProgress)
                    }
                    .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
                } else if selected.isEmpty {
                    ContentUnavailableView("Select regions", systemImage: "cursorarrow.click",
                        description: Text("Choose one or more source region rows to inspect their mesh sizing."))
                        .frame(minHeight: 220)
                } else if let sizing {
                    if sizing.state == "mixedTypes" {
                        ContentUnavailableView("Selected regions have different patch types.",
                            systemImage: "square.on.square", description: Text(L10n.text(sizing.message)))
                    } else if sizing.state != "ready" {
                        VStack(spacing: 10) {
                            ContentUnavailableView("Patch sizing unavailable", systemImage: "square.dashed",
                                description: Text(L10n.text(sizing.message)))
                            Button("Retry side data load", systemImage: "arrow.clockwise") {
                                retrySideDataLoad()
                            }
                            .disabled(session.isLoading || session.isEditing || session.parentSaveInProgress)
                        }
                    } else {
                        selectionHeader(sizing)
                        GeometryMeshPatchBoundaryPreview(
                            map: session.snapshot?.map,
                            selectedRows: selected,
                            sourceRevision: session.snapshot?.revision,
                            topologyFingerprint: session.snapshot?.topologyFingerprint,
                            selectedRegionIDs: session.snapshot?.selectedRegionIDs ?? [],
                            snapshotIsCurrent: session.canScanDegreeErrors,
                            canRetry: !session.isLoading && !session.isEditing && !session.parentSaveInProgress,
                            activeSideDimension: sizing.dimensions.first { $0.id == hoveredSideAxis },
                            onRetry: retrySideDataLoad
                        )
                        if selected.count == 1, let row = selected.first {
                            GeometryMeshRegionFieldEditor(row: row, fields: session.regions.editableFields,
                                canEdit: editable, session: session)
                        } else {
                            Text("Scalar patch properties apply to one selected region. Quick sizing follows the source editor's active selection.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        switch sizing.kind {
                        case "Quad":
                            ForEach(sizing.dimensions) { dimension in
                                GeometryMeshPatchDimensionEditor(dimension: dimension, featureIDs: selectedFIDs,
                                    canEdit: editable, session: session,
                                    onPreviewHover: { isHovering in
                                        hoveredSideAxis = isHovering ? dimension.id : nil
                                    })
                                    .id(GeometryMeshPatchDimensionEditorIdentity(assetID: session.assetIdentity,
                                        featureIDs: selectedFIDs, axis: dimension.id))
                            }
                        case "TrianglePaver", "Cartesian":
                            quickSizing(axis: nil)
                        case "OneD", "Empty":
                            Text("The selected source patch type has no mesh quick-sizing action.")
                                .font(.callout).foregroundStyle(.secondary)
                        default:
                            Text("Patch sizing is unavailable for this source patch type.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ContentUnavailableView("Patch sizing unavailable", systemImage: "square.dashed",
                        description: Text("Source patch sizing has not loaded."))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
        .onChange(of: selectedFIDs) { _, _ in hoveredSideAxis = nil }
        .onChange(of: session.geometryMeshIdentity) { _, _ in hoveredSideAxis = nil }
        .onDisappear { hoveredSideAxis = nil }
    }

    @ViewBuilder private func selectionHeader(_ sizing: GeometryMeshPatchSizing) -> some View {
        GroupBox("Selection") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Patch Type", value: L10n.text(sizing.kind ?? "—"))
                LabeledContent("Selected Regions", value: selected.count.formatted())
                if selected.count == 1, let row = selected.first {
                    LabeledContent("FID", value: row.fid.formatted()).textSelection(.enabled)
                    LabeledContent("X", value: row.values["X"] ?? "—").textSelection(.enabled)
                    LabeledContent("Y", value: row.values["Y"] ?? "—").textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder private func quickSizing(axis: String?) -> some View {
        GroupBox("Scale Cell Size") {
            HStack {
                Button("Half") { resizeQuickSizing(ratio: 0.5, axis: axis) }
                Button("Double") { resizeQuickSizing(ratio: 2, axis: axis) }
            }
            .disabled(!editable || !session.canEdit || selectedFIDs.isEmpty)
            if selected.count > 1, axis == nil {
                Text("The source quick editor applies this action to the first selected Triangle or Cartesian region.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func resizeQuickSizing(ratio: Double, axis: String?) {
        let requestIDs = selectedFIDs
        let requestAxis = axis
        let requestContext = session.patchEditorRequestIdentity
        Task {
            guard !Task.isCancelled, session.canEdit, session.patchEditorRequestIdentity == requestContext,
                  session.selectedRegionIDs == Set(requestIDs) else { return }
            await session.resizePatch(featureIDs: requestIDs, ratio: ratio, axis: requestAxis)
        }
    }

    private func retrySideDataLoad() {
        let requestIDs = session.selectedRegionIDs
        let requestContext = session.patchEditorRequestIdentity
        Task {
            guard !Task.isCancelled,
                  session.patchEditorRequestIdentity == requestContext,
                  session.selectedRegionIDs == requestIDs,
                  !session.isEditing, !session.parentSaveInProgress else { return }
            await session.reload()
        }
    }
}

/// Shows the selected region's actual source polygon beside the patch controls.
/// On Quad-side hover, it overlays only source arc polylines whose FIDs and
/// snapshot identities were returned by the retained patch-side calculation.
private struct GeometryMeshPatchBoundaryPreview: View {
    let map: GeometryMeshMapData?
    let selectedRows: [GeometryTopologyFeatureRow]
    let sourceRevision: String?
    let topologyFingerprint: String?
    let selectedRegionIDs: [Int]
    let snapshotIsCurrent: Bool
    let canRetry: Bool
    let activeSideDimension: GeometryMeshPatchDimension?
    let onRetry: () -> Void

    private var selectedIDs: Set<String> { Set(selectedRows.map(\.id)) }
    private var selectedFIDs: Set<Int> { Set(selectedRows.map(\.fid)) }
    private var regions: [GeometryTopologyMapFeature] {
        guard let features = map?.topology.features else { return [] }
        return features.filter { feature in
            feature.featureKind.lowercased() == "region"
                && (selectedFIDs.contains(feature.fid ?? Int.min)
                    || !selectedIDs.isDisjoint(with: feature.selectionIDs))
                && feature.paths.contains { $0.count >= 3 }
        }
    }

    private var previewContextIsCurrent: Bool {
        snapshotIsCurrent && Set(selectedRows.map(\.fid)) == Set(selectedRegionIDs)
            && selectedRows.count == selectedRegionIDs.count
    }

    private var sideArcPaths: [[GeometryTopologyCoordinate]]? {
        guard previewContextIsCurrent, let activeSideDimension else { return nil }
        return GeometryMeshArcPreview.sourcePaths(for: activeSideDimension,
            sourceRevision: sourceRevision, topologyFingerprint: topologyFingerprint,
            selectedRegionIDs: selectedRegionIDs, map: map)
    }

    private var extent: GeometryTopologyExtent? {
        let regionPoints = regions.flatMap(\.paths).flatMap { $0 }
        let sidePoints = (sideArcPaths ?? []).flatMap { $0 }
        let points = (regionPoints + sidePoints).filter { $0.x.isFinite && $0.y.isFinite }
        guard let first = points.first else { return nil }
        let minX = points.map(\.x).min() ?? first.x
        let maxX = points.map(\.x).max() ?? first.x
        let minY = points.map(\.y).min() ?? first.y
        let maxY = points.map(\.y).max() ?? first.y
        let padding = max(max(maxX - minX, maxY - minY) * 0.06, 1e-9)
        return GeometryTopologyExtent(minX: minX - padding, minY: minY - padding,
            maxX: maxX + padding, maxY: maxY + padding)
    }

    var body: some View {
        GroupBox(label: Text(verbatim: localized("Source Region Outline", "源区域边界"))) {
            VStack(alignment: .leading, spacing: 6) {
                if let extent, !regions.isEmpty {
                    Canvas { context, size in
                        draw(regions, sideArcPaths: sideArcPaths ?? [],
                            extent: extent, size: size, context: &context)
                    }
                    .frame(height: 150)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.45),
                        in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                    if activeSideDimension != nil, !previewContextIsCurrent {
                        Text(verbatim: localized(
                            "The preview is paused until the current geometry snapshot is ready.",
                            "当前几何快照就绪前，预览已暂停。"
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if activeSideDimension != nil, sideArcPaths == nil {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(verbatim: localized(
                                "The exact source side arcs are unavailable for this snapshot.",
                                "此快照中无法取得精确的源侧弧线。"
                            ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button(L10n.text("Retry side data load"), systemImage: "arrow.clockwise",
                                   action: onRetry)
                                .disabled(!canRetry)
                        }
                    } else if activeSideDimension != nil, sideArcPaths?.isEmpty == true {
                        Text(verbatim: localized(
                            "No source arcs are assigned to this side.",
                            "此侧边没有分配源弧线。"
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if activeSideDimension != nil {
                        Text(verbatim: localized(
                            "Highlighted arcs are the source arcs assigned to this Quad side.",
                            "高亮弧线是分配给此四边形侧边的源弧线。"
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: localized(
                            "Hover over a Quad side setting to preview its source arcs.",
                            "将指针悬停在四边形侧边设置上可预览对应的源弧线。"
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    ContentUnavailableView {
                        Label {
                            Text(verbatim: localized("Region outline unavailable", "区域边界暂不可用"))
                        } icon: {
                            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        }
                    } description: {
                        Text(verbatim: localized(
                            "The source mesh map did not include a polygon for the selected region.",
                            "源网格地图未提供所选区域的多边形。"
                        ))
                    }
                        .frame(minHeight: 110)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func draw(_ features: [GeometryTopologyMapFeature],
                      sideArcPaths: [[GeometryTopologyCoordinate]],
                      extent: GeometryTopologyExtent, size: CGSize, context: inout GraphicsContext) {
        let minX = min(extent.minX, extent.maxX)
        let maxX = max(extent.minX, extent.maxX)
        let minY = min(extent.minY, extent.maxY)
        let maxY = max(extent.minY, extent.maxY)
        let worldWidth = max(maxX - minX, 1e-12)
        let worldHeight = max(maxY - minY, 1e-12)
        let scale = min(max(size.width - 24, 1) / worldWidth,
                        max(size.height - 24, 1) / worldHeight)
        guard scale.isFinite, scale > 0 else { return }
        let offsetX = (size.width - worldWidth * scale) / 2
        let offsetY = (size.height - worldHeight * scale) / 2
        let color = Color.accentColor

        for feature in features {
            for ring in feature.paths where ring.count >= 3 {
                let points = ring.filter { $0.x.isFinite && $0.y.isFinite }.map { point in
                    CGPoint(x: offsetX + (point.x - minX) * scale,
                            y: size.height - offsetY - (point.y - minY) * scale)
                }
                guard let first = points.first, points.count >= 3 else { continue }
                var path = Path()
                path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
                path.closeSubpath()
                context.fill(path, with: .color(color.opacity(0.12)))
                context.stroke(path, with: .color(color), lineWidth: 2)
            }
        }

        for coordinates in sideArcPaths where coordinates.count >= 2 {
            let points = coordinates.map { point in
                CGPoint(x: offsetX + (point.x - minX) * scale,
                        y: size.height - offsetY - (point.y - minY) * scale)
            }
            guard let first = points.first else { continue }
            var path = Path()
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            context.stroke(path, with: .color(Color.cyan.opacity(196.0 / 255.0)), lineWidth: 4)
        }
    }

    private func localized(_ english: String, _ simplifiedChinese: String) -> String {
        let identifier = L10n.language == "System"
            ? (Locale.preferredLanguages.first ?? "en")
            : L10n.language
        return identifier.hasPrefix("zh") ? simplifiedChinese : english
    }
}

private struct GeometryMeshRegionFieldEditor: View {
    let row: GeometryTopologyFeatureRow
    let fields: [GeometryTopologyField]
    let canEdit: Bool
    @ObservedObject var session: GeometryMeshSession
    @State private var drafts: [String: String]

    init(row: GeometryTopologyFeatureRow, fields: [GeometryTopologyField], canEdit: Bool,
         session: GeometryMeshSession) {
        self.row = row
        self.fields = fields
        self.canEdit = canEdit
        self.session = session
        _drafts = State(initialValue: row.values)
    }

    var body: some View {
        GroupBox("Region Properties") {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(fields) { field in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(L10n.text(field.title)).font(.subheadline)
                            Spacer()
                            Button("Apply") {
                                let requestFID = row.fid
                                let requestFieldID = field.id
                                let requestValue = drafts[field.id] ?? ""
                                let requestContext = session.patchEditorRequestIdentity
                                Task {
                                    guard !Task.isCancelled, session.canEdit, session.patchEditorRequestIdentity == requestContext,
                                          session.selectedRegionIDs == Set([requestFID]) else { return }
                                    await session.setPatchField(featureIDs: [requestFID],
                                        fieldID: requestFieldID, value: requestValue)
                                }
                            }
                            .controlSize(.small)
                            .disabled(!canEdit || !session.canEdit || field.readOnly
                                || (drafts[field.id] ?? "") == (row.values[field.id] ?? ""))
                        }
                        fieldControl(field)
                    }
                    if field.id != fields.last?.id { Divider() }
                }
            }
        }
        .onChange(of: row.id) { _, _ in drafts = row.values }
        .onChange(of: row.values) { _, values in drafts = values }
    }

    @ViewBuilder private func fieldControl(_ field: GeometryTopologyField) -> some View {
        let value = Binding(get: { drafts[field.id] ?? row.values[field.id] ?? "" },
            set: { drafts[field.id] = $0 })
        if !field.choices.isEmpty {
            Picker(field.title, selection: value) {
                ForEach(field.choices, id: \.self) { choice in Text(L10n.text(choice)).tag(choice) }
            }
            .labelsHidden()
            .disabled(!canEdit || field.readOnly)
        } else if field.sourceType.lowercased() == "bool" || field.sourceType.lowercased() == "boolean" {
            Toggle(L10n.text(field.title), isOn: Binding(get: { value.wrappedValue.lowercased() == "true" },
                set: { value.wrappedValue = $0 ? "true" : "false" }))
                .labelsHidden().disabled(!canEdit || field.readOnly)
        } else {
            TextField(L10n.text(field.title), text: value)
                .textFieldStyle(.roundedBorder)
                .disabled(!canEdit || field.readOnly)
        }
    }
}

private struct GeometryMeshPatchDimensionEditor: View {
    let dimension: GeometryMeshPatchDimension
    let featureIDs: [Int]
    let canEdit: Bool
    @ObservedObject var session: GeometryMeshSession
    let onPreviewHover: (Bool) -> Void
    @State private var draftState: GeometryMeshPatchDimensionDraftState

    private var identity: GeometryMeshPatchDimensionEditorIdentity {
        GeometryMeshPatchDimensionEditorIdentity(assetID: session.assetIdentity,
            featureIDs: featureIDs, axis: dimension.id, sourceIdentity: session.geometryMeshIdentity)
    }
    private var remoteSource: GeometryMeshPatchDimensionDraftSource {
        GeometryMeshPatchDimensionDraftSource(dimension)
    }
    private var mode: String { remoteSource.modeText }
    private var canApplyValue: Bool {
        draftState.submissionValue(canEdit: canEdit && session.canEdit,
            sourceCanApply: dimension.canApply && dimension.sideArcIssues?.isEmpty != false,
            arcCount: dimension.arcCount,
            modeHasMismatch: dimension.sizeFunctionHasMismatch) != nil
    }

    init(dimension: GeometryMeshPatchDimension, featureIDs: [Int], canEdit: Bool,
         session: GeometryMeshSession, onPreviewHover: @escaping (Bool) -> Void) {
        self.dimension = dimension
        self.featureIDs = featureIDs
        self.canEdit = canEdit
        self.session = session
        self.onPreviewHover = onPreviewHover
        let identity = GeometryMeshPatchDimensionEditorIdentity(assetID: session.assetIdentity,
            featureIDs: featureIDs, axis: dimension.id, sourceIdentity: session.geometryMeshIdentity)
        _draftState = State(initialValue: GeometryMeshPatchDimensionDraftState(identity: identity,
            source: GeometryMeshPatchDimensionDraftSource(dimension)))
    }

    var body: some View {
        GroupBox(LocalizedStringKey(dimension.title)) {
            if let issues = dimension.sideArcIssues, !issues.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Source side data could not be loaded.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                    ForEach(issues) { issue in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.format("Region FID %@", issue.regionFID.formatted()))
                                .font(.caption.weight(.semibold).monospaced())
                            Text(L10n.text(issue.message))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Button("Retry side data load", systemImage: "arrow.clockwise") {
                        retrySideDataLoad()
                    }
                    .disabled(session.isLoading || session.isEditing || session.parentSaveInProgress)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Source Arcs", value: dimension.arcCount.formatted())
                Picker("Size Function", selection: Binding(get: { draftState.mode }, set: { newValue in
                    let oldValue = draftState.mode
                    guard newValue != oldValue else { return }
                    draftState.setMode(newValue)
                    guard newValue != mode, !newValue.isEmpty,
                          canEdit, session.canEdit, dimension.canChangeMode,
                          dimension.arcCount > 0, ["Constant", "CountWithBias"].contains(newValue) else { return }
                    let requestIDs = featureIDs
                    let requestAxis = dimension.id
                    let requestContext = session.patchEditorRequestIdentity
                    let requestMode = newValue
                    let request = draftState.beginModeRequest(requestMode, id: UUID())
                    Task {
                        guard !Task.isCancelled, session.canEdit, session.patchEditorRequestIdentity == requestContext,
                                  session.selectedRegionIDs == Set(requestIDs) else {
                            draftState.finish(request, returnedSource: nil)
                            return
                        }
                        await session.setPatchDimensionMode(featureIDs: requestIDs,
                            axis: requestAxis, mode: requestMode)
                        let returned = Self.returnedDimensionSource(session: session,
                            featureIDs: requestIDs, axis: requestAxis)
                        draftState.finish(request, returnedSource: returned)
                    }
                })) {
                    if mode.isEmpty || dimension.sizeFunctionHasMismatch {
                        Text("Mixed values").tag("")
                    }
                    Text("Constant").tag("Constant")
                    Text("Count with bias").tag("CountWithBias")
                }
                .disabled(!canEdit || !session.canEdit || !dimension.canChangeMode || dimension.arcCount == 0
                    || dimension.sideArcIssues?.isEmpty == false)
                TextField(mode == "CountWithBias" ? "Point Count" : "Cell Size", text: Binding(
                    get: { draftState.value }, set: { draftState.setValue($0) }),
                    prompt: Text(dimension.liveValueHasMismatch ? "Mixed values" : "—"))
                    .monospacedDigit()
                    .disabled(!canEdit || !session.canEdit || !dimension.canApply || dimension.arcCount == 0
                        || mode.isEmpty || dimension.sizeFunctionHasMismatch || draftState.mode != mode
                        || dimension.sideArcIssues?.isEmpty == false)
                if dimension.liveValueHasMismatch {
                    Text("The selected side arcs have different values.")
                        .font(.caption).foregroundStyle(.secondary)
                    if dimension.canApply, dimension.arcCount > 0,
                       !dimension.sizeFunctionHasMismatch, !mode.isEmpty, draftState.mode == mode {
                        Text("Applying this value sets it for every selected side arc.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if draftState.pendingRequest != nil {
                    Label("Applying source edit…", systemImage: "hourglass")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Apply") {
                        guard let requestValue = draftState.submissionValue(canEdit: canEdit && session.canEdit,
                            sourceCanApply: dimension.canApply, arcCount: dimension.arcCount,
                            modeHasMismatch: dimension.sizeFunctionHasMismatch) else { return }
                        let requestIDs = featureIDs
                        let requestAxis = dimension.id
                        let requestContext = session.patchEditorRequestIdentity
                        let requestMode = mode
                        let request = draftState.beginValueRequest(mode: requestMode,
                            value: requestValue, id: UUID())
                        Task {
                            guard !Task.isCancelled, session.canEdit, session.patchEditorRequestIdentity == requestContext,
                                  session.selectedRegionIDs == Set(requestIDs) else {
                                draftState.finish(request, returnedSource: nil)
                                return
                            }
                            await session.applyPatchDimension(featureIDs: requestIDs,
                                axis: requestAxis, value: requestValue)
                            let returned = Self.returnedDimensionSource(session: session,
                                featureIDs: requestIDs, axis: requestAxis)
                            draftState.finish(request, returnedSource: returned)
                        }
                    }
                    .disabled(!canApplyValue)
                    Spacer()
                    Button("Half") {
                        let requestIDs = featureIDs
                        let requestAxis = dimension.id
                        let requestContext = session.patchEditorRequestIdentity
                        Task {
                            guard !Task.isCancelled, session.canEdit, session.patchEditorRequestIdentity == requestContext,
                                  session.selectedRegionIDs == Set(requestIDs) else { return }
                            await session.resizePatch(featureIDs: requestIDs, ratio: 0.5, axis: requestAxis)
                        }
                    }
                    .disabled(!canEdit || !session.canEdit || !dimension.canResize || dimension.arcCount == 0
                        || dimension.sideArcIssues?.isEmpty == false)
                    Button("Double") {
                        let requestIDs = featureIDs
                        let requestAxis = dimension.id
                        let requestContext = session.patchEditorRequestIdentity
                        Task {
                            guard !Task.isCancelled, session.canEdit, session.patchEditorRequestIdentity == requestContext,
                                  session.selectedRegionIDs == Set(requestIDs) else { return }
                            await session.resizePatch(featureIDs: requestIDs, ratio: 2, axis: requestAxis)
                        }
                    }
                    .disabled(!canEdit || !session.canEdit || !dimension.canResize || dimension.arcCount == 0
                        || dimension.sideArcIssues?.isEmpty == false)
                }
            }
            .onAppear { draftState.synchronize(with: remoteSource) }
            .onChange(of: remoteSource) { _, newSource in draftState.synchronize(with: newSource) }
            .onChange(of: identity) { _, newIdentity in
                draftState = GeometryMeshPatchDimensionDraftState(identity: newIdentity, source: remoteSource)
            }
            }
        }
        .onHover(perform: onPreviewHover)
    }

    private func retrySideDataLoad() {
        let requestIDs = featureIDs
        let requestAxis = dimension.id
        let requestContext = session.patchEditorRequestIdentity
        Task {
            guard !Task.isCancelled,
                  session.patchEditorRequestIdentity == requestContext,
                  session.selectedRegionIDs == Set(requestIDs),
                  dimension.id == requestAxis,
                  !session.isEditing, !session.parentSaveInProgress else { return }
            await session.reload()
        }
    }

    private static func returnedDimensionSource(session: GeometryMeshSession,
                                                featureIDs: [Int], axis: String)
        -> GeometryMeshPatchDimensionDraftSource? {
        guard let sizing = session.snapshot?.patchSizing,
              sizing.state == "ready",
              Set(sizing.selectedRegionIDs) == Set(featureIDs),
              let dimension = sizing.dimensions.first(where: { $0.id == axis }) else { return nil }
        return GeometryMeshPatchDimensionDraftSource(dimension)
    }
}

private struct GeometryMeshDiagnosticsView: View {
    @ObservedObject var session: GeometryMeshSession
    @ObservedObject var store: WorkspaceStore
    @Binding var section: String
    @ObservedObject private var history = GeometryMeshDiagnosticsHistory.shared

    private var issues: [GeometryMeshDegreeIssue]? { session.degreeScan?.issues }
    private var selectedIssue: GeometryMeshDegreeIssue? { issues?.first { $0.id == session.selectedMapTargetID } }
    private var issueSelection: Binding<String?> {
        Binding(get: { session.selectedMapTargetID }, set: { session.selectDegreeIssue($0) })
    }
    private var canZoom: Bool { selectedIssue?.cellsExtent.map(valid) == true }
    private var checkMeshErrors: Binding<Bool> {
        Binding(get: { session.diagnosticsPreferences.checkMeshErrors }, set: { enabled in
            Task { await session.setCheckMeshErrors(enabled) }
        })
    }
    private var maxFacesPerNode: Binding<Int> {
        Binding(get: { session.diagnosticsPreferences.maxFacesPerNode }, set: { value in
            Task { await session.setMaxFacesPerNodeEntry(Double(value)) }
        })
    }
    @ViewBuilder private var meshErrorSummary: some View {
        HStack(spacing: 8) {
            Label(L10n.text("Mesh Error Summary"), systemImage: "waveform.path.ecg")
                .foregroundStyle(.secondary)
            if !session.diagnosticsPreferences.checkMeshErrors {
                Text(L10n.text("Not checked.")).foregroundStyle(.secondary)
            } else if session.isScanningDegreeErrors {
                ProgressView().controlSize(.small)
                Text(L10n.text("Scanning mesh...")).foregroundStyle(.secondary)
            } else if let issues {
                if issues.isEmpty {
                    Text(L10n.text("This mesh will export to HEC-RAS 7."))
                        .foregroundStyle(.secondary)
                } else {
                    Text(L10n.format("%@ node(s) would error in HEC-RAS 7.", issues.count.formatted()))
                        .foregroundStyle(.orange)
                    Text(L10n.text("Select an issue, then open it on the mesh map."))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(L10n.text("Mesh errors have not been scanned."))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Toggle(L10n.text("Check mesh errors"), isOn: checkMeshErrors)
                    .disabled(session.diagnosticsPreferencesScope == nil || session.isSavingDiagnosticsPreferences
                        || session.diagnosticsPreferencesScopeMismatch || session.parentSaveInProgress
                        || session.isEditing || session.isLoading)
                Stepper(L10n.text("Maximum faces per node"), value: maxFacesPerNode, in: 3...64, step: 1)
                    .frame(maxWidth: 270)
                    .disabled(!session.diagnosticsPreferences.checkMeshErrors
                        || session.diagnosticsPreferencesScope == nil || session.isSavingDiagnosticsPreferences
                        || session.diagnosticsPreferencesScopeMismatch || session.parentSaveInProgress
                        || session.isEditing || session.isLoading)
                Button("Scan Degree Errors", systemImage: "waveform.path.ecg") {
                    Task { await session.scanDegreeErrors() }
                }
                .disabled(!session.canScanDegreeErrors || !session.diagnosticsPreferences.checkMeshErrors)
                Button("Generate Mesh", systemImage: "arrow.triangle.2.circlepath") {
                    let projectSessionID = store.projectSessionID
                    Task { await session.generateMesh(projectSessionID: projectSessionID) }
                }
                .disabled(!session.canEdit)
                Spacer()
                Button("Zoom to Error", systemImage: "viewfinder") { zoomToSelected() }
                    .disabled(!canZoom)
                Button("Show on Mesh Map", systemImage: "map") { section = "Mesh Map" }
                    .disabled(selectedIssue == nil)
            }
            .padding(12)

            if let report = session.snapshot?.generationReport {
                GeometryMeshGenerationNotice(report: report,
                    cancelled: session.meshGenerationOutcome == "cancelled")
            }

            meshErrorSummary
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            VSplitView {
                GeometryMeshDiagnosticsHistoryPanel(history: history)
                    .frame(minHeight: 200, idealHeight: 255)
                Group {
                    if session.snapshot?.flowAreas.isEmpty == true {
                        ContentUnavailableView("No flow areas", systemImage: "square.grid.3x3",
                            description: Text("The geometry currently contains no source mesh rows. Scan and generate actions use the conceptual mesh in memory."))
                    } else {
                        Table(issues ?? [], selection: issueSelection) {
                            TableColumn("Flow Area", value: \.flowAreaName)
                                .width(min: 120, ideal: 180)
                            TableColumn("Node") { row in Text(row.nodeIndex.formatted()).monospacedDigit() }
                                .width(min: 65, ideal: 80)
                            TableColumn("Faces") { row in Text(row.faceCount.formatted()).monospacedDigit() }
                                .width(min: 65, ideal: 85)
                            TableColumn("Node Coordinates") { row in
                                if let x = row.x, let y = row.y, x.isFinite, y.isFinite {
                                    Text("\(x.formatted()), \(y.formatted())").monospacedDigit()
                                } else {
                                    Text("Unavailable").foregroundStyle(.secondary)
                                }
                            }
                            .width(min: 140, ideal: 170)
                            TableColumn("Cells Extent") { row in
                                Text(row.cellsExtent.map(extentSummary) ?? "Unavailable")
                                    .lineLimit(1).foregroundStyle(.secondary)
                            }
                            .width(min: 180, ideal: 260)
                        }
                        .overlay {
                            if !session.diagnosticsPreferences.checkMeshErrors {
                                ContentUnavailableView("Mesh error checking is turned off", systemImage: "checkmark.circle",
                                    description: Text("Enable Check mesh errors to scan the source flow-area meshes."))
                                    .allowsHitTesting(false)
                            } else if issues == nil {
                                ContentUnavailableView("Mesh error list unavailable", systemImage: "stethoscope",
                                    description: Text("Run the source degree scan to inspect high-degree mesh nodes."))
                            } else if issues?.isEmpty == true {
                                ContentUnavailableView("No mesh errors reported", systemImage: "checkmark.circle",
                                    description: Text("The source degree scan found no nodes above this face-count limit."))
                            }
                        }
                    }
                }
                .frame(minHeight: 210)
            }
            HStack {
                Text("This mesh preview is not saved until you save the geometry model.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let selectedIssue {
                    Text("Node \(selectedIssue.nodeIndex) · \(selectedIssue.faceCount) faces")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(10)
        }
    }

    private func zoomToSelected() {
        guard let extent = selectedIssue?.cellsExtent, valid(extent) else { return }
        let width = extent.maxX - extent.minX
        let height = extent.maxY - extent.minY
        let padX = width * 0.5
        let padY = height * 0.5
        store.activeMapState.viewport = ViewportRequest(
            lowerLeft: MapPoint(x: extent.minX - padX, y: extent.minY - padY),
            upperRight: MapPoint(x: extent.maxX + padX, y: extent.maxY + padY), animated: true, padding: 0)
    }

    private func valid(_ extent: GeometryMeshExtent) -> Bool {
        [extent.minX, extent.minY, extent.maxX, extent.maxY].allSatisfy(\.isFinite)
            && extent.minX < extent.maxX && extent.minY < extent.maxY
    }

    private func extentSummary(_ extent: GeometryMeshExtent) -> String {
        "X: \(extent.minX.formatted())–\(extent.maxX.formatted()), Y: \(extent.minY.formatted())–\(extent.maxY.formatted())"
    }
}

private struct GeometryMeshGenerationNotice: View {
    let report: GeometryMeshGenerationReport
    var cancelled = false
    private var title: String {
        if cancelled { return "Mesh generation cancelled" }
        if !report.meshWasReplaced { return "Mesh generation failed" }
        if report.partial { return "Partial mesh generated" }
        if report.succeeded { return "Mesh generated" }
        return "Mesh generation failed"
    }
    private var symbol: String {
        if cancelled { return "xmark.circle" }
        return report.succeeded && !report.partial ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }
    private var color: Color {
        if cancelled { return .secondary }
        return report.succeeded && !report.partial ? .green : .orange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L10n.text(title), systemImage: symbol).foregroundStyle(color).font(.headline)
            if let cellCount = report.cellCount {
                LabeledContent("Generated Cells", value: cellCount.formatted())
            }
            if !cancelled {
                ForEach(Array(report.messages.enumerated()), id: \.offset) { _, message in
                    Text(message).font(.callout).textSelection(.enabled)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

private struct GeometryMeshPrepareSummaryView: View {
    @ObservedObject var session: GeometryMeshSession
    @ObservedObject var store: WorkspaceStore
    private var summary: GeometryMeshPrepareSummary? { session.snapshot?.prepareSummary }

    var body: some View {
        Form {
            GeometryMeshPropertyTablesActionView(session: session)
            if let summary {
                Section("Prepare Summary") {
                    if let succeeded = summary.succeeded {
                        LabeledContent("Succeeded", value: succeeded ? "Yes" : "No")
                    } else { LabeledContent("Succeeded", value: "Not available") }
                    if let reason = summary.failureReason, !reason.isEmpty {
                        LabeledContent("Failure Reason") { Text(reason).textSelection(.enabled) }
                    }
                    if let version = summary.softwareVersion {
                        LabeledContent("Software Version", value: version).textSelection(.enabled)
                    }
                    if let start = summary.startTime {
                        LabeledContent("Start Time", value: start).textSelection(.enabled)
                    }
                    if let end = summary.endTime {
                        LabeledContent("End Time", value: end).textSelection(.enabled)
                    }
                    if let duration = summary.totalDurationSeconds {
                        LabeledContent("Total Duration", value: duration.formatted() + " s")
                    }
                    if let duration = summary.propertyTableDurationSeconds {
                        LabeledContent("Property Table Duration", value: duration.formatted() + " s")
                    }
                    HStack {
                        Button("Refresh Summary", systemImage: "arrow.clockwise") {
                            Task { await session.reload() }
                        }
                        .disabled(session.isLoading || session.isEditing || session.parentSaveInProgress)
                        Spacer()
                        Button("Copy Prepare Log", systemImage: "doc.on.doc") {
                            if let log = summary.prepareLog { store.system.copy(log) }
                        }
                        .disabled(summary.prepareLog?.isEmpty != false)
                    }
                }
                if let log = summary.prepareLog, !log.isEmpty {
                    Section("Prepare Log") {
                        ScrollView { Text(log).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(minHeight: 180)
                    }
                } else {
                    Section("Prepare Log") {
                        Text(L10n.text("Preparation completed without logging any messages."))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                ContentUnavailableView("Prepare summary unavailable", systemImage: "doc.text.magnifyingglass",
                    description: Text(session.preparePending
                        ? "Prepare is queued in this geometry draft and will run during parent model save."
                        : "This geometry has not been prepared yet. Prepare it to generate a summary and log."))
            }
        }
        .formStyle(.grouped)
    }
}

struct GeometryMeshPropertyTablesActionView: View {
    @ObservedObject var session: GeometryMeshSession

    var body: some View {
        Section("Property Tables") {
            Text("Compute the source flow-area property tables for the current geometry and mesh draft.")
                .font(.caption).foregroundStyle(.secondary)
            if session.isComputingPropertyTables {
                OperationProgressView(title: "Computing property tables…",
                    message: L10n.text(session.propertyTablesProgress?.message
                        ?? session.propertyTablesProgress?.taskName
                        ?? "Processing property tables for this geometry…"),
                    fraction: session.propertyTablesProgress?.fraction,
                    cancelling: session.isCancellingPropertyTables,
                    cancel: session.isCancellingPropertyTables ? nil : { session.cancelPropertyTables() })
            } else {
                Button("Compute Property Tables", systemImage: "tablecells") {
                    Task { _ = await session.computePropertyTables() }
                }
                .disabled(!session.canComputePropertyTables)
            }
            if session.propertyTablesOutcome == "succeeded" {
                Label("Property tables computed. Save Geometry to write them to the project.",
                    systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if session.propertyTablesOutcome == "cancelled" {
                Label("Property-table computation cancelled.", systemImage: "xmark.circle")
                    .foregroundStyle(.secondary)
            }
            if !session.propertyTablesMessages.isEmpty {
                ForEach(Array(session.propertyTablesMessages.enumerated()), id: \.offset) { _, message in
                    Text(message).font(.callout).textSelection(.enabled)
                }
            }
        }
    }
}
