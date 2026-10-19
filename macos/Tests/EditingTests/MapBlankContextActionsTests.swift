import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
struct MapBlankContextActionsTests {
    @Test
    func capturePinsTheExactCameraWorldPointAndBackgroundSession() throws {
        let mapID = UUID()
        let mapState = MapState(kind: .buildable, id: mapID)
        let settings = BackgroundMapSettings(areBackgroundMapsOn: true,
            isOpenStreetMapOn: true, isSatelliteImageryOn: false,
            isShadedReliefOn: false, osmStyle: "basic", density: 1,
            showLabels: true, satelliteOpacity: 1)
        let projectSessionID = UUID()
        let session = makeBackgroundSession()
        session.settings = settings
        let identity = mapIdentity(mapID: mapID, revision: "camera-1")
        let transform = MapTransform(points: [.init(x: 0, y: 0), .init(x: 100, y: 100)],
            size: CGSize(width: 240, height: 160), scale: 2,
            offset: CGSize(width: 14, height: -9))
        let location = CGPoint(x: 72.5, y: 51.25)
        let viewport = try #require(MapBlankContextCapture.viewport(transform: transform))
        session.updateViewport(mapID: mapID, projectSessionID: projectSessionID,
            projectionType: "Projected", projectionValue: "EPSG:26910",
            viewport: viewport, worldUnitsPerPixel: 1 / Double(transform.factor))
        let capture = try #require(MapBlankContextCapture.make(
            projectSessionID: projectSessionID, mapID: mapID, mapState: mapState,
            mapIdentity: identity, backgroundSession: session,
            settings: settings, projectionType: "Projected", projectionValue: "EPSG:26910",
            location: location, transform: transform))

        #expect(capture.worldPoint == transform.world(location))
        #expect(capture.worldUnitsPerPixel == 1 / Double(transform.factor))
        #expect(capture.viewport == MapBlankContextCapture.viewport(transform: transform))
        #expect(capture.backgroundSessionIdentity == ObjectIdentifier(session))
        #expect(capture.canCopyHoveredTileJSON)
        let items = MapBlankContextMenuContract.items(for: capture)
        #expect(items.count == 1)
        #expect(items.first?.action == .copyHoveredTileJSON)
        #expect(items.first?.titleKey == "Hovered Tile as JSON Data")
        #expect(items.first?.isEnabled == true)
    }

    @Test
    func asyncClipboardCurrentnessRejectsOwnerSourceViewportAndPointChanges() throws {
        let mapID = UUID()
        let projectSessionID = UUID()
        let mapState = MapState(kind: .buildable, id: mapID)
        let settings = BackgroundMapSettings(areBackgroundMapsOn: true,
            isOpenStreetMapOn: true, isSatelliteImageryOn: false,
            isShadedReliefOn: false, osmStyle: "basic", density: 1,
            showLabels: true, satelliteOpacity: 1)
        let session = makeBackgroundSession()
        session.settings = settings
        let identity = mapIdentity(mapID: mapID, revision: "camera-1")
        let transform = MapTransform(points: [.init(x: -20, y: -10), .init(x: 80, y: 90)],
            size: CGSize(width: 400, height: 260), scale: 1.25,
            offset: CGSize(width: 0, height: 0))
        let location = CGPoint(x: 180, y: 90)
        let viewport = try #require(MapBlankContextCapture.viewport(transform: transform))
        session.updateViewport(mapID: mapID, projectSessionID: projectSessionID,
            projectionType: "Projected", projectionValue: "EPSG:26910",
            viewport: viewport, worldUnitsPerPixel: 1 / Double(transform.factor))
        let capture = try #require(MapBlankContextCapture.make(
            projectSessionID: projectSessionID, mapID: mapID, mapState: mapState,
            mapIdentity: identity, backgroundSession: session, settings: settings,
            projectionType: "Projected", projectionValue: "EPSG:26910",
            location: location, transform: transform))
        let currentViewport = MapBlankContextCapture.viewport(transform: transform)
        let currentPoint = transform.world(location)

        #expect(MapBlankContextCurrentness.matches(capture,
            projectSessionID: projectSessionID, mapID: mapID, mapState: mapState,
            mapIdentity: identity, backgroundSession: session, settings: settings,
            projectionType: "Projected", projectionValue: "EPSG:26910", currentViewport: currentViewport,
            currentWorldPoint: currentPoint))
        #expect(!MapBlankContextCurrentness.matches(capture,
            projectSessionID: UUID(), mapID: mapID, mapState: mapState,
            mapIdentity: identity, backgroundSession: session, settings: settings,
            projectionType: "Projected", projectionValue: "EPSG:26910", currentViewport: currentViewport,
            currentWorldPoint: currentPoint))
        #expect(!MapBlankContextCurrentness.matches(capture,
            projectSessionID: projectSessionID, mapID: mapID, mapState: mapState,
            mapIdentity: mapIdentity(mapID: mapID, revision: "camera-2"),
            backgroundSession: session, settings: settings,
            projectionType: "Projected", projectionValue: "EPSG:26910",
            currentViewport: currentViewport, currentWorldPoint: currentPoint))
        #expect(!MapBlankContextCurrentness.matches(capture,
            projectSessionID: projectSessionID, mapID: mapID, mapState: mapState,
            mapIdentity: identity, backgroundSession: makeBackgroundSession(),
            settings: settings, projectionType: "Projected", projectionValue: "EPSG:26910",
            currentViewport: currentViewport,
            currentWorldPoint: currentPoint))

        var changedSettings = settings
        changedSettings.osmStyle = "streets"
        #expect(!MapBlankContextCurrentness.matches(capture,
            projectSessionID: projectSessionID, mapID: mapID, mapState: mapState,
            mapIdentity: identity, backgroundSession: session, settings: changedSettings,
            projectionType: "Projected", projectionValue: "EPSG:26910", currentViewport: currentViewport,
            currentWorldPoint: currentPoint))

        let panned = MapTransform(points: [.init(x: -20, y: -10), .init(x: 80, y: 90)],
            size: transform.size, scale: 1.25,
            offset: CGSize(width: 10, height: 0))
        #expect(!MapBlankContextCurrentness.matches(capture,
            projectSessionID: projectSessionID, mapID: mapID, mapState: mapState,
            mapIdentity: identity, backgroundSession: session, settings: settings,
            projectionType: "Projected", projectionValue: "EPSG:26910",
            currentViewport: MapBlankContextCapture.viewport(transform: panned),
            currentWorldPoint: panned.world(location)))
        #expect(!MapBlankContextCurrentness.matches(capture,
            projectSessionID: projectSessionID, mapID: mapID, mapState: mapState,
            mapIdentity: identity, backgroundSession: session, settings: settings,
            projectionType: "Projected", projectionValue: "EPSG:26910", currentViewport: currentViewport,
            currentWorldPoint: .init(x: currentPoint.x + 1, y: currentPoint.y)))
    }

    @Test
    func popupCanBeBuiltForBlankAreasWithoutInventingAFeatureOwner() throws {
        let mapID = UUID()
        let mapState = MapState(kind: .buildable, id: mapID)
        let session = makeBackgroundSession()
        let transform = MapTransform(points: [.init(x: 0, y: 0), .init(x: 1, y: 1)],
            size: CGSize(width: 100, height: 100), scale: 1, offset: .zero)
        let capture = try #require(MapBlankContextCapture.make(
            projectSessionID: UUID(), mapID: mapID, mapState: mapState,
            mapIdentity: nil, backgroundSession: session,
            settings: session.settings, projectionType: "", projectionValue: "",
            location: CGPoint(x: 50, y: 50), transform: transform))

        #expect(capture.mapID == mapID)
        #expect(capture.mapIdentity == nil)
        #expect(capture.worldPoint == transform.world(CGPoint(x: 50, y: 50)))
        #expect(!capture.canCopyHoveredTileJSON)
        let items = MapBlankContextMenuContract.items(for: capture)
        #expect(items.count == 1)
        #expect(items.first?.action == .copyHoveredTileJSON)
        #expect(items.first?.isEnabled == false)
        #expect(items.first?.helpKey != nil)
    }

    private func mapIdentity(mapID: UUID, revision: String) -> MapTreeMapIdentity {
        MapTreeMapIdentity(projectPath: "/tmp/project.prj", projectXml: "<Project />",
            projectXmlSHA: String(repeating: "A", count: 64), mapID: mapID.uuidString,
            mapIndex: 0, mapName: "Project Map", mapType: "Buildable",
            expectedVisualizationRevision: revision)
    }

    private func makeBackgroundSession() -> BackgroundMapSession {
        BackgroundMapSession(renderRequest: { request in
            BackgroundMapRenderResult(requestID: request.requestID,
                mapID: request.mapID, projectSessionID: request.projectSessionID,
                viewport: request.viewport, rasters: [], features: [], labels: [],
                sources: [], osmBackgroundColor: nil)
        })
    }
}
