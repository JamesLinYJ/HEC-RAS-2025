import Combine
import Foundation
import RASWorkspaceCore

@MainActor
final class ResultProfileSession: ObservableObject {
    @Published private(set) var identity: ResultProfileIdentity?
    @Published private(set) var catalog: ResultProfileCatalog?
    @Published private(set) var selection: ResultProfileSelection?
    @Published private(set) var mapData: ResultProfileMapResult?
    @Published private(set) var series: ResultProfileSeries?
    @Published private(set) var sampleLineSources: ResultProfileSources?
    @Published private(set) var sampleLineMapData: ResultProfileMapResult?
    @Published private(set) var sampleLinePoints: [GeometryTopologyCoordinate] = []
    @Published private(set) var selectedSampleLineResultPaths: Set<String> = []
    @Published private(set) var sampleLineMode: ResultProfileSampleLineMode = .flow
    @Published private(set) var sampleLineSeries: [ResultProfileSampleLineSeries] = []
    @Published private(set) var isLoadingCatalog = false
    @Published private(set) var isLoadingMap = false
    @Published private(set) var isLoadingSeries = false
    @Published private(set) var isLoadingSampleLineSources = false
    @Published private(set) var isLoadingSampleLineMap = false
    @Published private(set) var isComputingSampleLine = false
    @Published private(set) var isCancellingSampleLine = false
    @Published private(set) var sampleLineProgressFraction: Double?
    @Published private(set) var sampleLineProgressMessage: String?
    @Published private(set) var sampleLineProgressTaskName: String?
    @Published private(set) var error: String?
    @Published private(set) var sampleLineError: String?

    private let provider: any ResultProfileProvider
    private var catalogTask: Task<ResultProfileCatalog, any Error>?
    private var mapTask: Task<ResultProfileMapResult, any Error>?
    private var seriesTask: Task<ResultProfileSeries, any Error>?
    private var sampleLineSourcesTask: Task<ResultProfileSources, any Error>?
    private var sampleLineMapTask: Task<ResultProfileMapResult, any Error>?
    private var sampleLineTask: Task<ResultProfileSampleLineResult, any Error>?
    private var sampleLineProjectContext: ResultProfileSampleLineProjectContext?
    private var catalogGeneration = 0
    private var mapGeneration = 0
    private var seriesGeneration = 0
    private var sampleLineSourcesGeneration = 0
    private var sampleLineMapGeneration = 0
    private var sampleLineGeneration = 0

    init(provider: any ResultProfileProvider = BackendResultProfileProvider()) {
        self.provider = provider
    }

    func load(_ newIdentity: ResultProfileIdentity, force: Bool = false) async {
        guard force || identity != newIdentity || catalog == nil else { return }
        catalogTask?.cancel()
        mapTask?.cancel()
        seriesTask?.cancel()
        invalidateSampleLine(clearSources: true)
        catalogGeneration &+= 1
        mapGeneration &+= 1
        seriesGeneration &+= 1
        let generation = catalogGeneration
        identity = newIdentity
        catalog = nil
        selection = nil
        mapData = nil
        series = nil
        error = nil
        isLoadingCatalog = true
        isLoadingMap = false
        isLoadingSeries = false

        let provider = self.provider
        let request = Task { try await provider.loadCatalog(resultPath: newIdentity.resultPath, revision: newIdentity.revision) }
        catalogTask = request
        do {
            let loaded = try await withTaskCancellationHandler {
                try await request.value
            } onCancel: {
                request.cancel()
            }
            guard generation == catalogGeneration, identity == newIdentity else { return }
            guard loaded.resultPath == newIdentity.resultPath, loaded.revision == newIdentity.revision else {
                throw BackendServiceError(code: "sourceChanged", message: L10n.text("The selected result changed while its profiles were loading."))
            }
            catalog = loaded
            selection = defaultSelection(in: loaded)
            isLoadingCatalog = false
            catalogTask = nil
        } catch {
            guard generation == catalogGeneration, identity == newIdentity else { return }
            isLoadingCatalog = false
            catalogTask = nil
            if !(error is CancellationError) && !Task.isCancelled { self.error = L10n.text(error.localizedDescription) }
        }
    }

