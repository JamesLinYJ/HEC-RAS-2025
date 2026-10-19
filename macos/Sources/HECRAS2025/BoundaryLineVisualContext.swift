import Foundation
import RASWorkspaceCore

struct BoundaryLineVisualContext: Equatable, Sendable {
    /// Effective values for this map's boundary line and vertex options.
    /// Missing local `.vis` attributes have already inherited the captured
    /// global defaults, subject to the source whole-option dirty rule.
    let settings: BoundaryLineVisualSettings
    let localOverrides: BoundaryLineVisualOverrides
    /// Baseline captured with this context; Reset and Apply must use the same
    /// preference revision to avoid publishing against a newer default.
    let globalDefaults: BoundaryLineVisualSettings
    let vectorStyleRevision: UInt64
    let projectSessionID: UUID
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let boundaryName: String
    let assetID: String
    let visualizationRevision: String?

    init(
        settings: BoundaryLineVisualSettings,
        projectSessionID: UUID,
        mapIndex: Int,
        mapName: String,
        mapType: String,
        boundaryName: String,
        assetID: String,
        visualizationRevision: String?,
        localOverrides: BoundaryLineVisualOverrides = .init(),
        globalDefaults: BoundaryLineVisualSettings? = nil,
        vectorStyleRevision: UInt64 = 0
    ) {
        self.settings = settings
        self.localOverrides = localOverrides
        self.globalDefaults = globalDefaults ?? settings
        self.vectorStyleRevision = vectorStyleRevision
        self.projectSessionID = projectSessionID
        self.mapIndex = mapIndex
        self.mapName = mapName
        self.mapType = mapType
        self.boundaryName = boundaryName
        self.assetID = assetID
        self.visualizationRevision = visualizationRevision
    }
}
