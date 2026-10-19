import Combine
import Foundation
import RASWorkspaceCore

@MainActor
private final class MapResultChartTaskWaiter<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, any Error>?
    private var isResolved = false

    func value(of task: Task<Value, any Error>) async throws -> Value {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
            self.continuation = continuation
            Task { @MainActor [weak self] in
                self?.resolve(await task.result)
            }
        }
    }

    func cancel() {
        resolve(.failure(CancellationError()))
    }

    private func resolve(_ result: Result<Value, any Error>) {
        guard !isResolved, let continuation else { return }
        isResolved = true
        self.continuation = nil
        continuation.resume(with: result)
    }
}

/// Map-scoped source chooser. Selection overrides are transient native state;
/// the retained ResultSelection settings are not serialized by the source.
@MainActor
final class MapResultSourcesSession: ObservableObject {
    @Published private(set) var sources: MapResultChartSources?
    @Published private(set) var selectionOverrides: [MapResultSelectionOverride] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isSelecting = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isStale = false
    @Published private(set) var logicalSelectionModes: [String: MapResultSelectionMode] = [:]
    @Published private(set) var transientLiveSelections: [String: LiveMapResultSelectionOverride] = [:]
    @Published private(set) var liveComputeEntry: WorkspaceResultComputeEntry?
    @Published private(set) var isComputeLeaseActive = false

    private let provider: any MapResultChartProvider
    private var map: MapResultChartMapRequest?
    private var identity: String?
    private var projectSessionID: UUID?
    private var activeComputeCapture: WorkspaceResultComputeCapture?
    private var computeReadLease: MapResultComputeReadLease?
    private var computeLeaseReadIsCurrent: (@MainActor () -> Bool)?
    private var isRefreshingSourcesForComputeLease = false
    private var needsPostComputeReload = false
    private var logicalSlotCounts: [String: Int] = [:]
    private var logicalStoredChoices: [String: MapResultChartSourceChoice] = [:]
    private var liveSelectionDidChange: (@MainActor (String, Int, MapResultSelectionMode, WorkspaceResultComputeEntry?, LiveMapResultProfileTimeline?, MapResultChartSourceChoice?) -> Void)?
    private var liveSelectionSlotDidRemove: (@MainActor (String, Int) -> Void)?
    private var confirmedLiveResultDidChange: (@MainActor (WorkspaceResultComputeEntry) -> Void)?
    private var canReadSource: (@MainActor () -> Bool) = { true }
    private var isCurrent: (@MainActor () -> Bool)?
    private var selectionOverridesDidChange: (@MainActor ([MapResultSelectionOverride]) -> Void)?
    private var sourcesDidChange: (@MainActor () -> Void)?
    private var loadTask: Task<MapResultChartSources, any Error>?
    private var loadCompletionTask: Task<Void, Never>?
    private var selectionTask: Task<MapResultChartSources, any Error>?
    private var selectionCompletionTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var committedLoadGeneration: Int?
    private var selectionGeneration = 0

    init(provider: any MapResultChartProvider = BackendMapResultChartProvider()) {
        self.provider = provider
    }

    var sourceReadsBlocked: Bool { !isStale && !canReadCurrentRequest() }
    var selectionActionsBlocked: Bool {
        isStale || isLoading || isSelecting || (!canReadCurrentRequest() && !isComputeLeaseActive)
    }

    /// Rebinds a map-scoped session. The identity should include the project
    /// session and the selected map tree source identity, not a display title.
    func configure(map: MapResultChartMapRequest, identity: String,
                   projectSessionID: UUID? = nil,
                   selectionOverrides: [MapResultSelectionOverride],
                   canReadSource: @escaping @MainActor () -> Bool = { true },
                   isCurrent: @escaping @MainActor () -> Bool,
                   selectionOverridesDidChange: @escaping @MainActor ([MapResultSelectionOverride]) -> Void = { _ in },
                   sourcesDidChange: @escaping @MainActor () -> Void = {},
                   liveSelectionDidChange: @escaping @MainActor (String, Int, MapResultSelectionMode, WorkspaceResultComputeEntry?, LiveMapResultProfileTimeline?, MapResultChartSourceChoice?) -> Void = { _, _, _, _, _, _ in },
                   liveSelectionSlotDidRemove: @escaping @MainActor (String, Int) -> Void = { _, _ in },
                   confirmedLiveResultDidChange: @escaping @MainActor (WorkspaceResultComputeEntry) -> Void = { _ in }) {
        cancelRequests()
        self.map = map
        self.identity = identity
        self.projectSessionID = projectSessionID
        self.selectionOverrides = selectionOverrides
        self.canReadSource = canReadSource
        self.isCurrent = isCurrent
        self.selectionOverridesDidChange = selectionOverridesDidChange
        self.sourcesDidChange = sourcesDidChange
        self.liveSelectionDidChange = liveSelectionDidChange
        self.liveSelectionSlotDidRemove = liveSelectionSlotDidRemove
        self.confirmedLiveResultDidChange = confirmedLiveResultDidChange
        activeComputeCapture = nil
        computeReadLease = nil
        computeLeaseReadIsCurrent = nil
        isRefreshingSourcesForComputeLease = false
        liveComputeEntry = nil
        transientLiveSelections = [:]
        logicalSelectionModes = [:]
        logicalStoredChoices = [:]
        logicalSlotCounts = [:]
        isComputeLeaseActive = false
        needsPostComputeReload = false
        sources = nil
        isLoading = false
        isSelecting = false
        errorMessage = nil
        isStale = false
        committedLoadGeneration = nil
    }

    var snapshot: MapResultSourcesSnapshot? {
        guard let map, let identity, let sources, !isStale,
              !isRefreshingSourcesForComputeLease else { return nil }
        return MapResultSourcesSnapshot(map: map, identity: identity,
            sources: sources, selectionOverrides: selectionOverrides)
    }

    @discardableResult
    func loadSources(force: Bool = false) async -> Bool {
        guard let map, let identity, !isStale else { return false }
        guard isCurrent?() == true else { invalidate(); return false }
        guard canRead(map) else { setSourceReadBlocked(); return false }
        if isSelecting, let selectionCompletionTask {
            // A map setup can arrive while the user's Previous/Explicit choice
            // is being committed. Let that exact selection settle before
            // reading sources; cancelling it here would reload the old slot.
            await selectionCompletionTask.value
            guard self.identity == identity, !isStale,
                  isCurrent?() == true else { return false }
        }
        // A second caller for the same configured session joins the in-flight
        // source read. Cancelling one UI waiter ends only that wait; a
        // session-owned completion task still validates and publishes the
        // reply needed by other callers. configure()/invalidate() own the
        // generation and cancel the shared provider request.
        let task: Task<MapResultChartSources, any Error>
        let completionTask: Task<Void, Never>
        let generation: Int
        if let existingTask = loadTask, let existingCompletion = loadCompletionTask {
            task = existingTask
            completionTask = existingCompletion
            generation = loadGeneration
        } else if !(force || needsPostComputeReload), sources != nil {
            return true
        } else {
            loadGeneration &+= 1
            generation = loadGeneration
            let requestedMap = map
            let requestedIdentity = identity
            let requestedOverrides = selectionOverrides
            isLoading = true
            errorMessage = nil

            let provider = self.provider
            let canReadRequestedMap: @MainActor () -> Bool = { [weak self] in
                self?.canRead(requestedMap) == true
            }
            let providerTask = Task {
                guard canReadRequestedMap() else { throw MapResultChartSourceReadBlocked() }
                return try await provider.loadSources(map: requestedMap,
                    selectionOverrides: requestedOverrides)
            }
            task = providerTask
            loadTask = providerTask
            let finishTask = Task { @MainActor [weak self] in
                let outcome = await providerTask.result
                self?.finishLoadSources(outcome, generation: generation, map: requestedMap,
                    identity: requestedIdentity, overrides: requestedOverrides)
            }
            completionTask = finishTask
            loadCompletionTask = finishTask
        }

        do {
            _ = try await waitForLoad(task)
            await completionTask.value
            guard sources != nil, !isStale, self.identity == identity,
                  isCurrent?() == true else { return false }
            if !isRefreshingSourcesForComputeLease {
                await reconcileDeferredLogicalSelections()
                if let selectionCompletionTask { await selectionCompletionTask.value }
            }
            clearLiveComputeWhenConfirmed(in: sources)
            return sources != nil && !isStale && self.identity == identity
                && isCurrent?() == true && errorMessage == nil
        } catch {
            if Task.isCancelled && !task.isCancelled { return false }
            await completionTask.value
            return false
        }
    }

