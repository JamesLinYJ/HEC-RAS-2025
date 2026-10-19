import Foundation
import RASWorkspaceCore
import SwiftUI

/// Exact map owner, camera and background-map settings captured when the user
/// opens the blank-map context menu. The click point is in the map's current
/// world coordinates; it is never recomputed from a later pointer location.
struct MapBlankContextCapture: Equatable, Sendable {
    let projectSessionID: UUID
    let mapID: UUID
    let mapStateIdentity: ObjectIdentifier
    let mapIdentity: MapTreeMapIdentity?
    let backgroundSessionIdentity: ObjectIdentifier
    let settings: BackgroundMapSettings
    let projectionType: String
    let projectionValue: String
    let canCopyHoveredTileJSON: Bool
    let screenX: Double
    let screenY: Double
    let worldPoint: MapPoint
    let viewport: BackgroundMapViewport
    let worldUnitsPerPixel: Double

    @MainActor
    static func make(projectSessionID: UUID, mapID: UUID, mapState: MapState,
                     mapIdentity: MapTreeMapIdentity?,
                     backgroundSession: BackgroundMapSession,
                     settings: BackgroundMapSettings,
                     projectionType: String, projectionValue: String,
                     location: CGPoint, transform: MapTransform) -> Self? {
        guard location.x.isFinite, location.y.isFinite,
              mapIdentity == nil || mapIdentity?.mapID.caseInsensitiveCompare(mapID.uuidString) == .orderedSame,
              transform.factor.isFinite, transform.factor > 0,
              let viewport = viewport(transform: transform),
              let worldUnitsPerPixel = finitePositive(1 / Double(transform.factor)) else { return nil }
        let worldPoint = transform.world(location)
        guard worldPoint.x.isFinite, worldPoint.y.isFinite else { return nil }
        let canCopy = backgroundSession.canCopyHoveredTileJSON
            && backgroundSession.matchesContext(mapID: mapID,
                projectSessionID: projectSessionID, projectionType: projectionType,
                projectionValue: projectionValue, viewport: viewport,
                worldUnitsPerPixel: worldUnitsPerPixel, settings: settings)
        return .init(projectSessionID: projectSessionID, mapID: mapID,
            mapStateIdentity: ObjectIdentifier(mapState),
            mapIdentity: mapIdentity,
            backgroundSessionIdentity: ObjectIdentifier(backgroundSession),
            settings: settings, projectionType: projectionType, projectionValue: projectionValue,
            canCopyHoveredTileJSON: canCopy,
            screenX: Double(location.x), screenY: Double(location.y),
            worldPoint: worldPoint, viewport: viewport,
            worldUnitsPerPixel: worldUnitsPerPixel)
    }

    static func viewport(transform: MapTransform) -> BackgroundMapViewport? {
        guard transform.size.width.isFinite, transform.size.height.isFinite,
              let width = pixelDimension(transform.size.width),
              let height = pixelDimension(transform.size.height) else { return nil }
        let lowerLeft = transform.world(CGPoint(x: 0, y: transform.size.height))
        let upperRight = transform.world(CGPoint(x: transform.size.width, y: 0))
        let result = BackgroundMapViewport(minX: lowerLeft.x, minY: lowerLeft.y,
            maxX: upperRight.x, maxY: upperRight.y,
            pixelWidth: width, pixelHeight: height)
        return Self.isValid(result) ? result : nil
    }

    private static func pixelDimension(_ value: CGFloat) -> Int? {
        guard value.isFinite, value > 0 else { return nil }
        let rounded = Double(value.rounded())
        // Swift's floating-point-to-Int conversion traps at Int.max's rounded
        // floating representation (2^63 on 64-bit targets).
        return rounded >= Double(Int.max) ? Int.max : max(Int(rounded), 1)
    }

    static func isValid(_ viewport: BackgroundMapViewport) -> Bool {
        [viewport.minX, viewport.minY, viewport.maxX, viewport.maxY].allSatisfy(\.isFinite)
            && viewport.minX < viewport.maxX && viewport.minY < viewport.maxY
            && viewport.pixelWidth > 0 && viewport.pixelHeight > 0
    }

    private static func finitePositive(_ value: Double) -> Double? {
        value.isFinite && value > 0 ? value : nil
    }
}

@MainActor
enum MapBlankContextCurrentness {
    /// The async clipboard closure calls this only after the tile request
    /// returns. In addition to the background session's own capture check,
    /// this rejects a result if the project/map owner, source settings, camera
    /// viewport, or exact world point has changed while the request was away.
    static func matches(_ capture: MapBlankContextCapture,
                        projectSessionID: UUID, mapID: UUID,
                        mapState: MapState,
                        mapIdentity: MapTreeMapIdentity?,
                        backgroundSession: BackgroundMapSession,
                        settings: BackgroundMapSettings,
                        projectionType: String, projectionValue: String,
                        currentViewport: BackgroundMapViewport?,
                        currentWorldPoint: MapPoint?) -> Bool {
        capture.projectSessionID == projectSessionID
            && capture.mapID == mapID
            && capture.mapStateIdentity == ObjectIdentifier(mapState)
            && capture.mapIdentity == mapIdentity
            && capture.backgroundSessionIdentity == ObjectIdentifier(backgroundSession)
            && capture.settings == settings
            && capture.projectionType == projectionType
            && capture.projectionValue == projectionValue
            && capture.viewport == currentViewport
            && capture.worldPoint == currentWorldPoint
            && backgroundSession.matchesContext(mapID: capture.mapID,
                projectSessionID: capture.projectSessionID,
                projectionType: capture.projectionType,
                projectionValue: capture.projectionValue,
                viewport: capture.viewport,
                worldUnitsPerPixel: capture.worldUnitsPerPixel,
                settings: capture.settings)
    }
}

enum MapBlankContextMenuAction: Int {
    case copyHoveredTileJSON
}

struct MapBlankContextMenuItem: Equatable {
    let action: MapBlankContextMenuAction
    let titleKey: String
    let isEnabled: Bool
    let helpKey: String?
}

enum MapBlankContextMenuContract {
    static let groupTitleKey = "Copy to Clipboard..."

    /// The original map-level context callback contributes one clipboard
    /// command. Layer-wide copy/paste/export commands belong to feature/layer
    /// owners and must never appear for empty map space.
    static func items(for capture: MapBlankContextCapture) -> [MapBlankContextMenuItem] {
        [.init(action: .copyHoveredTileJSON,
            titleKey: "Hovered Tile as JSON Data",
            isEnabled: capture.canCopyHoveredTileJSON,
            helpKey: capture.canCopyHoveredTileJSON ? nil
                : "Turn on OpenStreetMap background tiles and wait for the current map context before copying tile data.")]
    }
}
