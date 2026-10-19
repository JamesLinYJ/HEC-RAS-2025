import Combine
import CoreGraphics
import Foundation
import RASWorkspaceCore

@MainActor
final class BoundaryMapSession: ObservableObject {
    @Published private(set) var entries: [BoundaryMapSourceState] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var selectedLineID: String?
    @Published private(set) var selectedLineIDs: Set<String> = []
    @Published private(set) var hoveredLineID: String?
    @Published private(set) var renderRevision = 0

    private let provider: any BoundaryMapProvider
    private var captures: [BoundaryMapCapture] = []
    private var visualStylesByCaptureIdentity: [String: BoundaryMapRenderStyle] = [:]
    private var showsStrokeVerticesByOwner: [String: Bool] = [:]
    // ActiveFeaturesControl owns a SelectedSet per render-layer instance.
    // Keep BoundaryCondition lines from separate Result/source captures in
    // separate selections even though they share one native map canvas.
    private var lineSelectionsBySource: [String: MapVectorFeatureSelection] = [:]
    private var activeLineSelectionSource: String?
    private var generation: UInt64 = 0
    private var activeRequest: Task<BoundaryMapSnapshot, Error>?
    private var activeRequestID: UUID?

    init(provider: any BoundaryMapProvider) { self.provider = provider }

    var visibleLines: [BoundaryMapLinePresentation] {
        entries.flatMap { entry in
            entry.visibleLines.map { BoundaryMapLinePresentation(sourceIdentity: entry.capture.sourceIdentity, line: $0) }
        }
    }

    var visiblePoints: [MapPoint] { entries.flatMap(\.visiblePoints) }

    /// Installs line and vertex style values only for the exact capture that
    /// is still active. This prevents a late style response from another map,
    /// source revision or Result owner from repainting these lines.
    @discardableResult
    func installVisualStyles(_ options: [String: VectorVisualSettingsOptions],
                             for capture: BoundaryMapCapture) -> Bool {
        guard captures.contains(where: { $0.identity == capture.identity }),
              let style = BoundaryMapRenderStyle.resolve(options: options) else { return false }
        guard visualStylesByCaptureIdentity[capture.identity] != style else { return true }
        visualStylesByCaptureIdentity[capture.identity] = style
        renderRevision &+= 1
        return true
    }

    /// Returns the exact owner's installed styles or the retained source
    /// catalog defaults while its local/global values are being loaded.
    func visualStyle(for sourceIdentity: String) -> BoundaryMapRenderStyle {
        guard let capture = captures.first(where: { $0.sourceIdentity == sourceIdentity }) else {
            return .sourceDefault
        }
        return visualStylesByCaptureIdentity[capture.identity] ?? .sourceDefault
    }

    func setShowsStrokeVertices(_ enabled: Bool, sourceIdentity: String) {
        guard let capture = captures.first(where: { $0.sourceIdentity == sourceIdentity }) else { return }
        let ownerKey = BoundaryMapRenderOwnerIdentity.key(for: capture)
        guard showsStrokeVerticesByOwner[ownerKey] != enabled else { return }
        showsStrokeVerticesByOwner[ownerKey] = enabled
        renderRevision &+= 1
    }

    func showsStrokeVertices(for sourceIdentity: String) -> Bool {
        guard let capture = captures.first(where: { $0.sourceIdentity == sourceIdentity }) else { return false }
        return showsStrokeVerticesByOwner[BoundaryMapRenderOwnerIdentity.key(for: capture)] ?? false
    }

    func configure(captures newCaptures: [BoundaryMapCapture]) async {
        if captures.map(\.identity) == newCaptures.map(\.identity),
           entries.count == newCaptures.count, !entries.contains(where: { $0.status == .loading || $0.status == .failed }) {
            return
        }
        let currentCaptureIdentities = Set(newCaptures.map(\.identity))
        visualStylesByCaptureIdentity = visualStylesByCaptureIdentity.filter {
            currentCaptureIdentities.contains($0.key)
        }
        let currentOwnerKeys = Set(newCaptures.map(BoundaryMapRenderOwnerIdentity.key))
        showsStrokeVerticesByOwner = showsStrokeVerticesByOwner.filter {
            currentOwnerKeys.contains($0.key)
        }
        activeRequest?.cancel()
        activeRequest = nil
        activeRequestID = nil
        captures = newCaptures
        await loadCurrentCaptures(force: false)
    }

    func refresh() async {
        activeRequest?.cancel()
        activeRequest = nil
        activeRequestID = nil
        await loadCurrentCaptures(force: true)
    }