    func beginPlanCompute(_ capture: WorkspaceResultComputeCapture) {
        guard projectSessionID == nil || projectSessionID == capture.projectSessionID else { return }
        if activeComputeCapture != capture {
            liveComputeEntry = nil
        }
        activeComputeCapture = capture
        computeReadLease = nil
        computeLeaseReadIsCurrent = nil
        isRefreshingSourcesForComputeLease = false
        isComputeLeaseActive = true
        needsPostComputeReload = true
    }

    /// Loads the current map sources with the exact writer-path exclusion for
    /// this run. This path deliberately avoids `configure()` and its normal
    /// source-change callback so a refresh cannot clear live selections.
    @discardableResult
    func refreshHistoricalResultsDuringCompute(
        lease: MapResultComputeReadLease,
        capture: WorkspaceResultComputeCapture,
        entry: WorkspaceResultComputeEntry,
        readIsCurrent: @escaping @MainActor () -> Bool
    ) async -> MapResultSourcesSnapshot? {
        guard let currentMap = map,
              isComputeLeaseActive,
              activeComputeCapture == capture,
              LiveMapResultRunIdentity(entry: entry).matches(capture),
              entry.projectSessionID == capture.projectSessionID,
              lease.validates(map: currentMap, capture: capture, entry: entry),
              readIsCurrent(), isCurrent?() == true else { return nil }

        if computeReadLease == lease, !isRefreshingSourcesForComputeLease,
           let currentSnapshot = snapshot,
           currentSnapshot.map.computeReadLease == lease,
           !currentSnapshot.sources.contextToken.isEmpty {
            return currentSnapshot
        }

        cancelRequests()
        var leasedMap = currentMap
        leasedMap.computeReadLease = lease
        map = leasedMap
        computeReadLease = lease
        computeLeaseReadIsCurrent = readIsCurrent
        isRefreshingSourcesForComputeLease = true
        isLoading = false
        isSelecting = false
        errorMessage = nil

        let loaded = await loadSources(force: true)
        isRefreshingSourcesForComputeLease = false
        guard loaded,
              computeReadLease == lease,
              computeLeaseReadIsCurrent?() == true,
              activeComputeCapture == capture,
              isCurrent?() == true,
              let refreshed = snapshot,
              refreshed.map.computeReadLease == lease,
              !refreshed.sources.contextToken.isEmpty,
              SourceFilePaths.canonical(URL(fileURLWithPath: refreshed.sources.projectPath))
                == capture.projectPath,
              refreshed.sources.projectRevision.caseInsensitiveCompare(capture.projectRevision) == .orderedSame,
              refreshed.sources.projectXmlSHA.caseInsensitiveCompare(capture.projectXmlFingerprint) == .orderedSame else {
            if computeReadLease == lease {
                isStale = true
                errorMessage = L10n.text("Result source reads are paused during an active compute or initial-condition update.")
            }
            return nil
        }
        return refreshed
    }

    func acceptPlanComputeEntry(_ entry: WorkspaceResultComputeEntry) {
        guard let capture = activeComputeCapture,
              projectSessionID == nil || projectSessionID == entry.projectSessionID,
              LiveMapResultRunIdentity(entry: entry).matches(capture) else { return }
        liveComputeEntry = entry
        for sourceNode in sources?.activeNodes ?? [] where LiveMapResultSelectionProjection.nodeMatches(
            sourceNode, projectSessionID: entry.projectSessionID, capture: capture, entry: entry) {
            notifySelectedLiveSlots(sourceNode, entry: entry)
        }
    }

    func endPlanCompute(_ capture: WorkspaceResultComputeCapture) {
        guard activeComputeCapture == capture else { return }
        let hadComputeReadLease = computeReadLease != nil
        computeReadLease = nil
        computeLeaseReadIsCurrent = nil
        isRefreshingSourcesForComputeLease = false
        if hadComputeReadLease {
            cancelRequests()
            var unleasedMap = map
            unleasedMap?.computeReadLease = nil
            map = unleasedMap
            isStale = true
        }
        isComputeLeaseActive = false
        needsPostComputeReload = true
        if let entry = liveComputeEntry, entry.status == .running,
           LiveMapResultRunIdentity(entry: entry).matches(capture) {
            let unresolved = WorkspaceResultComputeEntry(runID: entry.runID,
                projectSessionID: entry.projectSessionID, editorID: entry.editorID,
                operationOwnerToken: entry.operationOwnerToken,
                operationContextID: entry.operationContextID, projectPath: entry.projectPath,
                projectRevision: entry.projectRevision,
                projectXmlFingerprint: entry.projectXmlFingerprint, planPath: entry.planPath,
                planRevision: entry.planRevision, resultPath: entry.resultPath,
                resultName: entry.resultName, resultRevision: nil, status: .unknown,
                fraction: entry.fraction,
                message: entry.message ?? L10n.text("The compute ended before a stable Result revision was reported."),
                taskName: entry.taskName, failureReason: nil, profileTimeline: entry.profileTimeline)
            liveComputeEntry = unresolved
        }
        if let entry = liveComputeEntry {
            for sourceNode in sources?.activeNodes ?? [] where LiveMapResultSelectionProjection.nodeMatches(
                sourceNode, projectSessionID: capture.projectSessionID, capture: capture, entry: entry) {
                notifySelectedLiveSlots(sourceNode, entry: entry)
            }
        }
    }

    func selectionMode(nodeID: String, selectionIndex: Int) -> MapResultSelectionMode {
        let key = Self.slotKey(nodeID, selectionIndex)
        if let liveSelection = transientLiveSelections[key], liveSelection.origin == .explicit { return .explicit }
        if let mode = logicalSelectionModes[key] { return mode }
        return sources?.activeNodes.first(where: { $0.id == nodeID })?.selections
            .first(where: { $0.selectionIndex == selectionIndex })?.selectionMode ?? .latest
    }

    func displayNode(_ node: MapResultChartActiveNode) -> MapResultChartActiveNode {
        let count = max(node.selections.count, logicalSlotCounts[node.id] ?? 0)
        let template = node.selections.first
        guard let template, count > 0 else { return node }
        let slots = (0..<count).map { index -> MapResultChartSelectionSlot in
            let existing = node.selections.first(where: { $0.selectionIndex == index })
            let key = Self.slotKey(node.id, index)
            let isTransientExplicitRun = transientLiveSelections[key]?.origin == .explicit
            return MapResultChartSelectionSlot(selectionIndex: index,
                selectionMode: selectionMode(nodeID: node.id, selectionIndex: index),
                selectedResult: isTransientExplicitRun ? nil : selectedStoredChoice(nodeID: node.id,
                    selectionIndex: index, node: node) ?? existing?.selectedResult,
                choices: existing?.choices ?? template.choices)
        }
        return MapResultChartActiveNode(node: node.node, nodeKind: node.nodeKind,
            name: node.name, selections: slots, selectedMapType: node.selectedMapType,
            profileIndex: node.profileIndex)
    }

    func selectedLiveEntry(nodeID: String, selectionIndex: Int) -> WorkspaceResultComputeEntry? {
        guard let node = sources?.activeNodes.first(where: { $0.id == nodeID }) else { return nil }
        return selectedLiveEntry(nodeID: nodeID, selectionIndex: selectionIndex, node: node)
    }

    func liveComputeCandidate(nodeID: String) -> WorkspaceResultComputeEntry? {
        guard let node = sources?.activeNodes.first(where: { $0.id == nodeID }),
              let capture = activeComputeCapture, let entry = liveComputeEntry,
              let projectSessionID,
              LiveMapResultSelectionProjection.nodeMatches(node,
                projectSessionID: projectSessionID, capture: capture, entry: entry) else { return nil }
        return entry
    }

