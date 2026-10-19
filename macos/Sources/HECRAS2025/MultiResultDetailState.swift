import Foundation
import RASWorkspaceCore

enum MultiResultSelectionDiagnosticState: Equatable, Sendable {
    case unknown
    case noIssues
    case issues([CatalogLayerDiagnostic])
    case readFailed(String?)
}

@MainActor
enum MultiResultSelectionProjection {
    /// Prefer live progress only when both the exact Result path and the exact
    /// MultiResult Plan owner match. Persisted state is already tied to the
    /// choice's Result SHA by the backend and remains usable when no live entry
    /// is present.
    static func computePresentation(for node: MapResultChartActiveNode,
                                    choice: MapResultChartSourceChoice,
                                    projectSessionID: UUID,
                                    liveEntries: [String: WorkspaceResultComputeEntry]) -> WorkspaceResultComputePresentation {
        let resultPath = MultiResultContextRouteProjection.canonicalPath(choice.resultPath)
        var exactLiveEntries: [String: WorkspaceResultComputeEntry] = [:]
        if let owner = WorkspaceStore.exactPlanOwnerForResultGroup(node.node) {
            let planPath = MultiResultContextRouteProjection.canonicalPath(owner.assetID)
            for (key, entry) in liveEntries where
                MultiResultContextRouteProjection.canonicalPath(key) == resultPath
                    && entry.projectSessionID == projectSessionID
                    && MultiResultContextRouteProjection.canonicalPath(entry.planPath) == planPath {
                exactLiveEntries[resultPath] = entry
            }
        }
        return WorkspaceResultComputePresentation.resolve(path: choice.resultPath,
            projectSessionID: projectSessionID, sourceRevision: choice.revision,
            liveEntries: exactLiveEntries, persistedState: choice.computeState,
            persistedFailureReason: choice.computeFailureReason)
    }

    /// Finds an exact unrepresented compute Result for a Latest slot as soon
    /// as computeStarted reports its real path. This lookup never creates a
    /// persisted choice or supplies a missing revision; MapResultSourcesSession
    /// owns the corresponding transient logical selection until stable source
    /// data arrives.
    static func transientLatestEntry(for node: MapResultChartActiveNode,
                                     choices: [MapResultChartSourceChoice],
                                     projectSessionID: UUID,
                                     isPlanComputeActive: Bool,
                                     liveEntries: [String: WorkspaceResultComputeEntry]) -> WorkspaceResultComputeEntry? {
        guard isPlanComputeActive,
              let owner = WorkspaceStore.exactPlanOwnerForResultGroup(node.node) else { return nil }
        let planPath = MultiResultContextRouteProjection.canonicalPath(owner.assetID)
        let representedPaths = Set(choices.map {
            MultiResultContextRouteProjection.canonicalPath($0.resultPath)
        })
        let candidates = liveEntries.values.filter { entry in
            entry.projectSessionID == projectSessionID
                && entry.status == .running
                && MultiResultContextRouteProjection.canonicalPath(entry.planPath) == planPath
                && !representedPaths.contains(
                    MultiResultContextRouteProjection.canonicalPath(entry.resultPath))
        }
        // If more than one unrepresented live Result claims this exact Plan,
        // identity is ambiguous; do not guess which run the Latest slot means.
        guard candidates.count == 1 else { return nil }
        return candidates[0]
    }

    static func diagnostics(for choice: MapResultChartSourceChoice) -> MultiResultSelectionDiagnosticState {
        switch choice.diagnosticStatus?.lowercased() {
        case "loaded":
            guard let errors = choice.layerErrors else { return .unknown }
            return errors.isEmpty ? .noIssues : .issues(errors)
        case "readfailed":
            return .readFailed(choice.diagnosticReadError)
        default:
            return .unknown
        }
    }
}