    func select(_ newSelection: ResultProfileSelection?) {
        let oldMapKey = mapKey(for: selection)
        let newMapKey = mapKey(for: newSelection)
        if newSelection != nil && oldMapKey != newMapKey { invalidateMap() }
        seriesTask?.cancel()
        seriesTask = nil
        seriesGeneration &+= 1
        series = nil
        isLoadingSeries = false
        error = nil
        guard let newSelection, let catalog, valid(newSelection, in: catalog) else {
            selection = nil
            return
        }
        selection = newSelection
    }

    func loadMap(flowAreaIndex: Int, elementKind: String,
                 extent: GeometryTopologyExtent? = nil, limit: Int = 2500) async {
        guard let identity,
              let area = catalog?.flowAreas.first(where: { $0.index == flowAreaIndex }),
              (area.elementCount(for: elementKind) ?? 0) > 0 else {
            invalidateMap()
            return
        }
        mapTask?.cancel()
        mapGeneration &+= 1
        let generation = mapGeneration
        let requestedIdentity = identity
        mapData = nil
        isLoadingMap = true
        error = nil

        let provider = self.provider
        let request = Task {
            try await provider.loadMap(resultPath: requestedIdentity.resultPath,
                revision: requestedIdentity.revision, flowAreaIndex: flowAreaIndex,
                elementKind: elementKind, extent: extent, limit: limit)
        }
        mapTask = request
        do {
            let loaded = try await withTaskCancellationHandler {
                try await request.value
            } onCancel: {
                request.cancel()
            }
            guard generation == mapGeneration, self.identity == requestedIdentity else { return }
            guard loaded.resultPath == requestedIdentity.resultPath,
                  loaded.revision == requestedIdentity.revision,
                  loaded.flowAreaIndex == flowAreaIndex,
                  loaded.elementKind == elementKind,
                  loaded.returnedElements == loaded.elements.count,
                  loaded.elementLimit > 0, loaded.vertexLimit > 0,
                  (loaded.isComplete
                    ? loaded.intersectingElements == loaded.returnedElements && !loaded.requiresZoom
                    : loaded.requiresZoom && loaded.elements.isEmpty && loaded.intersectingElements == nil) else {
                throw BackendServiceError(code: "sourceChanged", message: L10n.text("The result mesh map reply no longer matches the selected result or flow area."))
            }
            mapData = loaded
            isLoadingMap = false
            mapTask = nil
        } catch {
            guard generation == mapGeneration, self.identity == requestedIdentity else { return }
            isLoadingMap = false
            mapTask = nil
            if !(error is CancellationError) && !Task.isCancelled { self.error = L10n.text(error.localizedDescription) }
        }
    }

    func cancelMap() {
        invalidateMap()
    }

