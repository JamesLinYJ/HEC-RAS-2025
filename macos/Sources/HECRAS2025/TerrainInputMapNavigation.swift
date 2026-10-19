import Foundation
import RASWorkspaceCore

/// A valid world-coordinate extent materialized from the exact source
/// ITerrainInput. It is intentionally nullable at the backend boundary.
struct TerrainInputValidExtent: Codable, Equatable, Hashable, Sendable {
    let minX: Double
    let maxX: Double
    let minY: Double
    let maxY: Double

    var isFiniteAndOrdered: Bool {
        minX.isFinite && maxX.isFinite && minY.isFinite && maxY.isFinite
            && minX < maxX && minY < maxY
    }
}
