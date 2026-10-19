import Combine
import Foundation
import RASWorkspaceCore

@MainActor
final class BoundaryMapStyleSession: ObservableObject {
    @Published private(set) var context: BoundaryMapStyleContext?
    @Published private(set) var snapshot: BoundaryMapStyleSnapshot?
    @Published var draft: [String: VectorVisualSettingsOptions]?
    @Published private(set) var isLoading = false
    @Published private(set) var isApplying = false
    @Published private(set) var isInvalidated = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var resetRequested = false

    private let provider: any BoundaryMapStyleProvider
    private var generation: UInt64 = 0
    private var loadTask: Task<BoundaryMapStyleSnapshot, Error>?

    init(context: BoundaryMapStyleContext, provider: any BoundaryMapStyleProvider) {
        self.context = context
        self.provider = provider
    }

    var hasConditionalOverrides: Bool {
        (draft ?? snapshot?.options ?? [:]).values.contains { option in
            option.conditionGroups.contains { !$0.rules.isEmpty }
        }
    }

    var hasChanges: Bool {
        guard let draft, let snapshot else { return false }
        return resetRequested || draft != snapshot.options
    }

    func load() async {
        guard let context, !isInvalidated, snapshot == nil, loadTask == nil else { return }
        generation &+= 1
        let requestedGeneration = generation
        isLoading = true
        errorMessage = nil
        let task = Task { @MainActor in try await provider.load(context) }
        loadTask = task
        defer {
            if generation == requestedGeneration {
                isLoading = false
                loadTask = nil
            }
        }
        do {
            let loaded = try await task.value
            guard !Task.isCancelled, generation == requestedGeneration,
                  self.context?.identity == context.identity, !isInvalidated else { return }
            self.snapshot = loaded
            self.draft = loaded.options
        } catch is CancellationError {
            return
        } catch {
            guard generation == requestedGeneration,
                  self.context?.identity == context.identity, !isInvalidated else { return }
            errorMessage = VectorSymbologyErrorPresentation.text(error.localizedDescription)
        }
    }

    /// Dismissal may cancel a read, but must never cancel a submitted write.
    func cancelPendingLoad() {
        guard let task = loadTask else { return }
        generation &+= 1
        task.cancel()
        loadTask = nil
        isLoading = false
    }

    @discardableResult
    func apply() async -> Bool {
        guard let context, let snapshot, let draft, !isInvalidated,
              !isLoading, !isApplying else { return false }
        generation &+= 1
        let requestedGeneration = generation
        isApplying = true
        errorMessage = nil
        defer {
            if generation == requestedGeneration { isApplying = false }
        }
        do {
            let refreshed = try await provider.apply(context, snapshot: snapshot,
                options: draft, resetToDefaults: resetRequested)
            guard generation == requestedGeneration,
                  self.context?.identity == context.identity, !isInvalidated else { return false }
            self.context = refreshed.context
            self.snapshot = refreshed
            self.draft = refreshed.options
            resetRequested = false
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard generation == requestedGeneration, !isInvalidated else { return false }
            errorMessage = VectorSymbologyErrorPresentation.text(error.localizedDescription)
            return false
        }
    }

    /// Reset is a pending persistence operation even when the effective values
    /// already equal defaults; Core still needs the explicit flag to remove
    /// redundant local `.vis` attributes.
    func resetToDefaults() {
        guard let context, let snapshot, !isApplying, !isInvalidated else { return }
        var reset = draft ?? snapshot.options
        for definitionID in [BoundaryMapRenderStyle.lineDefinitionID,
                             BoundaryMapRenderStyle.vertexDefinitionID] {
            guard var option = reset[definitionID],
                  let defaults = context.defaults[definitionID] else { continue }
            option.values = defaults
            reset[definitionID] = option
        }
        draft = reset
        resetRequested = true
        errorMessage = nil
    }

    func setPenColor(_ value: String, definitionID: String) {
        updateValues(definitionID) { $0.penColor = value }
    }

    func setFillColor(_ value: String, definitionID: String) {
        updateValues(definitionID) { $0.fillColor = value }
    }

    func setPenWidth(_ value: Double, definitionID: String) {
        guard value.isFinite, (0...256).contains(value) else { return }
        updateValues(definitionID) { $0.penWidth = value }
    }

    func setPointSize(_ value: Int, definitionID: String) {
        guard (0...256).contains(value) else { return }
        updateValues(definitionID) { $0.pointSize = value }
    }

    func invalidate() {
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
        context = nil
        snapshot = nil
        draft = nil
        isLoading = false
        isApplying = false
        isInvalidated = true
        resetRequested = false
        errorMessage = L10n.text("The Boundary map or source changed. Refresh the style editor.")
    }

    private func updateValues(_ definitionID: String,
                              _ operation: (inout VectorStyleValues) -> Void) {
        guard !isApplying, !isInvalidated, var options = draft,
              var option = options[definitionID] else { return }
        let previousValues = option.values
        operation(&option.values)
        guard option.values != previousValues else { return }
        options[definitionID] = option
        draft = options
        if resetRequested { resetRequested = false }
    }
}