    func loadSampleSources(projectPath: String?, projectXml: String?, contextID: String) async {
        guard let identity, let projectPath, let projectXml,
              !projectPath.isEmpty, !projectXml.isEmpty,
              let provider = provider as? any ResultProfileSampleLineProvider else {
            invalidateSampleLine(clearSources: true)
            sampleLineError = L10n.text("Open a saved project and choose a result before computing a sample-line series.")
            return
        }
        let requestedContext = ResultProfileSampleLineProjectContext(
            projectPath: URL(fileURLWithPath: projectPath).standardizedFileURL.path,
            projectXml: projectXml, contextID: contextID)
        if sampleLineProjectContext == requestedContext,
           sampleLineSources?.resultPath == identity.resultPath,
           sampleLineSources?.revision == identity.revision { return }

        invalidateSampleLine(clearSources: true)
        sampleLineProjectContext = requestedContext
        sampleLineSourcesGeneration &+= 1
        let generation = sampleLineSourcesGeneration
        let requestedIdentity = identity
        isLoadingSampleLineSources = true
        sampleLineError = nil
        let task = Task {
            try await provider.loadSampleSources(projectPath: requestedContext.projectPath,
                projectXml: requestedContext.projectXml, resultPath: requestedIdentity.resultPath,
                revision: requestedIdentity.revision)
        }
        sampleLineSourcesTask = task
        do {
            let loaded = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard generation == sampleLineSourcesGeneration,
                  self.identity == requestedIdentity, sampleLineProjectContext == requestedContext else { return }
            let primary = loaded.sources.first {
                Self.samePath($0.resultPath, requestedIdentity.resultPath)
                    && $0.revision == requestedIdentity.revision
            }
            guard Self.samePath(loaded.projectPath, requestedContext.projectPath),
                  Self.samePath(loaded.resultPath, requestedIdentity.resultPath),
                  loaded.revision == requestedIdentity.revision,
                  !loaded.embeddedPlanName.isEmpty,
                  loaded.firstFlowAreaCellCount >= 0, loaded.firstFlowAreaFaceCount >= 0,
                  Set(loaded.sources.map { Self.canonicalPath($0.resultPath) }).count == loaded.sources.count,
                  loaded.sources.allSatisfy({ !$0.revision.isEmpty && $0.embeddedPlanName == loaded.embeddedPlanName
                      && $0.firstFlowAreaCellCount >= 0 && $0.firstFlowAreaFaceCount >= 0 }),
                  primary != nil else {
                throw BackendServiceError(code: "protocolFailure", message: L10n.text("The related results no longer match the selected Result."))
            }
            sampleLineSources = loaded
            selectedSampleLineResultPaths = [Self.canonicalPath(requestedIdentity.resultPath)]
            isLoadingSampleLineSources = false
            sampleLineSourcesTask = nil
        } catch {
            guard generation == sampleLineSourcesGeneration,
                  self.identity == requestedIdentity, sampleLineProjectContext == requestedContext else { return }
            isLoadingSampleLineSources = false
            sampleLineSourcesTask = nil
            if !(error is CancellationError) && !Task.isCancelled {
                sampleLineError = L10n.text(error.localizedDescription)
            }
        }
    }

    func loadSampleLineMap(extent: GeometryTopologyExtent? = nil, limit: Int = 2500) async {
        guard let identity,
              (sampleLineSources?.firstFlowAreaCellCount ?? 0) > 0 else {
            invalidateSampleLineMap()
            return
        }
        let provider = self.provider
        sampleLineMapTask?.cancel()
        sampleLineMapGeneration &+= 1
        let generation = sampleLineMapGeneration
        let requestedIdentity = identity
        sampleLineMapData = nil
        isLoadingSampleLineMap = true
        sampleLineError = nil
        let task = Task {
            try await provider.loadMap(resultPath: requestedIdentity.resultPath,
                revision: requestedIdentity.revision, flowAreaIndex: 0,
                elementKind: "Cell", extent: extent, limit: limit)
        }
        sampleLineMapTask = task
        do {
            let loaded = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard generation == sampleLineMapGeneration, self.identity == requestedIdentity else { return }
            guard Self.samePath(loaded.resultPath, requestedIdentity.resultPath),
                  loaded.revision == requestedIdentity.revision, loaded.flowAreaIndex == 0,
                  loaded.elementKind == "Cell", loaded.returnedElements == loaded.elements.count,
                  loaded.elementLimit > 0, loaded.vertexLimit > 0,
                  (loaded.isComplete
                    ? loaded.intersectingElements == loaded.returnedElements && !loaded.requiresZoom
                    : loaded.requiresZoom && loaded.elements.isEmpty && loaded.intersectingElements == nil) else {
                throw BackendServiceError(code: "protocolFailure", message: L10n.text("The result mesh map reply no longer matches the selected result or flow area."))
            }
            sampleLineMapData = loaded
            isLoadingSampleLineMap = false
            sampleLineMapTask = nil
        } catch {
            guard generation == sampleLineMapGeneration, self.identity == requestedIdentity else { return }
            isLoadingSampleLineMap = false
            sampleLineMapTask = nil
            if !(error is CancellationError) && !Task.isCancelled {
                sampleLineError = L10n.text(error.localizedDescription)
            }
        }
    }

