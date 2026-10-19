import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import RASWorkspaceCore
import XCTest

final class BoundaryLineVisualizationTests: XCTestCase {
    func testStylePublicationKeepsMapScopeEmbeddedResultsConditionsAndPendingViews() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("Boundary.ras")
        let visual = project.deletingPathExtension().appendingPathExtension("vis")
        let tree = """
        <Tree><Nodes><Node Type="Folder" Name="Inputs"><Node Type="BoundaryCondition" Name="River">
        <Node Type="BoundaryConditionLineLayer" Name="Boundary Condition Lines" Future="keep">
        <Symbology ID="BC_Line_Symbology" PenColor="#FF123456" PenWidth="2.5" Future="style">
        <PenWidthConditions><Condition Column="FID" Operator="Equal" Threshold="0" Result="5"/></PenWidthConditions><Unknown Keep="yes"/>
        </Symbology></Node></Node></Node>
        <Node Type="Result" Name="Stored"><Node Type="BoundaryCondition" Name="River"><Node Type="BoundaryConditionLineLayer"><Symbology ID="BC_Line_Symbology" PenWidth="9"/></Node></Node></Node>
        </Nodes></Tree>
        """
        try Data("<Ras><Maps><Map Name='A' Type='Project'>\(tree)</Map><Map Name='A' Type='Buildable'>\(tree)</Map></Maps><Views/><UML Keep='yes'/></Ras>".utf8).write(to: visual)
        let document = try VisualizationDocument(projectURL: project)
        var settings = try document.boundaryLineVisualSettings(mapIndex: 1, boundaryName: "River")
        XCTAssertEqual(settings.line.penColor, "#FF123456")
        XCTAssertTrue(settings.hasConditionalOverrides)
        settings.line.penColor = "#80112233"; settings.line.penWidth = 4
        settings.vertex.fillColor = "#40123456"; settings.vertex.pointSize = 8
        try document.add(.init(name: "Pending", lowerLeft: .init(x: 0, y: 0), upperRight: .init(x: 5, y: 5)))
        try document.saveBoundaryLineVisualSettings(settings, mapIndex: 1, boundaryName: "River")
        let reopened = try VisualizationDocument(projectURL: project)
        XCTAssertEqual(try reopened.boundaryLineVisualSettings(mapIndex: 1, boundaryName: "River"), settings)
        XCTAssertEqual(try reopened.boundaryLineVisualSettings(mapIndex: 0, boundaryName: "River").line.penWidth, 2.5)
        XCTAssertTrue(document.modified)
        XCTAssertEqual(document.views.first?.name, "Pending")
        XCTAssertTrue(reopened.views.isEmpty)
        let xml = try XMLDocument(data: Data(contentsOf: visual))
        XCTAssertEqual(try xml.nodes(forXPath: "//Node[@Type='Result']//Symbology[@PenWidth='9']").count, 2)
        XCTAssertEqual(try xml.nodes(forXPath: "//PenWidthConditions/Condition[@Result='5']").count, 2)
        XCTAssertEqual(try xml.nodes(forXPath: "//Unknown[@Keep='yes']").count, 2)
        XCTAssertEqual(try xml.nodes(forXPath: "//Symbology[@Future='style']").count, 2)
        XCTAssertEqual(try xml.nodes(forXPath: "/Ras/UML[@Keep='yes']").count, 1)
        try document.save()
        XCTAssertEqual(try VisualizationDocument(projectURL: project).views.first?.name, "Pending")
    }

    func testExternalChangeAndAmbiguousContextsCannotOverwriteSource() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("Boundary.ras")
        let visual = project.deletingPathExtension().appendingPathExtension("vis")
        let duplicate = Data("<Ras><Maps><Map Name='M' Type='Project'><Tree><Nodes><Node Type='BoundaryCondition' Name='River'/><Node Type='BoundaryCondition' Name='River'/></Nodes></Tree></Map></Maps></Ras>".utf8)
        try duplicate.write(to: visual)
        let document = try VisualizationDocument(projectURL: project)
        XCTAssertThrowsError(try document.boundaryLineVisualSettings(mapIndex: 0, boundaryName: "River"))
        XCTAssertThrowsError(try document.saveBoundaryLineVisualSettings(.init(), mapIndex: 0, boundaryName: "River"))
        XCTAssertEqual(try Data(contentsOf: visual), duplicate)
        let external = Data("<Ras><External/></Ras>".utf8)
        try external.write(to: visual)
        XCTAssertThrowsError(try document.boundaryLineVisualSettings(mapIndex: 0, boundaryName: "River"))
        XCTAssertThrowsError(try document.saveBoundaryLineVisualSettings(.init(), mapIndex: 0, boundaryName: "River"))
        XCTAssertEqual(try Data(contentsOf: visual), external)
    }

    func testFirstPublicationUsesOriginalSchemaAndRejectsInvalidDraftBeforeWriting() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("Boundary.ras")
        let visual = project.deletingPathExtension().appendingPathExtension("vis")
        let document = try VisualizationDocument(projectURL: project)
        var invalid = BoundaryLineVisualSettings()
        invalid.line.penWidth = .nan
        XCTAssertThrowsError(try document.saveBoundaryLineVisualSettings(invalid, mapIndex: 0, boundaryName: "River"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: visual.path))
        invalid = .init(); invalid.vertex.fillColor = "#red"
        XCTAssertThrowsError(try document.saveBoundaryLineVisualSettings(invalid, mapIndex: 0, boundaryName: "River"))
        try document.saveBoundaryLineVisualSettings(.init(), mapIndex: 0, boundaryName: "River")
        XCTAssertFalse(FileManager.default.fileExists(atPath: visual.path))
        var custom = BoundaryLineVisualSettings()
        custom.line.penWidth = 7
        custom.vertex.pointSize = 8
        try document.saveBoundaryLineVisualSettings(custom, mapIndex: 0, boundaryName: "River")
        let reopened = try VisualizationDocument(projectURL: project)
        XCTAssertEqual(reopened.maps, [.init(index: 0, name: "Map", type: "Project")])
        XCTAssertEqual(try reopened.boundaryLineVisualSettings(mapIndex: 0, boundaryName: "River"), custom)
        let xml = try XMLDocument(data: Data(contentsOf: visual))
        XCTAssertEqual(try xml.nodes(forXPath: "/Ras/Maps/Map/Tree/Nodes/Node[@Type='BoundaryCondition']/Node[@Type='BoundaryConditionLineLayer']/Symbology").count, 2)
        try document.saveBoundaryLineVisualSettings(.init(), mapIndex: 0, boundaryName: "River")
        let reset = try XMLDocument(data: Data(contentsOf: visual))
        XCTAssertTrue(try reset.nodes(forXPath: "//Symbology").isEmpty)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
