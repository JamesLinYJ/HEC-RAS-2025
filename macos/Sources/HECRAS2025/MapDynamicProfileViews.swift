import CryptoKit
import RASWorkspaceCore
import SwiftUI

enum GeometryDynamicProfileKind { case arcs, barrels }

enum GeometryDynamicProfileLines {
    static func arcs(_ snapshot: GeometryTopologySnapshot?, selectedIDs: Set<String>) -> [MapDynamicProfileLine] {
        guard let snapshot, !selectedIDs.isEmpty else { return [] }
        return (snapshot.map?.features ?? []).filter { feature in
            feature.featureKind == "arc" && feature.geometryType == "line" &&
                (selectedIDs.contains(feature.id) || !selectedIDs.isDisjoint(with: feature.selectionIDs) ||
                 feature.fid.map({ selectedIDs.contains(String($0)) }) == true)
        }.sorted { $0.id < $1.id }.compactMap { feature in
            guard feature.paths.count == 1, let points = feature.paths.first, valid(points) else { return nil }
            return MapDynamicProfileLine(id: feature.id, points: points)
        }
    }

    static func barrels(_ snapshot: GeometryCulvertSnapshot?, selectedIDs: Set<String>) -> [MapDynamicProfileLine] {
        guard let snapshot, !selectedIDs.isEmpty else { return [] }
        return snapshot.barrels.rows.filter { selectedIDs.contains($0.id) }.sorted { $0.id < $1.id }
            .compactMap { row in
                let points = row.polyline.map { GeometryTopologyCoordinate(x: $0.x, y: $0.y) }
                return valid(points) ? MapDynamicProfileLine(id: row.id, points: points) : nil
            }
    }

    static func token(lines: [MapDynamicProfileLine], sourceIdentity: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let bytes = (try? encoder.encode(lines)) ?? Data()
        return MapDynamicProfileRequest.digest(Data(sourceIdentity.utf8) + Data([0]) + bytes)
    }

    private static func valid(_ points: [GeometryTopologyCoordinate]) -> Bool {
        guard points.count >= 2, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        return zip(points, points.dropFirst()).contains { $0 != $1 }
    }
}