    func cancelSampleLineMap() {
        invalidateSampleLineMap()
    }

    func addSampleLinePoint(_ point: GeometryTopologyCoordinate) {
        guard point.x.isFinite, point.y.isFinite else { return }
        sampleLinePoints.append(point)
        invalidateSampleLineComputation()
        sampleLineError = nil
    }

    func undoSampleLinePoint() {
        guard !sampleLinePoints.isEmpty else { return }
        sampleLinePoints.removeLast()
        invalidateSampleLineComputation()
        sampleLineError = nil
    }

    func clearSampleLine() {
        sampleLinePoints = []
        invalidateSampleLineComputation()
        sampleLineError = nil
    }

    func setSampleLineMode(_ mode: ResultProfileSampleLineMode) {
        guard sampleLineMode != mode else { return }
        sampleLineMode = mode
        invalidateSampleLineComputation()
        sampleLineError = nil
    }

    func setSampleLineSource(_ sourcePath: String, selected: Bool) {
        guard let sources = sampleLineSources,
              let source = sources.sources.first(where: { Self.samePath($0.resultPath, sourcePath) }),
              let identity, !Self.samePath(source.resultPath, identity.resultPath) else { return }
        let path = Self.canonicalPath(source.resultPath)
        if selected, !selectedSampleLineResultPaths.contains(path), selectedSampleLineResultPaths.count >= 32 {
            sampleLineError = L10n.text("Select no more than 32 Results for one sample-line chart.")
            return
        }
        if selected { selectedSampleLineResultPaths.insert(path) }
        else { selectedSampleLineResultPaths.remove(path) }
        invalidateSampleLineComputation()
        sampleLineError = nil
    }

    func computeSampleLine() async {
        guard let identity, let context = sampleLineProjectContext,
              let sources = sampleLineSources,
              let provider = provider as? any ResultProfileSampleLineProvider else {
            sampleLineError = L10n.text("Load the selected Result and its related results before computing a sample line.")
            return
        }
        guard sampleLinePoints.count >= 2 else {
            sampleLineSeries = []
            sampleLineError = L10n.text("Draw a sample line with two or more points before computing.")
            return
        }
        let selected = sources.sources.filter { selectedSampleLineResultPaths.contains(Self.canonicalPath($0.resultPath)) }
        guard selected.count <= 32 else {
            sampleLineError = L10n.text("Select no more than 32 Results for one sample-line chart.")
            return
        }
        guard selected.contains(where: { Self.samePath($0.resultPath, identity.resultPath)
            && $0.revision == identity.revision }) else {
            sampleLineError = L10n.text("Include the selected result in the sample-line chart.")
            return
        }
        invalidateSampleLineComputation()
        sampleLineGeneration &+= 1
        let generation = sampleLineGeneration
        let requestedIdentity = identity
        let requestedPoints = sampleLinePoints
        let requestedMode = sampleLineMode
        let requestedSources = selected.map { ResultProfileSourceIdentity(resultPath: $0.resultPath, revision: $0.revision) }
        let request = ResultProfileSampleLineRequest(projectPath: context.projectPath,
            projectXml: context.projectXml, resultPath: requestedIdentity.resultPath,
            revision: requestedIdentity.revision, sources: requestedSources,
            sampleLine: requestedPoints, mode: requestedMode.rawValue)
        isComputingSampleLine = true
        isCancellingSampleLine = false
        sampleLineProgressFraction = nil
        sampleLineProgressMessage = nil
        sampleLineProgressTaskName = nil
        sampleLineSeries = []
        sampleLineError = nil
        let progress: @Sendable (BackendProgressUpdate) -> Void = { [weak self] update in
            Task { @MainActor [weak self] in
                guard let self, self.sampleLineGeneration == generation, self.isComputingSampleLine else { return }
                self.acceptSampleLineProgress(update)
            }
        }
        let task = Task { try await provider.computeSampleLine(request, progress: progress) }
        sampleLineTask = task
        do {
            let loaded = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard generation == sampleLineGeneration,
                  self.identity == requestedIdentity, sampleLinePoints == requestedPoints,
                  sampleLineMode == requestedMode,
                  selectedSampleLineResultPaths == Set(requestedSources.map { Self.canonicalPath($0.resultPath) }) else { return }

            let requestedSourceIdentities = requestedSources.map {
                ResultProfileSourceIdentity(resultPath: Self.canonicalPath($0.resultPath), revision: $0.revision)
            }
            let returnedSourceIdentities = loaded.series.map {
                ResultProfileSourceIdentity(resultPath: Self.canonicalPath($0.resultPath), revision: $0.revision)
            }
            let sourceIdentitiesMatch = requestedSourceIdentities.elementsEqual(returnedSourceIdentities)
            let requestIdentityMatches = Self.samePath(loaded.projectPath, context.projectPath)
                && Self.samePath(loaded.resultPath, requestedIdentity.resultPath)
                && loaded.revision == requestedIdentity.revision
                && loaded.mode == requestedMode.rawValue
                && loaded.sampleLine == requestedPoints
            let seriesShapeMatches = loaded.series.allSatisfy { series in
                series.mode == requestedMode.rawValue
                    && (series.available ? !series.points.isEmpty : series.points.isEmpty)
            }
            guard requestIdentityMatches, sourceIdentitiesMatch, seriesShapeMatches else {
                throw BackendServiceError(code: "protocolFailure", message: L10n.text("The sample-line reply no longer matches the selected Results or line."))
            }
            sampleLineSeries = loaded.series
            isComputingSampleLine = false
            isCancellingSampleLine = false
            sampleLineTask = nil
        } catch {
            guard generation == sampleLineGeneration,
                  self.identity == requestedIdentity, sampleLinePoints == requestedPoints,
                  sampleLineMode == requestedMode else { return }
            isComputingSampleLine = false
            isCancellingSampleLine = false
            sampleLineTask = nil
            if !(error is CancellationError) && !Task.isCancelled {
                sampleLineError = L10n.text(error.localizedDescription)
            }
        }
    }

