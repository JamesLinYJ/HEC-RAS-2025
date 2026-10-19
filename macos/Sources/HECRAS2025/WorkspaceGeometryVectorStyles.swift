import RASWorkspaceCore

/// A persisted specialized map-tree owner. Geometry bytes and draft state are
/// owned by the model editor; this value carries presentation settings only.
struct SpecializedVectorSymbologySource {
    let context: VectorSymbologyContext
    let settings: VectorVisualSettingsSnapshot
    let defaults: [String: VectorStyleValues]
}
