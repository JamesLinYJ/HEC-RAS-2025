import SwiftUI
import RASWorkspaceCore

@MainActor
struct GeometryMeshElementChartWindowView: View {
    @ObservedObject var session: GeometryMeshSession
    let ownerCapture: GeometryMeshToolsOwnerCapture
    let elementKind: GeometryMeshElementKind
    let elementIndex: Int
    let projectContext: GeometryMeshToolsProjectContext
    let onComputeAndPlotRequested: @MainActor () -> Void

    @State private var result: GeometryMeshElementPropertyChartResult?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var isCancelling = false
    @State private var progress: BackendProgressUpdate?
    @State private var activeOperationID: String?
    @State private var generation = UUID()
    private let provider: any GeometryMeshElementChartProviding

    init(session: GeometryMeshSession, ownerCapture: GeometryMeshToolsOwnerCapture,
         elementKind: GeometryMeshElementKind, elementIndex: Int,
         projectContext: GeometryMeshToolsProjectContext,
         onComputeAndPlotRequested: @escaping @MainActor () -> Void = {},
         provider: any GeometryMeshElementChartProviding = BackendGeometryMeshElementChartProvider()) {
        self.session = session
        self.ownerCapture = ownerCapture
        self.elementKind = elementKind
        self.elementIndex = elementIndex
        self.projectContext = projectContext
        self.onComputeAndPlotRequested = onComputeAndPlotRequested
        self.provider = provider
    }

    private var identity: String {
        [ownerCapture.identity, elementKind.rawValue, String(elementIndex),
         projectContext.projectSessionID.uuidString,
         projectContext.coreLayerContext?.identityToken ?? ""].joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L10n.format("%@ property curve", elementKind.rawValue), systemImage: "chart.xyaxis.line")
                    .font(.headline)
                Spacer()
                Text(L10n.format("%@ · %@ · %d", ownerCapture.flowAreaName,
                    elementKind.rawValue, elementIndex))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if isLoading {
                HStack(spacing: 10) {
                    if let fraction = progress?.fraction {
                        ProgressView(value: min(1, max(0, fraction)))
                            .frame(maxWidth: 180)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.text(progress?.taskName ?? "Reading the current Geometry property table…"))
                            .font(.callout)
                        if let message = progress?.message, !message.isEmpty {
                            Text(L10n.text(message)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(isCancelling ? L10n.text("Cancelling…") : L10n.text("Cancel"),
                           systemImage: "xmark.circle") { cancelLoading() }
                        .disabled(isCancelling)
                }
            } else if let result, result.state == "ready" {
                if let data = GeometryMeshElementPropertyChartData.make(result) {
                    SeriesChartView(samples: data.samples, presentation: data.presentation,
                        emptyMessage: L10n.text("The source property table contains no chart points."))
                        .frame(minHeight: 300)
                } else {
                    ContentUnavailableView(L10n.text("The source property table contains no chart points."),
                        systemImage: "chart.xyaxis.line")
                }
            } else if let result {
                ContentUnavailableView {
                    Label(L10n.text(result.state == "requiresPropertyTables"
                        ? "Property tables need to be computed"
                        : result.state == "cancelled"
                            ? "Property chart calculation cancelled"
                            : "Current property tables are unavailable"),
                        systemImage: result.state == "cancelled"
                            ? "xmark.circle"
                            : "tablecells.badge.ellipsis")
                } description: {
                    Text(L10n.text(result.message ?? "Compute property tables in the Geometry draft to plot this source curve."))
                }
                if result.state == "requiresPropertyTables", isCurrent {
                    Button(L10n.text("Compute Property Tables and Plot"),
                           systemImage: "tablecells.badge.ellipsis",
                           action: onComputeAndPlotRequested)
                        .buttonStyle(.borderedProminent)
                }
            } else if let errorMessage {
                ContentUnavailableView {
                    Label(L10n.text("Property curve unavailable"), systemImage: "exclamationmark.triangle")
                } description: { Text(verbatim: errorMessage).textSelection(.enabled) }
            } else if !isCurrent {
                ContentUnavailableView(L10n.text("The Geometry mesh selection changed"),
                    systemImage: "arrow.clockwise",
                    description: Text(L10n.text("Find the element again before opening its property curve.")))
            }
        }
        .padding(12)
        .task(id: identity) { await load() }
        .onChange(of: session.geometryMeshIdentity) { _, _ in invalidate() }
        .onChange(of: projectContext) { _, _ in invalidate() }
        .onDisappear { cancelLoading() }
    }

    private var isCurrent: Bool {
        session.isMeshToolsOwnerCurrent(ownerCapture, projectContext: projectContext)
    }