    func cancelSampleLineComputation() {
        guard isComputingSampleLine, !isCancellingSampleLine else { return }
        isCancellingSampleLine = true
        sampleLineTask?.cancel()
    }

    private func acceptSampleLineProgress(_ update: BackendProgressUpdate) {
        if let fraction = update.fraction, fraction.isFinite, (0...1).contains(fraction) {
            sampleLineProgressFraction = fraction
        }
        if let message = update.message, !message.isEmpty {
            sampleLineProgressMessage = message
        }
        if let taskName = update.taskName, !taskName.isEmpty {
            sampleLineProgressTaskName = taskName
        }
    }

    func readSelectedSeries() async {
        guard let identity, let selection, let catalog, valid(selection, in: catalog) else {
            error = L10n.text("Choose a stored output block, variable, flow area, and valid element index.")
            series = nil
            return
        }
        seriesTask?.cancel()
        seriesGeneration &+= 1
        let generation = seriesGeneration
        let requestedIdentity = identity
        let requestedSelection = selection
        series = nil
        error = nil
        isLoadingSeries = true

        let provider = self.provider
        let request = Task {
            try await provider.readSeries(resultPath: requestedIdentity.resultPath,
                revision: requestedIdentity.revision, selection: requestedSelection)
        }
        seriesTask = request
        do {
            let loaded = try await withTaskCancellationHandler {
                try await request.value
            } onCancel: {
                request.cancel()
            }
            guard generation == seriesGeneration, self.identity == requestedIdentity,
                  self.selection == requestedSelection else { return }
            guard loaded.resultPath == requestedIdentity.resultPath, loaded.revision == requestedIdentity.revision,
                  loaded.outputBlockName == requestedSelection.outputBlockName,
                  loaded.variable == requestedSelection.variableID,
                  loaded.flowAreaIndex == requestedSelection.flowAreaIndex,
                  loaded.elementIndex == requestedSelection.elementIndex else {
                throw BackendServiceError(code: "sourceChanged", message: L10n.text("The result profile reply no longer matches the selected result or element."))
            }
            series = loaded
            isLoadingSeries = false
            seriesTask = nil
        } catch {
            guard generation == seriesGeneration, self.identity == requestedIdentity,
                  self.selection == requestedSelection else { return }
            isLoadingSeries = false
            seriesTask = nil
            if !(error is CancellationError) && !Task.isCancelled { self.error = L10n.text(error.localizedDescription) }
        }
    }

