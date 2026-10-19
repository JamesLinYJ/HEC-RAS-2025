import Foundation

/// A global shortcut hands presentation to the existing primary editor, whose
/// model-change prompt and save/discard boundary remain authoritative. Geometry
/// requests carry no feature FID; the exact primary topology session resolves a
/// real user selection before exposing an action that needs one.
struct EditorToolPresentationRequest: Identifiable, Equatable {
    let id: UUID
    let projectSessionID: UUID
    let assetID: String
    let action: ToolKind
    let spatialLayerID: String?
    let featureKind: String?
}