/// One original DynamicProfilePlot attached to the exact selected saved map.
/// The lines may come from an unsaved geometry child draft; all plotted values
/// are sampled by the retained map resamplers, never by chart pixel lookup.
struct MapDynamicProfileWorkspace: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    @ObservedObject private var sources: MapResultSourcesSession
    @ObservedObject private var rendering: MapResultMapSession
    @ObservedObject private var linked: MapLinkedResultContextSession
    @StateObject private var sampler: MapDynamicProfileSession
    let lines: [MapDynamicProfileLine]
    let linesToken: String
    let presentation: MapDynamicProfileWindowPresentation
    let windowSession: MapDynamicProfileWindowSession?

    @State private var targetSampleCount = 256
    @State private var plotTerrains = true
    @State private var plotResults = true
    @State private var terrainRequiresElevationResult = true
    @State private var selectedMapType: String?
    @State private var selectedLineID = ""
    @State private var showLegend = true
    @State private var showValues = false
    @State private var refreshGeneration = 0
    @State private var cursor: Double?
    @State private var overlayOwner = UUID()
    @State private var containerSize = CGSize.zero

    init(store: WorkspaceStore, mapState: MapState, client: BackendProcessClient,
         lines: [MapDynamicProfileLine], linesToken: String,
         presentation: MapDynamicProfileWindowPresentation = .geometryDraft,
         windowSession: MapDynamicProfileWindowSession? = nil) {
        self.store = store
        self.mapState = mapState
        self.lines = lines
        self.linesToken = linesToken
        self.presentation = presentation
        self.windowSession = windowSession
        _sources = ObservedObject(wrappedValue: mapState.resultSources)
        _rendering = ObservedObject(wrappedValue: mapState.resultMap)
        _linked = ObservedObject(wrappedValue: mapState.linkedResults)
        _sampler = StateObject(wrappedValue: windowSession?.sampler
            ?? MapDynamicProfileSession(provider: BackendMapDynamicProfileProvider(client: client)))
        _targetSampleCount = State(initialValue: presentation.targetSampleCount)
        _plotTerrains = State(initialValue: presentation.plotTerrains)
        _plotResults = State(initialValue: presentation.plotResults)
        _terrainRequiresElevationResult = State(initialValue: presentation.terrainRequiresElevationResult)
        _selectedMapType = State(initialValue: presentation.initialMapType)
    }

    private var baseIdentity: String {
        "\(store.projectSessionID)|\(store.mapWorkflowIdentity(mapState.id))"
    }
    private var request: MapDynamicProfileRequest? {
        guard !store.isRunningPlanCompute,
              windowSession?.isValid != false, windowSession?.isRebindingSources != true,
              let snapshot = windowSession?.sources ?? sources.snapshot,
              sources.snapshot == snapshot,
              snapshot.identity == store.mapWorkflowIdentity(mapState.id),
              snapshot.map == store.mapResultRequest(for: mapState.id), !lines.isEmpty else { return nil }
        let frames = snapshot.sources.activeNodes.compactMap { node -> MapDynamicProfileSelection? in
            guard let index = rendering.nodes.first(where: { $0.id == node.id })?.profileIndex
                    ?? node.profileIndex else { return nil }
            return MapDynamicProfileSelection(node: node.node, profileIndex: index)
        }
        var request = MapDynamicProfileRequest(map: snapshot.map, contextToken: snapshot.sources.contextToken,
            selectionOverrides: snapshot.selectionOverrides, lines: lines, linesToken: linesToken,
            targetSampleCount: targetSampleCount, plotTerrains: plotTerrains, plotResults: plotResults,
            terrainRequiresElevationResult: terrainRequiresElevationResult,
            mapType: selectedMapType, profileSelections: frames)
        if linked.isActive {
            guard let selection = linked.selection else { return nil }
            request = MapDynamicProfileRequest(map: snapshot.map, contextToken: snapshot.sources.contextToken,
                selectionOverrides: snapshot.selectionOverrides, lines: lines, linesToken: linesToken,
                targetSampleCount: targetSampleCount, plotTerrains: plotTerrains, plotResults: plotResults,
                terrainRequiresElevationResult: terrainRequiresElevationResult, mapType: selectedMapType,
                profileSelections: [], linkedResults: LinkedResultProfilesRequest(
                    projectPath: selection.projectPath, projectXml: snapshot.map.projectXml,
                    projectRevision: selection.projectRevision, anchor: selection.anchor,
                    selectedGroups: selection.selectedGroups, profileIndex: linked.profileIndex),
                linkedFrameMode: linked.frameMode.rawValue)
        }
        return request
    }
    private var requestIdentity: String {
        "\(baseIdentity)|\(request?.identity ?? linesToken)|\(linked.isActive)|\(linked.profileIndex)|\(linked.frameMode.rawValue)|\(sources.isLoading)|\(sources.isSelecting)|\(windowSession?.isRebindingSources ?? false)|\(store.isRunningPlanCompute)|\(windowSession?.id.uuidString ?? "embedded")|\(refreshGeneration)"
    }
    private var snapshot: MapDynamicProfileResult? {
        guard sampler.acceptedRequestIdentity == request?.identity else { return nil }
        return sampler.snapshot
    }
    private var visibleLines: [MapDynamicProfileLineResult] {
        (snapshot?.lines ?? []).filter { selectedLineID.isEmpty || $0.id == selectedLineID }
    }
    private var series: [MapDynamicProfileSeries] { visibleLines.flatMap(\.series) }
    private var seriesColors: [Color] {
        let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .red]
        return series.indices.map { palette[$0 % palette.count] }
    }
    private var stationDistanceTitle: String {
        guard let units = snapshot?.distanceUnits ?? presentation.axisUnits else {
            return L10n.text("Station Distance")
        }
        return L10n.text("Station Distance") + " (\(units))"
    }
    private var legendFitsThresholds: Bool {
        containerSize.width.isFinite && containerSize.height.isFinite
            && containerSize.width >= presentation.legendWidthThreshold
            && containerSize.height >= presentation.legendHeightThreshold
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            controls
            if windowSession?.isRebindingSources == true {
                ProgressView()
            } else if sources.isLoading || sampler.isLoading {
                ProgressView(L10n.text("Sampling the selected map profiles…"))
            }
            if let error = sources.errorMessage ?? sampler.error {
                Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.caption).textSelection(.enabled)
            }
            if lines.isEmpty {
                ContentUnavailableView(L10n.text("Select source lines to sample their map profiles."),
                    systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            } else if let snapshot {
                if series.contains(where: { $0.samples.contains(where: { $0 != nil }) }) {
                    chart.frame(minHeight: 220, idealHeight: 300)
                    if showLegend && legendFitsThresholds { legend }
                } else {
                    ContentUnavailableView(L10n.text("No profile values are available for the selected map."),
                        systemImage: "chart.xyaxis.line")
                }
                unavailableSources
                if snapshot.lines.allSatisfy({ $0.series.isEmpty }) {
                    Text(L10n.text("The selected map has no active sources allowed by these profile options."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup(L10n.text("Sample values"), isExpanded: $showValues) {
                    if showValues { valuesTable.frame(minHeight: 160, idealHeight: 230) }
                }
            } else if windowSession?.isRebindingSources != true,
                      !sampler.isLoading && !sources.isLoading && sampler.error == nil {
                Text(L10n.text("Choose an active saved map to load its real profile sources."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .onPreferenceChange(MapDynamicProfileContainerSizeKey.self) { containerSize = $0 }
        .task(id: baseIdentity) {
            if let windowSession {
                let currentMapIdentity = store.mapWorkflowIdentity(mapState.id)
                if windowSession.mapWorkflowIdentity != currentMapIdentity {
                    store.rebindMapDynamicProfileSources(mapID: mapState.id)
                    await store.configureMapResultSources(mapState.id)
                }
            } else {
                await store.configureMapResultSources(mapState.id)
            }
        }
        .task(id: requestIdentity) {
            guard !store.isRunningPlanCompute, !sources.isLoading, !sources.isSelecting,
                  let request, let expectedRevision = (windowSession?.sources ?? sources.snapshot)?.sources.projectRevision else {
                sampler.invalidate()
                return
            }
            let identity = requestIdentity
            let project = store.projectSessionID
            await sampler.load(request, expectedProjectRevision: expectedRevision) {
                guard !store.isRunningPlanCompute,
                      store.isCurrentMapState(mapState, mapID: mapState.id, projectSessionID: project) else { return false }
                if let windowSession {
                    return store.isCurrentMapDynamicProfileWindow(windowSession, state: mapState)
                }
                return identity == requestIdentity
            }
        }
        .onChange(of: requestIdentity) { _, _ in
            cursor = nil
            mapState.dynamicProfileOverlay.clear(owner: overlayOwner)
        }
        .onChange(of: store.isRunningPlanCompute) { _, isComputing in
            if isComputing {
                sampler.invalidate()
                cursor = nil
                mapState.dynamicProfileOverlay.clear(owner: overlayOwner)
            }
        }
        .onChange(of: lines.map(\.id)) { _, ids in
            if !ids.contains(selectedLineID) { selectedLineID = "" }
        }
        .onChange(of: selectedLineID) { _, _ in
            cursor = nil
            mapState.dynamicProfileOverlay.clear(owner: overlayOwner)
        }
        .onDisappear {
            sampler.invalidate()
            mapState.dynamicProfileOverlay.clear(owner: overlayOwner)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if lines.count > 1 {
                    Picker(L10n.text("Profile"), selection: $selectedLineID) {
                        Text(L10n.text("All Profiles")).tag("")
                        ForEach(lines) { line in Text(verbatim: line.id).tag(line.id) }
                    }.frame(maxWidth: 220)
                } else if let line = lines.first {
                    Text(verbatim: line.id).lineLimit(1).help(line.id)
                }
                if presentation.showsResultMapTypeSelector {
                    Picker(L10n.text("Result Map Type"), selection: $selectedMapType) {
                        Text(L10n.text("Source Profile")).tag(String?.none)
                        Text(L10n.text("Water Surface Elevation")).tag(String?.some("WaterSurfaceElevation"))
                        Text(L10n.text("Depth")).tag(String?.some("Depth"))
                        Text(L10n.text("Velocity")).tag(String?.some("Velocity"))
                    }.frame(maxWidth: 220)
                }
                Spacer(minLength: 4)
                Button { refreshGeneration += 1 } label: {
                    Label(L10n.text("Refresh"), systemImage: "arrow.clockwise")
                }.disabled(request == nil || sampler.isLoading || store.isRunningPlanCompute)
            }
            HStack {
                Toggle(L10n.text("Terrain"), isOn: $plotTerrains)
                Toggle(L10n.text("Results"), isOn: $plotResults)
                Toggle(L10n.text("Terrain requires elevation result"), isOn: $terrainRequiresElevationResult)
                    .help(L10n.text("Show terrain with Water Surface Elevation, or clear this option to overlay terrain with other result map types."))
                Spacer(minLength: 4)
                Stepper(L10n.format("Target samples: %d", targetSampleCount),
                    value: $targetSampleCount, in: 1...4096, step: 1)
                    .frame(maxWidth: 220)
                Toggle(L10n.text("Legend"), isOn: $showLegend)
            }.toggleStyle(.checkbox).font(.caption)
        }
    }

    private var chart: some View {
        MapDynamicProfileFacetedChart(lines: visibleLines, orderedSeries: series,
            colors: seriesColors, stationDistanceTitle: stationDistanceTitle,
            cursor: cursor, onHover: hover)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: MapDynamicProfileContainerSizeKey.self,
                        value: geometry.size)
                }
            }
    }

    private func hover(_ distance: Double?) {
        cursor = distance
        guard snapshot != nil else { mapState.dynamicProfileOverlay.clear(owner: overlayOwner); return }
        let sampledLines = visibleLines.map { MapDynamicProfileLine(id: $0.id, points: $0.samplePoints) }
        let distances = Dictionary(uniqueKeysWithValues: visibleLines.map { ($0.id, $0.distances) })
        mapState.dynamicProfileOverlay.install(owner: overlayOwner, lines: sampledLines, distancesByID: distances)
        mapState.dynamicProfileOverlay.move(owner: overlayOwner, distance: distance)
    }

    private var unavailableSources: some View {
        ForEach(series.filter { $0.unavailableReason != nil }) { item in
            Label("\(item.name): \(L10n.text(item.unavailableReason ?? ""))", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private var legend: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading) {
            ForEach(series.indices, id: \.self) { index in
                let item = series[index]
                HStack(spacing: 5) {
                    Capsule().fill(seriesColors[index]).frame(width: 18, height: 3)
                    Text(verbatim: item.name + " · " + item.lineId).lineLimit(1)
                }.font(.caption).help(item.sourcePath)
            }
        }
    }

    private var valueRows: [MapDynamicProfileValueRow] {
        visibleLines.flatMap { line in
            line.series.flatMap { series in
                line.distances.indices.map { index in
                    MapDynamicProfileValueRow(id: series.id + ":" + String(index), line: line.id,
                        source: series.name, sourcePath: series.sourcePath, distance: line.distances[index],
                        value: series.samples[index], units: series.units)
                }
            }
        }
    }

    private var valuesTable: some View {
        Table(valueRows) {
            TableColumn(L10n.text("Profile"), value: \.line)
            TableColumn(L10n.text("Source")) { row in Text(verbatim: row.source).help(row.sourcePath) }
            TableColumn(stationDistanceTitle) { row in Text(row.distance.formatted()).monospacedDigit() }
            TableColumn(L10n.text("Value")) { row in
                Text(row.value.map { $0.formatted() } ?? L10n.text("No data")).monospacedDigit()
            }
            TableColumn(L10n.text("Units"), value: \.units)
        }.textSelection(.enabled)
    }
}

private struct MapDynamicProfileValueRow: Identifiable {
    let id: String
    let line: String
    let source: String
    let sourcePath: String
    let distance: Double
    let value: Double?
    let units: String
}

private struct MapDynamicProfileContainerSizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}
