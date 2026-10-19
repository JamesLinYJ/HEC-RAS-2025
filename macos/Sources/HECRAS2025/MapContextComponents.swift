import RASWorkspaceCore
import SwiftUI

enum MapContextComponentResolver {
    static func visibleRows(_ rows: [MapSourceRenderRecord], mapID: UUID) -> [MapSourceRenderRecord] {
        rows.filter { $0.mapID == mapID && $0.isActiveAndVisible }
            .sorted { lhs, rhs in
                if lhs.familyOrder != rhs.familyOrder { return lhs.familyOrder < rhs.familyOrder }
                if lhs.treeOrdinal != rhs.treeOrdinal { return lhs.treeOrdinal < rhs.treeOrdinal }
                return lhs.activeLayerOrdinal ?? -1 < rhs.activeLayerOrdinal ?? -1
            }
    }

    static func exactRow(contextIdentity: String?, among rows: [MapSourceRenderRecord]) -> MapSourceRenderRecord? {
        guard let contextIdentity, !contextIdentity.isEmpty else { return nil }
        let matches = rows.filter { $0.contextIdentity == contextIdentity }
        return matches.count == 1 ? matches[0] : nil
    }

    static func exactVectorLayers(for row: MapSourceRenderRecord,
                                  candidates: [MapVectorLayer]) -> [MapVectorLayer] {
        guard row.payloadKind == "MapLayer", row.payloadLayerIDs.count == 1,
              let expectedID = row.payloadLayerIDs.first else { return [] }
        let matches = candidates.filter {
            $0.id == expectedID && ($0.sourceMapID == nil || $0.sourceMapID == row.mapID)
        }
        return matches.count == 1 ? matches : []
    }
}