    func cancel() {
        generation &+= 1
        activeRequest?.cancel()
        activeRequest = nil
        activeRequestID = nil
        isLoading = false
        let message = L10n.text("Boundary map loading was cancelled.")
        entries = entries.map { entry in
            guard entry.status == .loading else { return entry }
            return BoundaryMapSourceState(capture: entry.capture,
                contextToken: entry.contextToken, boundarySourceState: entry.boundarySourceState,
                lines: entry.lines, status: .failed, diagnostic: message)
        }
        errorMessage = nil
        renderRevision &+= 1
    }

    func invalidate() {
        generation &+= 1
        activeRequest?.cancel()
        activeRequest = nil
        activeRequestID = nil
        captures = []
        visualStylesByCaptureIdentity = [:]
        showsStrokeVerticesByOwner = [:]
        entries = []
        lineSelectionsBySource = [:]
        activeLineSelectionSource = nil
        selectedLineID = nil
        selectedLineIDs = []
        hoveredLineID = nil
        errorMessage = nil
        isLoading = false
        renderRevision &+= 1
    }

    func selectLine(_ presentationID: String?, mode: MapVectorSelectionMode = .replace) {
        guard let presentationID else {
            lineSelectionsBySource = [:]
            activeLineSelectionSource = nil
            publishLineSelections()
            return
        }
        guard let owner = visibleLines.first(where: { $0.id == presentationID })?.sourceIdentity else { return }
        let available = visibleLines.filter { $0.sourceIdentity == owner }.map(\.id)
        var selection = lineSelectionsBySource[owner] ?? MapVectorFeatureSelection()
        selection.select(presentationID, mode: mode, available: available, rangeOrder: available)
        lineSelectionsBySource[owner] = selection
        activeLineSelectionSource = owner
        publishLineSelections()
    }

    /// Source context-menu behavior keeps a selected set when the right-click
    /// lands on one of its members; an unselected target becomes the sole row.
    func selectLineForContextMenu(_ presentationID: String) {
        guard let owner = visibleLines.first(where: { $0.id == presentationID })?.sourceIdentity else { return }
        var selection = lineSelectionsBySource[owner] ?? MapVectorFeatureSelection()
        guard !selection.identities.contains(presentationID) else {
            activeLineSelectionSource = owner
            publishLineSelections()
            return
        }
        selection.replaceLegacy(presentationID)
        lineSelectionsBySource[owner] = selection
        activeLineSelectionSource = owner
        publishLineSelections()
    }

    func hoverLine(at screenPoint: CGPoint, transform: MapTransform) {
        var nearest: (id: String, distance: CGFloat)?
        for presentation in visibleLines {
            let coordinates = presentation.line.coordinates
            guard coordinates.count >= 2,
                  coordinates.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { continue }
            let screenPoints = coordinates.map(transform.screen)
            for (start, end) in zip(screenPoints, screenPoints.dropFirst()) {
                let distance = Self.distance(screenPoint, toSegmentFrom: start, to: end)
                if nearest == nil || distance < nearest!.distance { nearest = (presentation.id, distance) }
            }
        }
        setHoveredLine(nearest.flatMap { $0.distance <= 8 ? $0.id : nil })
    }

    func setHoveredLine(_ presentationID: String?) {
        guard presentationID == nil || visibleLines.contains(where: { $0.id == presentationID }) else { return }
        guard hoveredLineID != presentationID else { return }
        hoveredLineID = presentationID
        renderRevision &+= 1
    }

    /// Exact screen-space hit test used by the parent map's shared tap router.
    /// Returns false when no source line is within the native hit tolerance.
    @discardableResult
    func selectLine(at screenPoint: CGPoint, transform: MapTransform,
                    modifiers: Set<MapInput.Modifier>? = nil) -> Bool {
        var nearest: (id: String, distance: CGFloat)?
        for presentation in visibleLines {
            let screenPoints = presentation.line.coordinates.map(transform.screen)
            for (start, end) in zip(screenPoints, screenPoints.dropFirst()) {
                let distance = Self.distance(screenPoint, toSegmentFrom: start, to: end)
                if nearest == nil || distance < nearest!.distance { nearest = (presentation.id, distance) }
            }
        }
        guard let nearest, nearest.distance <= 8 else { return false }
        selectLine(nearest.id, mode: .pointer(modifiers: modifiers ?? MapInput.currentModifiers()))
        return true
    }

    private func reconcileLineSelection() {
        let availableBySource = Dictionary(grouping: visibleLines, by: \.sourceIdentity)
            .mapValues { Set($0.map(\.id)) }
        lineSelectionsBySource = lineSelectionsBySource.filter { availableBySource[$0.key] != nil }
        for (owner, available) in availableBySource {
            guard var selection = lineSelectionsBySource[owner] else { continue }
            selection.reconcile(available: available)
            lineSelectionsBySource[owner] = selection
        }
        if let activeLineSelectionSource,
           availableBySource[activeLineSelectionSource] == nil {
            self.activeLineSelectionSource = nil
        }
        publishLineSelections()
    }