    func isWaitingForStableRevision(nodeID: String, selectionIndex: Int) -> Bool {
        selectedLiveEntry(nodeID: nodeID, selectionIndex: selectionIndex) != nil
    }

    private func selectedLiveEntry(nodeID: String, selectionIndex: Int,
                                   node: MapResultChartActiveNode) -> WorkspaceResultComputeEntry? {
        let key = Self.slotKey(nodeID, selectionIndex)
        if let explicit = transientLiveSelections[key],
           explicit.entry.runID == liveComputeEntry?.runID,
           let capture = activeComputeCapture,
           LiveMapResultSelectionProjection.nodeMatches(node,
               projectSessionID: explicit.entry.projectSessionID,
               capture: capture, entry: explicit.entry) {
            return explicit.entry
        }
        guard selectionMode(nodeID: nodeID, selectionIndex: selectionIndex) == .latest,
              let capture = activeComputeCapture, let entry = liveComputeEntry,
              let projectSessionID,
              LiveMapResultSelectionProjection.nodeMatches(node,
                  projectSessionID: projectSessionID, capture: capture, entry: entry) else { return nil }
        return entry
    }

    private func notifySelectedLiveSlots(_ node: MapResultChartActiveNode,
                                         entry: WorkspaceResultComputeEntry) {
        for slot in displayNode(node).selections {
            guard selectedLiveEntry(nodeID: node.id,
                selectionIndex: slot.selectionIndex, node: node) != nil else { continue }
            liveSelectionDidChange?(node.id, slot.selectionIndex,
                selectionMode(nodeID: node.id, selectionIndex: slot.selectionIndex), entry,
                entry.profileTimeline, nil)
        }
    }

    private static func slotKey(_ nodeID: String, _ selectionIndex: Int) -> String {
        "\(nodeID)|\(selectionIndex)"
    }

    func selectedStoredChoice(nodeID: String, selectionIndex: Int) -> MapResultChartSourceChoice? {
        guard let node = sources?.activeNodes.first(where: { $0.id == nodeID }) else { return nil }
        return selectedStoredChoice(nodeID: nodeID, selectionIndex: selectionIndex, node: node)
    }

    private func selectedStoredChoice(nodeID: String, selectionIndex: Int,
                                      node: MapResultChartActiveNode) -> MapResultChartSourceChoice? {
        let key = Self.slotKey(nodeID, selectionIndex)
        if let live = transientLiveSelections[key], live.origin == .explicit { return nil }
        if let stored = logicalStoredChoices[key] {
            return (node.selections.first(where: { $0.selectionIndex == selectionIndex })?.choices
                ?? node.selections.first?.choices)?.first(where: {
                    MapResultChartContractValidation.sameChoice($0, stored)
                })
        }
        guard let slot = node.selections.first(where: { $0.selectionIndex == selectionIndex })
                ?? node.selections.first else { return nil }
        switch selectionMode(nodeID: nodeID, selectionIndex: selectionIndex) {
        case .latest:
            return selectedLiveEntry(nodeID: nodeID, selectionIndex: selectionIndex, node: node) == nil
                ? slot.selectedResult : nil
        case .previous:
            guard let live = liveComputeCandidate(nodeID: nodeID),
                  !slot.choices.contains(where: {
                      MapResultChartContractValidation.canonicalPath($0.resultPath)
                        == LiveMapResultRunIdentity(entry: live).resultPath
                  }) else { return slot.choices.dropFirst().first }
            return slot.choices.first
        case .explicit:
            return slot.selectedResult
        }
    }

    private func setLogicalSelection(node: MapResultChartActiveNode, selectionIndex: Int,
                                     mode: MapResultSelectionMode,
                                     storedChoice: MapResultChartSourceChoice?,
                                     liveEntry: WorkspaceResultComputeEntry?) {
        let key = Self.slotKey(node.id, selectionIndex)
        logicalSelectionModes[key] = mode
        logicalSlotCounts[node.id] = max(logicalSlotCounts[node.id] ?? node.selections.count,
            selectionIndex + 1)
        if let liveEntry, mode == .explicit {
            transientLiveSelections[key] = LiveMapResultSelectionOverride(
                nodeIdentity: node.id, selectionIndex: selectionIndex,
                entry: liveEntry, origin: .explicit)
            logicalStoredChoices.removeValue(forKey: key)
        } else {
            transientLiveSelections.removeValue(forKey: key)
            if let storedChoice, mode == .explicit {
                logicalStoredChoices[key] = storedChoice
            } else {
                logicalStoredChoices.removeValue(forKey: key)
            }
        }
        errorMessage = nil
        notifyLogicalSelectionChange(node, affectedSelectionIndex: selectionIndex)
    }

    private func addLogicalSelection(node: MapResultChartActiveNode) {
        let currentSlots = displayNode(node).selections
        guard currentSlots.count < 32,
              let choices = node.selections.first?.choices else { return }
        let activeEntry: WorkspaceResultComputeEntry? = {
            guard let capture = activeComputeCapture, let entry = liveComputeEntry,
                  let projectSessionID,
                  LiveMapResultSelectionProjection.nodeMatches(node,
                      projectSessionID: projectSessionID, capture: capture, entry: entry) else { return nil }
            return entry
        }()
        var selectedPaths = Set<String>()
        for slot in currentSlots {
            if let live = selectedLiveEntry(nodeID: node.id, selectionIndex: slot.selectionIndex,
                node: node) {
                selectedPaths.insert(LiveMapResultRunIdentity(entry: live).resultPath)
            } else if let stored = selectedStoredChoice(nodeID: node.id,
                selectionIndex: slot.selectionIndex, node: node) {
                selectedPaths.insert(MapResultChartContractValidation.canonicalPath(stored.resultPath))
            }
        }
        let newIndex = currentSlots.count
        if let activeEntry {
            let activePath = LiveMapResultRunIdentity(entry: activeEntry).resultPath
            if !selectedPaths.contains(activePath) {
                setLogicalSelection(node: node, selectionIndex: newIndex, mode: .latest,
                    storedChoice: nil, liveEntry: nil)
                return
            }
            guard let choice = choices.first(where: {
                !selectedPaths.contains(MapResultChartContractValidation.canonicalPath($0.resultPath))
            }) else {
                errorMessage = L10n.text("No unselected stored Result is available for this selection.")
                return
            }
            let previousCandidate: MapResultChartSourceChoice? = {
                guard let sourceLatest = choices.first,
                      MapResultChartContractValidation.canonicalPath(sourceLatest.resultPath) == activePath
                else { return choices.first }
                return choices.dropFirst().first
            }()
            let mode: MapResultSelectionMode = previousCandidate.map {
                MapResultChartContractValidation.sameChoice($0, choice)
            } == true ? .previous : .explicit
            setLogicalSelection(node: node, selectionIndex: newIndex, mode: mode,
                storedChoice: mode == .explicit ? choice : nil, liveEntry: nil)
            return
        }
        guard let choice = choices.first(where: {
            !selectedPaths.contains(MapResultChartContractValidation.canonicalPath($0.resultPath))
        }) else {
            errorMessage = L10n.text("No unselected stored Result is available for this selection.")
            return
        }
        let mode: MapResultSelectionMode
        if choices.first.map({ MapResultChartContractValidation.sameChoice($0, choice) }) == true {
            mode = .latest
        } else if choices.dropFirst().first.map({ MapResultChartContractValidation.sameChoice($0, choice) }) == true {
            mode = .previous
        } else {
            mode = .explicit
        }
        setLogicalSelection(node: node, selectionIndex: newIndex, mode: mode,
            storedChoice: mode == .explicit ? choice : nil, liveEntry: nil)
    }