    private func invalidate() {
        cancelLoading()
        generation = UUID()
        result = nil
        errorMessage = nil
        isLoading = false
        progress = nil
    }

    private func cancelLoading() {
        guard let operationID = activeOperationID else { return }
        _ = provider.cancel(operationID: operationID)
        isCancelling = true
    }

    private func load() async {
        let requestGeneration = UUID()
        generation = requestGeneration
        result = nil
        errorMessage = nil
        progress = nil
        isCancelling = false
        guard isCurrent, elementIndex >= 0 else {
            errorMessage = L10n.text("The Geometry mesh selection changed. Find the element again.")
            return
        }
        isLoading = true
        defer { if generation == requestGeneration { isLoading = false } }
        do {
            let request = GeometryMeshElementPropertyChartRequest(owner: ownerCapture,
                elementKind: elementKind, elementIndex: elementIndex)
            activeOperationID = request.operationID
            defer {
                if activeOperationID == request.operationID { activeOperationID = nil }
            }
            let reply = try await provider.load(request) { update in
                guard generation == requestGeneration, activeOperationID == request.operationID else { return }
                progress = update
            }
            guard generation == requestGeneration, !Task.isCancelled, isCurrent,
                  GeometryMeshElementPropertyChartValidation.matches(reply, request: request) else { return }
            result = reply
        } catch is CancellationError {
            guard generation == requestGeneration, !Task.isCancelled else { return }
            errorMessage = L10n.text("The property curve request was cancelled.")
        } catch {
            guard generation == requestGeneration, !Task.isCancelled, isCurrent else { return }
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
private enum GeometryMeshElementPropertyChartData {
    static func make(_ result: GeometryMeshElementPropertyChartResult)
        -> (samples: [ChartSample], presentation: SeriesEditorPresentation)? {
        guard result.state == "ready", !result.points.isEmpty,
              result.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let seriesName = "\(result.xQuantity) / \(result.yQuantity)"
        let samples = result.points.enumerated().map { index, point in
            ChartSample(id: "property/\(result.elementKind)/\(result.elementIndex)/\(index)",
                x: point.x, y: point.y, series: seriesName)
        }
        let chart = SeriesChartPresentation(title: L10n.format("%@ %d · %@ / %@",
            result.elementKind, result.elementIndex, result.xQuantity, result.yQuantity), axes: [
                .init(id: "x", direction: .x, title: result.xQuantity, units: result.xUnits),
                .init(id: "y", direction: .y, title: result.yQuantity, units: result.yUnits)
            ], datasets: [.init(id: seriesName, name: seriesName, xAxisID: "x", yAxisID: "y")])
        return (samples, SeriesEditorPresentation(xTitle: result.xQuantity,
            yTitle: result.yQuantity, chart: chart))
    }
}

private enum GeometryMeshElementPropertyChartValidation {
    static func matches(_ result: GeometryMeshElementPropertyChartResult,
                        request: GeometryMeshElementPropertyChartRequest) -> Bool {
        result.projectSessionID.caseInsensitiveCompare(request.projectSessionID) == .orderedSame
            && result.operationID == request.operationID
            && result.assetID == request.assetID
            && SourceFilePaths.canonical(URL(fileURLWithPath: result.canonicalAssetPath))
                == SourceFilePaths.canonical(URL(fileURLWithPath: request.model.assetPath))
            && result.sourceRevision.caseInsensitiveCompare(request.revision) == .orderedSame
            && result.meshDraftSHA256.caseInsensitiveCompare(request.meshDraftSHA256) == .orderedSame
            && result.topologyDraftSHA256.caseInsensitiveCompare(request.topologyDraftSHA256) == .orderedSame
            && result.flowAreaID == request.flowAreaID
            && result.flowAreaName == request.expectedFlowAreaName
            && result.elementKind == request.elementKind
            && result.elementIndex == request.elementIndex
            && (result.state == "cancelled" || result.flowAreaIndex >= 0)
            && (result.state != "ready" || (!result.points.isEmpty
                && result.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite })))
    }
}

@MainActor
struct GeometryMeshElementCrossResultChartEntry: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var session: GeometryMeshSession
    let ownerCapture: GeometryMeshToolsOwnerCapture
    let elementKind: GeometryMeshElementKind
    let elementIndex: Int
    let projectContext: GeometryMeshToolsProjectContext

    @State private var selectedMapID: UUID?

