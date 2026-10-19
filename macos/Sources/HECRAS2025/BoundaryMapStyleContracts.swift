import Foundation
import RASWorkspaceCore

/// The app-side Boundary capture and Core's exact `.vis` identity joined
/// together for one map-scoped style editor. The line child may be implicit
/// only when the live source tree exposes its unique fixed-name context.
struct BoundaryMapStyleContext: Sendable {
    let mapID: UUID
    let capture: BoundaryMapCapture
    let visualNode: BoundaryVectorVisualNodeIdentity
    let defaults: [String: VectorStyleValues]
    let globalStyleRevision: UInt64

    var identity: String {
        [mapID.uuidString, capture.identity,
         visualNode.rootName,
         visualNode.boundaryNodePath.map(String.init).joined(separator: "."),
         visualNode.boundaryName,
         (visualNode.lineNodePath ?? []).map(String.init).joined(separator: "."),
         visualNode.lineNodeName,
         String(globalStyleRevision)]
            .map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}

struct BoundaryMapStyleSnapshot: Sendable {
    let context: BoundaryMapStyleContext
    let options: [String: VectorVisualSettingsOptions]
    let revision: String
}

@MainActor
protocol BoundaryMapStyleProvider {
    func load(_ context: BoundaryMapStyleContext) async throws -> BoundaryMapStyleSnapshot
    func apply(_ context: BoundaryMapStyleContext,
               snapshot: BoundaryMapStyleSnapshot,
               options: [String: VectorVisualSettingsOptions],
               resetToDefaults: Bool) async throws -> BoundaryMapStyleSnapshot
}

enum BoundaryMapStyleSessionError: Error, LocalizedError {
    case invalidDraft
    case staleContext
    case sourceChanged

    var errorDescription: String? {
        switch self {
        case .invalidDraft:
            "The Boundary style draft is invalid or changed saved conditional rules."
        case .staleContext:
            "The Boundary map or style defaults changed. Reopen the style editor."
        case .sourceChanged:
            "The Boundary source changed while its style was being saved."
        }
    }
}