    private func removeLogicalSelection(node: MapResultChartActiveNode, selectionIndex: Int) {
        let count = max(logicalSlotCounts[node.id] ?? node.selections.count, node.selections.count)
        guard count > 1, (0..<count).contains(selectionIndex) else { return }
        var nextModes: [String: MapResultSelectionMode] = [:]
        var nextChoices: [String: MapResultChartSourceChoice] = [:]
        var nextLive: [String: LiveMapResultSelectionOverride] = [:]
        for oldIndex in 0..<count where oldIndex != selectionIndex {
            let newIndex = oldIndex > selectionIndex ? oldIndex - 1 : oldIndex
            let oldKey = Self.slotKey(node.id, oldIndex)
            let newKey = Self.slotKey(node.id, newIndex)
            if let mode = logicalSelectionModes[oldKey] { nextModes[newKey] = mode }
            if let choice = logicalStoredChoices[oldKey] { nextChoices[newKey] = choice }
            if let live = transientLiveSelections[oldKey] {
                nextLive[newKey] = LiveMapResultSelectionOverride(
                    nodeIdentity: node.id, selectionIndex: newIndex,
                    entry: live.entry, origin: live.origin)
            }
        }
        for key in Array(logicalSelectionModes.keys) where key.hasPrefix(node.id + "|") {
            logicalSelectionModes.removeValue(forKey: key)
        }
        for key in Array(logicalStoredChoices.keys) where key.hasPrefix(node.id + "|") {
            logicalStoredChoices.removeValue(forKey: key)
        }
        for key in Array(transientLiveSelections.keys) where key.hasPrefix(node.id + "|") {
            transientLiveSelections.removeValue(forKey: key)
        }
        logicalSelectionModes.merge(nextModes) { _, new in new }
        logicalStoredChoices.merge(nextChoices) { _, new in new }
        transientLiveSelections.merge(nextLive) { _, new in new }
        logicalSlotCounts[node.id] = count - 1
        liveSelectionSlotDidRemove?(node.id, selectionIndex)
        if selectionIndex == 0 {
            notifyLogicalSelectionChange(node, affectedSelectionIndex: 0)
        }
        let remainingCount = count - 1
        if remainingCount > 1 {
            for index in 1..<remainingCount where selectedLiveEntry(
                nodeID: node.id, selectionIndex: index, node: node) != nil {
                notifyLogicalSelectionChange(node, affectedSelectionIndex: index)
            }
        }
    }

    private func notifyLogicalSelectionChange(_ node: MapResultChartActiveNode,
                                              affectedSelectionIndex: Int) {
        guard let capture = activeComputeCapture, let entry = liveComputeEntry,
              let projectSessionID,
              LiveMapResultSelectionProjection.nodeMatches(node,
                  projectSessionID: projectSessionID, capture: capture, entry: entry) else { return }
        let isLive = selectedLiveEntry(nodeID: node.id,
            selectionIndex: affectedSelectionIndex, node: node) != nil
        let storedChoice = isLive ? nil : selectedStoredChoice(nodeID: node.id,
            selectionIndex: affectedSelectionIndex, node: node)
        liveSelectionDidChange?(node.id, affectedSelectionIndex,
            selectionMode(nodeID: node.id, selectionIndex: affectedSelectionIndex), isLive ? entry : nil,
            isLive ? entry.profileTimeline : nil, storedChoice)
    }

    func setSelection(nodeID: String, selectionIndex: Int,
                      mode: MapResultSelectionMode,
                      choice: MapResultChartSourceChoice? = nil,
                      liveRunID: String? = nil) async {
        guard let map, let identity, let sources, !isStale,
              !isSelecting, let node = sources.activeNodes.first(where: { $0.id == nodeID }),
              let slot = displayNode(node).selections.first(where: { $0.selectionIndex == selectionIndex }) else { return }
        guard isCurrent?() == true else { invalidate(); return }
        guard node.nodeKind == "MultiResult" || (selectionIndex == 0 && mode == .explicit) else {
            errorMessage = L10n.text("A single Result source has a fixed result selection.")
            return
        }
        if let liveRunID {
            guard let entry = liveComputeEntry, entry.runID == liveRunID,
                  let capture = activeComputeCapture,
                  projectSessionID == entry.projectSessionID,
                  LiveMapResultSelectionProjection.nodeMatches(node,
                      projectSessionID: entry.projectSessionID, capture: capture, entry: entry) else {
                errorMessage = L10n.text("The running Result is no longer the active selection candidate.")
                return
            }
            setLogicalSelection(node: node, selectionIndex: selectionIndex,
                mode: .explicit, storedChoice: nil, liveEntry: entry)
            return
        }
        if !canReadSource() {
            guard isComputeLeaseActive else { setSourceReadBlocked(); return }
            if mode == .explicit {
                guard let choice, slot.choices.contains(where: { MapResultChartContractValidation.sameChoice($0, choice) }) else {
                    errorMessage = L10n.text("Choose an available result from this map source.")
                    return
                }
                setLogicalSelection(node: node, selectionIndex: selectionIndex,
                    mode: mode, storedChoice: choice, liveEntry: nil)
                return
            }
            guard choice == nil, liveRunID == nil else {
                errorMessage = L10n.text("Latest and previous selection use the source's ordered results.")
                return
            }
            setLogicalSelection(node: node, selectionIndex: selectionIndex,
                mode: mode, storedChoice: nil, liveEntry: nil)
            return
        }
        guard liveRunID == nil else { return }
        let selectedChoice: MapResultChartSourceChoice?
        if mode == .explicit {
            guard let choice, slot.choices.contains(where: { MapResultChartContractValidation.sameChoice($0, choice) }) else {
                errorMessage = L10n.text("Choose an available result from this map source.")
                return
            }
            selectedChoice = choice
        } else {
            guard choice == nil else {
                errorMessage = L10n.text("Latest and previous selection use the source's ordered results.")
                return
            }
            selectedChoice = nil
        }

        guard var next = try? fullOverrides(from: sources, current: selectionOverrides) else {
            errorMessage = L10n.text("The map has a result selection that cannot be represented.")
            return
        }
        let updated = MapResultSelectionOverride(node: node.node,
            selectionIndex: selectionIndex, mode: mode,
            resultPath: selectedChoice?.resultPath, resultRevision: selectedChoice?.revision)
        guard let target = next.firstIndex(where: { $0.id == updated.id }) else {
            errorMessage = L10n.text("The selected result slot is no longer available.")
            return
        }
        next[target] = updated
        await apply(next, map: map, identity: identity, sourceSnapshot: sources)
    }

    func addSelection(nodeID: String) async {
        guard let map, let identity, let sources, !isStale,
              !isSelecting, let node = sources.activeNodes.first(where: { $0.id == nodeID }),
              node.nodeKind == "MultiResult", displayNode(node).selections.count < 32 else { return }
        guard isCurrent?() == true else { invalidate(); return }
        if !canReadSource() {
            guard isComputeLeaseActive else { setSourceReadBlocked(); return }
            addLogicalSelection(node: node)
            return
        }
        guard var next = try? fullOverrides(from: sources, current: selectionOverrides) else {
            errorMessage = L10n.text("The map has a result selection that cannot be represented.")
            return
        }
        guard let availableChoices = node.selections.first?.choices, !availableChoices.isEmpty else {
            errorMessage = L10n.text("No stored Results are available for this selection.")
            return
        }
        let selectedChoiceIDs = Set(node.selections.compactMap { $0.selectedResult?.id })
        // Ras's AddResult_Click first chooses the first unselected ResultOption
        // in source order, then falls back to GetDefaultResultOption (computing
        // Result when available, otherwise latest).
        let choice = availableChoices.first(where: { !selectedChoiceIDs.contains($0.id) })
            ?? availableChoices.first(where: \.isComputing)
            ?? availableChoices.first
        guard let choice else { return }
        let mode: MapResultSelectionMode
        if availableChoices.first.map({ MapResultChartContractValidation.sameChoice($0, choice) }) == true {
            mode = .latest
        } else if availableChoices.dropFirst().first.map({ MapResultChartContractValidation.sameChoice($0, choice) }) == true {
            mode = .previous
        } else {
            mode = .explicit
        }
        let newIndex = node.selections.count
        next.append(MapResultSelectionOverride(node: node.node,
            selectionIndex: newIndex, mode: mode,
            resultPath: mode == .explicit ? choice.resultPath : nil,
            resultRevision: mode == .explicit ? choice.revision : nil))
        await apply(next, map: map, identity: identity, sourceSnapshot: sources)
    }