/// An exact, map-scoped component inspector. Rows are resolved by the full
/// serialized locator and payload IDs produced for this MapState; names only
/// label the controls and never join a component to source data.
@MainActor
struct MapContextComponentsPane: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    @Environment(\.openWindow) private var openWindow
    @State private var featureFilter = ""

    private var visibleRows: [MapSourceRenderRecord] {
        MapContextComponentResolver.visibleRows(mapState.sourceMapRenderRows, mapID: mapState.id)
    }

    private var selectedRow: MapSourceRenderRecord? {
        MapContextComponentResolver.exactRow(
            contextIdentity: mapState.selectedSourceContextIdentity,
            among: visibleRows)
    }

    private var isCurrentMap: Bool {
        store.existingMapState(for: mapState.id) === mapState
    }

    private var currentWorkflowIdentity: String { store.mapWorkflowIdentity(mapState.id) }

    var body: some View {
        Group {
            if !isCurrentMap {
                ContentUnavailableView("Map Is No Longer Open", systemImage: "map.slash",
                    description: Text("Open a current map to inspect its visible components."))
            } else if visibleRows.isEmpty {
                ContentUnavailableView("No Visible Components", systemImage: "square.3.layers.3d",
                    description: Text("Checked map components appear here with their source details."))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Component", selection: selectedContextBinding) {
                        Text("Choose a component").tag("")
                        ForEach(visibleRows) { row in
                            Text(verbatim: componentTitle(row)).tag(row.contextIdentity)
                        }
                    }
                    .pickerStyle(.menu)

                    if let row = selectedRow {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                commonDetails(for: row)
                                sourceDetails(for: row)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                        }
                    } else {
                        ContentUnavailableView("Choose a Visible Component", systemImage: "cursorarrow.click",
                            description: Text("Component details stay tied to the selected map and source row."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(12)
            }
        }
        .onChange(of: mapState.selectedSourceContextIdentity) { _, _ in featureFilter = "" }
    }

    private var selectedContextBinding: Binding<String> {
        Binding(get: { mapState.selectedSourceContextIdentity ?? "" }, set: { value in
            guard isCurrentMap else { return }
            if value.isEmpty { mapState.selectSourceContext(nil) }
            else if visibleRows.contains(where: { $0.contextIdentity == value }) {
                store.activateMap(mapState.id)
                mapState.selectSourceContext(value)
            }
        })
    }

    private func componentTitle(_ row: MapSourceRenderRecord) -> String {
        let type = localizedComponentType(row.payloadKind)
        return "\(type) · \(row.locator.nodeName)"
    }

    @ViewBuilder
    private func commonDetails(for row: MapSourceRenderRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: row.locator.nodeName)
                .font(.headline)
                .textSelection(.enabled)
            detailRow("Type", value: localizedComponentType(row.payloadKind))
            detailRow("Tree Section", value: L10n.text(row.locator.rootName))
            detailRow("Tree Path", value: (row.locator.nodePath ?? []).map(String.init).joined(separator: " › "))
            detailRow("Visibility", value: row.isChecked && row.isEffectivelyVisible
                ? L10n.text("Visible") : L10n.text("Hidden"))
            if let path = sourcePath(for: row) {
                detailRow("Source", value: path, selectable: true)
            }
            HStack(spacing: 8) {
                if let (kind, assetID) = modelEditorTarget(for: row) {
                    Button("Open Model", systemImage: "square.and.pencil") {
                        openExactModel(kind, assetID: assetID, row: row)
                    }
                    .disabled(!canOpenExactModel(kind, assetID: assetID, row: row))
                }
                if row.payloadKind == "MapLayer", let layer = exactVectorLayers(for: row).first,
                   layer.url.pathExtension.lowercased() == "shp" {
                    Button("Open Attribute Table…", systemImage: "tablecells") {
                        openExactAttributeTable(layer, row: row)
                    }
                    .disabled(!isCurrentMap)
                }
                if store.launchDebugEnabled {
                    Button("Reflect", systemImage: "point.3.connected.trianglepath.dotted") {
                        guard isCurrentMap,
                              visibleRows.filter({ $0.contextIdentity == row.contextIdentity }).count == 1 else { return }
                        store.activateMap(mapState.id)
                        mapState.selectSourceContext(row.contextIdentity)
                        openWindow(value: MapSourceReflectionRoute(projectSessionID: store.projectSessionID,
                            mapID: mapState.id, contextIdentity: row.contextIdentity))
                    }
                    .disabled(!isCurrentMap)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func sourceDetails(for row: MapSourceRenderRecord) -> some View {
        switch row.payloadKind {
        case "MapLayer":
            if let layer = exactVectorLayers(for: row).first {
                vectorDetails(layer, row: row)
            } else {
                statusCard("Source Data", message: "Vector source data is unavailable for this map row.")
            }
            let rasters = exactRasterLayers(for: row)
            ForEach(rasters, id: \.id) { raster in
                rasterDetails(raster)
            }
        case "Terrain", "NValue", "Classification":
            associatedDetails(for: row)
        case "BoundaryCondition":
            boundaryDetails(for: row)
        case "Geometry", "ConceptualMesh", "FlowAreaLayer", "CulvertBarrelLayer":
            geometryDetails(for: row)
        case "Result", "MultiResult":
            resultDetails(for: row)
        case "LinkedResult":
            linkedResultDetails()
        case "Raster", "DiscreteRaster":
            ForEach(exactRasterLayers(for: row), id: \.id) { raster in rasterDetails(raster) }
            if exactRasterLayers(for: row).isEmpty {
                statusCard("Raster", message: "Raster pixels are not available for this map component.")
            }
        case "WindLayer":
            statusCard("Wind Forces", message: "Wind Forces are read through their exact Boundary Condition owner when velocity particles are configured.")
        default:
            statusCard("Source Data", message: "Source details are unavailable for this component.")
        }
    }

    private func exactVectorLayers(for row: MapSourceRenderRecord) -> [MapVectorLayer] {
        MapContextComponentResolver.exactVectorLayers(for: row, candidates: mapState.vectors(store.mapLayers))
    }

    private func exactRasterLayers(for row: MapSourceRenderRecord) -> [MapRasterLayer] {
        let ids = Set(row.payloadLayerIDs)
        guard !ids.isEmpty else { return [] }
        let candidates = store.rasterLayers + mapState.resultMap.layers(for: row.locator)
            + mapState.associatedMapLayers.visibleLayers
        var seen = Set<String>()
        return candidates.filter { layer in
            ids.contains(layer.id) && (layer.sourceMapID == nil || layer.sourceMapID == mapState.id)
                && seen.insert(layer.id).inserted
        }
    }

    @ViewBuilder
    private func vectorDetails(_ layer: MapVectorLayer, row: MapSourceRenderRecord) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("Features")
            detailRow("Feature Count", value: layer.features.count.formatted())
            detailRow("Geometry Type", value: layer.features.first.map { localizedGeometryType($0.kind) }
                ?? L10n.text("Unknown"))
            if layer.sourceRevision != nil {
                detailRow("Source Revision", value: layer.sourceRevision ?? "", selectable: true)
            }
            if !layer.features.isEmpty {
                TextField("Filter features", text: $featureFilter)
                    .textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredFeatures(in: layer)) { feature in
                            Button {
                                select(feature, in: layer, row: row)
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: isSelected(feature, in: layer) ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(isSelected(feature, in: layer) ? Color.accentColor : Color.secondary)
                                    Text(verbatim: featureLabel(feature))
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    if !feature.hasUniqueStableIdentity {
                                        Image(systemName: "exclamationmark.triangle")
                                            .foregroundStyle(.orange)
                                            .help(L10n.text("This source feature identity is not unique."))
                                    }
                                }
                                .font(.caption)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!feature.hasUniqueStableIdentity || !isCurrentMap)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
            if let feature = selectedFeature(in: layer) {
                selectedFeatureDetails(feature)
            } else {
                Text("Select a source feature to inspect its fields.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
    }

    private func filteredFeatures(in layer: MapVectorLayer) -> [MapFeature] {
        guard !featureFilter.isEmpty else { return layer.features }
        return layer.features.filter { feature in
            featureLabel(feature).localizedCaseInsensitiveContains(featureFilter)
                || feature.attributes.values.contains { $0.localizedCaseInsensitiveContains(featureFilter) }
        }
    }

    private func featureLabel(_ feature: MapFeature) -> String {
        let sourceName = feature.attributes.first { key, _ in key.caseInsensitiveCompare("name") == .orderedSame }?.value
        let name = sourceName ?? L10n.format("Feature %d", feature.id + 1)
        if let ordinal = feature.sourceFeatureIndex { return "\(name) · \(L10n.format("Row %d", ordinal + 1))" }
        return name
    }

    private func isSelected(_ feature: MapFeature, in layer: MapVectorLayer) -> Bool {
        mapState.selectedLayerID == layer.id
            && mapState.selectedFeatureIdentities.contains(feature.stableIdentity)
            && feature.hasUniqueStableIdentity
    }

    private func select(_ feature: MapFeature, in layer: MapVectorLayer, row: MapSourceRenderRecord) {
        guard isCurrentMap, row.isActiveAndVisible,
              visibleRows.contains(where: { $0.contextIdentity == row.contextIdentity }),
              feature.hasUniqueStableIdentity,
              layer.features.filter({ $0.stableIdentity == feature.stableIdentity }).count == 1 else { return }
        store.activateMap(mapState.id)
        mapState.selectSourceContext(row.contextIdentity)
        guard mapState.selectVectorFeature(feature, in: layer,
            mode: .list(modifiers: MapInput.currentModifiers()),
            rangeOrder: filteredFeatures(in: layer).map(\.stableIdentity)) else { return }
        store.selectedFeatureID = mapState.selectedFeatureID
        store.inspectorMode = .components
        store.showInspector = true
    }

    private func selectedFeature(in layer: MapVectorLayer) -> MapFeature? {
        guard mapState.selectedLayerID == layer.id,
              let identity = mapState.selectedFeatureIdentity else { return nil }
        let matches = layer.features.filter { $0.stableIdentity == identity && $0.hasUniqueStableIdentity }
        return matches.count == 1 ? matches[0] : nil
    }

    @ViewBuilder
    private func selectedFeatureDetails(_ feature: MapFeature) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Selected Feature")
            detailRow("Feature", value: featureLabel(feature), selectable: true)
            detailRow("Stable Source Identity", value: feature.stableIdentity, selectable: true)
            if let ordinal = feature.sourceFeatureIndex {
                detailRow("Source Row", value: ordinal.formatted())
            }
            if let columns = feature.sourceAttributeColumns, !columns.isEmpty {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "\(column.ordinal + 1). \(column.name)")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(attributeValue(column.value))
                            .textSelection(.enabled)
                    }
                    .font(.caption)
                }
            } else {
                ForEach(feature.attributes.keys.sorted(), id: \.self) { key in
                    sourceAttributeRow(key, value: feature.attributes[key] ?? "")
                }
            }
            detailRow("Coordinate Paths", value: feature.paths.count.formatted())
            detailRow("Coordinates", value: feature.paths.reduce(0) { $0 + $1.count }.formatted())
        }
        .padding(8)
        .background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
    }

    private func attributeValue(_ value: MapSourceAttributeValue) -> String {
        switch value {
        case .null: L10n.text("Null")
        case .string(let text), .integer(let text), .number(let text), .date(let text): text
        case .boolean(let value): value ? L10n.text("True") : L10n.text("False")
        case .binary(let data): L10n.format("%d bytes", data.count)
        }
    }

    private func sourceAttributeRow(_ name: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: name).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(verbatim: value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func rasterDetails(_ raster: MapRasterLayer) -> some View {
        let sourceMatches = store.rasterMapSources.filter {
            $0.id == raster.id && $0.sourceMapID == mapState.id
        }
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("Raster")
            detailRow("Dimensions", value: L10n.format("%d × %d", raster.width, raster.height))
            detailRow("Extent", value: "\(coordinate(raster.lowerLeft.x)), \(coordinate(raster.lowerLeft.y)) – \(coordinate(raster.upperRight.x)), \(coordinate(raster.upperRight.y))")
            if sourceMatches.count == 1, let source = sourceMatches.first {
                detailRow("Source File", value: source.sourcePath, selectable: true)
                let sourcePropertiesKey = "\(mapState.id.uuidString)|\(source.id)"
                let sourceProperties = store.rasterMapSourceInfoStats[sourcePropertiesKey]
                if let revision = source.sourceRevision ?? sourceProperties?.revision {
                    detailRow("Source Revision", value: revision, selectable: true)
                }
                detailRow("Map", value: "\(source.mapName) · \(source.mapType) · #\(source.mapIndex)")
                detailRow("Visualization", value: source.visualizationPath, selectable: true)
                detailRow("Visualization Revision", value: source.visualizationRevision, selectable: true)
                detailRow("Tree Path", value: source.nodePath.map(String.init).joined(separator: " › "))
                detailRow("Raster Type", value: L10n.text(source.mapLayerType == "SingleBandRasterMapLayer"
                    ? "Single-band raster" : source.mapLayerType))
                if let sourceProperties,
                   SourceFilePaths.canonical(URL(fileURLWithPath: sourceProperties.path))
                        == SourceFilePaths.canonical(URL(fileURLWithPath: source.sourcePath)),
                   source.sourceRevision.map({ sourceProperties.revision.caseInsensitiveCompare($0) == .orderedSame }) ?? true {
                    if let info = sourceProperties.info {
                        sectionTitle("Raster File Properties")
                        if let fileName = info.fileName { detailRow("File Name", value: fileName) }
                        if let directory = info.directory { detailRow("Directory", value: directory, selectable: true) }
                        if let projection = info.rasterProjection { detailRow("Projection", value: projection) }
                        if let projectionStatus = info.projectionFriendlyText {
                            detailRow("Projection Status", value: L10n.text(projectionStatus))
                        }
                        if let cellSize = info.cellSize { detailRow("Cell Size", value: cellSize) }
                        if let size = info.size { detailRow("File Size", value: size) }
                        if let uncompressedSize = info.uncompressedSize { detailRow("Uncompressed Size", value: uncompressedSize) }
                        if let compressionRatio = info.compressionRatio { detailRow("Compression Ratio", value: compressionRatio) }
                        if let driver = info.driver { detailRow("Driver", value: driver) }
                        if let bandCount = info.bandCount { detailRow("Band Count", value: bandCount.formatted()) }
                        if let unitSystem = info.unitSystem {
                            detailRow("Unit System", value: L10n.text(unitSystem == "USCustomary" ? "US Customary" : unitSystem))
                        }
                        if let overviewCount = info.overviewsCount {
                            detailRow("Overview Count", value: Int(overviewCount).formatted())
                        }
                        if let overviews = info.overviews, !overviews.isEmpty {
                            detailRow("Overviews", value: overviews.joined(separator: ", "))
                        }
                    }
                    if let statistics = sourceProperties.stats {
                        sectionTitle("Raster Statistics")
                        detailRow("Minimum", value: statistics.min)
                        detailRow("Maximum", value: statistics.max)
                        detailRow("Mean", value: statistics.mean)
                        detailRow("Standard Deviation", value: statistics.standardDeviation)
                    }
                    if let error = sourceProperties.error, !error.isEmpty {
                        Text(verbatim: error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                } else if store.isRasterMapLoading {
                    detailRow("Raster Statistics", value: L10n.text("Loading"))
                } else {
                    detailRow("Raster Statistics", value: L10n.text("Unavailable"))
                }
            } else if sourceMatches.count > 1 {
                detailRow("Source", value: L10n.text("Ambiguous source identity"))
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func associatedDetails(for row: MapSourceRenderRecord) -> some View {
        let matches = mapState.associatedMapLayers.entries.filter {
            $0.capture.projectSessionID == store.projectSessionID
                && $0.capture.mapID == mapState.id
                && $0.capture.mapWorkflowIdentity == currentWorkflowIdentity
                && $0.capture.associationNode == row.locator
        }
        if matches.count == 1, let entry = matches.first {
            VStack(alignment: .leading, spacing: 5) {
                sectionTitle("Associated Source")
                detailRow("Status", value: localizedSourceStatus(entry.payload?.status.rawValue ?? entry.status?.rawValue))
                detailRow("Association Kind", value: L10n.text(entry.payload?.kind.rawValue ?? row.locator.associationKind ?? L10n.text("Unknown")))
                detailRow("Source", value: entry.capture.assetPath, selectable: true)
                detailRow("Map", value: "\(entry.capture.map.mapName) · \(entry.capture.map.mapType) · #\(entry.capture.map.mapIndex)")
                detailRow("Project", value: entry.capture.map.projectPath, selectable: true)
                detailRow("Project XML SHA", value: entry.capture.map.projectXmlSHA, selectable: true)
                detailRow("Visualization Revision", value: entry.capture.map.expectedVisualizationRevision, selectable: true)
                detailRow("Map Source ID", value: row.locator.sourceIdentity, selectable: true)
                if let payload = entry.payload {
                    detailRow("Source Revision", value: payload.revision, selectable: true)
                    detailRow("Source Row", value: "\(payload.locator.nodeType) · \(payload.locator.nodeName)")
                    detailRow("Source Tree Path", value: (payload.locator.nodePath ?? []).map(String.init).joined(separator: " › "))
                    detailRow("Checked", value: L10n.text(payload.isChecked ? "Checked" : "Unchecked"))
                    detailRow("Effective Visibility", value: L10n.text(payload.effectiveVisible ? "Visible" : "Hidden"))
                    if payload.width > 0, payload.height > 0 {
                        detailRow("Raster Dimensions", value: L10n.format("%d × %d", payload.width, payload.height))
                    }
                    if let extent = payload.sourceExtent {
                        detailRow("Source Extent", value: "\(coordinate(extent.minX)), \(coordinate(extent.minY)) – \(coordinate(extent.maxX)), \(coordinate(extent.maxY))")
                    }
                    if let diagnostic = payload.diagnostic {
                        Text(diagnostic).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if !payload.legend.isEmpty {
                        DisclosureGroup(L10n.format("Legend (%d)", payload.legend.count)) {
                            LazyVStack(alignment: .leading, spacing: 5) {
                                ForEach(payload.legend) { value in
                                    HStack(spacing: 8) {
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(Color(.sRGB,
                                                red: Double(min(max(value.red, 0), 255)) / 255,
                                                green: Double(min(max(value.green, 0), 255)) / 255,
                                                blue: Double(min(max(value.blue, 0), 255)) / 255,
                                                opacity: Double(min(max(value.alpha, 0), 255)) / 255))
                                            .frame(width: 16, height: 16)
                                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.quaternary))
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(verbatim: value.label).font(.caption)
                                            Text(verbatim: value.value).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    if !payload.dependencies.isEmpty {
                        DisclosureGroup(L10n.format("Source Files (%d)", payload.dependencies.count)) {
                            ForEach(Array(payload.dependencies.enumerated()), id: \.offset) { _, dependency in
                                VStack(alignment: .leading, spacing: 2) {
                                    detailRow("Role", value: L10n.text(dependency.role))
                                    Text(verbatim: dependency.path).font(.caption.monospaced()).textSelection(.enabled)
                                    Text(verbatim: dependency.revision).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if !payload.geometryNodes.isEmpty {
                        DisclosureGroup(L10n.format("Geometry Sources (%d)", payload.geometryNodes.count)) {
                            ForEach(Array(payload.geometryNodes.enumerated()), id: \.offset) { _, locator in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: "\(locator.rootName) · \(locator.nodeType) · \(locator.nodeName)")
                                        .font(.caption).textSelection(.enabled)
                                    Text(verbatim: "\((locator.nodePath ?? []).map(String.init).joined(separator: " › ")) · \(locator.assetID ?? "—")")
                                        .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    if !payload.planNodes.isEmpty {
                        DisclosureGroup(L10n.format("Plan Sources (%d)", payload.planNodes.count)) {
                            ForEach(Array(payload.planNodes.enumerated()), id: \.offset) { _, locator in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: "\(locator.rootName) · \(locator.nodeType) · \(locator.nodeName)")
                                        .font(.caption).textSelection(.enabled)
                                    Text(verbatim: "\((locator.nodePath ?? []).map(String.init).joined(separator: " › ")) · \(locator.assetID ?? "—")")
                                        .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    if !payload.resultOwners.isEmpty {
                        DisclosureGroup(L10n.format("Result Owners (%d)", payload.resultOwners.count)) {
                            ForEach(Array(payload.resultOwners.enumerated()), id: \.offset) { _, owner in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: "\(owner.resultNode.nodeType) · \(owner.resultNode.nodeName) · \(L10n.format("Selection %d", owner.selectionIndex))")
                                        .font(.caption).textSelection(.enabled)
                                    Text(verbatim: owner.selectedResultPath).font(.caption.monospaced()).textSelection(.enabled)
                                    Text(verbatim: owner.selectedResultRevision).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                if AssociatedMapLayerRasterTileOutlineToggle.supports(entry.capture) {
                    AssociatedMapLayerRasterTileOutlineToggle(
                        store: store, mapID: mapState.id, capture: entry.capture)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
        } else {
            statusCard("Associated Source", message: "Source data is unavailable for this map row.")
        }
    }

    @ViewBuilder
    private func boundaryDetails(for row: MapSourceRenderRecord) -> some View {
        let matches = mapState.boundaryMap.entries.filter {
            $0.capture.projectSessionID == store.projectSessionID
                && $0.capture.map.mapID.caseInsensitiveCompare(mapState.id.uuidString) == .orderedSame
                && $0.capture.mapWorkflowIdentity == currentWorkflowIdentity
                && $0.capture.boundaryNode == row.locator
        }
        if matches.count == 1, let entry = matches.first {
            VStack(alignment: .leading, spacing: 5) {
                sectionTitle("Boundary Condition")
                detailRow("Status", value: localizedSourceStatus(entry.status.rawValue))
                detailRow("Source", value: entry.capture.sourcePath, selectable: true)
                detailRow("Source Revision", value: entry.capture.sourceRevision, selectable: true)
                detailRow("Visible Lines", value: entry.visibleLines.count.formatted())
                if let sourceState = entry.boundarySourceState {
                    detailRow("Boundary Source", value: sourceState)
                }
                if let diagnostic = entry.diagnostic {
                    Text(diagnostic).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                ForEach(entry.visibleLines.map { BoundaryMapLinePresentation(
                    sourceIdentity: entry.capture.sourceIdentity, line: $0) }) { line in
                    Button {
                        guard isCurrentMap, row.isActiveAndVisible else { return }
                        store.activateMap(mapState.id)
                        mapState.selectSourceContext(row.contextIdentity)
                        mapState.boundaryMap.selectLine(line.id,
                            mode: .list(modifiers: MapInput.currentModifiers()))
                    } label: {
                        HStack {
                            Image(systemName: mapState.boundaryMap.selectedLineIDs.contains(line.id)
                                ? "largecircle.fill.circle" : "circle")
                            Text(verbatim: line.line.name.isEmpty
                                ? L10n.format("Line %d", line.line.sourceOrdinal + 1) : line.line.name)
                            Spacer()
                            Text(L10n.format("%d points", line.line.coordinates.count)).foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
        } else {
            statusCard("Boundary Condition", message: "Boundary Condition source data is unavailable for this map row.")
        }
    }

    @ViewBuilder
    private func geometryDetails(for row: MapSourceRenderRecord) -> some View {
        let matches = mapState.projectGeometryMap.sources.filter {
            $0.capture.projectSessionID == store.projectSessionID
                && $0.capture.mapID == mapState.id
                && $0.capture.mapWorkflowIdentity == currentWorkflowIdentity
                && geometrySourceMatches($0, row: row)
        }
        if matches.count == 1, let source = matches.first, let snapshot = source.snapshot {
            VStack(alignment: .leading, spacing: 5) {
                sectionTitle("Geometry Source")
                detailRow("Geometry", value: source.capture.geometryName)
                detailRow("Source", value: source.capture.geometryCanonicalPath, selectable: true)
                detailRow("Source Revision", value: snapshot.geometryRevision, selectable: true)
                geometryLayerSummary("Topology", state: snapshot.topologyState,
                    count: source.topologyFeatures.count, progress: source.topologyProgress,
                    include: row.payloadKind == "Geometry" || row.payloadKind == "ConceptualMesh"
                        || snapshot.topologyState.locator == row.locator)
                geometryLayerSummary("Flow Areas", state: snapshot.flowAreasState,
                    count: source.cells.count, progress: source.cellsProgress,
                    include: row.payloadKind == "Geometry" || row.payloadKind == "FlowAreaLayer"
                        || snapshot.flowAreasState.locator == row.locator)
                if row.locator.nodeType == "FlowAreaLayer",
                   let flowAreaNode = snapshot.flowAreasState.locator,
                   flowAreaNode == row.locator {
                    if source.flowAreaGenerationPresentation?.phase == .generating
                        || source.flowAreaGenerationPresentation?.phase == .awaitingSavedSource {
                        Text("Mesh diagnostics will refresh from the current Geometry mesh.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if source.flowAreaGenerationPresentation?.phase == .childDraft
                        && source.flowAreaGenerationPresentation?.map == nil {
                        Text("Mesh diagnostics are unavailable for the current Geometry draft.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let context = try? MapTreeMeshErrorContext(capture: source.capture,
                        flowAreaNode: flowAreaNode, sourceRevision: snapshot.geometryRevision,
                        contextToken: snapshot.contextToken,
                        geometryMeshDraftIdentity: source.flowAreaGenerationPresentation?.phase == .childDraft
                            && source.flowAreaGenerationPresentation?.map != nil
                                ? source.flowAreaGenerationPresentation?.identity : nil) {
                        MapMeshErrorPropertiesView(store: store, mapState: mapState,
                            session: mapState.meshErrors, context: context)
                    }
                }
                geometryLayerSummary("Culvert Barrels", state: snapshot.culvertsState,
                    count: source.culvertFeatures.count, progress: source.culvertsProgress,
                    include: row.payloadKind == "Geometry" || row.payloadKind == "CulvertBarrelLayer"
                        || snapshot.culvertsState.locator == row.locator)
                if let error = source.error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                if let selection = mapState.projectGeometryMap.selection,
                   selection.id.hasPrefix(source.capture.identity + "|") {
                    sectionTitle("Selected Geometry Feature")
                    detailRow("Geometry", value: selection.geometryName)
                    detailRow("Layer", value: L10n.text(selection.layerTitle))
                    detailRow("Feature", value: selection.featureLabel, selectable: true)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
        } else if matches.count == 1, let source = matches.first {
            if let error = source.error {
                statusCard("Geometry Source", message: error, localizeMessage: false)
            } else {
                statusCard("Geometry Source", message: source.isLoading
                    ? L10n.text("Loading Geometry source…") : L10n.text("Geometry source data is unavailable."))
            }
        } else {
            statusCard("Geometry Source", message: "Geometry source data is unavailable for this map row.")
        }
    }

    @ViewBuilder
    private func geometryLayerSummary(_ title: String, state: MapGeometryLayerState,
                                      count: Int, progress: ProjectGeometryMapPageProgress,
                                      include: Bool) -> some View {
        if include {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text(title)).font(.subheadline.weight(.medium))
                detailRow("Status", value: localizedSourceStatus(state.status.rawValue))
                detailRow("Checked", value: state.isChecked ? L10n.text("Yes") : L10n.text("No"))
                detailRow("Effective Visibility", value: state.effectiveVisible ? L10n.text("Visible") : L10n.text("Hidden"))
                detailRow("Loaded Features", value: count.formatted())
                detailRow("Source Features", value: progress.sourceCount.formatted())
                if !progress.complete {
                    detailRow("Scanned", value: progress.scannedCount.formatted())
                }
                if let diagnostic = state.diagnostic {
                    Text(diagnostic).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .padding(.top, 4)
        }
    }

    private func geometrySourceMatches(_ source: ProjectGeometryMapSourceState,
                                       row: MapSourceRenderRecord) -> Bool {
        if source.capture.geometryNode == row.locator { return true }
        guard let snapshot = source.snapshot else { return false }
        return [snapshot.topologyState.locator, snapshot.flowAreasState.locator, snapshot.culvertsState.locator]
            .compactMap { $0 }.contains(row.locator)
    }

    @ViewBuilder
    private func resultDetails(for row: MapSourceRenderRecord) -> some View {
        let currentSources = mapState.resultSources.snapshot.flatMap { snapshot -> MapResultChartSources? in
            guard snapshot.identity == currentWorkflowIdentity,
                  snapshot.sources.mapID.caseInsensitiveCompare(mapState.id.uuidString) == .orderedSame else {
                return nil
            }
            return snapshot.sources
        }
        let activeMatches = (currentSources?.activeNodes ?? []).filter { $0.node == row.locator }
        if activeMatches.count == 1, let active = activeMatches.first {
            let availability = mapState.resultMap.availability(for: row.locator)
            let matchingMapNodes = mapState.resultMap.nodes.filter { $0.id == active.id }
            VStack(alignment: .leading, spacing: 5) {
                sectionTitle("Result Source")
                detailRow("Node Type", value: L10n.text(active.nodeKind))
                if matchingMapNodes.count == 1, let mapNode = matchingMapNodes.first {
                    if mapNode.isLoading { detailRow("Render State", value: L10n.text("Loading")) }
                    else if mapNode.isRefreshing { detailRow("Render State", value: L10n.text("Refreshing")) }
                    detailRow("Rendered Raster Layers", value: mapNode.layerCount.formatted())
                    if let message = mapNode.unavailableMessage {
                        Text(verbatim: message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let liveStatus = mapNode.liveComputeStatus {
                        detailRow("Live Compute Status", value: L10n.text(liveStatus.localizedTitle))
                        if let fraction = mapNode.liveComputeFraction, fraction.isFinite {
                            detailRow("Live Compute Progress", value: L10n.format("%.0f%%", min(max(fraction, 0), 1) * 100))
                        }
                        detailRow("Live Profile Metadata", value: mapNode.liveProfileMetadataCount.formatted())
                        if mapNode.isLiveProfileMetadataOnly {
                            Text(L10n.text("Profile metadata is available; raster frames are not yet readable."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let mapType = active.selectedMapType { detailRow("Selected Map Type", value: L10n.text(mapType)) }
                if let profileIndex = active.profileIndex { detailRow("Profile Index", value: profileIndex.formatted()) }
                if !active.selections.isEmpty {
                    sectionTitle("Result Selections")
                    ForEach(active.selections) { selection in
                        VStack(alignment: .leading, spacing: 4) {
                            sectionTitle(L10n.format("Result Slot %d", selection.selectionIndex + 1))
                            detailRow("Selection", value: L10n.text(selection.selectionMode.titleKey))
                            detailRow("Available Results", value: selection.choices.count.formatted())
                            if let selected = selection.selectedResult {
                                detailRow("Result", value: selected.resultName)
                                detailRow("Result Source", value: selected.resultPath, selectable: true)
                                detailRow("Result Revision", value: selected.revision, selectable: true)
                                if let planName = selected.planName { detailRow("Plan", value: planName) }
                                if let endTime = selected.endTime { detailRow("End Time", value: endTime) }
                                if selected.isComputing {
                                    detailRow("Compute Status", value: L10n.text("Running"))
                                } else if let state = selected.computeState {
                                    detailRow("Compute Status", value: L10n.text(state))
                                }
                                if let failure = selected.computeFailureReason, !failure.isEmpty {
                                    detailRow("Compute Failure", value: failure)
                                }
                                if let status = selected.diagnosticStatus {
                                    detailRow("Diagnostic Status", value: L10n.text(status))
                                }

                                let selectedPath = SourceFilePaths.canonical(URL(fileURLWithPath: selected.resultPath))
                                let sourceStatuses = (availability?.sourceStatuses ?? []).enumerated().filter { _, status in
                                    status.selectionIndices.contains(selection.selectionIndex)
                                        && SourceFilePaths.canonical(URL(fileURLWithPath: status.resultPath)) == selectedPath
                                        && status.revision.caseInsensitiveCompare(selected.revision) == .orderedSame
                                }
                                if sourceStatuses.isEmpty {
                                    detailRow("Render Availability", value: L10n.text("Unknown"))
                                } else {
                                    ForEach(sourceStatuses, id: \.offset) { _, status in
                                        detailRow("Render Availability", value: L10n.text(status.available ? "Available" : "Unavailable"))
                                        detailRow("Render Profile Index", value: status.profileIndex.map(String.init) ?? L10n.text("Unavailable"))
                                        if let terrainPath = status.terrainPath {
                                            detailRow("Terrain Source", value: terrainPath, selectable: true)
                                        }
                                        if let terrainRevision = status.terrainRevision {
                                            detailRow("Terrain Revision", value: terrainRevision, selectable: true)
                                        }
                                        if let reason = status.unavailableReason, !reason.isEmpty {
                                            Text(verbatim: reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                        }
                                    }
                                }

                                if let diagnostics = selected.layerErrors {
                                    DisclosureGroup(L10n.format("Diagnostics (%d)", diagnostics.count)) {
                                        if diagnostics.isEmpty {
                                            Text(L10n.text("No stored diagnostic messages."))
                                                .font(.caption).foregroundStyle(.secondary)
                                        } else {
                                            ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                                                VStack(alignment: .leading, spacing: 3) {
                                                    Text(verbatim: "\(diagnostic.severity) · \(diagnostic.code)")
                                                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                                    Text(verbatim: diagnostic.evaluatedMessage).font(.caption).textSelection(.enabled)
                                                    ForEach(Array(diagnostic.logData.enumerated()), id: \.offset) { _, datum in
                                                        detailRow(datum.key, value: datum.value ?? "—", selectable: true)
                                                    }
                                                }
                                                .padding(.vertical, 3)
                                            }
                                        }
                                    }
                                } else if let readError = selected.diagnosticReadError, !readError.isEmpty {
                                    detailRow("Diagnostic Read", value: L10n.text("Diagnostic read failed"))
                                    Text(verbatim: readError).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                                } else {
                                    detailRow("Diagnostic Status", value: L10n.text("Diagnostics are unknown or unavailable."))
                                }
                            } else {
                                Text(L10n.text("No Result is selected for this slot."))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                if mapState.resultMap.selectedNodeID == active.id,
                   let timeline = mapState.resultMap.selectedTimeline {
                    ProfileTimeline(mapState: mapState, session: timeline)
                        .frame(minHeight: 56)
                } else if let selectedNode = mapState.resultMap.nodes.first(where: { $0.id == active.id }),
                          let unavailable = selectedNode.unavailableMessage {
                    Text(unavailable).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
        } else {
            statusCard("Result Source", message: "Result source data is unavailable for this map row.")
        }
    }

    @ViewBuilder
    private func linkedResultDetails() -> some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("Linked Results")
            if let capture = mapState.linkedResults.capture,
               capture.projectSessionID == store.projectSessionID,
               capture.mapID == mapState.id,
               capture.mapWorkflowIdentity == currentWorkflowIdentity {
                detailRow("Anchor Source", value: capture.anchorPath, selectable: true)
                detailRow("Profile", value: mapState.linkedResults.profileIndex.formatted())
                if let step = mapState.linkedResults.currentStep {
                    detailRow("Time", value: step.time)
                }
                MapLinkedProfileTimeline(mapState: mapState)
            } else {
                Text("Linked result context is not available.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func statusCard(_ title: String, message: String,
                            localizeMessage: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle(title)
            Group {
                if localizeMessage { Text(L10n.text(message)) }
                else { Text(verbatim: message) }
            }
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(L10n.text(title)).font(.subheadline.weight(.semibold))
    }

    private func localizedComponentType(_ rawValue: String) -> String {
        let key: String
        switch rawValue {
        case "WindLayer": key = "Wind Forces"
        case "NValue": key = "N-Value Layer"
        case "BoundaryCondition": key = "Boundary Condition"
        case "FlowAreaLayer": key = "Flow Area"
        case "CulvertBarrelLayer": key = "Culvert Barrels"
        case "ConceptualMesh": key = "Conceptual Mesh"
        case "MapLayer": key = "Map Layer"
        case "MultiResult": key = "Multiple Results"
        case "LinkedResult": key = "Linked Results"
        case "DiscreteRaster": key = "Raster Layer"
        default: key = rawValue
        }
        return L10n.text(key)
    }

    private func localizedGeometryType(_ kind: MapFeature.Kind) -> String {
        switch kind {
        case .point: L10n.text("Point")
        case .line: L10n.text("Line")
        case .polygon: L10n.text("Polygon")
        }
    }

    private func localizedSourceStatus(_ rawValue: String?) -> String {
        switch rawValue?.lowercased() {
        case "available": L10n.text("Available")
        case "hidden": L10n.text("Hidden")
        case "empty": L10n.text("Empty")
        case "unavailable": L10n.text("Unavailable")
        case "failed": L10n.text("Failed")
        case "partial": L10n.text("Partial")
        case "loading", nil: L10n.text("Loading")
        case .some(let value): L10n.text(value)
        }
    }

    private func detailRow(_ title: String, value: String, selectable: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L10n.text(title)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if selectable {
                Text(verbatim: value).multilineTextAlignment(.trailing).textSelection(.enabled)
            } else {
                Text(verbatim: value).multilineTextAlignment(.trailing).textSelection(.disabled)
            }
        }
        .font(.caption)
    }

    private func coordinate(_ value: Double) -> String {
        guard value.isFinite else { return L10n.text("Unavailable") }
        return value.formatted(.number.precision(.fractionLength(0...6)))
    }

    private func sourcePath(for row: MapSourceRenderRecord) -> String? {
        if let path = row.locator.associationAssetID, path.hasPrefix("/") { return SourceFilePaths.canonical(URL(fileURLWithPath: path)) }
        if let path = row.locator.parentResultAssetID, path.hasPrefix("/") { return SourceFilePaths.canonical(URL(fileURLWithPath: path)) }
        if let path = row.locator.parentGeometryAssetID, path.hasPrefix("/") { return SourceFilePaths.canonical(URL(fileURLWithPath: path)) }
        if let path = row.locator.assetID, path.hasPrefix("/") { return SourceFilePaths.canonical(URL(fileURLWithPath: path)) }
        if let path = row.locator.filename, path.hasPrefix("/") { return SourceFilePaths.canonical(URL(fileURLWithPath: path)) }
        return nil
    }

    private func modelEditorTarget(for row: MapSourceRenderRecord) -> (ModelEditorKind, String)? {
        let type = row.locator.nodeType
        if let resultPath = row.locator.parentResultAssetID, resultPath.hasPrefix("/"),
           ["Geometry", "ConceptualMesh", "FlowAreaLayer", "CulvertBarrelLayer"].contains(type) {
            return (.result, SourceFilePaths.canonical(URL(fileURLWithPath: resultPath)))
        }
        let rawPath: String?
        let kind: ModelEditorKind
        switch type {
        case "Plan": kind = .plan; rawPath = row.locator.assetID
        case "Result", "MultiResult":
            kind = .result
            rawPath = (mapState.resultSources.sources?.activeNodes.first { $0.node == row.locator })?
                .selections.first?.selectedResult?.resultPath ?? row.locator.assetID
        case "Geometry", "ConceptualMesh", "FlowAreaLayer", "CulvertBarrelLayer":
            kind = .geometry; rawPath = row.locator.parentGeometryAssetID ?? row.locator.assetID
        case "Terrain": kind = .terrain; rawPath = row.locator.associationAssetID ?? row.locator.assetID
        case "NValue", "Classification": kind = .surface; rawPath = row.locator.associationAssetID ?? row.locator.assetID
        case "BoundaryCondition": kind = .boundaryCondition; rawPath = row.locator.associationAssetID ?? row.locator.assetID
        default: return nil
        }
        guard let rawPath, rawPath.hasPrefix("/") else { return nil }
        return (kind, SourceFilePaths.canonical(URL(fileURLWithPath: rawPath)))
    }

    private func canOpenExactModel(_ kind: ModelEditorKind, assetID: String, row: MapSourceRenderRecord) -> Bool {
        guard isCurrentMap, store.hasProject, store.mapIdentityRequest(for: mapState.id) != nil,
              visibleRows.contains(where: { $0 == row }) else { return false }
        let matches = store.assets.filter {
            $0.section == kind.section && $0.isModelFile
                && SourceFilePaths.canonical($0.url) == assetID
        }
        return matches.count == 1
    }

    private func openExactModel(_ kind: ModelEditorKind, assetID: String, row: MapSourceRenderRecord) {
        let projectID = store.projectSessionID
        let workflow = store.mapWorkflowIdentity(mapState.id)
        guard projectID == store.projectSessionID,
              store.existingMapState(for: mapState.id) === mapState,
              store.mapWorkflowIdentity(mapState.id) == workflow,
              canOpenExactModel(kind, assetID: assetID, row: row),
              let asset = store.assets.first(where: {
                  $0.section == kind.section && $0.isModelFile
                      && SourceFilePaths.canonical($0.url) == assetID
              }) else { return }
        store.activateMap(mapState.id)
        store.openEditor(kind, assetID: asset.id)
    }

    private func openExactAttributeTable(_ layer: MapVectorLayer, row: MapSourceRenderRecord) {
        let projectID = store.projectSessionID
        let workflow = store.mapWorkflowIdentity(mapState.id)
        let path = SourceFilePaths.canonical(layer.url)
        guard isCurrentMap, projectID == store.projectSessionID,
              store.existingMapState(for: mapState.id) === mapState,
              store.mapWorkflowIdentity(mapState.id) == workflow,
              visibleRows.contains(where: { $0 == row }),
              exactVectorLayers(for: row).filter({ SourceFilePaths.canonical($0.url) == path }).count == 1,
              path.lowercased().hasSuffix(".shp") else { return }
        store.activateMap(mapState.id)
        openWindow(value: AttributeTableRoute(path: path))
    }
}
