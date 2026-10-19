import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import RASWorkspaceCore
import XCTest

final class VectorVisualSettingsTests: XCTestCase {
    func testGenericLayerReadAndSaveUseExactMapNodeAndPreserveAllSourceGroups() throws {
        let (directory, project, visual, identity) = try makePolylineFixture()
        defer { try? FileManager.default.removeItem(at: directory) }

        let document = try VisualizationDocument(projectURL: project)
        let defaults = polylineDefaults
        let snapshot = try document.vectorVisualSettings(identity: identity, defaults: defaults)
        XCTAssertEqual(snapshot.options.keys.sorted(), ["Polyline_Line_Symbology", "Polyline_Vertex_Symbology"])
        XCTAssertEqual(snapshot.options["Polyline_Line_Symbology"]?.values.penColor, "#FF123456")
        XCTAssertEqual(snapshot.options["Polyline_Line_Symbology"]?.values.penWidth, 2.5)
        XCTAssertEqual(snapshot.options["Polyline_Line_Symbology"]?.conditionGroups.map(\.field), VectorStyleField.allCases)
        XCTAssertEqual(snapshot.options["Polyline_Line_Symbology"]?.rules(for: .penColor).first?.comparison, "==")
        XCTAssertEqual(snapshot.options["Polyline_Line_Symbology"]?.rules(for: .penWidth).first?.comparison, ">")
        XCTAssertEqual(snapshot.options["Polyline_Line_Symbology"]?.rules(for: .fillColor).first?.comparison, "equals")
        XCTAssertEqual(snapshot.options["Polyline_Line_Symbology"]?.rules(for: .fillColor).first?.resultValue, "#FF010203")
        XCTAssertEqual(snapshot.options["Polyline_Vertex_Symbology"]?.values.pointSize, 8)

        try document.add(.init(name: "Unpublished view", lowerLeft: .init(x: 0, y: 0), upperRight: .init(x: 2, y: 3)))
        var changed = try XCTUnwrap(snapshot.options["Polyline_Line_Symbology"])
        changed.values.penColor = "#FFABCDEF"
        changed.values.penWidth = defaults["Polyline_Line_Symbology"]!.penWidth
        changed.conditionGroups[2].rules[0].resultValue = "#FF102030"
        try document.saveVectorVisualSettings(identity: identity,
            options: ["Polyline_Line_Symbology": changed], defaults: defaults,
            expectedRevision: snapshot.revision)

        XCTAssertTrue(document.modified)
        XCTAssertEqual(document.views.first?.name, "Unpublished view")
        let bytes = try Data(contentsOf: visual)
        let xml = try XMLDocument(data: bytes)
        XCTAssertEqual(try xml.nodes(forXPath: "/Ras/Maps/Map[1]/Tree/Nodes/Node[@Type='Root']/Node[@Type='Folder']/Node[@Type='MapLayer']/Symbology[@ID='Polyline_Line_Symbology']/@PenColor").first?.stringValue, "#FFABCDEF")
        XCTAssertEqual(try xml.nodes(forXPath: "/Ras/Maps/Map[1]/Tree/Nodes/Node[@Type='Root']/Node[@Type='Folder']/Node[@Type='MapLayer']/Symbology[@ID='Polyline_Line_Symbology']/@PenWidth").first?.stringValue, "2.0")
        XCTAssertEqual(try xml.nodes(forXPath: "/Ras/Maps/Map[1]/Tree/Nodes/Node[@Type='Root']/Node[@Type='Folder']/Node[@Type='MapLayer']/Symbology[@ID='Polyline_Line_Symbology']/@Future").first?.stringValue, "keep-style")
        XCTAssertEqual(try xml.nodes(forXPath: "//Symbology[@ID='Polyline_Line_Symbology']/Unknown[@Keep='yes']").count, 1)
        XCTAssertEqual(try xml.nodes(forXPath: "//PenWidthConditions/Condition[@Future='keep-rule']").count, 1)
        XCTAssertEqual(try xml.nodes(forXPath: "//PointSizeConditions/Condition[@Result='4']").count, 1)
        XCTAssertEqual(try xml.nodes(forXPath: "//PenColorConditions/Condition/@Operator").first?.stringValue, "Equal")
        XCTAssertEqual(try xml.nodes(forXPath: "//PenWidthConditions/Condition/@Operator").first?.stringValue, "GreaterThan")
        XCTAssertEqual(try xml.nodes(forXPath: "//FillColorConditions/Condition/@Operator").first?.stringValue, "StringEquals")
        XCTAssertEqual(try xml.nodes(forXPath: "/Ras/Maps/Map[2]/Tree/Nodes/Node[@Type='Root']/Node[@Type='Folder']/Node[@Type='MapLayer']/Symbology[@ID='Polyline_Line_Symbology']/@PenWidth").first?.stringValue, "9")
        XCTAssertEqual(try xml.nodes(forXPath: "/Ras/UML[@Keep='yes']").count, 1)
        XCTAssertEqual(try xml.nodes(forXPath: "/Ras/Future[@Keep='yes']").count, 1)
        XCTAssertTrue(try xml.nodes(forXPath: "/Ras/Views/View").isEmpty)

        let reopened = try VisualizationDocument(projectURL: project)
        let afterSave = try reopened.vectorVisualSettings(identity: identity, defaults: defaults)
        XCTAssertEqual(afterSave.options["Polyline_Line_Symbology"]?.values.penColor, "#FFABCDEF")
        XCTAssertEqual(afterSave.options["Polyline_Line_Symbology"]?.values.penWidth, 2)
        XCTAssertEqual(afterSave.options["Polyline_Line_Symbology"]?.rules(for: .fillColor).first?.resultValue, "#FF102030")
        XCTAssertEqual(afterSave.options["Polyline_Line_Symbology"]?.rules(for: .penColor).first?.column, "FID")
        XCTAssertTrue(reopened.views.isEmpty)
    }