    func removeSelection(nodeID: String, selectionIndex: Int) async {
        guard let map, let identity, let sources, !isStale,
              !isSelecting, let node = sources.activeNodes.first(where: { $0.id == nodeID }),
              node.nodeKind == "MultiResult", displayNode(node).selections.count > 1,
              displayNode(node).selections.contains(where: { $0.selectionIndex == selectionIndex }) else { return }
        guard isCurrent?() == true else { invalidate(); return }
        if !canReadSource() {
            guard isComputeLeaseActive else { setSourceReadBlocked(); return }
            removeLogicalSelection(node: node, selectionIndex: selectionIndex)
            return
        }
        guard var next = try? fullOverrides(from: sources, current: selectionOverrides) else {
            errorMessage = L10n.text("The map has a result selection that cannot be represented.")
            return
        }
        let nodeOverrides = next.filter { $0.nodeIdentity == nodeID && $0.selectionIndex != selectionIndex }
            .sorted { $0.selectionIndex < $1.selectionIndex }
            .enumerated().map { offset, item in
                MapResultSelectionOverride(node: item.node, selectionIndex: offset, mode: item.mode,
                    resultPath: item.resultPath, resultRevision: item.resultRevision)
            }
        next.removeAll { $0.nodeIdentity == nodeID }
        next.append(contentsOf: nodeOverrides)
        await apply(next, map: map, identity: identity, sourceSnapshot: sources)
    }

    func invalidate() {
        guard !isStale else { return }
        isStale = true
        cancelRequests()
        computeReadLease = nil
        computeLeaseReadIsCurrent = nil
        isRefreshingSourcesForComputeLease = false
        isComputeLeaseActive = false
        activeComputeCapture = nil
        sources = nil
        isLoading = false
        isSelecting = false
        errorMessage = L10n.text("The selected map or result-source visibility changed. Refresh the map source panel.")
    }

    /// Cancels pending map-source reads/selection requests when a source HDF
    /// enters a writer lease. Cached rows remain visible; callers can reload
    /// after the lease ends.
    func suspendSourceReads() {
        guard !isStale else { return }
        cancelRequests()
        isLoading = false
        isSelecting = false
        setSourceReadBlocked()
    }

    func close() {
        cancelRequests()
        computeReadLease = nil
        computeLeaseReadIsCurrent = nil
        isRefreshingSourcesForComputeLease = false
        isComputeLeaseActive = false
        activeComputeCapture = nil
        sources = nil
        isLoading = false
        isSelecting = false
    }

    private func apply(_ requestedOverrides: [MapResultSelectionOverride],
                       map: MapResultChartMapRequest, identity: String,
                       sourceSnapshot: MapResultChartSources) async {
        guard canReadSource() else { setSourceReadBlocked(); return }
        selectionTask?.cancel()
        loadTask?.cancel()
        loadGeneration &+= 1
        committedLoadGeneration = nil
        loadTask = nil
        loadCompletionTask?.cancel()
        loadCompletionTask = nil
        isLoading = false
        selectionGeneration &+= 1
        let generation = selectionGeneration
        let previousOverrides = selectionOverrides
        let expectedToken = sourceSnapshot.contextToken
        isSelecting = true
        errorMessage = nil

        let provider = self.provider
        let canReadSource = self.canReadSource
        let providerTask = Task {
            guard canReadSource() else { throw MapResultChartSourceReadBlocked() }
            return try await provider.selectSources(map: map, expectedContextToken: expectedToken,
                currentSelectionOverrides: previousOverrides,
                selectionOverrides: requestedOverrides)
        }
        selectionTask = providerTask
        let completionTask = Task { @MainActor [weak self] in
            let outcome = await providerTask.result
            self?.finishSelection(outcome, generation: generation, map: map,
                identity: identity, overrides: requestedOverrides)
        }
        selectionCompletionTask = completionTask
        await completionTask.value
    }

    private func fullOverrides(from sources: MapResultChartSources,
                               current: [MapResultSelectionOverride]) throws -> [MapResultSelectionOverride] {
        var result: [MapResultSelectionOverride] = []
        for node in sources.activeNodes {
            for slot in node.selections.sorted(by: { $0.selectionIndex < $1.selectionIndex }) {
                if let existing = current.first(where: {
                    $0.nodeIdentity == node.id && $0.selectionIndex == slot.selectionIndex
                }) {
                    result.append(existing)
                    continue
                }
                let mode = slot.selectionMode
                guard mode != .explicit || slot.selectedResult != nil else {
                    throw MapResultChartContractValidation.protocolError("The selected Result is no longer available.")
                }
                result.append(MapResultSelectionOverride(node: node.node,
                    selectionIndex: slot.selectionIndex, mode: mode,
                    resultPath: mode == .explicit ? slot.selectedResult?.resultPath : nil,
                    resultRevision: mode == .explicit ? slot.selectedResult?.revision : nil))
            }
        }
        return result
    }

    private func reconcileDeferredLogicalSelections() async {
        guard canReadSource(), !isSelecting,
              !logicalSelectionModes.isEmpty || !logicalSlotCounts.isEmpty || !transientLiveSelections.isEmpty,
              let map, let identity, let loaded = sources else { return }
        guard let desired = deferredOverrides(in: loaded) else { return }
        let baseline = (try? fullOverrides(from: loaded, current: selectionOverrides)) ?? []
        guard desired != baseline else {
            clearLogicalSelectionsAfterAcceptance(loaded)
            return
        }
        await apply(desired, map: map, identity: identity, sourceSnapshot: loaded)
    }

    private func deferredOverrides(in loaded: MapResultChartSources) -> [MapResultSelectionOverride]? {
        guard !logicalSelectionModes.isEmpty || !logicalSlotCounts.isEmpty
                || !transientLiveSelections.isEmpty else { return nil }
        let baseline = (try? fullOverrides(from: loaded, current: selectionOverrides)) ?? []
        var byID = Dictionary(uniqueKeysWithValues: baseline.map { ($0.id, $0) })
        for node in loaded.activeNodes where node.nodeKind == "MultiResult" {
            let originalCount = node.selections.count
            let requestedCount = logicalSlotCounts[node.id] ?? originalCount
            let count = min(max(requestedCount, 1), 32)
            let template = node.selections.first
            guard let template else { return nil }
            for index in 0..<count {
                let key = Self.slotKey(node.id, index)
                let mode = logicalSelectionModes[key]
                    ?? byID["\(node.id)|\(index)"]?.mode
                    ?? node.selections.first(where: { $0.selectionIndex == index })?.selectionMode
                    ?? .latest
                let live = transientLiveSelections[key]
                if let live {
                    guard live.origin == .explicit,
                          live.entry.status.isTerminal,
                          let choice = LiveMapResultSelectionProjection.stableChoice(for: live.entry, in: node) else {
                        return nil
                    }
                    byID["\(node.id)|\(index)"] = MapResultSelectionOverride(
                        node: node.node, selectionIndex: index, mode: .explicit,
                        resultPath: choice.resultPath, resultRevision: choice.revision)
                    continue
                }

                switch mode {
                case .latest, .previous:
                    byID["\(node.id)|\(index)"] = MapResultSelectionOverride(
                        node: node.node, selectionIndex: index, mode: mode)
                case .explicit:
                    let requested = logicalStoredChoices[key]
                        ?? node.selections.first(where: { $0.selectionIndex == index })?.selectedResult
                    guard let requested,
                          let exact = template.choices.first(where: {
                              MapResultChartContractValidation.sameChoice($0, requested)
                          }) else { return nil }
                    byID["\(node.id)|\(index)"] = MapResultSelectionOverride(
                        node: node.node, selectionIndex: index, mode: .explicit,
                        resultPath: exact.resultPath, resultRevision: exact.revision)
                }
            }
            for staleIndex in count..<max(originalCount, logicalSlotCounts[node.id] ?? originalCount) {
                byID.removeValue(forKey: "\(node.id)|\(staleIndex)")
            }
        }
        let ordered = loaded.activeNodes.flatMap { node -> [MapResultSelectionOverride] in
            let count = logicalSlotCounts[node.id] ?? node.selections.count
            return (0..<min(max(count, 1), 32)).compactMap {
                byID["\(node.id)|\($0)"]
            }
        }
        guard Set(ordered.map(\.id)).count == ordered.count,
              (try? MapResultChartContractValidation.validateOverrideShape(ordered)) != nil else { return nil }
        return ordered
    }

