import CryptoKit
import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@Suite
struct MapHoverModelVectorCaptureTests {
    @Test
    func culvertCaptureBindsVisibleSourceAndReplaysTheExactParentDraft() throws {
        let fixture = try makeCulvertFixture()
        let draftText = "<Geometry draft='edited' />"
        let draft = GeometryCulvertSnapshot(revision: fixture.revision,
            draftState: draftText, canEdit: true, isDirty: true,
            barrels: emptyTable("barrel"), barrelProperties: emptyTable("barrel"),
            openingProperties: emptyTable("opening"), associatedTerrainName: nil, profiles: [])

        let capture = try #require(MapHoverModelVectorCaptureBuilder.culvertBarrel(
            row: fixture.row, source: fixture.source, model: fixture.model,
            culvertSnapshot: draft))
        #expect(capture.ownerMode.rawValue == "parentDraft")
        #expect(canonical(capture.sourcePath) == canonical(fixture.path))
        #expect(capture.sourceRevision == fixture.revision)
        #expect(capture.culvertDraftState == draftText)
        #expect(capture.culvertDraftSHA256 == sha256(draftText))
        #expect(capture.model?.assetPath == fixture.path)
        #expect(capture.geometryNode == fixture.capture.geometryNode)
        #expect(capture.geometryContextToken == fixture.source.contextToken)
    }

    @Test
    func culvertCaptureRejectsStaleProjectSourceAndNonVisibleRows() throws {
        let fixture = try makeCulvertFixture()
        let wrongProject = GeometryCulvertModelRequest(assetPath: fixture.path,
            kind: "Geometry", projectPath: fixture.map.projectPath,
            projectXml: "<DifferentProject />")
        #expect(MapHoverModelVectorCaptureBuilder.culvertBarrel(
            row: fixture.row, source: fixture.source, model: wrongProject).map { _ in false } ?? true)

        var hiddenRow = fixture.row
        hiddenRow.payloadLayerIDs = []
        #expect(MapHoverModelVectorCaptureBuilder.culvertBarrel(
            row: hiddenRow, source: fixture.source, model: fixture.model).map { _ in false } ?? true)

        let staleDraft = GeometryCulvertSnapshot(revision: String(repeating: "D", count: 64),
            draftState: "stale", canEdit: true, isDirty: true,
            barrels: emptyTable("barrel"), barrelProperties: emptyTable("barrel"),
            openingProperties: emptyTable("opening"), associatedTerrainName: nil, profiles: [])
        #expect(MapHoverModelVectorCaptureBuilder.culvertBarrel(
            row: fixture.row, source: fixture.source, model: fixture.model,
            culvertSnapshot: staleDraft).map { _ in false } ?? true)
    }

    @Test
    func resultCulvertCaptureCarriesExactSlotZeroOwner() throws {
        let fixture = try makeCulvertFixture(resultOwned: true)
        let capture = try #require(MapHoverModelVectorCaptureBuilder.culvertBarrel(
            row: fixture.row, source: fixture.source, model: nil))

        #expect(capture.ownerMode.rawValue == "resultSource")
        #expect(capture.model.map { _ in false } ?? true)
        #expect(capture.resultOwner?.selectionIndex == 0)
        #expect(capture.resultOwner.map { canonical($0.selectedResultPath) } == canonical(fixture.path))
        #expect(capture.resultOwner?.selectedResultRevision == fixture.revision)

        let wrongOwnerLocator = withParentResult(fixture.row.locator,
            path: "/tmp/map-hover/wrong-result.hdf", revision: fixture.revision)
        var wrongOwnerRow = replacingRow(fixture.row, locator: wrongOwnerLocator)
        wrongOwnerRow.payloadLayerIDs = [fixture.capture.identity + "|" + wrongOwnerRow.locator.sourceIdentity]
        var source = fixture.source
        var snapshot = try #require(source.snapshot)
        snapshot = replacingCulvertLocator(in: snapshot, with: wrongOwnerRow.locator)
        source.snapshot = snapshot
        #expect(MapHoverModelVectorCaptureBuilder.culvertBarrel(
            row: wrongOwnerRow, source: source, model: nil).map { _ in false } ?? true)
    }

    @Test
    func boundaryCapturePreservesSourceLineIdentityOrderAndCoordinates() throws {
        let mapID = UUID()
        let (map, projectXMLSHA) = makeMap(mapID: mapID)
        let path = "/tmp/map-hover/boundary.g01"
        let revision = String(repeating: "E", count: 64)
        let sourceState = "boundary-state-v1"
        let locator = CatalogTreeNodeLocator(rootName: "Boundary Conditions",
            nodeType: "BoundaryCondition", nodeName: "Boundary A", nodePath: [0], assetID: path)
        let capture = try BoundaryMapCapture(projectSessionID: UUID(),
            mapWorkflowIdentity: "boundary-workflow", map: map,
            boundaryNode: locator, sourcePath: path, sourceRevision: revision,
            boundarySourceState: sourceState, isChecked: true, effectiveVisible: true)
        let line = BoundaryMapLine(id: "line:stable-17", sourceOrdinal: 17,
            name: "Upstream", coordinates: [MapPoint(x: 1, y: 2), MapPoint(x: 3, y: 4)])
        let source = BoundaryMapSourceState(capture: capture, contextToken: "boundary-context",
            boundarySourceState: sourceState, lines: [line], status: .available, diagnostic: nil)

        let result = try #require(MapHoverModelVectorCaptureBuilder.boundaryConditionLine(source: source))
        #expect(result.rendererKind.rawValue == "boundaryConditionLine")
        #expect(result.ownerMode.rawValue == "savedSource")
        #expect(result.model?.kind == "Boundary Conditions")
        #expect(result.model?.projectXml.map { sha256($0) } == projectXMLSHA.lowercased())
        #expect(result.boundaryLines?.map(\.id) == [line.id])
        #expect(result.boundaryLines?.map(\.sourceOrdinal) == [line.sourceOrdinal])
        #expect(result.boundaryLines?.first?.coordinates == [
            MapHoverCoordinate(x: 1, y: 2), MapHoverCoordinate(x: 3, y: 4)
        ])

        let invalidLine = BoundaryMapLine(id: "line:invalid", sourceOrdinal: 18,
            name: "Invalid", coordinates: [MapPoint(x: .nan, y: 0), MapPoint(x: 1, y: 1)])
        let invalidSource = BoundaryMapSourceState(capture: capture, contextToken: "boundary-context",
            boundarySourceState: sourceState, lines: [line, invalidLine], status: .available, diagnostic: nil)
        #expect(MapHoverModelVectorCaptureBuilder.boundaryConditionLine(source: invalidSource)
            .map { _ in false } ?? true)
    }

    private struct CulvertFixture {
        let map: MapTreeMapIdentity
        let capture: ProjectGeometryMapCapture
        let source: ProjectGeometryMapSourceState
        let row: MapSourceRenderRecord
        let model: GeometryCulvertModelRequest
        let path: String
        let revision: String
    }

    private func makeCulvertFixture(resultOwned: Bool = false) throws -> CulvertFixture {
        let mapID = UUID()
        let (map, _) = makeMap(mapID: mapID)
        let path = resultOwned ? "/tmp/map-hover/result.hdf" : "/tmp/map-hover/geometry.hdf"
        let revision = String(repeating: resultOwned ? "F" : "A", count: 64)
        let resultOwner: MapResultGeometryOwner?
        let geometryNode: CatalogTreeNodeLocator
        if resultOwned {
            let resultNode = CatalogTreeNodeLocator(rootName: "Results", nodeType: "Result",
                nodeName: "Plan 01", nodePath: [0, 1], assetID: path)
            resultOwner = try MapResultGeometryOwner(resultNode: resultNode,
                contextToken: "result-context", selectionOverrides: nil,
                selectionIndex: 0, selectedResultPath: path,
                selectedResultRevision: revision)
            geometryNode = CatalogTreeNodeLocator(rootName: "Results", nodeType: "Geometry",
                nodeName: "Geometry A", nodePath: [0, 1, 0], assetID: path,
                parentResultNodeType: "Result", parentResultAssetID: path,
                parentResultNodePath: [0, 1], parentResultNodeName: "Plan 01",
                parentResultRevision: revision)
        } else {
            resultOwner = nil
            geometryNode = CatalogTreeNodeLocator(rootName: "Geometries", nodeType: "Geometry",
                nodeName: "Geometry A", nodePath: [0, 0], assetID: path)
        }
        let projectCapture = try ProjectGeometryMapCapture(projectSessionID: UUID(),
            mapID: mapID, mapWorkflowIdentity: "geometry-workflow", map: map,
            geometryNode: geometryNode, geometryAssetPath: path,
            geometryName: "Geometry A", resultOwner: resultOwner)
        let child = CatalogTreeNodeLocator(rootName: geometryNode.rootName,
            nodeType: "CulvertBarrelLayer", nodeName: "CulvertBarrelLayer",
            nodePath: (geometryNode.nodePath ?? []) + [0], assetID: path,
            parentGeometryAssetID: path, parentGeometryNodePath: geometryNode.nodePath,
            parentGeometryNodeName: geometryNode.nodeName,
            parentResultNodeType: resultOwner?.resultNode.nodeType,
            parentResultAssetID: resultOwner?.selectedResultPath,
            parentResultNodePath: resultOwner?.resultNode.nodePath,
            parentResultNodeName: resultOwner?.resultNode.nodeName,
            parentResultRevision: resultOwner?.selectedResultRevision)
        let extent = GeometryTopologyExtent(minX: 0, minY: 0, maxX: 10, maxY: 10)
        let emptyState = MapGeometryLayerState(nodeID: nil, locator: nil,
            isChecked: false, effectiveVisible: false, status: .empty, diagnostic: nil)
        let layerState = MapGeometryLayerState(nodeID: "culvert-node", locator: child,
            isChecked: true, effectiveVisible: true, status: .available, diagnostic: nil)
        let snapshot = MapGeometrySnapshot(mapID: map.mapID, mapIndex: map.mapIndex,
            mapName: map.mapName, mapType: map.mapType, projectCanonicalPath: map.projectPath,
            projectRevision: "project-revision", projectXmlSHA: map.projectXmlSHA,
            visualizationRevision: map.expectedVisualizationRevision,
            contextToken: "geometry-context", geometryNode: geometryNode,
            geometryName: "Geometry A", geometryCanonicalPath: path,
            geometryRevision: revision, geometryChecked: true, geometryEffectiveVisible: true,
            extent: extent, planNodes: [], topologyState: emptyState,
            flowAreasState: emptyState, culvertsState: layerState,
            topology: nil, flowAreas: nil, culverts: nil)
        var source = ProjectGeometryMapSourceState(capture: projectCapture)
        source.snapshot = snapshot
        let row = MapSourceRenderRecord(mapID: mapID, nodeID: "culvert-node", locator: child,
            familyOrder: 0, treeOrdinal: 0, activeLayerOrdinal: 0,
            contextIdentity: "culvert-row-context", payloadKind: "CulvertBarrelLayer",
            payloadLayerIDs: [projectCapture.identity + "|" + child.sourceIdentity],
            isChecked: true, isEffectivelyVisible: true, isStatic: false,
            staticInsertionAfterRaster: false)
        let model = GeometryCulvertModelRequest(assetPath: path, kind: "Geometry",
            projectPath: map.projectPath, projectXml: map.projectXml)
        return CulvertFixture(map: map, capture: projectCapture, source: source,
            row: row, model: model, path: path, revision: revision)
    }

    private func makeMap(mapID: UUID) -> (MapTreeMapIdentity, String) {
        let xml = "<Project />"
        let digest = sha256(xml)
        let map = MapTreeMapIdentity(projectPath: "/tmp/map-hover/Model.ras",
            projectXml: xml, projectXmlSHA: digest.uppercased(), mapID: mapID.uuidString,
            mapIndex: 0, mapName: "Map A", mapType: "Project",
            expectedVisualizationRevision: String(repeating: "C", count: 64))
        return (map, digest)
    }

    private func emptyTable(_ featureKind: String) -> GeometryCulvertFeatureTable {
        GeometryCulvertFeatureTable(featureKind: featureKind, columns: [], editableFields: [], rows: [])
    }

    private func replacingCulvertLocator(in snapshot: MapGeometrySnapshot,
                                         with locator: CatalogTreeNodeLocator) -> MapGeometrySnapshot {
        MapGeometrySnapshot(mapID: snapshot.mapID, mapIndex: snapshot.mapIndex,
            mapName: snapshot.mapName, mapType: snapshot.mapType,
            projectCanonicalPath: snapshot.projectCanonicalPath,
            projectRevision: snapshot.projectRevision, projectXmlSHA: snapshot.projectXmlSHA,
            visualizationRevision: snapshot.visualizationRevision,
            contextToken: snapshot.contextToken, geometryNode: snapshot.geometryNode,
            geometryName: snapshot.geometryName, geometryCanonicalPath: snapshot.geometryCanonicalPath,
            geometryRevision: snapshot.geometryRevision, geometryChecked: snapshot.geometryChecked,
            geometryEffectiveVisible: snapshot.geometryEffectiveVisible, extent: snapshot.extent,
            planNodes: snapshot.planNodes, topologyState: snapshot.topologyState,
            flowAreasState: snapshot.flowAreasState,
            culvertsState: MapGeometryLayerState(nodeID: "culvert-node", locator: locator,
                isChecked: true, effectiveVisible: true, status: .available, diagnostic: nil),
            topology: snapshot.topology, flowAreas: snapshot.flowAreas, culverts: snapshot.culverts)
    }

    private func replacingRow(_ row: MapSourceRenderRecord,
                              locator: CatalogTreeNodeLocator) -> MapSourceRenderRecord {
        MapSourceRenderRecord(mapID: row.mapID, nodeID: row.nodeID, locator: locator,
            familyOrder: row.familyOrder, treeOrdinal: row.treeOrdinal,
            activeLayerOrdinal: row.activeLayerOrdinal, contextIdentity: row.contextIdentity,
            payloadKind: row.payloadKind, payloadLayerIDs: row.payloadLayerIDs,
            isChecked: row.isChecked, isEffectivelyVisible: row.isEffectivelyVisible,
            isStatic: row.isStatic, staticInsertionAfterRaster: row.staticInsertionAfterRaster)
    }

    private func canonical(_ path: String) -> String {
        SourceFilePaths.canonical(URL(fileURLWithPath: path))
    }

    private func withParentResult(_ locator: CatalogTreeNodeLocator, path: String,
                                  revision: String) -> CatalogTreeNodeLocator {
        CatalogTreeNodeLocator(rootName: locator.rootName, nodeType: locator.nodeType,
            nodeName: locator.nodeName, nodePath: locator.nodePath, assetID: locator.assetID,
            parentGeometryAssetID: locator.parentGeometryAssetID,
            parentGeometryNodePath: locator.parentGeometryNodePath,
            parentGeometryNodeName: locator.parentGeometryNodeName,
            parentResultNodeType: "Result", parentResultAssetID: path,
            parentResultNodePath: [0, 1], parentResultNodeName: "Plan 01",
            parentResultRevision: revision)
    }

    private func sha256(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