    private func publishLineSelections() {
        let selected = lineSelectionsBySource.values.reduce(into: Set<String>()) {
            $0.formUnion($1.identities)
        }
        let primary = activeLineSelectionSource.flatMap { lineSelectionsBySource[$0]?.primary }
        guard selectedLineIDs != selected || selectedLineID != primary else { return }
        selectedLineIDs = selected
        selectedLineID = primary
        renderRevision &+= 1
    }

    private func loadCurrentCaptures(force: Bool) async {
        generation &+= 1
        let capturedGeneration = generation
        let requestedCaptures = captures
        let previousEntries = entries
        let previousByExactIdentity = Dictionary(previousEntries.map { ($0.capture.identity, $0) },
                                                 uniquingKeysWith: { _, latest in latest })
        let previousBySourceIdentity = Dictionary(previousEntries.map { ($0.capture.sourceIdentity, $0) },
                                                  uniquingKeysWith: { first, _ in first })

        if requestedCaptures.isEmpty {
            entries = []
            lineSelectionsBySource = [:]
            activeLineSelectionSource = nil
            selectedLineID = nil
            selectedLineIDs = []
            hoveredLineID = nil
            errorMessage = nil
            isLoading = false
            renderRevision &+= 1
            return
        }

        entries = requestedCaptures.map { capture in
            if !force, let previous = previousByExactIdentity[capture.identity] { return previous }
            let previousSource = previousBySourceIdentity[capture.sourceIdentity]
            return BoundaryMapSourceState(capture: capture,
                contextToken: previousByExactIdentity[capture.identity]?.contextToken,
                boundarySourceState: capture.boundarySourceState ?? previousSource?.boundarySourceState,
                lines: [], status: .loading, diagnostic: nil)
        }
        reconcileLineSelection()
        hoveredLineID = hoveredLineID.flatMap { hovered in
            visibleLines.contains(where: { $0.id == hovered }) ? hovered : nil
        }
        errorMessage = nil
        isLoading = true
        renderRevision &+= 1

        defer {
            if generation == capturedGeneration {
                isLoading = false
                renderRevision &+= 1
            }
        }

        for (index, capture) in requestedCaptures.enumerated() {
            guard generation == capturedGeneration, !Task.isCancelled else { return }
            if !force, previousByExactIdentity[capture.identity] != nil { continue }

            let previousExact = previousByExactIdentity[capture.identity]
            let previousSource = previousBySourceIdentity[capture.sourceIdentity]
            let boundarySourceState = capture.boundarySourceState ?? previousSource?.boundarySourceState
            do {
                let requestID = UUID()
                activeRequestID = requestID
                let request = Task { @MainActor in
                    try await provider.load(capture,
                        boundarySourceState: boundarySourceState,
                        contextToken: previousExact?.contextToken)
                }
                activeRequest = request
                let snapshot = try await request.value
                guard activeRequestID == requestID else { return }
                activeRequest = nil
                activeRequestID = nil
                guard generation == capturedGeneration, !Task.isCancelled,
                      captures.indices.contains(index), captures[index].identity == capture.identity else { return }
                let state = try BackendBoundaryMapProvider.sourceState(from: snapshot, capture: capture)
                entries[index] = state
                reconcileLineSelection()
            } catch is CancellationError {
                guard generation == capturedGeneration else { return }
                activeRequest = nil
                activeRequestID = nil
                entries[index] = failedState(for: capture, contextToken: previousExact?.contextToken,
                    sourceState: boundarySourceState, message: L10n.text("Boundary map loading was cancelled."))
                reconcileLineSelection()
            } catch {
                guard generation == capturedGeneration, !Task.isCancelled else { return }
                activeRequest = nil
                activeRequestID = nil
                let message = L10n.text(error.localizedDescription)
                entries[index] = failedState(for: capture, contextToken: previousExact?.contextToken,
                    sourceState: boundarySourceState, message: message)
                reconcileLineSelection()
                errorMessage = message
            }
            renderRevision &+= 1
        }
    }

    private func failedState(for capture: BoundaryMapCapture, contextToken: String?,
                             sourceState: String?, message: String) -> BoundaryMapSourceState {
        BoundaryMapSourceState(capture: capture, contextToken: contextToken,
            boundarySourceState: sourceState, lines: [], status: .failed, diagnostic: message)
    }

    private static func distance(_ point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let denominator = dx * dx + dy * dy
        guard denominator.isFinite, denominator > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let projection = min(max(((point.x - start.x) * dx + (point.y - start.y) * dy) / denominator, 0), 1)
        return hypot(point.x - (start.x + projection * dx), point.y - (start.y + projection * dy))
    }
}