    private func clearLogicalSelectionsAfterAcceptance(_ loaded: MapResultChartSources) {
        let accepted = loaded.activeNodes
        for node in accepted {
            let keys = Array(logicalSelectionModes.keys).filter { $0.hasPrefix(node.id + "|") }
                + Array(logicalStoredChoices.keys).filter { $0.hasPrefix(node.id + "|") }
                + Array(transientLiveSelections.keys).filter { $0.hasPrefix(node.id + "|") }
            guard !keys.isEmpty else { continue }
            let acceptedCount = node.selections.count
            let requestedCount = logicalSlotCounts[node.id] ?? acceptedCount
            guard requestedCount == acceptedCount else { continue }
            for key in Array(logicalSelectionModes.keys) where key.hasPrefix(node.id + "|") {
                logicalSelectionModes.removeValue(forKey: key)
            }
            for key in Array(logicalStoredChoices.keys) where key.hasPrefix(node.id + "|") {
                logicalStoredChoices.removeValue(forKey: key)
            }
            for key in Array(transientLiveSelections.keys) where key.hasPrefix(node.id + "|") {
                transientLiveSelections.removeValue(forKey: key)
            }
            logicalSlotCounts.removeValue(forKey: node.id)
        }
    }

    private func clearLiveComputeWhenConfirmed(in loaded: MapResultChartSources?) {
        guard let capture = activeComputeCapture, let entry = liveComputeEntry,
              let loaded else { return }
        let confirmedNode = loaded.activeNodes.first { node in
            LiveMapResultSelectionProjection.nodeMatches(node,
                projectSessionID: capture.projectSessionID, capture: capture, entry: entry)
                && LiveMapResultSelectionProjection.stableChoice(for: entry, in: node) != nil
        }
        guard let node = confirmedNode else { return }
        let hasUnreconciledExplicitLiveSlot = transientLiveSelections.values.contains {
            $0.nodeIdentity == node.id && $0.entry.runID == entry.runID && $0.origin == .explicit
        }
        guard !hasUnreconciledExplicitLiveSlot else { return }
        confirmedLiveResultDidChange?(entry)
        let keys = Array(transientLiveSelections.keys).filter {
            $0.hasPrefix(node.id + "|") && transientLiveSelections[$0]?.entry.runID == entry.runID
        }
        for key in keys { transientLiveSelections.removeValue(forKey: key) }
        liveComputeEntry = nil
        activeComputeCapture = nil
        needsPostComputeReload = false
        // The cached renderer may still be the earlier frame even when the
        // stable source token did not change. Rebind once to the confirmed
        // source identity so the cleared node can install real payload.
        if !isRefreshingSourcesForComputeLease { sourcesDidChange?() }
    }

    private func waitForLoad(_ task: Task<MapResultChartSources, any Error>) async throws -> MapResultChartSources {
        let waiter = MapResultChartTaskWaiter<MapResultChartSources>()
        return try await withTaskCancellationHandler {
            try await waiter.value(of: task)
        } onCancel: {
            Task { @MainActor in waiter.cancel() }
        }
    }

    private func finishLoadSources(_ outcome: Result<MapResultChartSources, any Error>,
                                   generation: Int,
                                   map requestedMap: MapResultChartMapRequest,
                                   identity requestedIdentity: String,
                                   overrides requestedOverrides: [MapResultSelectionOverride]) {
        guard generation == loadGeneration, self.identity == requestedIdentity, !isStale else { return }
        guard isCurrent?() == true else { invalidate(); return }
        guard canRead(requestedMap) else {
            setSourceReadBlocked()
            isLoading = false
            loadTask = nil
            loadCompletionTask = nil
            return
        }
        switch outcome {
        case .success(let loaded):
            do {
                try MapResultChartContractValidation.validate(loaded, map: requestedMap,
                    overrides: requestedOverrides)
                let acceptedOverrides: [MapResultSelectionOverride]
                if requestedOverrides.isEmpty {
                    acceptedOverrides = []
                } else {
                    acceptedOverrides = try MapResultChartContractValidation.canonicalOverrides(from: loaded)
                }
                if committedLoadGeneration != generation {
                    let previousContextToken = sources?.contextToken
                    sources = loaded
                    committedLoadGeneration = generation
                    if !isRefreshingSourcesForComputeLease,
                       acceptedOverrides != selectionOverrides {
                        selectionOverrides = acceptedOverrides
                        selectionOverridesDidChange?(acceptedOverrides)
                    }
                    if previousContextToken != loaded.contextToken,
                       !isRefreshingSourcesForComputeLease {
                        sourcesDidChange?()
                    }
                }
                needsPostComputeReload = false
                errorMessage = nil
            } catch {
                errorMessage = L10n.text(error.localizedDescription)
            }
        case .failure(let error):
            if !(error is CancellationError) {
                errorMessage = L10n.text(error.localizedDescription)
            }
        }
        isLoading = false
        loadTask = nil
        loadCompletionTask = nil
    }

    private func finishSelection(_ outcome: Result<MapResultChartSources, any Error>,
                                 generation: Int,
                                 map requestedMap: MapResultChartMapRequest,
                                 identity requestedIdentity: String,
                                 overrides requestedOverrides: [MapResultSelectionOverride]) {
        guard generation == selectionGeneration, self.identity == requestedIdentity, !isStale else { return }
        guard isCurrent?() == true else { invalidate(); return }
        guard canReadSource() else {
            setSourceReadBlocked()
            isSelecting = false
            selectionTask = nil
            selectionCompletionTask = nil
            return
        }
        switch outcome {
        case .success(let loaded):
            do {
                try MapResultChartContractValidation.validate(loaded, map: requestedMap,
                    overrides: requestedOverrides)
                let acceptedOverrides = try MapResultChartContractValidation.canonicalOverrides(from: loaded)
                let previousContextToken = sources?.contextToken
                sources = loaded
                selectionOverrides = acceptedOverrides
                committedLoadGeneration = loadGeneration
                errorMessage = nil
                selectionOverridesDidChange?(acceptedOverrides)
                needsPostComputeReload = false
                if previousContextToken != loaded.contextToken {
                    sourcesDidChange?()
                }
            } catch {
                errorMessage = L10n.text(error.localizedDescription)
            }
        case .failure(let error):
            if !(error is CancellationError) {
                errorMessage = L10n.text(error.localizedDescription)
            }
        }
        isSelecting = false
        selectionTask = nil
        selectionCompletionTask = nil
    }

    private func cancelRequests() {
        loadGeneration &+= 1
        committedLoadGeneration = nil
        selectionGeneration &+= 1
        loadTask?.cancel()
        loadCompletionTask?.cancel()
        selectionTask?.cancel()
        selectionCompletionTask?.cancel()
        loadTask = nil
        loadCompletionTask = nil
        selectionTask = nil
        selectionCompletionTask = nil
    }

    private func setSourceReadBlocked() {
        errorMessage = L10n.text("Result source reads are paused during an active compute or initial-condition update.")
    }

    private func canReadCurrentRequest() -> Bool {
        guard let map else { return canReadSource() }
        return canRead(map)
    }

    private func canRead(_ requestedMap: MapResultChartMapRequest) -> Bool {
        guard let lease = requestedMap.computeReadLease else { return canReadSource() }
        return isComputeLeaseActive
            && computeReadLease == lease
            && computeLeaseReadIsCurrent?() == true
    }

}

private struct MapResultChartSourceReadBlocked: LocalizedError {
    var errorDescription: String? {
        "Result source reads are paused during an active compute or initial-condition update."
    }
}