    init(store: WorkspaceStore, session: GeometryMeshSession,
         ownerCapture: GeometryMeshToolsOwnerCapture, elementKind: GeometryMeshElementKind,
         elementIndex: Int, projectContext: GeometryMeshToolsProjectContext) {
        self.store = store
        self.session = session
        self.ownerCapture = ownerCapture
        self.elementKind = elementKind
        self.elementIndex = elementIndex
        self.projectContext = projectContext
        let activeMap = store.lastActiveMapID
        _selectedMapID = State(initialValue: store.mapResultRequest(for: activeMap) == nil ? nil : activeMap)
    }

    private var mapChoices: [MapDocument] {
        store.mapDocuments.filter { store.mapResultRequest(for: $0.id) != nil }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Picker(L10n.text("Result map"), selection: $selectedMapID) {
                    Text(L10n.text("Choose a map…")).tag(UUID?.none)
                    ForEach(mapChoices) { map in Text(map.name).tag(Optional(map.id)) }
                }
                .pickerStyle(.menu)
                if let selectedMapID, let state = store.existingMapState(for: selectedMapID) {
                    GeometryMeshMapResultCaptureControl(store: store, mapState: state,
                        selectedMapID: selectedMapID, source: .geometry(ownerCapture,
                            kind: elementKind, index: elementIndex),
                        originIsCurrent: {
                            session.isMeshToolsOwnerCurrent(ownerCapture, projectContext: projectContext)
                        })
                        .id(selectedMapID)
                } else {
                    Label(L10n.text("Open a saved map with accepted Results to compare this mesh element."),
                        systemImage: "map")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(L10n.text("Compare Across Results"), systemImage: "chart.xyaxis.line")
        }
    }
}

@MainActor
struct MapResultMeshTimeSeriesEntry: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    @ObservedObject private var resultSources: MapResultSourcesSession
    let snapshot: MapResultSourcesSnapshot
    let node: MapResultChartActiveNode

    init(store: WorkspaceStore, mapState: MapState,
         snapshot: MapResultSourcesSnapshot, node: MapResultChartActiveNode) {
        self.store = store
        self.mapState = mapState
        self._resultSources = ObservedObject(wrappedValue: mapState.resultSources)
        self.snapshot = snapshot
        self.node = node
    }

    var body: some View {
        GroupBox {
            if let current = resultSources.snapshot, current == snapshot,
               let exactNode = current.sources.activeNodes.first(where: { $0.id == node.id && $0 == node }) {
                MapResultMeshTimeSeriesControl(store: store, mapState: mapState,
                    selectedMapID: mapState.id, source: .result(node: exactNode),
                    initialSnapshot: snapshot, originIsCurrent: { true })
                    .id(MapResultMeshTimeSeriesOriginInput.result(node: exactNode).identity
                        + "|" + snapshot.identity)
            } else {
                Label(L10n.text("Refresh the map Result sources before plotting this mesh element."),
                    systemImage: "arrow.clockwise")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } label: {
            Label(L10n.text("Mesh Element Across Results"), systemImage: "chart.xyaxis.line")
        }
    }
}

