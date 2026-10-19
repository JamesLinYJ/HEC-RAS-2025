import RASWorkspaceCore
import SwiftUI

private enum TerrainTopologyTool: String, CaseIterable, Identifiable, Hashable {
    case select = "Select"
    case draw = "Draw Arc"
    case split = "Split Arc"
    case moveNodes = "Move or Merge Nodes"
    case moveVertex = "Move Arc Vertex"
    case insertVertex = "Insert Arc Vertex"
    case deleteVertex = "Delete Arc Vertex"
    case maskRegion = "Mask Region"
    case remove = "Remove"
    var id: String { rawValue }
}

struct TerrainTopologyWorkbench: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @State private var map: TerrainMapData?
    @State private var topology: TerrainTopologyData?
    @State private var selectedIDs: Set<String> = []
    @State private var drawPoints: [TerrainMapCoordinate] = []
    @State private var mapCellSize: Double?
    @State private var tool: TerrainTopologyTool = .select
    @State private var splitMode: TerrainTopologySplitMode = .anywhere
    @State private var loading = false
    @State private var working = false
    @State private var error: String?
    @State private var loadedIdentity: String?
    @State private var refreshGeneration = 0
    @State private var metadataEdits: [String: String] = [:]

    private let topologyTableID = "ChannelModTopologyEditor/Features"

    private var inputID: String? {
        guard let value = session.fields[TerrainEditorContract.sourceField], !value.isEmpty else { return nil }
        return value
    }
    private var inputType: String? {
        guard let inputID else { return nil }
        return session.sourceCollections[TerrainEditorContract.sourceField]?.itemDetails[inputID]?.terrainInfo?.type
    }
    private var isChannelInput: Bool { inputType == "Channel" }
    private var refreshIdentity: String {
        [session.modelAssetID ?? "", session.terrainSourceRevision ?? "", inputID ?? "", String(session.terrainEditRevision)].joined(separator: "|")
    }
    private var rasterLayers: [MapRasterLayer] {
        var layers: [MapRasterLayer] = []
        if let raster = map?.raster, let layer = try? raster.presentation(name: "Full Terrain").rasters.first { layers.append(layer) }
        if let raster = map?.selectedRaster, let layer = try? raster.presentation(name: "Selected Terrain Input").rasters.first { layers.append(layer) }
        return layers
    }
    private var sourceMapFeatures: [TerrainMapFeature] { map?.features ?? [] }
    private var topologyFeatures: [TerrainMapFeature] {
        (topology?.features ?? []).compactMap { feature in
            guard feature.kind != "region" else { return nil }
            let kind = feature.kind == "arcVertex" ? "controlPoint" : feature.kind
            return TerrainMapFeature(id: feature.id, tableId: topologyTableID, points: feature.points, kind: kind)
        }
    }
    private var topologyRegions: [TerrainMapPolygon] {
        (topology?.features ?? []).compactMap { feature in
            guard feature.kind == "region", let rings = feature.rings, !rings.isEmpty else { return nil }
            return TerrainMapPolygon(id: feature.id, tableId: topologyTableID, rings: rings)
        }
    }
    private var renderedFeatures: [TerrainMapFeature] {
        sourceMapFeatures + topologyFeatures + (!drawPoints.isEmpty
            ? [TerrainMapFeature(id: "terrain-topology-local-draft", tableId: topologyTableID, points: drawPoints, kind: "draft")]
            : [])
    }
    private var selectedMapIDs: Set<String> {
        let tableID = map?.features?.first?.tableId
        return selectedIDs.union(tableID.flatMap { session.tablePresentations[$0]?.selection?.rowIDs } ?? [])
    }
    private var selectedFeature: TerrainTopologyFeature? {
        guard selectedIDs.count == 1, let id = selectedIDs.first else { return nil }
        return topology?.feature(id: id)
    }
    private var selectedNodes: [TerrainTopologyFeature] {
        selectedIDs.sorted().compactMap { topology?.feature(id: $0) }.filter { $0.kind == "node" }
    }
    private var selectedArc: TerrainTopologyFeature? {
        selectedIDs.sorted().compactMap { topology?.feature(id: $0) }.first { $0.kind == "arc" }
    }
    private var selectedVertex: TerrainTopologyFeature? {
        selectedIDs.sorted().compactMap { topology?.feature(id: $0) }.first { $0.isEditableVertex }
    }
    private var selectedRegion: TerrainTopologyFeature? {
        selectedIDs.sorted().compactMap { topology?.feature(id: $0) }.first { $0.kind == "region" }
    }
    private var canRemoveSelection: Bool {
        !selectedIDs.isEmpty && selectedIDs.allSatisfy { id in
            guard let feature = topology?.feature(id: id) else { return false }
            switch feature.kind {
            case "arc", "node", "controlPoint": return true
            case "region": return feature.controlPointIndex != nil
            default: return false
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).textSelection(.enabled).padding(.horizontal, 12).padding(.bottom, 8)
            }
            if !isChannelInput {
                Label("Channel topology operations require a channel modification input.", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
            } else {
                toolInstructions
            }
            HStack(spacing: 0) {
                TerrainFeatureMapCanvas(
                    rasters: rasterLayers,
                    features: renderedFeatures,
                    polygons: topologyRegions,
                    selectedRowIDs: selectedMapIDs,
                    loading: loading || working || session.isBusy,
                    onSelect: handleMapSelection,
                    onMapClick: handleMapClick
                )
                .frame(minWidth: 300, minHeight: 360)
                Divider()
                featureSidebar
                    .frame(width: 360)
            }
            HStack {
                Label("Source channel topology", systemImage: "point.3.connected.trianglepath.dotted")
                Spacer()
                Text(L10n.format("%d graph features", topology?.features.count ?? 0)).monospacedDigit()
                if !selectedIDs.isEmpty { Text(L10n.format("%d selected", selectedIDs.count)).monospacedDigit() }
            }
            .font(.caption).foregroundStyle(.secondary).padding(10)
            if isChannelInput {
                BoundSourceForm(title: "Channel Mod Terrain Input Properties", schemas: ["ChannelModTerrainInputProperties"], session: session, store: store)
                    .frame(minHeight: 115)
            }
        }
        .task(id: refreshIdentity) { await refresh() }
        .onChange(of: session.isBusy) { _, busy in
            if !busy && !loading && loadedIdentity != refreshIdentity { Task { await refresh() } }
        }
        .onChange(of: session.loadingSelection) { _, selecting in
            if !selecting && !loading && loadedIdentity != refreshIdentity { Task { await refresh() } }
        }
        .onChange(of: session.modelAssetID) { _, _ in
            selectedIDs = []; drawPoints = []; topology = nil; map = nil; loadedIdentity = nil; metadataEdits = [:]
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Topology Tool", selection: $tool) {
                ForEach(TerrainTopologyTool.allCases) { item in Text(item.rawValue).tag(item) }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 230)
            .disabled(!isChannelInput || loading || working || session.isBusy)

            if tool == .split {
                Picker("Split Mode", selection: $splitMode) {
                    ForEach(TerrainTopologySplitMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 210)
            }
            if tool == .draw {
                Button("Finish Arc", systemImage: "checkmark") { Task { await finishDraw() } }
                    .disabled(drawPoints.count < 2 || mapCellSize == nil || loading || working || session.isBusy)
                Button("Cancel Draft", systemImage: "xmark") { drawPoints = [] }
                    .disabled(drawPoints.isEmpty || working)
            }
            if tool == .remove {
                Button("Remove Selected", systemImage: "minus", role: .destructive) { Task { await removeSelected() } }
                    .disabled(!canRemoveSelection || loading || working || session.isBusy)
            }
            if tool == .deleteVertex {
                Button("Delete Selected Vertex", systemImage: "minus.circle", role: .destructive) { Task { await deleteSelectedVertex() } }
                    .disabled(selectedVertex == nil || loading || working || session.isBusy)
            }
            if tool == .maskRegion, let region = selectedRegion {
                Button(region.isMask == true ? "Remove Region Mask" : "Mask Region", systemImage: "circle.lefthalf.filled") {
                    Task { await toggleMask(region) }
                }
                .disabled(loading || working || session.isBusy || region.controlPointIndex == nil)
            }
            Spacer()
            Button("Undo", systemImage: "arrow.uturn.backward") { Task { await performHistory(.undo) } }
                .disabled(topology?.canUndo != true || loading || working || session.isBusy)
            Button("Redo", systemImage: "arrow.uturn.forward") { Task { await performHistory(.redo) } }
                .disabled(topology?.canRedo != true || loading || working || session.isBusy)
            if loading || working { ProgressView().controlSize(.small) }
        }
        .padding(12)
    }

    @ViewBuilder private var toolInstructions: some View {
        switch tool {
        case .draw:
            instruction("Click the terrain map to add vertices, then finish the arc.")
        case .split:
            VStack(alignment: .leading, spacing: 3) {
                instruction("Select one arc in the feature list, then click the map location to split it.")
                Text("The source editor does not support splitting one arc into more than two fragments.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
            }
        case .moveNodes:
            instruction("Select one or more nodes, then click a destination. A single node can merge with a node or arc.")
        case .moveVertex:
            instruction("Select an internal arc vertex, then click its new location.")
        case .insertVertex:
            instruction("Select an arc, then click a valid segment location to insert a vertex.")
        case .deleteVertex:
            instruction("Select an internal arc vertex, then choose Delete Selected Vertex.")
        case .maskRegion:
            instruction("Select a completed region and toggle its source mask state.")
        case .remove:
            instruction("Select graph features in the map or list, then remove them together.")
        case .select:
            instruction("Select arcs, internal vertices, nodes, control points, and completed regions in the map or list.")
        }
    }

    private func instruction(_ value: String) -> some View {
        Text(value).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 6)
    }

    private var featureSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Topology Features").font(.headline)
                Spacer()
                Text(L10n.format("%d", topology?.features.count ?? 0)).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(12)
            List(selection: Binding(get: { selectedIDs }, set: { setSelectedIDsFromUser($0) })) {
                ForEach(topology?.features ?? []) { feature in
                    HStack(spacing: 8) {
                        Image(systemName: symbol(for: feature.kind)).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(featureTitle(feature)).lineLimit(1)
                            Text(featureSummary(feature)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .tag(feature.id)
                    .contextMenu {
                        if feature.kind == "region", feature.controlPointIndex != nil {
                            Button(feature.isMask == true ? "Remove Region Mask" : "Mask Region") { Task { await toggleMask(feature) } }
                        }
                        if feature.isEditableVertex {
                            Button("Delete Selected Vertex", role: .destructive) { Task { await deleteVertex(feature) } }
                        }
                    }
                }
            }
            .listStyle(.inset)
            Divider()
            featureDetails
                .frame(maxHeight: 310)
            if isChannelInput {
                Divider()
                BoundSourceForm(title: "Channel Mod", schemas: ["ChannelModEditor"], session: session, store: store)
                    .frame(maxHeight: 180)
            }
        }
    }

    @ViewBuilder private var featureDetails: some View {
        if let feature = selectedFeature {
            Form {
                Section("Feature") {
                    LabeledContent("Type", value: L10n.text(feature.kind))
                    if feature.kind == "arcVertex", let index = feature.vertexIndex {
                        LabeledContent("Vertex Index", value: String(index))
                    }
                    if let point = feature.points.first {
                        LabeledContent("X", value: point.x.formatted(.number.precision(.fractionLength(0...6))))
                        LabeledContent("Y", value: point.y.formatted(.number.precision(.fractionLength(0...6))))
                    }
                    if feature.kind == "region" {
                        LabeledContent("Mask", value: feature.isMask.map { $0 ? L10n.text("Masked") : L10n.text("Not Masked") } ?? L10n.text("No control point"))
                        if feature.controlPointIndex == nil { Text("This completed region has no control point and cannot be masked.").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                let kind = metadataKind(for: feature)
                if let kind, let fields = feature.metadata, !fields.isEmpty {
                    Section {
                        ForEach(fields) { field in metadataRow(feature: feature, kind: kind, field: field) }
                    } header: {
                        Text(L10n.format("%@ Metadata", L10n.text(metadataSectionTitle(kind))))
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("Select a topology feature", systemImage: "point.3.connected.trianglepath.dotted",
                description: Text("The source feature metadata and geometry appear here."))
                .padding(12)
        }
    }

    @ViewBuilder private func metadataRow(feature: TerrainTopologyFeature, kind: String,
                                           field: TerrainTopologyMetadataField) -> some View {
        let key = metadataKey(feature: feature, field: field)
        if field.readOnly {
            LabeledContent(L10n.text(field.title), value: field.value ?? "—")
        } else if let options = field.options, !options.isEmpty {
            Picker(L10n.text(field.title), selection: metadataBinding(key, initial: field.value ?? options[0])) {
                ForEach(options, id: \.self) { option in Text(L10n.text(option)).tag(option) }
            }
            .pickerStyle(.menu)
            metadataApplyButton(feature: feature, kind: kind, field: field, key: key)
        } else if field.sourceType.localizedCaseInsensitiveContains("bool") {
            Toggle(L10n.text(field.title), isOn: Binding(
                get: {
                    if let edited = metadataEdits[key], let parsed = Bool(edited) { return parsed }
                    return field.value == "true"
                },
                set: { metadataEdits[key] = $0 ? "true" : "false" }))
            metadataApplyButton(feature: feature, kind: kind, field: field, key: key)
        } else {
            TextField(L10n.text(field.title), text: metadataBinding(key, initial: field.value ?? ""))
                .textFieldStyle(.roundedBorder)
            metadataApplyButton(feature: feature, kind: kind, field: field, key: key)
        }
    }

    private func metadataApplyButton(feature: TerrainTopologyFeature, kind: String,
                                     field: TerrainTopologyMetadataField, key: String) -> some View {
        Button("Apply Attribute") { Task { await applyMetadata(feature: feature, kind: kind, field: field, key: key) } }
            .disabled(loading || working || session.isBusy || metadataEdits[key] == nil)
    }

    private func metadataBinding(_ key: String, initial: String) -> Binding<String> {
        Binding(get: { metadataEdits[key] ?? initial }, set: { metadataEdits[key] = $0 })
    }

    private func metadataKey(feature: TerrainTopologyFeature, field: TerrainTopologyMetadataField) -> String {
        feature.id + "|" + field.id
    }

    private func metadataKind(for feature: TerrainTopologyFeature) -> String? {
        switch feature.kind {
        case "arc": return "arc"
        case "node": return "node"
        case "controlPoint", "region": return "controlPoint"
        default: return nil
        }
    }

    private func metadataTargetID(for feature: TerrainTopologyFeature, kind: String) -> String? {
        if kind == "controlPoint", let controlPoint = feature.controlPointIndex, feature.kind == "region",
           let inputID {
            return "terrain-topology:\(inputID):controlPoint:\(controlPoint)"
        }
        if feature.kind == "arcVertex" { return feature.parentId }
        return feature.id
    }

    private func metadataSectionTitle(_ kind: String) -> String {
        switch kind {
        case "arc": "Arc"
        case "node": "Node"
        default: "Control Point"
        }
    }

    private func featureTitle(_ feature: TerrainTopologyFeature) -> String {
        if let name = feature.metadata?.first(where: { $0.id == "Name" })?.value, !name.isEmpty { return name }
        let index = feature.id.split(separator: ":").last ?? ""
        return L10n.format("%@ %@", L10n.text(feature.kind), String(index))
    }

    private func featureSummary(_ feature: TerrainTopologyFeature) -> String {
        if feature.kind == "region" { return feature.isMask == true ? L10n.text("Masked Region") : L10n.text("Completed Region") }
        if feature.kind == "arcVertex" { return L10n.format("Internal vertex %d", feature.vertexIndex ?? 0) }
        guard let point = feature.points.first else { return L10n.text(feature.kind) }
        return "\(point.x.formatted(.number.precision(.fractionLength(0...3)))), \(point.y.formatted(.number.precision(.fractionLength(0...3))))"
    }

    private func symbol(for kind: String) -> String {
        switch kind {
        case "arc": "point.3.connected.trianglepath.dotted"
        case "arcVertex": "circle.small"
        case "node": "circle.fill"
        case "controlPoint": "mappin.and.ellipse"
        case "region": "polygon"
        default: "point.topleft.down.to.point.bottomright.curvepath"
        }
    }

    @MainActor private func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let requestedIdentity = refreshIdentity
        loading = false
        guard loadedIdentity != requestedIdentity else { return }
        map = nil; topology = nil; selectedIDs = []; drawPoints = []; metadataEdits = [:]
        guard let inputID else { loadedIdentity = requestedIdentity; return }
        guard !session.isBusy, !session.loadingSelection else { return }
        loading = true; error = nil; topology = nil; map = nil; selectedIDs = []
        defer { if generation == refreshGeneration { loading = false } }
        do {
            let rasterMap = try await session.terrainMap(inputID: inputID)
            try Task.checkCancellation()
            var graph: TerrainTopologyData?
            if isChannelInput {
                graph = try await session.terrainTopology(inputID: inputID,
                    command: .init(operation: .load), expectedDraftIdentity: nil)
                try Task.checkCancellation()
            }
            guard rasterMap.inputId == inputID, rasterMap.sourceRevision == session.terrainSourceRevision,
                  graph == nil || graph?.inputId == inputID && graph?.sourceRevision == session.terrainSourceRevision,
                  requestedIdentity == refreshIdentity, generation == refreshGeneration else { throw CancellationError() }
            map = rasterMap; topology = graph; loadedIdentity = requestedIdentity
            selectedIDs = Set(graph?.selectedFeatureIDs ?? [])
        } catch {
            if !Task.isCancelled { self.error = L10n.text(error.localizedDescription) }
        }
    }

    @MainActor private func setSelectedIDsFromUser(_ ids: Set<String>) {
        guard ids != selectedIDs else { return }
        selectedIDs = ids
        metadataEdits = [:]
        Task { await synchronizeSelection(ids) }
    }

    @MainActor private func synchronizeSelection(_ ids: Set<String>) async {
        guard let inputID, let topology, !loading, !working, !session.isBusy else { return }
        do {
            let result = try await session.terrainTopology(inputID: inputID,
                command: .init(operation: .select, featureIDs: ids.sorted()),
                expectedDraftIdentity: topology.draftIdentity)
            guard result.inputId == inputID, result.sourceRevision == session.terrainSourceRevision else { throw CancellationError() }
            self.topology = result
            error = nil
        } catch {
            if !Task.isCancelled { self.error = L10n.text(error.localizedDescription) }
        }
    }

    @MainActor private func handleMapSelection(_ mapFeature: TerrainMapFeature) {
        guard let feature = topology?.feature(id: mapFeature.id), !loading, !working, !session.isBusy else {
            if mapFeature.tableId != topologyTableID {
                Task { _ = await session.perform(.selectTableRows(table: mapFeature.tableId, ids: [mapFeature.id])) }
            }
            return
        }
        if tool == .maskRegion, feature.kind == "region" {
            selectedIDs = [feature.id]
            Task { await synchronizeSelection(selectedIDs); await toggleMask(feature) }
        } else if tool == .select {
            var next = selectedIDs
            if next.contains(feature.id) { next.remove(feature.id) } else { next.insert(feature.id) }
            setSelectedIDsFromUser(next)
        }
    }

    @MainActor private func handleMapClick(_ coordinate: TerrainMapCoordinate, _ cellSize: Double) {
        mapCellSize = cellSize
        guard isChannelInput, !loading, !working, !session.isBusy else { return }
        switch tool {
        case .draw:
            if drawPoints.last?.x != coordinate.x || drawPoints.last?.y != coordinate.y { drawPoints.append(coordinate) }
        case .split:
            guard let arc = selectedArc else { error = L10n.text("Select one arc before splitting."); return }
            Task { await performCommand(.init(operation: .split, featureIDs: [arc.id], points: [coordinate],
                mapCellSize: cellSize, splitMode: splitMode)) }
        case .moveNodes:
            guard !selectedNodes.isEmpty else { error = L10n.text("Select at least one node before moving."); return }
            let anchor = selectedNodes[0].points[0]
            Task { await performCommand(.init(operation: .moveNodes, featureIDs: selectedNodes.map(\.id),
                points: [anchor, coordinate], mapCellSize: cellSize)) }
        case .moveVertex:
            guard let vertex = selectedVertex, let parentID = vertex.parentId,
                  let anchor = vertex.points.first else { error = L10n.text("Select an internal arc vertex before moving it."); return }
            Task { await performCommand(.init(operation: .moveVertex, featureIDs: [parentID],
                points: [anchor, coordinate], mapCellSize: cellSize, vertexIndex: vertex.vertexIndex)) }
        case .insertVertex:
            guard let arc = selectedArc else { error = L10n.text("Select one arc before inserting a vertex."); return }
            Task { await performCommand(.init(operation: .insertVertex, featureIDs: [arc.id],
                points: [coordinate], mapCellSize: cellSize)) }
        case .select, .deleteVertex, .maskRegion, .remove:
            break
        }
    }

    @MainActor private func finishDraw() async {
        guard drawPoints.count >= 2, let mapCellSize else { return }
        let points = drawPoints
        drawPoints = []
        await performCommand(.init(operation: .draw, points: points, mapCellSize: mapCellSize))
    }

    @MainActor private func removeSelected() async {
        guard canRemoveSelection else { return }
        // The retained DeleteTopologySelectionOperation consumes selection sets;
        // its required HitTestArgs is only base-operation context and does not
        // drive a snap or tolerance calculation for this command.
        await performCommand(.init(operation: .remove, featureIDs: selectedIDs.sorted(), mapCellSize: mapCellSize ?? 1))
    }

    @MainActor private func deleteSelectedVertex() async {
        guard let vertex = selectedVertex, let parentID = vertex.parentId,
              let index = vertex.vertexIndex else { return }
        await deleteVertex(vertex, parentID: parentID, index: index)
    }

    @MainActor private func deleteVertex(_ vertex: TerrainTopologyFeature) async {
        guard let parentID = vertex.parentId, let index = vertex.vertexIndex else { return }
        await deleteVertex(vertex, parentID: parentID, index: index)
    }

    @MainActor private func deleteVertex(_ vertex: TerrainTopologyFeature, parentID: String, index: Int) async {
        await performCommand(.init(operation: .deleteVertex, featureIDs: [parentID], vertexIndex: index))
    }

    @MainActor private func toggleMask(_ feature: TerrainTopologyFeature) async {
        guard feature.kind == "region", feature.controlPointIndex != nil else { return }
        await performCommand(.init(operation: .maskRegion, featureIDs: [feature.id]))
    }

    @MainActor private func applyMetadata(feature: TerrainTopologyFeature, kind: String,
                                          field: TerrainTopologyMetadataField, key: String) async {
        guard !field.readOnly, let value = metadataEdits[key], let targetID = metadataTargetID(for: feature, kind: kind) else { return }
        await performCommand(.init(operation: .setMetadata, featureIDs: [targetID],
            metadataKind: kind, metadataColumn: field.id, metadataValue: value))
    }

    @MainActor private func performHistory(_ operation: TerrainTopologyOperation) async {
        await performCommand(.init(operation: operation))
    }

    @MainActor private func performCommand(_ command: TerrainTopologyCommand) async {
        guard let inputID, let currentTopology = topology, !working, !loading, !session.isBusy else { return }
        let capturedAsset = session.modelAssetID
        let capturedRevision = session.terrainSourceRevision
        let capturedInput = inputID
        working = true; error = nil
        defer { working = false }
        do {
            let result = try await session.terrainTopology(inputID: inputID, command: command,
                expectedDraftIdentity: command.operation == .load ? nil : currentTopology.draftIdentity)
            try Task.checkCancellation()
            guard session.modelAssetID == capturedAsset, session.terrainSourceRevision == capturedRevision,
                  self.inputID == capturedInput, result.inputId == capturedInput,
                  result.sourceRevision == capturedRevision else { throw CancellationError() }
            topology = result
            selectedIDs = Set(result.selectedFeatureIDs)
            metadataEdits = [:]
            loadedIdentity = refreshIdentity
            if command.operation != .select && command.operation != .load { await refreshMap(for: capturedInput) }
        } catch {
            if !Task.isCancelled {
                self.error = L10n.text(error.localizedDescription)
                loadedIdentity = nil
                await refresh()
            }
        }
    }

    @MainActor private func refreshMap(for inputID: String) async {
        do {
            let result = try await session.terrainMap(inputID: inputID)
            try Task.checkCancellation()
            guard result.inputId == inputID, result.sourceRevision == session.terrainSourceRevision,
                  session.fields[TerrainEditorContract.sourceField] == inputID else { throw CancellationError() }
            map = result
        } catch {
            if !Task.isCancelled { self.error = L10n.text(error.localizedDescription) }
        }
    }
}