/// One independently cancellable chart window. The source snapshot is frozen
/// when the window opens; changes in its map or source session invalidate it.
@MainActor
final class MapResultChartSession: ObservableObject {
    @Published private(set) var result: MapResultChartSeries?
    @Published private(set) var isComputing = false
    @Published private(set) var isCancelling = false
    @Published private(set) var progressFraction: Double?
    @Published private(set) var progressMessage: String?
    @Published private(set) var progressTaskName: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isStale = false
    @Published private(set) var isClosed = false

    let context: MapResultChartContext
    let sourceSnapshot: MapResultSourcesSnapshot
    let mode: MapResultChartMode

    private let provider: any MapResultChartProvider
    private let isCurrent: @MainActor () -> Bool
    private var computeTask: Task<MapResultChartSeries, any Error>?
    private var computeGeneration = 0
    private var hasAutoStarted = false

    init(context: MapResultChartContext, sourceSnapshot: MapResultSourcesSnapshot,
         mode: MapResultChartMode,
         provider: any MapResultChartProvider = BackendMapResultChartProvider(),
         isCurrent: @escaping @MainActor () -> Bool) {
        self.context = context
        self.sourceSnapshot = sourceSnapshot
        self.mode = mode
        self.provider = provider
        self.isCurrent = isCurrent
        if sourceSnapshot.map != context.mapRequest {
            isStale = true
            errorMessage = L10n.text("The selected map source does not match the captured sample line.")
        }
    }

    var canCompute: Bool {
        guard !isClosed, !isStale, !isComputing,
              sourceSnapshot.map == context.mapRequest,
              !sourceSnapshot.sources.activeNodes.isEmpty else { return false }
        return sourceSnapshot.sources.activeNodes.allSatisfy { node in
            !node.selections.isEmpty && node.selections.allSatisfy { $0.selectedResult != nil }
        }
    }

    func startOnOpen() async {
        guard !hasAutoStarted else { return }
        hasAutoStarted = true
        guard result == nil, !isComputing else { return }
        await compute()
    }

    func compute() async {
        guard canCompute else {
            if !isClosed, !isStale, errorMessage == nil {
                errorMessage = L10n.text("Choose a result for every active map source before plotting the selected line.")
            }
            return
        }
        guard isCurrent() else { invalidate(); return }
        computeTask?.cancel()
        computeGeneration &+= 1
        let generation = computeGeneration
        let requestedContext = context
        let requestedSnapshot = sourceSnapshot
        let request = MapResultChartSampleLineRequest(context: requestedContext,
            contextToken: requestedSnapshot.sources.contextToken,
            selectionOverrides: requestedSnapshot.selectionOverrides, mode: mode)
        result = nil
        errorMessage = nil
        isComputing = true
        isCancelling = false
        progressFraction = nil
        progressMessage = nil
        progressTaskName = nil

        let provider = self.provider
        let progressHandler: @Sendable (BackendProgressUpdate) -> Void = { [weak self] update in
            Task { @MainActor [weak self] in
                guard let self, generation == self.computeGeneration,
                      self.isComputing, !self.isCancelling, !self.isClosed, !self.isStale else { return }
                guard self.isCurrent() else { self.invalidate(); return }
                self.progressFraction = update.fraction
                self.progressMessage = update.message
                self.progressTaskName = update.taskName
            }
        }
        let task = Task { [provider, request, progressHandler] in
            try await provider.compute(request, progress: progressHandler)
        }
        computeTask = task
        do {
            let loaded = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard generation == computeGeneration, !isClosed, !isStale else { return }
            guard !isCancelling else { finishCompute(); return }
            guard isCurrent() else { invalidate(); return }
            try MapResultChartContractValidation.validate(loaded, context: requestedContext,
                snapshot: requestedSnapshot, mode: mode)
            result = loaded
            finishCompute()
        } catch {
            guard generation == computeGeneration, !isClosed, !isStale else { return }
            finishCompute()
            if !(error is CancellationError) && !Task.isCancelled {
                errorMessage = L10n.text(error.localizedDescription)
            }
        }
    }

    func cancelComputation() {
        guard isComputing else { return }
        isCancelling = true
        computeTask?.cancel()
    }

    func invalidate() {
        guard !isStale else { return }
        isStale = true
        computeGeneration &+= 1
        computeTask?.cancel()
        computeTask = nil
        result = nil
        finishCompute()
        errorMessage = L10n.text("The selected map, result sources, or sample line changed. Close this chart and open it again.")
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        computeGeneration &+= 1
        computeTask?.cancel()
        computeTask = nil
        result = nil
        errorMessage = nil
        finishCompute()
    }

    private func finishCompute() {
        isComputing = false
        isCancelling = false
        progressFraction = nil
        progressMessage = nil
        progressTaskName = nil
    }
}

@MainActor
enum MapResultChartContractValidation {
    static func validate(_ loaded: MapResultChartSources, map: MapResultChartMapRequest,
                         overrides: [MapResultSelectionOverride]) throws {
        guard samePath(loaded.projectPath, map.projectPath),
              sameDigest(loaded.projectXmlSHA, map.projectXmlSHA),
              loaded.mapID.caseInsensitiveCompare(map.mapID) == .orderedSame,
              loaded.mapIndex == map.mapIndex, loaded.mapName == map.mapName,
              loaded.mapType == map.mapType,
              sameDigest(loaded.visualizationRevision, map.expectedVisualizationRevision),
              !loaded.projectRevision.isEmpty, !loaded.contextToken.isEmpty,
              Set(loaded.activeNodes.map(\.id)).count == loaded.activeNodes.count else {
            throw protocolError("The result sources no longer match the captured map.")
        }
        try validateOverrideShape(overrides)
        let overridesByID = Dictionary(grouping: overrides, by: \.id)
        guard overridesByID.values.allSatisfy({ $0.count == 1 }),
              overrides.allSatisfy({ item in loaded.activeNodes.contains(where: { $0.id == item.nodeIdentity }) }) else {
            throw protocolError("The result selection contains a node that is not active on this map.")
        }
        for node in loaded.activeNodes {
            guard node.nodeKind == "Result" || node.nodeKind == "MultiResult",
                  (1...32).contains(node.selections.count),
                  node.selections.map(\.selectionIndex) == Array(0..<node.selections.count) else {
                throw protocolError("The active map source has an invalid result selection list.")
            }
            if node.nodeKind == "Result" {
                guard node.selections.count == 1, node.selections[0].selectionIndex == 0,
                      node.selections[0].selectionMode == .explicit else {
                    throw protocolError("A standalone Result source must retain its exact source selection.")
                }
            }
            for slot in node.selections {
                guard Set(slot.choices.map { canonicalPath($0.resultPath) }).count == slot.choices.count,
                      slot.choices.allSatisfy({ isAbsolute($0.resultPath) && !$0.revision.isEmpty }),
                      slot.selectedResult.map({ selected in slot.choices.contains(where: { sameChoice($0, selected) }) }) ?? true,
                      node.nodeKind == "MultiResult" || slot.selectionMode == .explicit else {
                    throw protocolError("The active map source has inconsistent result choices.")
                }
                switch slot.selectionMode {
                case .latest:
                    guard sameOptionalChoice(slot.selectedResult, slot.choices.first) else {
                        throw protocolError("The latest Result selection does not match its ordered choices.")
                    }
                case .previous:
                    guard sameOptionalChoice(slot.selectedResult, slot.choices.dropFirst().first) else {
                        throw protocolError("The previous Result selection does not match its ordered choices.")
                    }
                case .explicit:
                    guard slot.selectedResult != nil else {
                        throw protocolError("An explicit Result selection has no selected Result.")
                    }
                }
                if let override = overridesByID[overrideID(node.id, slot.selectionIndex)]?.first {
                    try validateOverride(override, slot: slot)
                }
            }
            let nodeOverrides = overrides.filter { $0.nodeIdentity == node.id }.map(\.selectionIndex).sorted()
            if !nodeOverrides.isEmpty, nodeOverrides != Array(0..<node.selections.count) {
                throw protocolError("The map result selections must include every slot in order.")
            }
        }
    }

