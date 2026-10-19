import Foundation
import CryptoKit
#if canImport(FoundationXML)
import FoundationXML
#endif
import RASWorkspaceCore
import XCTest

final class VisualizationDocumentTests: XCTestCase {
    func testRemovingResultReferencesPreservesOtherResultsUnknownXMLAndUnsavedViews() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("Results.ras")
        let visual = directory.appendingPathComponent("Results.vis")
        let original = """
        <Ras Custom="keep"><Maps><Map Name="Same" Type="Project"><Tree><Nodes>
        <Node Type="Folder" Name="Results"><Node Type="Result" Name="Delete 中文"><Node Type="Geometry" Name="Embedded"/></Node><Node Type="Result" Name="Keep"/><Node Type="Geometry" Name="Delete 中文"/></Node>
        <Node Type="MultiResult" Name="Plan"><Unknown Keep="yes"/></Node>
        </Nodes></Tree></Map><Map Name="Same" Type="Buildable"><Tree><Nodes><Node Type="Result" Name="Delete 中文"/></Nodes></Tree></Map></Maps><Views/><UML Keep="yes"/><Unknown/></Ras>
        """
        try Data(original.utf8).write(to: visual)
        let document = try VisualizationDocument(projectURL: project)
        try document.add(SavedMapView(name: "Unsaved view", lowerLeft: .init(x: 0, y: 0), upperRight: .init(x: 10, y: 10)))
        let revision = document.sourceRevision
        XCTAssertEqual(try document.removeResultReferences(named: "Delete 中文"), 2)
        XCTAssertNotEqual(document.sourceRevision, revision)
        XCTAssertTrue(document.modified)
        XCTAssertEqual(document.views.first?.name, "Unsaved view")
        let published = try XMLDocument(data: Data(contentsOf: visual))
        XCTAssertEqual(try published.nodes(forXPath: "//Node[@Type='Result' and @Name='Delete 中文']").count, 0)
        XCTAssertEqual(try published.nodes(forXPath: "//Node[@Type='Result' and @Name='Keep']").count, 1)
        XCTAssertEqual(try published.nodes(forXPath: "//Node[@Type='Geometry' and @Name='Delete 中文']").count, 1)
        XCTAssertEqual(try published.nodes(forXPath: "//Node[@Type='MultiResult']/Unknown[@Keep='yes']").count, 1)
        XCTAssertFalse(String(decoding: try Data(contentsOf: visual), as: UTF8.self).contains("Unsaved view"))
        try document.save()
        let reopened = try VisualizationDocument(projectURL: project)
        XCTAssertEqual(reopened.views.first?.name, "Unsaved view")
        XCTAssertEqual(try document.removeResultReferences(named: "Delete 中文"), 0)
    }

    func testNewExternalMapDocumentCanBeAcceptedWithoutPublishingPendingViews() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("New.ras")
        let visual = directory.appendingPathComponent("New.vis")
        let document = try VisualizationDocument(projectURL: project)
        try document.add(SavedMapView(name: "Draft", lowerLeft: .init(x: 1, y: 2), upperRight: .init(x: 4, y: 6)))
        XCTAssertNil(document.sourceRevision)
        let bytes = Data("<Ras><Maps><Map Name='Created' Type='Buildable'><Tree><Nodes/></Tree></Map></Maps><Views/><Future/></Ras>".utf8)
        try bytes.write(to: visual)
        let revision = SHA256.hash(data: bytes).map { String(format: "%02X", $0) }.joined()
        try document.acceptExternalMapChange(expectedPreviousRevision: nil, newRevision: revision)
        XCTAssertEqual(document.maps.first?.name, "Created")
        XCTAssertEqual(document.views.first?.name, "Draft")
        XCTAssertTrue(document.modified)
        XCTAssertEqual(try Data(contentsOf: visual), bytes)
        // An old missing-file baseline cannot be accepted twice.
        XCTAssertThrowsError(try document.acceptExternalMapChange(expectedPreviousRevision: nil, newRevision: revision))
        try document.save()
        XCTAssertEqual(try VisualizationDocument(projectURL: project).views.first?.name, "Draft")
    }

    func testOriginalViewSchemaRoundTripPreservesOtherSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("项目.ras")
        let visual = directory.appendingPathComponent("项目.vis")
        try Data("<Ras><Maps Maps='Original'><Map Type='Project'/></Maps><UML Keep='yes'/><Views><View Keep='original'><Extent Left='10' Top='50' Right='30' Bottom='20' Extra='keep'/><Bind>Shift+V</Bind><Name>原视图</Name><Unknown>保留</Unknown></View><View><Name>Malformed but preserved</Name></View></Views><Symbology><Custom/></Symbology></Ras>".utf8).write(to: visual)
        let document = try VisualizationDocument(projectURL: project)
        XCTAssertEqual(document.views.count, 1)
        var view = try XCTUnwrap(document.views.first)
        XCTAssertEqual(view.lowerLeft, MapPoint(x: 10, y: 20))
        XCTAssertEqual(view.upperRight, MapPoint(x: 30, y: 50))
        view.name = "中文重命名"; view.upperRight = MapPoint(x: 100, y: 90)
        try document.update(view); try document.save()
        let restored = try VisualizationDocument(projectURL: project)
        XCTAssertEqual(restored.views.first?.name, "中文重命名")
        XCTAssertEqual(restored.views.first?.upperRight, MapPoint(x: 100, y: 90))
        XCTAssertEqual(restored.views.first?.shortcut, "Shift+V")
        let bytes = try String(contentsOf: visual, encoding: .utf8)
        let xml = try XMLDocument(xmlString: bytes)
        let root = try XCTUnwrap(xml.rootElement())
        XCTAssertEqual(root.elements(forName: "Maps").first?.attribute(forName: "Maps")?.stringValue, "Original")
        XCTAssertEqual(root.elements(forName: "UML").first?.attribute(forName: "Keep")?.stringValue, "yes")
        XCTAssertEqual(root.elements(forName: "Views").first?.elements(forName: "View").first?.elements(forName: "Extent").first?.attribute(forName: "Extra")?.stringValue, "keep")
        for preserved in ["保留", "Malformed but preserved", "<Custom"] { XCTAssertTrue(bytes.contains(preserved), preserved) }
    }

    func testExternalChangesPreventVisualizationOverwriteAndKeepDraft() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("Conflict.ras")
        let visual = directory.appendingPathComponent("Conflict.vis")
        let document = try VisualizationDocument(projectURL: project)
        try document.add(SavedMapView(name: "草稿", lowerLeft: MapPoint(x: 0, y: 0), upperRight: MapPoint(x: 1, y: 1)))
        let external = Data("<Ras><NewExternalSettings/></Ras>".utf8)
        try external.write(to: visual)
        XCTAssertThrowsError(try document.save())
        XCTAssertTrue(document.modified)
        XCTAssertEqual(document.views.first?.name, "草稿")
        XCTAssertEqual(try Data(contentsOf: visual), external)
    }

    func testDuplicateViewNamesAndInvalidExtentsAreRejected() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ras")
        let document = try VisualizationDocument(projectURL: project)
        try document.add(SavedMapView(name: "River", lowerLeft: MapPoint(x: 0, y: 0), upperRight: MapPoint(x: 3, y: 4)))
        XCTAssertThrowsError(try document.add(SavedMapView(name: " river ", lowerLeft: MapPoint(x: 0, y: 0), upperRight: MapPoint(x: 3, y: 4))))
        XCTAssertThrowsError(try document.add(SavedMapView(name: "Invalid", lowerLeft: MapPoint(x: 0, y: 0), upperRight: MapPoint(x: .infinity, y: 4))))
        XCTAssertThrowsError(try document.add(SavedMapView(name: "Collapsed", lowerLeft: MapPoint(x: 0, y: 0), upperRight: MapPoint(x: 0, y: 4))))
        document.remove(try XCTUnwrap(document.views.first).id)
        XCTAssertTrue(document.views.isEmpty)
    }

    func testCurrentVisRasterSourcesUseOrderedMapAndNodeIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("terrain"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("Maps.ras")
        let raster = directory.appendingPathComponent("terrain/elevation.tif")
        try Data([1, 2, 3]).write(to: raster)
        let visual = directory.appendingPathComponent("Maps.vis")
        let xml = """
        <Ras><Maps Maps="Hydro"><Map Name="Hydro" Type="Project"><Tree><Nodes>
        <Node Type="Group" Name="Terrain"><Node Type="MapLayer" MapType="SingleBandRasterMapLayer" Name="Elevation" Filename="unused.tif" FilenameRelative="terrain/elevation.tif"/></Node>
        </Nodes></Tree></Map><Map Name="Hydro" Type="Plan"><Tree><Nodes/></Tree></Map></Maps><Symbology/><Views/></Ras>
        """
        try Data(xml.utf8).write(to: visual)
        let document = try VisualizationDocument(projectURL: project)

        XCTAssertEqual(document.maps, [
            VisualizationMapIdentity(index: 0, name: "Hydro", type: "Project"),
            VisualizationMapIdentity(index: 1, name: "Hydro", type: "Plan")
        ])
        let sources = try document.singleBandRasterMapSources()
        let source = try XCTUnwrap(sources.first)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(source.mapIndex, 0)
        XCTAssertEqual(source.mapName, "Hydro")
        XCTAssertEqual(source.mapType, "Project")
        XCTAssertEqual(source.nodePath, [0, 0])
        XCTAssertEqual(source.sourcePath, raster.resolvingSymlinksInPath().path)
        XCTAssertEqual(source.id, "vis-map-0-node-0.0")
    }

    func testExternalRasterStyleChangePreservesUnsavedViewDraftAndChecksBothRevisions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("Style.ras")
        let visual = directory.appendingPathComponent("Style.vis")
        let original = Data("<Ras><Maps/><Symbology/><Views/></Ras>".utf8)
        try original.write(to: visual)
        let document = try VisualizationDocument(projectURL: project)
        try document.add(SavedMapView(name: "Unsaved view", lowerLeft: MapPoint(x: 0, y: 0), upperRight: MapPoint(x: 4, y: 5)))

        let external = Data("<Ras><Maps><Map Name=\"Updated\" Type=\"Project\"/></Maps><Symbology><CustomSymbology Name=\"Palette\"/></Symbology><Views/></Ras>".utf8)
        try external.write(to: visual)
        let oldRevision = SHA256.hash(data: original).map { String(format: "%02X", $0) }.joined()
        let newRevision = SHA256.hash(data: external).map { String(format: "%02X", $0) }.joined()
        try document.acceptExternalRasterSymbologyChange(expectedPreviousRevision: oldRevision, newRevision: newRevision)
        XCTAssertEqual(document.views.first?.name, "Unsaved view")
        XCTAssertTrue(document.modified)
        try document.save()

        let saved = try String(contentsOf: visual, encoding: .utf8)
        XCTAssertTrue(saved.contains("Name=\"Updated\""))
        XCTAssertTrue(saved.contains("Name=\"Palette\""))
        XCTAssertTrue(saved.contains("Unsaved view"))

        XCTAssertThrowsError(try document.acceptExternalRasterSymbologyChange(expectedPreviousRevision: oldRevision, newRevision: newRevision))
    }
    func testMeshDiagnosticsSettingsBelongToOneMapAndPreservePendingViews() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("Mesh.ras")
        let visual = directory.appendingPathComponent("Mesh.vis")
        let tree = "<Tree><Nodes><Node Type='Geometry' Name='几何'><Node Type='FlowAreaLayer' Name='Mesh' CheckMeshErrors='false' MaxFacesPerNode='8' Future='keep'/></Node><Node Type='Result' Name='Result'><Node Type='Geometry' Name='几何'><Node Type='FlowAreaLayer' CheckMeshErrors='false'/></Node></Node></Nodes></Tree>"
        try Data("<Ras><Maps><Map Name='A' Type='Project'>\(tree)</Map><Map Name='B' Type='Buildable'>\(tree)</Map></Maps><Views/><Unknown Value='keep'/></Ras>".utf8).write(to: visual)
        let document = try VisualizationDocument(projectURL: project)
        try document.add(SavedMapView(name: "Pending", lowerLeft: .init(x: 0, y: 0), upperRight: .init(x: 10, y: 10)))
        try document.saveMeshDiagnosticsSettings(.init(checkMeshErrors: true, maxFacesPerNode: 12), mapIndex: 1, geometryName: "几何")
        XCTAssertEqual(try document.meshDiagnosticsSettings(mapIndex: 0, geometryName: "几何"), .init())
        XCTAssertEqual(try document.meshDiagnosticsSettings(mapIndex: 1, geometryName: "几何"), .init(checkMeshErrors: true, maxFacesPerNode: 12))
        XCTAssertTrue(document.modified)
        XCTAssertEqual(document.views.first?.name, "Pending")
        let saved = try XMLDocument(data: Data(contentsOf: visual))
        XCTAssertTrue(try saved.nodes(forXPath: "//View").isEmpty)
        XCTAssertEqual(try saved.nodes(forXPath: "//Map[@Name='B']//Node[@Type='FlowAreaLayer' and @Future='keep' and @CheckMeshErrors='true' and @MaxFacesPerNode='12']").count, 1)
        XCTAssertEqual(try saved.nodes(forXPath: "//Node[@Type='Result']//Node[@Type='FlowAreaLayer' and @CheckMeshErrors='false']").count, 2)
        XCTAssertEqual(try saved.nodes(forXPath: "/Ras/Unknown[@Value='keep']").count, 1)
        try document.save()
        XCTAssertEqual(try VisualizationDocument(projectURL: project).views.first?.name, "Pending")
        let external = Data("<Ras><External/></Ras>".utf8)
        try external.write(to: visual)
        XCTAssertThrowsError(try document.saveMeshDiagnosticsSettings(.init(), mapIndex: 1, geometryName: "几何"))
        XCTAssertEqual(try Data(contentsOf: visual), external)
    }

    func testFirstMeshSettingsMaterializeOnlyTheSourceMapContext() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("New.ras")
        let document = try VisualizationDocument(projectURL: project)
        XCTAssertEqual(try document.meshDiagnosticsSettings(mapIndex: 0, geometryName: "几何"), .init())
        try document.saveMeshDiagnosticsSettings(.init(checkMeshErrors: true, maxFacesPerNode: 9), mapIndex: 0, geometryName: "几何")
        let reopened = try VisualizationDocument(projectURL: project)
        XCTAssertEqual(reopened.maps, [.init(index: 0, name: "Map", type: "Project")])
        XCTAssertEqual(try reopened.meshDiagnosticsSettings(mapIndex: 0, geometryName: "几何"), .init(checkMeshErrors: true, maxFacesPerNode: 9))
        XCTAssertThrowsError(try document.saveMeshDiagnosticsSettings(.init(maxFacesPerNode: 2), mapIndex: 0, geometryName: "几何"))
        XCTAssertThrowsError(try document.meshDiagnosticsSettings(mapIndex: 7, geometryName: "几何"))
    }

}
