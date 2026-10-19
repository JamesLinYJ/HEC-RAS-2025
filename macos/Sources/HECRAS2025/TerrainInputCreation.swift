import Foundation

/// Typed Add actions exposed by TerrainAddControl. Raw values are only the
/// backend operation identifiers; the visible labels retain the source names.
enum TerrainInputCreationKind: String, CaseIterable, Identifiable, Sendable {
    case functionalSurface
    case polygonVectorMod
    case channelVectorMod
    case simpleCutFill

    var id: String { rawValue }

    var title: String {
        switch self {
        case .functionalSurface: "Functional Surface"
        case .polygonVectorMod: "Polygon Vector Mod Layer"
        case .channelVectorMod: "Channel Vector Mod Layer"
        case .simpleCutFill: "Simple Cut/Fill Layer"
        }
    }

    var symbol: String {
        switch self {
        case .functionalSurface: "function"
        case .polygonVectorMod: "pentagon"
        case .channelVectorMod: "point.topleft.down.to.point.bottomright.curvepath"
        case .simpleCutFill: "water.waves"
        }
    }
}