    static func validateOverrideShape(_ overrides: [MapResultSelectionOverride]) throws {
        guard overrides.allSatisfy({ item in
            item.selectionIndex >= 0 && item.selectionIndex < 32
                && (item.mode == .explicit
                    ? item.resultPath.map(isAbsolute) == true && item.resultRevision?.isEmpty == false
                    : item.resultPath == nil && item.resultRevision == nil)
        }), Set(overrides.map(\.id)).count == overrides.count else {
            throw protocolError("The map result selections are invalid.")
        }
    }

    static func canonicalOverrides(from sources: MapResultChartSources) throws -> [MapResultSelectionOverride] {
        var result: [MapResultSelectionOverride] = []
        for node in sources.activeNodes {
            for slot in node.selections.sorted(by: { $0.selectionIndex < $1.selectionIndex }) {
                let selected: MapResultChartSourceChoice?
                if slot.selectionMode == .explicit {
                    guard let value = slot.selectedResult else {
                        throw protocolError("An explicit map result selection has no selected Result.")
                    }
                    selected = value
                } else {
                    selected = nil
                }
                result.append(MapResultSelectionOverride(node: node.node,
                    selectionIndex: slot.selectionIndex, mode: slot.selectionMode,
                    resultPath: selected?.resultPath, resultRevision: selected?.revision))
            }
        }
        try validateOverrideShape(result)
        return result
    }

    static func validate(_ loaded: MapResultChartSeries, context: MapResultChartContext,
                         snapshot: MapResultSourcesSnapshot, mode: MapResultChartMode) throws {
        guard snapshot.map == context.mapRequest,
              samePath(loaded.projectPath, context.projectPath),
              loaded.projectRevision == snapshot.sources.projectRevision,
              sameDigest(loaded.projectXmlSHA, context.projectXMLSHA),
              loaded.mapID.caseInsensitiveCompare(context.mapID.uuidString) == .orderedSame,
              loaded.mapIndex == context.mapIndex, loaded.mapName == context.mapName,
              loaded.mapType == context.mapType,
              sameDigest(loaded.visualizationRevision, context.visualizationRevision),
              loaded.contextToken == snapshot.sources.contextToken,
              loaded.mode == mode.rawValue, loaded.sampleLine == context.sampleLine,
              loaded.featureContextToken == context.expectedFeatureContextToken(
                contextToken: snapshot.sources.contextToken, mode: mode) else {
            throw protocolError("The result chart does not match the selected map, line, or source snapshot.")
        }
        let expectedFeature = MapResultFeatureIdentity(vectorPath: context.vectorPath,
            vectorRevision: context.vectorRevision, featureID: context.stableFeatureIdentity,
            coordinateSHA: context.coordinateSHA)
        guard samePath(loaded.feature.vectorPath, expectedFeature.vectorPath),
              sameDigest(loaded.feature.vectorRevision, expectedFeature.vectorRevision),
              loaded.feature.featureID == expectedFeature.featureID,
              sameDigest(loaded.feature.coordinateSHA, expectedFeature.coordinateSHA) else {
            throw protocolError("The result chart reply belongs to a different selected map feature.")
        }
        try validate(loadedSources: snapshot.sources, entries: loaded.series, mode: mode)
    }

    private static func validate(loadedSources: MapResultChartSources,
                                 entries: [MapResultChartSeriesEntry],
                                 mode: MapResultChartMode) throws {
        var expected: [String: Set<String>] = [:]
        for node in loadedSources.activeNodes {
            for slot in node.selections {
                guard let choice = slot.selectedResult else {
                    throw protocolError("Choose a result for every active map source before plotting the selected line.")
                }
                let key = seriesGroupKey(resultPath: choice.resultPath, revision: choice.revision,
                    mapType: node.selectedMapType, profileIndex: node.profileIndex)
                expected[key, default: []].insert(selectionKey(node: node.id, index: slot.selectionIndex))
            }
        }
        var actual: [String: Set<String>] = [:]
        for entry in entries {
            let selectionKeys = entry.selections.map {
                selectionKey(node: MapResultSelectionOverride(node: $0.node, selectionIndex: $0.selectionIndex,
                    mode: .latest).nodeIdentity, index: $0.selectionIndex)
            }
            guard !selectionKeys.isEmpty, Set(selectionKeys).count == selectionKeys.count,
                  entry.series.mode == mode.rawValue,
                  entry.series.points.allSatisfy({ $0.profileIndex >= 0 && ($0.value?.isFinite ?? true) }) else {
                throw protocolError("The result chart contains invalid source series.")
            }
            let key = seriesGroupKey(resultPath: entry.series.resultPath, revision: entry.series.revision,
                mapType: entry.selectedMapType, profileIndex: entry.profileIndex)
            guard expected[key] == Set(selectionKeys), actual[key] == nil else {
                throw protocolError("The result chart returned a source that was not selected on this map.")
            }
            for reference in entry.selections {
                let nodeID = MapResultSelectionOverride(node: reference.node, mode: .latest).nodeIdentity
                guard let node = loadedSources.activeNodes.first(where: { $0.id == nodeID }),
                      let slot = node.selections.first(where: { $0.selectionIndex == reference.selectionIndex }),
                      let choice = slot.selectedResult,
                      samePath(choice.resultPath, entry.series.resultPath),
                      sameDigest(choice.revision, entry.series.revision),
                      node.selectedMapType == entry.selectedMapType,
                      node.profileIndex == entry.profileIndex else {
                    throw protocolError("The result chart returned values for a different active result context.")
                }
            }
            actual[key] = Set(selectionKeys)
        }
        guard actual == expected else {
            throw protocolError("The result chart is missing one or more active result contexts.")
        }
    }

    private static func validateOverride(_ override: MapResultSelectionOverride,
                                         slot: MapResultChartSelectionSlot) throws {
        if override.mode == .explicit {
            guard let path = override.resultPath, let revision = override.resultRevision,
                  let selected = slot.selectedResult,
                  samePath(path, selected.resultPath), sameDigest(revision, selected.revision),
                  slot.selectionMode == .explicit
                    || (slot.selectionMode == .latest && sameOptionalChoice(selected, slot.choices.first))
                    || (slot.selectionMode == .previous && sameOptionalChoice(selected, slot.choices.dropFirst().first)) else {
                throw protocolError("The explicitly selected Result is no longer available.")
            }
        } else {
            guard override.mode == slot.selectionMode,
                  override.resultPath == nil, override.resultRevision == nil else {
                throw protocolError("The result source selection does not match the current map session.")
            }
        }
    }

    private static func sameOptionalChoice(_ lhs: MapResultChartSourceChoice?,
                                           _ rhs: MapResultChartSourceChoice?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (left?, right?): sameChoice(left, right)
        default: false
        }
    }

    private static func overrideID(_ nodeID: String, _ selectionIndex: Int) -> String {
        "\(nodeID)|\(selectionIndex)"
    }

    private static func selectionKey(node: String, index: Int) -> String { "\(node)|\(index)" }

    private static func seriesGroupKey(resultPath: String, revision: String,
                                       mapType: String?, profileIndex: Int?) -> String {
        [canonicalPath(resultPath), revision.uppercased(), mapType ?? "", String(profileIndex ?? -1)]
            .joined(separator: "|")
    }

    static func sameChoice(_ lhs: MapResultChartSourceChoice,
                           _ rhs: MapResultChartSourceChoice) -> Bool {
        samePath(lhs.resultPath, rhs.resultPath) && sameDigest(lhs.revision, rhs.revision)
    }

    private static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        canonicalPath(lhs) == canonicalPath(rhs)
    }

    static func canonicalPath(_ value: String) -> String {
        SourceFilePaths.canonical(URL(fileURLWithPath: value))
    }

    private static func isAbsolute(_ path: String) -> Bool {
        URL(fileURLWithPath: path).path.hasPrefix("/")
    }

    private static func sameDigest(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    static func protocolError(_ message: String) -> BackendServiceError {
        BackendServiceError(code: "protocolFailure", message: L10n.text(message))
    }
}