    func cancel() {
        catalogTask?.cancel()
        mapTask?.cancel()
        seriesTask?.cancel()
        invalidateSampleLine(clearSources: true)
        catalogTask = nil
        mapTask = nil
        seriesTask = nil
        catalogGeneration &+= 1
        mapGeneration &+= 1
        seriesGeneration &+= 1
        isLoadingCatalog = false
        isLoadingMap = false
        isLoadingSeries = false
    }

    func clear() {
        cancel()
        identity = nil
        catalog = nil
        selection = nil
        mapData = nil
        series = nil
        error = nil
        sampleLineError = nil
    }

    private func defaultSelection(in catalog: ResultProfileCatalog) -> ResultProfileSelection? {
        for outputBlock in catalog.outputBlocks where outputBlock.profileCount > 0 {
            for variable in outputBlock.variables {
                if let flowArea = catalog.flowAreas.first(where: { ($0.elementCount(for: variable.elementKind) ?? 0) > 0 }) {
                    return ResultProfileSelection(outputBlockName: outputBlock.name, variableID: variable.id,
                        flowAreaIndex: flowArea.index, elementIndex: 0)
                }
            }
        }
        return nil
    }

    private func valid(_ selection: ResultProfileSelection, in catalog: ResultProfileCatalog) -> Bool {
        guard let block = catalog.outputBlocks.first(where: { $0.name == selection.outputBlockName }),
              block.profileCount > 0, let variable = block.variables.first(where: { $0.id == selection.variableID }),
              let area = catalog.flowAreas.first(where: { $0.index == selection.flowAreaIndex }),
              let count = area.elementCount(for: variable.elementKind),
              count > 0 else { return false }
        return selection.elementIndex >= 0 && selection.elementIndex < count
    }

    private func mapKey(for selection: ResultProfileSelection?) -> String? {
        guard let selection,
              let variable = catalog?.outputBlocks.first(where: { $0.name == selection.outputBlockName })?
                .variables.first(where: { $0.id == selection.variableID }) else { return nil }
        return "\(selection.flowAreaIndex):\(variable.elementKind)"
    }

    private func invalidateMap() {
        mapTask?.cancel()
        mapTask = nil
        mapGeneration &+= 1
        mapData = nil
        isLoadingMap = false
    }

    private func invalidateSampleLine(clearSources: Bool) {
        sampleLineSourcesTask?.cancel()
        sampleLineMapTask?.cancel()
        invalidateSampleLineComputation()
        sampleLineSourcesTask = nil
        sampleLineMapTask = nil
        sampleLineSourcesGeneration &+= 1
        sampleLineMapGeneration &+= 1
        isLoadingSampleLineSources = false
        invalidateSampleLineMap()
        sampleLinePoints = []
        selectedSampleLineResultPaths = []
        if clearSources {
            sampleLineSources = nil
            sampleLineProjectContext = nil
        }
    }

    private func invalidateSampleLineMap() {
        sampleLineMapTask?.cancel()
        sampleLineMapTask = nil
        sampleLineMapGeneration &+= 1
        sampleLineMapData = nil
        isLoadingSampleLineMap = false
    }

    private func invalidateSampleLineComputation() {
        sampleLineTask?.cancel()
        sampleLineTask = nil
        sampleLineGeneration &+= 1
        sampleLineSeries = []
        isComputingSampleLine = false
        isCancellingSampleLine = false
        sampleLineProgressFraction = nil
        sampleLineProgressMessage = nil
        sampleLineProgressTaskName = nil
    }

    private static func canonicalPath(_ value: String) -> String {
        SourceFilePaths.canonical(URL(fileURLWithPath: value))
    }

    private static func samePath(_ first: String, _ second: String) -> Bool {
        canonicalPath(first) == canonicalPath(second)
    }
}
