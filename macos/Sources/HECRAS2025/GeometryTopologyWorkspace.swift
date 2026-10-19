import AppKit
import SwiftUI

/// Source-backed Topology Arcs/Regions/Nodes workspace. Parent routing and
/// save lifecycle stay in ModelEditorSession; this child edits a typed draft.
struct GeometryTopologyWorkspacePage: View {
    let featureKind: String
    @ObservedObject var session: GeometryTopologySession
    @ObservedObject var store: WorkspaceStore
    @State private var activeTool: GeometryTopologyToolPanel?
    @State private var patchSizingRequest: GeometryTopologyPatchSizingRequest?
    @State private var profileActionCapture: GeometryTopologyFeatureActionCapture?
    @State private var featureActionError: String?

    private var table: GeometryTopologyFeatureTable { session.table(for: featureKind) }
    private var selectedRows: [GeometryTopologyFeatureRow] { session.selectedRows(for: featureKind) }
    private var filterFeatureKind: String { featureKind == "region" ? "region" : "arc" }
    private var visibleTableRows: [GeometryTopologyFeatureRow] {
        guard featureKind == "arc" || featureKind == "region" else { return table.rows }
        let query = session.tagFilterQuery(for: filterFeatureKind)
        guard !query.clauses.isEmpty,
              session.tagFilterResultIsCurrent(for: filterFeatureKind),
              let result = session.tagFilterResult(for: filterFeatureKind) else { return table.rows }
        let matchingFIDs = Set(result.matchedFeatureIDs)
        return table.rows.filter { matchingFIDs.contains($0.fid) }
    }
    private var visibleTableRowIDs: Set<String> { Set(visibleTableRows.map(\.id)) }
    private var selection: Binding<Set<String>> {
        Binding(get: { session.selectedFeatureIDs[featureKind, default: []] },
                set: { newSelection in
                    // SwiftUI Table only reports visible rows after filtering.
                    // Keep selected source IDs that are temporarily hidden.
                    let hiddenSelection = session.selectedFeatureIDs[featureKind, default: []]
                        .subtracting(visibleTableRowIDs)
                    session.select(newSelection.union(hiddenSelection), featureKind: featureKind)
                })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label(L10n.text(title), systemImage: symbol).font(.headline)
                Text(visibleTableRows.count.formatted()).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if session.isEditing || session.isLoading {
                    ProgressView().controlSize(.small)
                }
                Button(L10n.text("Undo Topology Edit"), systemImage: "arrow.uturn.backward") {
                    Task { await session.undo() }
                }
                .disabled(!session.canUndo)
                Button(L10n.text("Redo Topology Edit"), systemImage: "arrow.uturn.forward") {
                    Task { await session.redo() }
                }
                .disabled(!session.canRedo)
                if session.isDirty {
                    Label("Unsaved topology changes", systemImage: "pencil.circle.fill")
                        .foregroundStyle(.orange)
                        .help("These edits will be included with the geometry's Save action.")
                }
                if session.hasPendingInputs {
                    Button(L10n.text("Discard Pending Input"), systemImage: "xmark.circle") {
                        session.discardPendingInputs()
                    }
                    .help(L10n.text("Discard unsubmitted recipe or coordinate text without discarding applied topology edits."))
                    .disabled(session.parentSaveInProgress || session.isEditing)
                }
                Button("Discard topology draft", systemImage: "arrow.uturn.backward") {
                    Task { await session.discardDraft() }
                }
                .disabled(!session.isDirty || session.parentSaveInProgress || session.isEditing)
                if !availableTools.isEmpty {
                    GeometryTopologyToolsMenu(selection: $activeTool, availableTools: availableTools)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if let error = session.error {
                Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            if let featureActionError {
                Label(L10n.text(featureActionError), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            Divider()

            if session.isLoading && session.snapshot == nil {
                ProgressView("Loading topology…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let snapshot = session.snapshot {
                HSplitView {
                    VSplitView {
                        GeometryTopologyMapView(map: snapshot.map ?? .empty,
                            cameraIdentity: session.mapCameraIdentity,
                            activeFeatureKind: featureKind,
                            selectedIDs: session.selectedFeatureIDs[featureKind, default: []],
                            diagnosticFeatureIDs: session.diagnosticMapFeatureIDs,
                            arcStyle: store.effectiveGeometryVectorStyle(definitionID: "Arc_Line_Symbology",
                                session: session, nodeType: "ConceptualMesh"),
                            internalPointStyle: store.effectiveGeometryVectorStyle(definitionID: "Internal_Point_Symbology",
                                session: session, nodeType: "ConceptualMesh"),
                            nodeStyle: store.effectiveGeometryVectorStyle(definitionID: "Node_Symbology",
                                session: session, nodeType: "ConceptualMesh"),
                            deletableNodeStyle: store.effectiveGeometryVectorStyle(definitionID: "Deletable_Node_Symbology",
                                session: session, nodeType: "ConceptualMesh")) { ids in
                                session.select(ids, featureKind: featureKind)
                            }
                            .frame(minHeight: 220, idealHeight: 320)
                        featureTable
                            .frame(minHeight: 190, idealHeight: 300, maxHeight: .infinity)
                    }
                    .frame(minWidth: 500, idealWidth: 820, maxWidth: .infinity, maxHeight: .infinity)
                    detailInspector(snapshot: snapshot)
                        .frame(minWidth: 300, idealWidth: 360, maxWidth: 440, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView("Topology unavailable",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text(L10n.text(session.error ?? "The geometry topology has not loaded.")))
            }
        }
        .task {
            if session.snapshot == nil { await session.reload() }
            routePendingToolRequest()
        }
        .task(id: store.geometryVectorStyleContextIdentity) {
            await store.refreshVectorSymbologyContexts(mapID: store.lastActiveMapID)
        }
        .onAppear(perform: routePendingToolRequest)
        .onChange(of: featureKind) { _, _ in activeTool = nil }
        .onChange(of: store.editorToolPresentationRequest?.id) { _, _ in routePendingToolRequest() }
        .onChange(of: session.snapshot?.revision) { _, _ in routePendingToolRequest() }
        .sheet(item: $patchSizingRequest) { request in
            GeometryTopologyQuadPatchSizingSheet(parent: request.parent, topology: session,
                regionFID: request.regionFID)
        }
        .sheet(item: $profileActionCapture) { capture in
            GeometryTopologyFeatureProfileSheet(store: store, topology: session, capture: capture)
        }
    }

    private var availableTools: [GeometryTopologyToolPanel] {
        switch featureKind {
        case "arc": [.arcPoints, .tagFilter]
        case "region": [.recipe, .tagFilter]
        default: []
        }
    }

    private func routePendingToolRequest() {
        guard let request = store.editorToolPresentationRequest,
              request.projectSessionID == store.projectSessionID,
              store.primaryEditorSession(.geometry).geometryTopology.map({ $0 === session }) == true,
              store.primaryEditorSession(.geometry).modelAssetID == request.assetID,
              session.mapAssetIdentity == request.assetID,
              session.snapshot != nil else { return }

        let panel: GeometryTopologyToolPanel?
        switch (featureKind, request.action) {
        case ("arc", .arcPoints) where request.featureKind == "arc":
            panel = .arcPoints
        case ("arc", .tagFilter) where request.featureKind == nil:
            panel = .tagFilter
        case ("region", .topologyRecipe) where request.featureKind == nil:
            panel = .recipe
        default:
            panel = nil
        }
        guard let panel else { return }
        activeTool = panel
        store.consumeEditorToolPresentationRequest(request.id)
    }

    private var featureTable: some View {
        Table(visibleTableRows, selection: selection) {
            TableColumn("FID") { row in
                Text(value(row, "FID", fallback: String(row.fid)))
                    .font(.caption.monospacedDigit())
                    .contextMenu { featureContextMenu(for: row) }
            }
            .width(min: 55, ideal: 70)
            TableColumn(L10n.text("Diagnostic")) { row in
                if session.diagnosticRowIDs(for: featureKind).contains(row.id) {
                    Label(L10n.text("Target"), systemImage: "scope")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.pink)
                        .help(L10n.text("This row is referenced by the selected topology message."))
                        .accessibilityLabel(L10n.text("Diagnostic target"))
                        .contextMenu { featureContextMenu(for: row) }
                }
            }
            .width(min: 42, ideal: 50)
            if featureKind == "arc" {
                TableColumn("Nodes") { row in
                    Text("\(value(row, "StartNodeID", fallback: "—")) → \(value(row, "EndNodeID", fallback: "—"))")
                        .font(.caption.monospacedDigit())
                        .contextMenu { featureContextMenu(for: row) }
                }
                .width(min: 100, ideal: 130)
                TableColumn("Length") { row in
                    Text(value(row, "Length", fallback: "—")).monospacedDigit()
                        .contextMenu { featureContextMenu(for: row) }
                }
                .width(min: 75, ideal: 90)
            } else {
                TableColumn("X") { row in
                    Text(value(row, "X", fallback: "—")).monospacedDigit()
                        .contextMenu { featureContextMenu(for: row) }
                }
                    .width(min: 85, ideal: 105)
                TableColumn("Y") { row in
                    Text(value(row, "Y", fallback: "—")).monospacedDigit()
                        .contextMenu { featureContextMenu(for: row) }
                }
                    .width(min: 85, ideal: 105)
            }
            TableColumn("Properties and tags") { row in
                Text(compactAttributes(row))
                    .lineLimit(1)
                    .font(.caption)
                    .contextMenu { featureContextMenu(for: row) }
            }
        }
        .overlay {
            if (featureKind == "arc" || featureKind == "region")
                && visibleTableRows.isEmpty && !table.rows.isEmpty && session.tagFilterResultIsCurrent(for: filterFeatureKind)
                && !session.tagFilterQuery(for: filterFeatureKind).clauses.isEmpty {
                ContentUnavailableView(L10n.text("No features match this filter."), systemImage: "line.3.horizontal.decrease",
                    description: Text(L10n.text("Change or clear the filter conditions to show source features.")))
                    .allowsHitTesting(false)
            } else if table.rows.isEmpty {
                ContentUnavailableView(L10n.format("No %@", L10n.text(title)), systemImage: symbol,
                    description: Text("The source topology contains no rows for this table."))
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func featureContextMenu(for row: GeometryTopologyFeatureRow) -> some View {
        GeometryTopologyFeatureContextMenu(topology: session, store: store,
            featureKind: featureKind, rowIDs: contextRowIDs(for: row.id),
            profileCapture: $profileActionCapture, error: $featureActionError)
    }

    /// Original DataGrid right-click behavior retains a selected row group,
    /// adds an unselected row under the multi-select modifier, and otherwise
    /// scopes the feature menu to the clicked row. SwiftUI opens context menus
    /// after its row hit test, so the concrete native action applies this
    /// captured group to the source FeatureContext selection before dispatch.
    private func contextRowIDs(for clickedRowID: String) -> [String] {
        let selected = session.selectedFeatureIDs[featureKind, default: []]
        let modifiers = NSEvent.modifierFlags
        return NativeDataGridContextSelection.rowIDs(clickedRowID: clickedRowID,
            selectedRowIDs: selected, sourceRowIDs: table.rows.map(\.id),
            addsToSelection: modifiers.contains(.control) || modifiers.contains(.command))
    }

    @ViewBuilder
    private func detailInspector(snapshot: GeometryTopologySnapshot) -> some View {
        Group {
            switch activeTool {
            case .recipe where featureKind == "region":
                GeometryTopologyRecipeToolView(session: session,
                    selectedControlPointFIDs: selectedControlPointFIDs)
            case .arcPoints where featureKind == "arc":
                GeometryTopologyArcPointsToolView(session: session, selectedArcRows: selectedRows)
            case .tagFilter where featureKind == "arc" || featureKind == "region":
                GeometryTopologyTagFilterToolView(session: session, featureKind: featureKind)
            default:
                regularDetailInspector(snapshot: snapshot)
            }
        }
    }

    private var selectedControlPointFIDs: [Int] {
        session.selectedRows(for: "region").map(\.fid)
    }

    private func regularDetailInspector(snapshot: GeometryTopologySnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if featureKind == "arc" {
                    GeometryTopologyUnavailableProfilePanel()
                }
                let selectedDiagnostics = session.diagnosticMessages(featureKind: featureKind,
                    rowIDs: Set(selectedRows.map(\.id)))
                if !selectedDiagnostics.isEmpty {
                    ResultLayerErrorIndicatorView(messages: selectedDiagnostics, store: store)
                }
                if selectedRows.isEmpty {
                    ContentUnavailableView(L10n.format("Select a %@", L10n.text(singular)), systemImage: "cursorarrow.click",
                        description: Text("Choose one source feature to edit its properties, or select several features to assign a shared tag."))
                        .frame(minHeight: 180)
                } else {
                    selectionHeader
                    if selectedRows.count == 1, featureKind != "node" {
                        quickSizeActions
                        GeometryTopologyFieldEditor(row: selectedRows[0], fields: table.editableFields,
                            canEdit: session.canEdit && !session.isEditing) { fieldID, value in
                            Task { await session.setField(featureKind: featureKind, fid: selectedRows[0].fid,
                                fieldID: fieldID, value: value) }
                        }
                    }
                    if featureKind != "node" {
                        GeometryTopologyTagEditor(featureKind: featureKind, selectedRows: selectedRows,
                            definitions: featureKind == "arc" ? snapshot.arcTags : snapshot.regionTags,
                            recentTags: featureKind == "arc" ? snapshot.recentArcTags : snapshot.recentRegionTags,
                            canEdit: session.canEdit && !session.isEditing,
                            createTag: { name, type in Task { await session.createTag(featureKind: featureKind, name: name, type: type) } },
                            applyRecent: { recent in Task { await session.setTag(featureKind: featureKind,
                                featureIDs: selectedRows.map(\.fid), name: recent.name, value: recent.value) } },
                            setTag: { name, value in Task { await session.setTag(featureKind: featureKind,
                                featureIDs: selectedRows.map(\.fid), name: name, value: value) } },
                            removeTag: { name in Task { await session.removeTag(featureKind: featureKind,
                                featureIDs: selectedRows.map(\.fid), name: name) } })
                    }
                    sourceDetails
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
    }

    private var selectionHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.format("Selected %@", L10n.text(selectedRows.count == 1 ? singular : title)))
                .font(.headline)
            if selectedRows.count == 1, let row = selectedRows.first {
                HStack(spacing: 4) {
                    Text("FID")
                    Text("\(row.fid) · \(row.id)")
                }
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            } else {
                Text(L10n.format("%@ source features", selectedRows.count.formatted()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var quickSizeActions: some View {
        if let row = selectedRows.first {
            let sizeFunction = row.values["SizeFunction"] ?? "Unset"
            let arcResizeIsNoOp = featureKind == "arc" && sizeFunction == "Unset"
            let patchType = row.values["PatchType"] ?? ""
            let scalarRegionResize = featureKind == "region" && ["TrianglePaver", "Cartesian"].contains(patchType)
            let quadRegionResize = featureKind == "region" && patchType == "Quad"
            let resizeDescription: String = {
                if scalarRegionResize { return "Scales both Constant Size and Secondary Constant Size." }
                if quadRegionResize { return "Resizes the selected side's boundary arcs, following their Constant or Count size function." }
                guard featureKind == "arc" else { return "The source editor does not define a scalar quick-size action for this patch type." }
                switch sizeFunction {
                case "Constant": return "Scales the selected arc's Constant Size."
                case "CountWithBias": return "Scales Point Count using the source integer ratio rule."
                default: return "The source size function is Unset; its quick resize action has no effect."
                }
            }()
            GroupBox("Quick size adjustment") {
                VStack(alignment: .leading, spacing: 10) {
                    Group {
                        if quadRegionResize {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("North / South arcs")
                                    Spacer()
                                    ratioButton("Half", systemImage: "arrow.down.right.and.arrow.up.left", row: row,
                                        half: true, axis: "NorthSouth")
                                    ratioButton("Double", systemImage: "arrow.up.left.and.arrow.down.right", row: row,
                                        half: false, axis: "NorthSouth")
                                }
                                HStack {
                                    Text("East / West arcs")
                                    Spacer()
                                    ratioButton("Half", systemImage: "arrow.down.right.and.arrow.up.left", row: row,
                                        half: true, axis: "EastWest")
                                    ratioButton("Double", systemImage: "arrow.up.left.and.arrow.down.right", row: row,
                                        half: false, axis: "EastWest")
                                }
                            }
                        } else if scalarRegionResize || featureKind == "arc" {
                            HStack {
                                ratioButton("Half size", systemImage: "arrow.down.right.and.arrow.up.left", row: row,
                                    half: true, axis: nil)
                                ratioButton("Double size", systemImage: "arrow.up.left.and.arrow.down.right", row: row,
                                    half: false, axis: nil)
                            }
                            .disabled(arcResizeIsNoOp)
                        } else {
                            Text(resizeDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.bordered)
                    if quadRegionResize || scalarRegionResize || featureKind == "arc" {
                        Text(resizeDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if quadRegionResize {
                        if patchSizingParentSession == nil {
                            Label("The current topology editor cannot be matched to its mesh child draft.",
                                systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("Open Patch Sizing", systemImage: "square.grid.3x3") {
                            openPatchSizing(for: row)
                        }
                        .disabled(patchSizingParentSession == nil || session.isEditing || session.isLoading)
                        .help(L10n.text("Open the selected Quad region in the matching mesh child draft."))
                    }
                }
            }
            .disabled(!session.canEdit || session.isEditing)
        }
    }

    private func ratioButton(_ title: String, systemImage: String, row: GeometryTopologyFeatureRow,
                             half: Bool, axis: String?) -> some View {
        Button(title, systemImage: systemImage) {
            Task { await session.adjustSize(featureKind: featureKind, fid: row.fid, half: half, axis: axis) }
        }
    }

    private var patchSizingParentSession: ModelEditorSession? {
        let parent = store.primaryEditorSession(.geometry)
        guard parent.geometryTopology === session,
              parent.modelAssetID == session.mapAssetIdentity,
              parent.geometryMesh != nil else { return nil }
        return parent
    }

    private func openPatchSizing(for row: GeometryTopologyFeatureRow) {
        guard featureKind == "region", selectedRows.count == 1,
              selectedRows.first?.fid == row.fid,
              row.values["PatchType"] == "Quad",
              let parent = patchSizingParentSession else { return }
        patchSizingRequest = GeometryTopologyPatchSizingRequest(parent: parent, regionFID: row.fid)
    }

    private var sourceDetails: some View {
        GroupBox("Source attributes") {
            VStack(alignment: .leading, spacing: 7) {
                if selectedRows.count == 1, let row = selectedRows.first {
                    ForEach(table.columns) { column in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(L10n.text(column.title)).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(row.values[column.id] ?? "—")
                                .font(.caption.monospaced())
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        }
                    }
                } else {
                    Text("Source attribute values vary by feature. Tag assignment applies the chosen value to every selected feature.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func value(_ row: GeometryTopologyFeatureRow, _ key: String, fallback: String) -> String {
        row.values[key] ?? fallback
    }

    private func compactAttributes(_ row: GeometryTopologyFeatureRow) -> String {
        let excluded = Set(["FID", "X", "Y", "StartNodeID", "EndNodeID", "Length"])
        return table.columns.filter { !excluded.contains($0.id) }
            .compactMap { column in
                guard let value = row.values[column.id], !value.isEmpty else { return nil }
                return "\(column.title): \(value)"
            }
            .joined(separator: " · ")
    }

    private var title: String {
        switch featureKind {
        case "arc": "Arcs"
        case "region": "Regions"
        case "node": "Nodes"
        default: "Topology"
        }
    }
    private var singular: String {
        switch featureKind {
        case "arc": "Arc"
        case "region": "Region"
        case "node": "Node"
        default: "Feature"
        }
    }
    private var symbol: String {
        switch featureKind {
        case "arc": "point.topleft.down.to.point.bottomright.curvepath"
        case "region": "point.3.filled.connected.trianglepath.dotted"
        case "node": "circle.grid.3x3.fill"
        default: "point.3.connected.trianglepath.dotted"
        }
    }
}

private struct GeometryTopologyPatchSizingRequest: Identifiable {
    let id = UUID()
    let parent: ModelEditorSession
    let regionFID: Int
}

/// Hands the selected topology region to the GeometryMeshSession owned by
/// the same model editor. All edits remain in that existing mesh child draft.
private struct GeometryTopologyQuadPatchSizingSheet: View {
    @ObservedObject var parent: ModelEditorSession
    @ObservedObject var topology: GeometryTopologySession
    let regionFID: Int
    @Environment(\.dismiss) private var dismiss
    @State private var preparedContext: GeometryMeshTopologyPatchContext?
    @State private var isPreparing = true
    @State private var routeError: String?

    private var mesh: GeometryMeshSession? { parent.geometryMesh }
    private var selectedRegionRows: [GeometryTopologyFeatureRow] { topology.selectedRows(for: "region") }
    private var liveContext: GeometryMeshTopologyPatchContext? {
        guard parent.loaded,
              let assetID = parent.modelAssetID,
              topology.mapAssetIdentity == assetID,
              let topologyRevision = topology.snapshot?.revision,
              topologyRevision == parent.sourceFileRevision,
              selectedRegionRows.count == 1,
              selectedRegionRows.first?.fid == regionFID,
              selectedRegionRows.first?.values["PatchType"] == "Quad" else { return nil }
        return GeometryMeshTopologyPatchContext(assetID: assetID,
            sourceRevision: parent.sourceFileRevision,
            topologyDraftState: topology.topologyStateForParentSave,
            selectedRegionIDs: [regionFID])
    }

    private var meshSnapshotIsCurrent: Bool {
        guard let context = liveContext, let mesh else { return false }
        return context.matchesMeshSnapshot(mesh.snapshot, meshAssetID: mesh.assetIdentity,
            liveSelection: mesh.selectedRegionIDs, canEdit: mesh.canEdit)
    }

    private var routeContextIsCurrent: Bool {
        guard parent.geometryTopology === topology,
              let context = liveContext else { return false }
        return preparedContext == context
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Quad Patch Sizing", systemImage: "square.grid.3x3").font(.headline)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()

            if parent.geometryTopology !== topology {
                unavailable("The current topology editor cannot be matched to its mesh child draft.")
            } else if liveContext == nil {
                unavailable("Topology selection changed while Patch Sizing was open.")
            } else if routeContextIsCurrent, meshSnapshotIsCurrent, let mesh {
                GeometryMeshPatchSizingInspector(session: mesh,
                    requiredRegionIDs: Set([regionFID]))
                Text("Patch edits stay in the geometry draft until the existing Save action.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if isPreparing {
                        ProgressView("Loading the current source topology and patch sides…")
                    } else if let error = routeError ?? mesh?.error {
                        Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    } else {
                        Label("The patch sizing snapshot does not match the current source revision, staged topology, or region selection.",
                            systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.secondary)
                    }
                    Button("Retry side data load", systemImage: "arrow.clockwise") {
                        Task { await synchronizeMeshChildDraft() }
                    }
                    .disabled(isPreparing || mesh?.isEditing == true || mesh?.parentSaveInProgress == true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(20)
            }
        }
        .frame(minWidth: 520, idealWidth: 640, minHeight: 620, idealHeight: 760)
        .task(id: liveContext?.stableKey ?? "no-quad-selection") {
            await synchronizeMeshChildDraft()
        }
    }

    @ViewBuilder private func unavailable(_ message: String) -> some View {
        ContentUnavailableView(L10n.text(message), systemImage: "exclamationmark.triangle",
            description: Text("Close the editor and reopen it from the currently selected Quad region."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor private func synchronizeMeshChildDraft() async {
        guard parent.geometryTopology === topology,
              let context = liveContext,
              let mesh else {
            isPreparing = false
            preparedContext = nil
            routeError = L10n.text("The current topology editor cannot be matched to its mesh child draft.")
            return
        }

        isPreparing = true
        routeError = nil
        preparedContext = nil
        await parent.ensureGeometryMeshLoaded()
        guard !Task.isCancelled,
              parent.geometryTopology === topology,
              liveContext == context else {
            isPreparing = false
            routeError = L10n.text("The topology source context changed while patch sizing was loading.")
            return
        }

        await mesh.selectRegions(Set(context.selectedRegionIDs))
        guard !Task.isCancelled,
              parent.geometryTopology === topology,
              liveContext == context else {
            isPreparing = false
            routeError = L10n.text("The topology source context changed while patch sizing was loading.")
            return
        }
        preparedContext = context
        isPreparing = false
        if !context.matchesMeshSnapshot(mesh.snapshot, meshAssetID: mesh.assetIdentity,
            liveSelection: mesh.selectedRegionIDs, canEdit: mesh.canEdit), mesh.error == nil {
            routeError = L10n.text("The patch sizing snapshot does not match the current source revision, staged topology, or region selection.")
        }
    }
}

private struct GeometryTopologyUnavailableProfilePanel: View {
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label(L10n.text("Sample lines and result profiles"), systemImage: "chart.xyaxis.line")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Menu {
                        Button(L10n.text("Unavailable")) {}
                            .disabled(true)
                    } label: {
                        Label(L10n.text("Result map type"), systemImage: "map")
                    }
                    .disabled(true)
                }
                ZStack {
                    Canvas { context, size in
                        let plot = CGRect(x: 12, y: 10, width: max(0, size.width - 22), height: max(0, size.height - 20))
                        var grid = Path()
                        grid.move(to: CGPoint(x: plot.minX, y: plot.minY))
                        grid.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
                        grid.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
                        for fraction in [0.25, 0.5, 0.75] {
                            let y = plot.minY + plot.height * fraction
                            grid.move(to: CGPoint(x: plot.minX, y: y))
                            grid.addLine(to: CGPoint(x: plot.maxX, y: y))
                        }
                        context.stroke(grid, with: .color(.secondary.opacity(0.28)),
                                       style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    }
                    Text(L10n.text("Terrain and result samples are not available from the current geometry provider."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(10)
                        .frame(maxWidth: 300)
                }
                .frame(height: 112)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct GeometryTopologyFieldEditor: View {
    let row: GeometryTopologyFeatureRow
    let fields: [GeometryTopologyField]
    let canEdit: Bool
    let apply: (String, String) -> Void
    @State private var drafts: [String: String]

    init(row: GeometryTopologyFeatureRow, fields: [GeometryTopologyField], canEdit: Bool,
         apply: @escaping (String, String) -> Void) {
        self.row = row
        self.fields = fields
        self.canEdit = canEdit
        self.apply = apply
        _drafts = State(initialValue: row.values)
    }

    var body: some View {
        GroupBox("Properties") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(fields) { field in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(L10n.text(field.title)).font(.subheadline)
                            Spacer()
                            Button("Apply") { apply(field.id, drafts[field.id] ?? "") }
                                .controlSize(.small)
                                .disabled(!canEdit || (drafts[field.id] ?? "") == (row.values[field.id] ?? ""))
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
                ForEach(field.choices, id: \.self) { choice in Text(choice).tag(choice) }
            }
            .labelsHidden()
            .disabled(!canEdit || field.readOnly)
        } else if field.sourceType.lowercased() == "bool" || field.sourceType.lowercased() == "boolean" {
            Toggle(field.title, isOn: Binding(get: { value.wrappedValue.lowercased() == "true" },
                set: { value.wrappedValue = $0 ? "true" : "false" }))
                .labelsHidden()
                .disabled(!canEdit || field.readOnly)
        } else {
            TextField(field.title, text: value)
                .textFieldStyle(.roundedBorder)
                .disabled(!canEdit || field.readOnly)
        }
    }
}

private struct GeometryTopologyTagEditor: View {
    let featureKind: String
    let selectedRows: [GeometryTopologyFeatureRow]
    let definitions: [GeometryTopologyTagDefinition]
    let recentTags: [GeometryTopologyRecentTag]
    let canEdit: Bool
    let createTag: (String, String) -> Void
    let applyRecent: (GeometryTopologyRecentTag) -> Void
    let setTag: (String, String) -> Void
    let removeTag: (String) -> Void

    @State private var selectedTagID = ""
    @State private var tagValue = ""
    @State private var tagBoolean = false
    @State private var showingCreateTag = false
    @State private var newTagName = ""
    @State private var newTagType = "String"

    private var selectedDefinition: GeometryTopologyTagDefinition? {
        definitions.first { $0.id == selectedTagID } ?? definitions.first
    }
    private var currentValues: [String] {
        guard let selectedDefinition else { return [] }
        return selectedRows.compactMap { $0.values[selectedDefinition.id] }
    }
    private var valuesVary: Bool { Set(currentValues).count > 1 }

    var body: some View {
        GroupBox("Tags") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("Tag", selection: $selectedTagID) {
                        ForEach(definitions) { definition in
                            Text("\(definition.id) · \(definition.type)").tag(definition.id)
                        }
                    }
                    .labelsHidden()
                    .disabled(definitions.isEmpty)
                    Button("Add Tag", systemImage: "plus") { showingCreateTag = true }
                        .labelStyle(.iconOnly)
                        .help("Create a metadata column in the source topology.")
                        .disabled(!canEdit)
                }

                if let selectedDefinition {
                    if selectedDefinition.type.caseInsensitiveCompare("Boolean") == .orderedSame || selectedDefinition.type.caseInsensitiveCompare("bool") == .orderedSame {
                        Toggle(valuesVary ? "Assign a shared Boolean value" : "Value",
                            isOn: $tagBoolean)
                            .disabled(!canEdit)
                    } else {
                        TextField(valuesVary ? "Values vary by feature" : "Tag value", text: $tagValue)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!canEdit)
                    }
                    HStack {
                        Button("Apply to Selection", systemImage: "checkmark") {
                            let value = selectedDefinition.type.caseInsensitiveCompare("Boolean") == .orderedSame
                                ? (tagBoolean ? "true" : "false") : tagValue
                            setTag(selectedDefinition.id, value)
                        }
                        .disabled(!canEdit || selectedRows.isEmpty)
                        Button("Remove Tag", systemImage: "minus.circle") {
                            removeTag(selectedDefinition.id)
                        }
                        .disabled(!canEdit || selectedRows.isEmpty)
                    }
                    if valuesVary {
                        Text("Selected features currently have different values for this tag.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No tag columns are defined for this feature table.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !recentTags.isEmpty {
                    Menu("Recent tag values") {
                        ForEach(recentTags) { recent in
                            Button("\(recent.name): \(recent.value)") { applyRecent(recent) }
                        }
                    }
                    .disabled(!canEdit || selectedRows.isEmpty || !recentTags.contains(where: { recent in definitions.contains(where: { $0.id == recent.name }) }))
                }
            }
        }
        .onAppear { selectInitialTag() }
        .onChange(of: definitions.map(\.id)) { _, _ in selectInitialTag() }
        .onChange(of: selectedTagID) { _, _ in loadSelectedValues() }
        .sheet(isPresented: $showingCreateTag) {
            createTagSheet
        }
    }

    private var createTagSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create Tag").font(.title2.weight(.semibold))
            TextField("Tag name", text: $newTagName)
                .textFieldStyle(.roundedBorder)
            Picker("Type", selection: $newTagType) {
                ForEach(["String", "Integer", "Numeric", "Boolean"], id: \.self) { type in
                    Text(type).tag(type)
                }
            }
            .pickerStyle(.segmented)
            HStack {
                Spacer()
                Button("Cancel") { showingCreateTag = false }
                Button("Create") {
                    let name = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
                    selectedTagID = name
                    createTag(name, newTagType)
                    showingCreateTag = false
                    newTagName = ""
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func selectInitialTag() {
        if !definitions.contains(where: { $0.id == selectedTagID }) {
            selectedTagID = definitions.first?.id ?? ""
        }
        loadSelectedValues()
    }

    private func loadSelectedValues() {
        guard let definition = definitions.first(where: { $0.id == selectedTagID }) else {
            tagValue = ""
            tagBoolean = false
            return
        }
        let values = selectedRows.compactMap { $0.values[definition.id] }
        tagValue = values.first ?? ""
        tagBoolean = values.first?.lowercased() == "true"
    }
}