    func testNoOpDoesNotMaterializeDefaultOverrides() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("NoOp.ras")
        let vector = directory.appendingPathComponent("points.geojson")
        let visual = project.deletingPathExtension().appendingPathExtension("vis")
        try Data("{}".utf8).write(to: vector)
        let xml = """
        <Ras><Maps><Map Name="M" Type="Project"><Tree><Nodes>
        <Node Type="Root" Name="Points"><Node Type="MapLayer" MapType="PointsVector" Name="Points" Filename="points.geojson" FilenameRelative="points.geojson"/></Node>
        </Nodes></Tree></Map></Maps><Views/><UML Keep="yes"/></Ras>
        """
        let original = Data(xml.utf8)
        try original.write(to: visual)
        let identity = VectorVisualNodeIdentity(mapIndex: 0, mapName: "M", mapType: "Project",
            rootName: "Points", nodePath: [0, 0], nodeName: "Points", mapLayerType: "PointsVector",
            filename: "points.geojson", filenameRelative: "points.geojson", assetID: vector.path)
        let document = try VisualizationDocument(projectURL: project)
        let defaults = ["Point_Map_Layer_Symbology": VectorStyleValues()]
        let snapshot = try document.vectorVisualSettings(identity: identity, defaults: defaults)
        try document.saveVectorVisualSettings(identity: identity,
            options: snapshot.options, defaults: defaults,
            expectedRevision: snapshot.revision)
        XCTAssertEqual(try Data(contentsOf: visual), original)
    }

    func testRepeatedConditionReadsDoNotMakeAnUnchangedApplyWrite() throws {
        let (directory, project, visual, identity) = try makePolylineFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try VisualizationDocument(projectURL: project)
        let snapshot = try document.vectorVisualSettings(identity: identity, defaults: polylineDefaults)
        let original = try Data(contentsOf: visual)
        try document.saveVectorVisualSettings(identity: identity, options: snapshot.options,
            defaults: polylineDefaults, expectedRevision: snapshot.revision)
        XCTAssertEqual(try Data(contentsOf: visual), original)
    }

    func testStaleRevisionAndMismatchedNodeIdentityCannotWrite() throws {
        let (directory, project, visual, identity) = try makePolylineFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try VisualizationDocument(projectURL: project)
        let snapshot = try document.vectorVisualSettings(identity: identity, defaults: polylineDefaults)
        let wrong = VectorVisualNodeIdentity(mapIndex: identity.mapIndex, mapName: identity.mapName,
            mapType: identity.mapType, rootName: identity.rootName, nodePath: identity.nodePath,
            nodeType: identity.nodeType, nodeName: "Different layer", mapLayerType: identity.mapLayerType,
            filename: identity.filename, filenameRelative: identity.filenameRelative, assetID: identity.assetID)
        XCTAssertThrowsError(try document.vectorVisualSettings(identity: wrong, defaults: polylineDefaults))

        let external = Data("<Ras><External/></Ras>".utf8)
        try external.write(to: visual)
        XCTAssertThrowsError(try document.saveVectorVisualSettings(identity: identity,
            options: snapshot.options, defaults: polylineDefaults, expectedRevision: snapshot.revision))
        XCTAssertEqual(try Data(contentsOf: visual), external)
    }

    func testDuplicateSourceDefinitionIsRejectedRatherThanChoosingOne() throws {
        let (directory, project, visual, identity) = try makePolylineFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try String(contentsOf: visual, encoding: .utf8)
        let duplicate = source.replacingOccurrences(
            of: "<Symbology ID=\"Polyline_Vertex_Symbology\"",
            with: "<Symbology ID=\"Polyline_Line_Symbology\" PenColor=\"#FF010101\" PenWidth=\"3\"/><Symbology ID=\"Polyline_Vertex_Symbology\""
        )
        try Data(duplicate.utf8).write(to: visual)
        let document = try VisualizationDocument(projectURL: project)
        XCTAssertThrowsError(try document.vectorVisualSettings(identity: identity, defaults: polylineDefaults))
        XCTAssertEqual(try Data(contentsOf: visual), Data(duplicate.utf8))
    }

    func testBoundaryPartialOverridesReadPresenceAndChangedOptionsSerializeAllExposedAttributes() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("Boundary.ras")
        let visual = project.deletingPathExtension().appendingPathExtension("vis")
        let xml = """
        <Ras><Maps><Map Name="M" Type="Project"><Tree><Nodes><Node Type="BoundaryCondition" Name="River">
        <Node Type="BoundaryConditionLineLayer" Name="Boundary Condition Lines">
        <Symbology ID="BC_Line_Symbology" PenColor="#FF123456"><PenWidthConditions><Condition Column="FID" Operator="Equal" Threshold="0" Result="4"/></PenWidthConditions></Symbology>
        <Symbology ID="BC_Line_Vertex_Symbology" PointSize="6"/>
        </Node></Node></Nodes></Tree></Map></Maps><Views/><UML Keep="yes"/></Ras>
        """
        try Data(xml.utf8).write(to: visual)
        let document = try VisualizationDocument(projectURL: project)
        let overrides = try document.boundaryLineVisualOverrides(mapIndex: 0, boundaryName: "River")
        XCTAssertEqual(overrides.line.penColor, "#FF123456")
        XCTAssertNil(overrides.line.penWidth)
        XCTAssertNil(overrides.vertex.penColor)
        XCTAssertEqual(overrides.vertex.pointSize, 6)
        XCTAssertTrue(overrides.hasConditionalOverrides)

        var global = BoundaryLineVisualSettings()
        global.line.penColor = "#FF123456"
        global.line.penWidth = 7
        global.vertex.penColor = "#FF112233"
        global.vertex.penWidth = 2
        global.vertex.fillColor = "#FF445566"
        global.vertex.pointSize = 3
        let effective = try document.boundaryLineVisualSettings(mapIndex: 0, boundaryName: "River", globalDefaults: global)
        XCTAssertEqual(effective.line.penWidth, 7)
        let original = try Data(contentsOf: visual)
        try document.saveBoundaryLineVisualSettings(effective, mapIndex: 0,
            boundaryName: "River", globalDefaults: global)
        XCTAssertEqual(try Data(contentsOf: visual), original,
            "Applying unchanged effective values should preserve the partial source attributes exactly.")
        var changed = effective
        changed.line.penWidth = 8
        changed.vertex.pointSize = 9
        try document.saveBoundaryLineVisualSettings(changed, mapIndex: 0,
            boundaryName: "River", globalDefaults: global)
        let saved = try XMLDocument(data: Data(contentsOf: visual))
        XCTAssertEqual(try saved.nodes(forXPath: "//Symbology[@ID='BC_Line_Symbology']/@PenColor").first?.stringValue, "#FF123456")
        XCTAssertEqual(try saved.nodes(forXPath: "//Symbology[@ID='BC_Line_Symbology']/@PenWidth").first?.stringValue, "8.0")
        XCTAssertEqual(try saved.nodes(forXPath: "//Symbology[@ID='BC_Line_Symbology']/PenWidthConditions/Condition[@Result='4']").count, 1)
        XCTAssertEqual(try saved.nodes(forXPath: "//Symbology[@ID='BC_Line_Vertex_Symbology']/@PenColor").first?.stringValue, "#FF112233")
        XCTAssertEqual(try saved.nodes(forXPath: "//Symbology[@ID='BC_Line_Vertex_Symbology']/@PenWidth").first?.stringValue, "2.0")
        XCTAssertEqual(try saved.nodes(forXPath: "//Symbology[@ID='BC_Line_Vertex_Symbology']/@FillColor").first?.stringValue, "#FF445566")
        XCTAssertEqual(try saved.nodes(forXPath: "//Symbology[@ID='BC_Line_Vertex_Symbology']/@PointSize").first?.stringValue, "9")
        XCTAssertEqual(try saved.nodes(forXPath: "/Ras/UML[@Keep='yes']").count, 1)

        try document.saveBoundaryLineVisualSettings(global, mapIndex: 0,
            boundaryName: "River", globalDefaults: global)
        let reset = try XMLDocument(data: Data(contentsOf: visual))
        for id in ["BC_Line_Symbology", "BC_Line_Vertex_Symbology"] {
            for key in ["PenColor", "PenWidth", "FillColor", "PointSize"] {
                XCTAssertTrue(try reset.nodes(forXPath: "//Symbology[@ID='\(id)']/@\(key)").isEmpty,
                    "Reset should remove the full exposed attribute group for \(id).\(key)")
            }
        }
        XCTAssertEqual(try reset.nodes(forXPath: "//Symbology[@ID='BC_Line_Symbology']/PenWidthConditions/Condition[@Result='4']").count, 1)
        XCTAssertEqual(try reset.nodes(forXPath: "/Ras/UML[@Keep='yes']").count, 1)
    }

    private var polylineDefaults: [String: VectorStyleValues] {
        [
            "Polyline_Line_Symbology": VectorStyleValues(penColor: "#FF000000", penWidth: 2, fillColor: "#00000000"),
            "Polyline_Vertex_Symbology": VectorStyleValues(penColor: "#FF000000", penWidth: 1, fillColor: "#800000FF", pointSize: 3)
        ]
    }

    private func makePolylineFixture() throws -> (URL, URL, URL, VectorVisualNodeIdentity) {
        let directory = try makeDirectory()
        let project = directory.appendingPathComponent("Vector.ras")
        let vector = directory.appendingPathComponent("channel.geojson")
        let visual = project.deletingPathExtension().appendingPathExtension("vis")
        try Data("{}".utf8).write(to: vector)
        let target = """
        <Node Type="Root" Name="Layers"><Node Type="Folder" Name="Vectors"><Node Type="MapLayer" MapType="PolylinesVector" Name="Channel" Filename="channel.geojson" FilenameRelative="channel.geojson">
        <Symbology ID="Polyline_Line_Symbology" PenColor="#FF123456" PenWidth="2.5" Future="keep-style">
        <PenColorConditions><Condition Column="FID" Operator="Equal" Threshold="0" Result="#FFAABBCC"/></PenColorConditions>
        <PenWidthConditions><Condition Column="Area" Operator="GreaterThan" Threshold="1" Result="5" Future="keep-rule"/></PenWidthConditions>
        <FillColorConditions><Condition Column="Kind" Operator="StringEquals" Threshold="main" Result="#FF010203"/></FillColorConditions>
        <PointSizeConditions><Condition Column="FID" Operator="Equal" Threshold="0" Result="4"/></PointSizeConditions>
        <Unknown Keep="yes"/></Symbology>
        <Symbology ID="Polyline_Vertex_Symbology" PenColor="#FF101010" PenWidth="1" FillColor="#FF202020" PointSize="8"/>
        <Symbology ID="Unrelated_Definition" PenColor="#FFAABBCC"/></Node></Node></Node>
        """
        let other = """
        <Node Type="Root" Name="Layers"><Node Type="Folder" Name="Vectors"><Node Type="MapLayer" MapType="PolylinesVector" Name="Channel" Filename="channel.geojson" FilenameRelative="channel.geojson">
        <Symbology ID="Polyline_Line_Symbology" PenColor="#FF999999" PenWidth="9"/></Node></Node></Node>
        """
        let xml = "<Ras><Maps><Map Name='Hydro' Type='Project'><Tree><Nodes>\(target)</Nodes></Tree></Map><Map Name='Hydro' Type='Buildable'><Tree><Nodes>\(other)</Nodes></Tree></Map></Maps><Symbology><Global Keep='yes'/></Symbology><Views/><UML Keep='yes'/><Future Keep='yes'/></Ras>"
        try Data(xml.utf8).write(to: visual)
        let identity = VectorVisualNodeIdentity(mapIndex: 0, mapName: "Hydro", mapType: "Project",
            rootName: "Layers", nodePath: [0, 0, 0], nodeName: "Channel", mapLayerType: "PolylinesVector",
            filename: "channel.geojson", filenameRelative: "channel.geojson", assetID: vector.path)
        return (directory, project, visual, identity)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