@MainActor
private struct GeometryMeshMapResultCaptureControl: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    @ObservedObject private var resultSources: MapResultSourcesSession
    let selectedMapID: UUID
    let source: MapResultMeshTimeSeriesOriginInput
    let originIsCurrent: @MainActor () -> Bool

    init(store: WorkspaceStore, mapState: MapState, selectedMapID: UUID,
         source: MapResultMeshTimeSeriesOriginInput,
         originIsCurrent: @escaping @MainActor () -> Bool) {
        self.store = store
        self.mapState = mapState
        self._resultSources = ObservedObject(wrappedValue: mapState.resultSources)
        self.selectedMapID = selectedMapID
        self.source = source
        self.originIsCurrent = originIsCurrent
    }

    private var snapshot: MapResultSourcesSnapshot? {
        guard !resultSources.isStale, !resultSources.isLoading, !resultSources.isSelecting,
              let snapshot = resultSources.snapshot,
              store.mapResultRequest(for: selectedMapID) == snapshot.map else { return nil }
        return snapshot
    }

    var body: some View {
        if snapshot != nil {
            MapResultMeshTimeSeriesControl(store: store, mapState: mapState,
                selectedMapID: selectedMapID, source: source,
                initialSnapshot: nil,
                originIsCurrent: originIsCurrent)
                .id(source.identity)
        } else {
            Label(L10n.text("This map has no accepted Result snapshot. Open a saved map with Results, then refresh its source list."),
                systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private enum MapResultMeshTimeSeriesOriginInput: Equatable, Sendable {
    case geometry(GeometryMeshToolsOwnerCapture, kind: GeometryMeshElementKind, index: Int)
    case result(node: MapResultChartActiveNode)

    var identity: String {
        switch self {
        case let .geometry(owner, kind, index):
            owner.identity + "|" + kind.rawValue + "|" + String(index)
        case let .result(node):
            node.id + "|" + node.selections.map { slot in
                "\(slot.selectionIndex):\(slot.selectedResult?.resultPath ?? ""):\(slot.selectedResult?.revision ?? "")"
            }.joined(separator: "|")
        }
    }
}

@MainActor
private struct MapResultMeshTimeSeriesControl: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    @ObservedObject private var resultSources: MapResultSourcesSession
    let selectedMapID: UUID
    let source: MapResultMeshTimeSeriesOriginInput
    let initialSnapshot: MapResultSourcesSnapshot?
    let originIsCurrent: @MainActor () -> Bool

    @State private var selectedFlowAreaID = ""
    @State private var elementKind = GeometryMeshElementKind.cell
    @State private var elementIndex = "0"
    @State private var capture: MapResultMeshTimeSeriesCapture?
    @State private var inspectResult: MapResultMeshTimeSeriesInspectResult?
    @State private var chartData: MapResultMeshTimeSeriesChartData?
    @State private var isInspecting = false
    @State private var isExecuting = false
    @State private var isCancelling = false
    @State private var activeOperationID: String?
    @State private var progress: BackendProgressUpdate?
    @State private var errorMessage: String?
    @State private var showingChart = false
    @State private var generation = UUID()
    @State private var operationTask: Task<Void, Never>?
    @State private var provider = BackendMapResultMeshTimeSeriesProvider()

    init(store: WorkspaceStore, mapState: MapState, selectedMapID: UUID,
         source: MapResultMeshTimeSeriesOriginInput,
         initialSnapshot: MapResultSourcesSnapshot? = nil,
         originIsCurrent: @escaping @MainActor () -> Bool) {
        self.store = store
        self.mapState = mapState
        self._resultSources = ObservedObject(wrappedValue: mapState.resultSources)
        self.selectedMapID = selectedMapID
        self.source = source
        self.initialSnapshot = initialSnapshot
        self.originIsCurrent = originIsCurrent
        if case let .geometry(_, kind, index) = source {
            _elementKind = State(initialValue: kind)
            _elementIndex = State(initialValue: String(index))
        }
    }

    private var sourceSnapshot: MapResultSourcesSnapshot? {
        guard let snapshot = initialSnapshot ?? resultSources.snapshot,
              !resultSources.isStale, !resultSources.isLoading, !resultSources.isSelecting,
              store.mapResultRequest(for: selectedMapID) == snapshot.map else { return nil }
        return snapshot
    }

    private var selectedFlowArea: MapResultMeshFlowAreaChoice? {
        inspectResult?.flowAreas.first(where: { $0.flowAreaID == selectedFlowAreaID })
    }

    private var meshFlowAreaChoices: [MapResultMeshFlowAreaChoice] {
        inspectResult?.flowAreas.filter(\.hasMesh) ?? []
    }

    private var parsedIndex: Int? {
        guard let index = Int(elementIndex), index >= 0 else { return nil }
        return index
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(L10n.text("Find Matching Results"), systemImage: "arrow.trianglehead.2.clockwise.rotate.90") {
                    startInspect()
                }
                .disabled(isInspecting || isExecuting || !canCapture)
                if isInspecting { ProgressView().controlSize(.small) }
                Spacer()
                if let inspectResult {
                    Text(L10n.format("%d matching Results", inspectResult.matchingResultNames.count))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }

            if case .geometry(let owner, let kind, let index) = source {
                LabeledContent(L10n.text("Source mesh element"),
                    value: "\(L10n.text(kind.rawValue)) · \(index)")
                LabeledContent(L10n.text("Source Flow Area"), value: owner.flowAreaName)
            } else {
                Picker(L10n.text("Flow Area"), selection: $selectedFlowAreaID) {
                    Text(L10n.text("Choose a Flow Area…")).tag("")
                    ForEach(meshFlowAreaChoices) { choice in
                        MapResultMeshFlowAreaPickerOption(choice: choice)
                            .tag(choice.flowAreaID)
                    }
                }
                .pickerStyle(.menu)
                Picker(L10n.text("Element type"), selection: $elementKind) {
                    Text(L10n.text("Cell")).tag(GeometryMeshElementKind.cell)
                    Text(L10n.text("Face")).tag(GeometryMeshElementKind.face)
                }
                .pickerStyle(.segmented)
                TextField(L10n.text("Zero-based mesh element index"), text: $elementIndex)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
            }

            if let inspectResult {
                if inspectResult.state != "ready" {
                    Label(L10n.text(inspectResult.message ?? "The selected source has no mesh."),
                        systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                } else if inspectResult.matchingResultNames.isEmpty {
                    Label(L10n.text(inspectResult.skippedComputingResultCount > 0
                        ? "No matching completed Results use this exact mesh; Results still computing were skipped."
                        : "No active Results use this exact mesh."), systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(inspectResult.matchingResultNames.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }

            HStack(spacing: 8) {
                if isExecuting {
                    Button(L10n.text("Cancel"), systemImage: "xmark.circle") { cancel() }
                        .disabled(isCancelling)
                    ProgressView(value: progress?.fraction)
                        .frame(maxWidth: 130)
                    Text(L10n.text(progress?.message ?? progress?.taskName ?? "Reading Result values…"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Button(L10n.text("Plot Element Across Results"), systemImage: "chart.xyaxis.line") {
                        startExecute()
                    }
                    .disabled(!canExecute)
                }
            }
            if let errorMessage {
                Label(L10n.text(errorMessage), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .onChange(of: resultSources.snapshot?.identity) { _, _ in invalidate() }
        .onChange(of: selectedFlowAreaID) { _, _ in chartData = nil; errorMessage = nil }
        .onChange(of: elementKind) { _, _ in chartData = nil; errorMessage = nil }
        .onChange(of: elementIndex) { _, _ in chartData = nil; errorMessage = nil }
        .onDisappear { invalidate() }
        .sheet(isPresented: $showingChart) {
            if let chartData { MapResultMeshTimeSeriesChartWindow(data: chartData) }
        }
    }

    private var canCapture: Bool {
        sourceSnapshot != nil && originIsCurrent() && store.existingMapState(for: selectedMapID) === mapState
            && selectedMapID == mapState.id
    }

    private var canExecute: Bool {
        guard !isInspecting, !isExecuting, let inspectResult, inspectResult.state == "ready",
              !inspectResult.matchingResultNames.isEmpty, let selectedFlowArea,
              selectedFlowArea.hasMesh, let index = parsedIndex,
              let capture, current(capture) else { return false }
        let count = elementKind == .cell ? selectedFlowArea.cellCount : selectedFlowArea.faceCount
        return index < count
    }

    private func startInspect() {
        guard !isInspecting, !isExecuting else { return }
        let requestGeneration = UUID()
        generation = requestGeneration
        isInspecting = true
        isCancelling = false
        progress = nil
        errorMessage = nil
        operationTask = Task { await inspect(requestGeneration: requestGeneration) }
    }

    private func inspect(requestGeneration: UUID) async {
        defer {
            if generation == requestGeneration {
                isInspecting = false
                operationTask = nil
            }
        }
        guard generation == requestGeneration, !Task.isCancelled else { return }
        guard let snapshot = sourceSnapshot, canCapture else {
            errorMessage = L10n.text("The map Result snapshot or mesh owner is stale. Refresh the map and retry.")
            return
        }
        let expectedSession = store.projectSessionID
        let context = store.sourceMapTreeContext(selectedMapID)
        guard context.projectSessionID == expectedSession,
              context.coreLayerContext == snapshot.map.coreLayerContext,
              store.mapResultRequest(for: selectedMapID) == snapshot.map,
              mapState.resultSources.snapshot == snapshot else {
            errorMessage = L10n.text("The selected map or Result selection changed before capture.")
            return
        }
        let origin: (geometry: MapResultMeshGeometryOrigin?, result: MapResultMeshResultOrigin?, identity: String)
        switch source {
        case let .geometry(owner, kind, index):
            guard sessionOwnerMatches(owner) else {
                errorMessage = L10n.text("The Geometry mesh draft changed. Find the element again.")
                return
            }
            origin = (MapResultMeshGeometryOrigin(owner: owner), nil,
                owner.identity + "|" + kind.rawValue + "|" + String(index))
        case let .result(node):
            guard let exactNode = snapshot.sources.activeNodes.first(where: { $0.id == node.id && $0 == node }),
                  (exactNode.nodeKind == "Result" || exactNode.nodeKind == "MultiResult"),
                  let slot = exactNode.selections.first(where: { $0.selectionIndex == 0 }),
                  let selected = slot.selectedResult,
                  selected.revision.count == 64, selected.revision.allSatisfy(\.isHexDigit),
                  !selected.isComputing, exactNode.node.nodePath?.isEmpty == false else {
                errorMessage = L10n.text("The selected Result slot zero is unavailable or still computing.")
                return
            }
            origin = (nil, MapResultMeshResultOrigin(resultNode: exactNode.node,
                selectionIndex: 0, selectedResultPath: SourceFilePaths.canonical(
                    URL(fileURLWithPath: selected.resultPath)),
                selectedResultRevision: selected.revision.uppercased()),
                exactNode.id + "|0|" + selected.resultPath + "|" + selected.revision)
        }
        let owner = MapResultMeshTimeSeriesOwner(map: .init(snapshot: snapshot, treeContext: context),
            projectSessionID: expectedSession.uuidString,
            contextToken: snapshot.sources.contextToken,
            selectionOverrides: snapshot.selectionOverrides,
            geometryOrigin: origin.geometry, resultOrigin: origin.result)
        let requestCapture = MapResultMeshTimeSeriesCapture(owner: owner, mapID: selectedMapID,
            projectSessionID: expectedSession,
            mapSourceWorkflowIdentity: store.mapSourceWorkflowIdentity(selectedMapID),
            sourceSnapshotIdentity: snapshot.identity, originIdentity: origin.identity)
        capture = requestCapture
        inspectResult = nil
        selectedFlowAreaID = ""
        errorMessage = nil
        do {
            let response = try await provider.inspect(.init(owner: owner))
            guard generation == requestGeneration, !Task.isCancelled, current(requestCapture),
                  MapResultMeshTimeSeriesValidation.matches(response, capture: requestCapture,
                    snapshot: snapshot, source: source) else { return }
            inspectResult = response
            if case let .geometry(owner, _, _) = source,
               let choice = response.flowAreas.first(where: {
                   $0.flowAreaID == owner.flowAreaID && $0.name == owner.flowAreaName
               }) {
                selectedFlowAreaID = choice.flowAreaID
            }
        } catch {
            guard generation == requestGeneration, !Task.isCancelled, current(requestCapture) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func startExecute() {
        guard canExecute, let capture, let selectedFlowArea, let index = parsedIndex,
              let inspectResult, let snapshot = sourceSnapshot else { return }
        let request = MapResultMeshTimeSeriesExecuteRequest(operationID: UUID().uuidString,
            owner: capture.owner, flowAreaIndex: selectedFlowArea.flowAreaIndex,
            flowAreaID: selectedFlowArea.flowAreaID, expectedFlowAreaName: selectedFlowArea.name,
            elementKind: elementKind.rawValue, elementIndex: index)
        let requestGeneration = UUID()
        generation = requestGeneration
        activeOperationID = request.operationID
        isExecuting = true
        isCancelling = false
        progress = nil
        errorMessage = nil
        operationTask = Task {
            await execute(request, capture: capture, inspectResult: inspectResult,
                snapshot: snapshot, requestGeneration: requestGeneration)
        }
    }

    private func execute(_ request: MapResultMeshTimeSeriesExecuteRequest,
                         capture: MapResultMeshTimeSeriesCapture,
                         inspectResult: MapResultMeshTimeSeriesInspectResult,
                         snapshot: MapResultSourcesSnapshot,
                         requestGeneration: UUID) async {
        defer {
            if generation == requestGeneration {
                isExecuting = false
                isCancelling = false
                activeOperationID = nil
                operationTask = nil
            }
        }
        guard generation == requestGeneration, !Task.isCancelled, current(capture) else { return }
        do {
            let response = try await provider.execute(request) { update in
                guard generation == requestGeneration, !Task.isCancelled, current(capture) else { return }
                progress = update
            }
            guard generation == requestGeneration, !Task.isCancelled, current(capture),
                  MapResultMeshTimeSeriesValidation.matches(response, request: request,
                    capture: capture, inspect: inspectResult, snapshot: snapshot) else { return }
            guard response.state == "ready" else {
                if response.state == "cancelled" {
                    errorMessage = L10n.text("The Result time-series request was cancelled.")
                } else {
                    errorMessage = L10n.text(response.message ?? "No matching Result values are available.")
                }
                return
            }
            guard let data = MapResultMeshTimeSeriesChartData.make(response) else {
                errorMessage = L10n.text("The Result time-series response is incomplete or invalid.")
                return
            }
            chartData = data
            showingChart = true
        } catch {
            guard generation == requestGeneration, !Task.isCancelled, current(capture) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func cancel() {
        guard let activeOperationID else { return }
        isCancelling = true
        _ = provider.cancel(operationID: activeOperationID)
    }

    private func current(_ capture: MapResultMeshTimeSeriesCapture) -> Bool {
        guard store.projectSessionID == capture.projectSessionID,
              store.existingMapState(for: capture.mapID) === mapState,
              selectedMapID == capture.mapID,
              store.mapResultRequest(for: capture.mapID) == sourceSnapshot?.map,
              mapState.resultSources.snapshot == sourceSnapshot,
              sourceSnapshot?.identity == capture.sourceSnapshotIdentity,
              store.mapSourceWorkflowIdentity(capture.mapID) == capture.mapSourceWorkflowIdentity,
              originIsCurrent() else { return false }
        return true
    }

    private func sessionOwnerMatches(_ owner: GeometryMeshToolsOwnerCapture) -> Bool {
        guard case let .geometry(expected, _, _) = source else { return false }
        return owner == expected && originIsCurrent()
    }

    private func invalidate() {
        generation = UUID()
        if let activeOperationID { _ = provider.cancel(operationID: activeOperationID) }
        operationTask?.cancel()
        operationTask = nil
        capture = nil
        inspectResult = nil
        chartData = nil
        activeOperationID = nil
        isInspecting = false
        isExecuting = false
        isCancelling = false
        errorMessage = nil
        selectedFlowAreaID = ""
        showingChart = false
    }
}

@MainActor
private struct MapResultMeshFlowAreaPickerOption: View {
    let choice: MapResultMeshFlowAreaChoice

    var body: some View {
        Text(L10n.format("%@ (%d cells / %d faces)", choice.name,
            choice.cellCount, choice.faceCount))
    }
}

@MainActor
private enum MapResultMeshTimeSeriesValidation {
    static func matches(_ response: MapResultMeshTimeSeriesInspectResult,
                        capture: MapResultMeshTimeSeriesCapture,
                        snapshot: MapResultSourcesSnapshot,
                        source: MapResultMeshTimeSeriesOriginInput) -> Bool {
        let map = capture.owner.map
        guard response.projectSessionID.caseInsensitiveCompare(capture.owner.projectSessionID) == .orderedSame,
              SourceFilePaths.canonical(URL(fileURLWithPath: response.projectCanonicalPath))
                == SourceFilePaths.canonical(URL(fileURLWithPath: map.projectPath)),
              response.projectRevision.caseInsensitiveCompare(snapshot.sources.projectRevision) == .orderedSame,
              response.projectXmlSHA.caseInsensitiveCompare(map.projectXmlSHA) == .orderedSame,
              response.visualizationRevision.caseInsensitiveCompare(map.expectedVisualizationRevision) == .orderedSame,
              response.coreLayerContextIdentity == (map.coreLayerContext?.identityToken ?? ""),
              response.mapID.caseInsensitiveCompare(map.mapID) == .orderedSame,
              response.mapIndex == map.mapIndex, response.mapName == map.mapName,
              response.mapType == map.mapType,
              response.contextToken == snapshot.sources.contextToken,
              response.skippedComputingResultCount >= 0,
              Set(response.flowAreas.map(\.flowAreaID)).count == response.flowAreas.count,
              response.flowAreas.allSatisfy({ $0.flowAreaIndex >= 0
                && $0.flowAreaID == "flow-area-row:\($0.flowAreaIndex)"
                && $0.cellCount >= 0 && $0.faceCount >= 0 }) else { return false }
        switch source {
        case let .geometry(owner, _, _):
            return response.originKind == "Geometry"
                && SourceFilePaths.canonical(URL(fileURLWithPath: response.originPath))
                    == SourceFilePaths.canonical(URL(fileURLWithPath: owner.model.assetPath))
                && response.originRevision.caseInsensitiveCompare(owner.sourceRevision) == .orderedSame
                && response.originMeshDraftSHA256.caseInsensitiveCompare(owner.meshDraftSHA256) == .orderedSame
                && response.originTopologyDraftSHA256.caseInsensitiveCompare(owner.topologyDraftSHA256) == .orderedSame
        case let .result(node):
            guard let slot = node.selections.first(where: { $0.selectionIndex == 0 }),
                  let selected = slot.selectedResult else { return false }
            return response.originKind == "Result" && response.originResultNode == node.node
                && response.originSelectionIndex == 0
                && SourceFilePaths.canonical(URL(fileURLWithPath: response.originPath))
                    == SourceFilePaths.canonical(URL(fileURLWithPath: selected.resultPath))
                && response.originRevision.caseInsensitiveCompare(selected.revision) == .orderedSame
        }
    }

    static func matches(_ response: MapResultMeshTimeSeriesResult,
                        request: MapResultMeshTimeSeriesExecuteRequest,
                        capture: MapResultMeshTimeSeriesCapture,
                        inspect: MapResultMeshTimeSeriesInspectResult,
                        snapshot: MapResultSourcesSnapshot?) -> Bool {
        guard let snapshot else { return false }
        guard response.operationID == request.operationID,
              response.projectSessionID.caseInsensitiveCompare(capture.owner.projectSessionID) == .orderedSame,
              samePath(response.projectCanonicalPath, capture.owner.map.projectPath),
              response.projectRevision.caseInsensitiveCompare(snapshot.sources.projectRevision) == .orderedSame,
              response.projectXmlSHA.caseInsensitiveCompare(capture.owner.map.projectXmlSHA) == .orderedSame,
              response.visualizationRevision.caseInsensitiveCompare(capture.owner.map.expectedVisualizationRevision) == .orderedSame,
              response.coreLayerContextIdentity == (capture.owner.map.coreLayerContext?.identityToken ?? ""),
              response.mapID.caseInsensitiveCompare(capture.owner.map.mapID) == .orderedSame,
              response.mapIndex == capture.owner.map.mapIndex,
              response.mapName == capture.owner.map.mapName,
              response.mapType == capture.owner.map.mapType,
              response.contextToken == capture.owner.contextToken,
              response.originKind == inspect.originKind,
              samePath(response.originPath, inspect.originPath),
              response.originRevision.caseInsensitiveCompare(inspect.originRevision) == .orderedSame,
              response.originMeshDraftSHA256.caseInsensitiveCompare(inspect.originMeshDraftSHA256) == .orderedSame,
              response.originTopologyDraftSHA256.caseInsensitiveCompare(inspect.originTopologyDraftSHA256) == .orderedSame,
              response.originResultNode == inspect.originResultNode,
              response.originSelectionIndex == inspect.originSelectionIndex,
              response.flowAreaIndex == request.flowAreaIndex,
              response.flowAreaID == request.flowAreaID,
              response.flowAreaName == request.expectedFlowAreaName,
              response.elementKind == request.elementKind,
              response.elementIndex == request.elementIndex,
              response.variable == (request.elementKind == "Cell" ? "Depth" : "Velocity"),
              response.meshHash == inspect.flowAreas.first(where: { $0.flowAreaID == request.flowAreaID })?.meshHash,
              response.skippedComputingResultCount >= 0 else { return false }
        if response.state == "ready" {
            guard let flowArea = inspect.flowAreas.first(where: { $0.flowAreaID == request.flowAreaID }),
                  flowArea.flowAreaIndex == request.flowAreaIndex,
                  flowArea.name == request.expectedFlowAreaName else { return false }
            var seenResults = Set<String>()
            guard !response.series.isEmpty,
                  response.series.allSatisfy({ item in
                      let resultPath = SourceFilePaths.canonical(URL(fileURLWithPath: item.resultPath))
                      let resultIdentity = resultPath + "|" + item.resultRevision.uppercased()
                      let retainedOwners = zip(item.owners, item.selectionIndices).allSatisfy { pair in
                          let owner = pair.0
                          let selectionIndex = pair.1
                          guard selectionIndex == 0,
                                let active = snapshot.sources.activeNodes.first(where: {
                                    $0.node == owner && ($0.nodeKind == "Result" || $0.nodeKind == "MultiResult")
                                }),
                                let slot = active.selections.first(where: { $0.selectionIndex == 0 }),
                                let selected = slot.selectedResult else { return false }
                          return samePath(selected.resultPath, resultPath)
                              && selected.revision.caseInsensitiveCompare(item.resultRevision) == .orderedSame
                              && !selected.isComputing
                      }
                      let unique = seenResults.insert(resultIdentity).inserted
                      return item.flowAreaIndex == request.flowAreaIndex
                        && item.flowAreaName == request.expectedFlowAreaName
                        && item.meshHash == response.meshHash
                        && item.variable == response.variable
                        && item.resultPath == resultPath
                        && item.resultRevision.count == 64
                        && item.resultRevision.allSatisfy(\.isHexDigit)
                        && !item.owners.isEmpty && unique && retainedOwners
                        && item.values.count == item.times.count
                        && item.values.allSatisfy(\.isFinite)
                        && item.owners.count == item.selectionIndices.count
                  }) else { return false }
            return true
        }
        return (response.state == "cancelled" || response.state == "noMatchingMesh") && response.series.isEmpty
    }

    private static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        SourceFilePaths.canonical(URL(fileURLWithPath: lhs))
            == SourceFilePaths.canonical(URL(fileURLWithPath: rhs))
    }
}

@MainActor
private struct MapResultMeshTimeSeriesChartWindow: View {
    let data: MapResultMeshTimeSeriesChartData
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SeriesChartView(samples: data.samples, presentation: data.presentation,
                emptyMessage: L10n.text("No matching Result values are available."))
        }
        .frame(minWidth: 720, minHeight: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.text("Close"), systemImage: "xmark") { dismiss() }
            }
        }
    }
}
