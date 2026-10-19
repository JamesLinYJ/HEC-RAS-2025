import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import RASWorkspaceCore
import XCTest

final class SpecializedVectorVisualSettingsTests: XCTestCase {
    func testListsOnlyExactPersistedGeometryChildrenAndReadsSourceDefinitions() throws {
        let (directory, project, visual) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }

        let beforeRead = try Data(contentsOf: visual)
        let document = try VisualizationDocument(projectURL: project)
        let identities = try document.specializedVectorVisualNodes(
            mapIndex: 0, geometryName: "Reach A", geometryAssetID: "/models/Reach A.g01.h5")
        XCTAssertEqual(identities.map(\.nodeType), ["ConceptualMesh", "FlowAreaLayer", "CulvertBarrelLayer"])
        XCTAssertEqual(identities.map(\.nodePath), [[0, 0, 0], [0, 0, 1], [0, 0, 2]])
        XCTAssertEqual(identities.map(\.definitionIDs), [
            ["Arc_Line_Symbology", "Node_Symbology", "Deletable_Node_Symbology", "Internal_Point_Symbology"],
            ["Mesh_Line_Symbology"],
            ["Culvert_Barrel_Symbology", "Culvert_Barrel_Vertex_Symbology"]
        ])
        XCTAssertTrue(identities.allSatisfy { $0.geometryAssetID == "/models/Reach A.g01.h5" })

        let topologyDefaults = defaults(for: identities[0])
        let topology = try document.specializedVectorVisualSettings(identity: identities[0], defaults: topologyDefaults)
        XCTAssertEqual(topology.options.keys.sorted(), [
            "Arc_Line_Symbology", "Deletable_Node_Symbology", "Internal_Point_Symbology", "Node_Symbology"
        ])
        XCTAssertEqual(topology.options["Arc_Line_Symbology"]?.values.penColor, "#FF123456")
        XCTAssertEqual(topology.options["Arc_Line_Symbology"]?.values.penWidth, 2.5)
        XCTAssertEqual(topology.options["Node_Symbology"]?.rules(for: .pointSize).first?.comparison, ">=")
        XCTAssertEqual(topology.options["Node_Symbology"]?.rules(for: .pointSize).first?.resultValue, "6")

        let flow = try document.specializedVectorVisualSettings(identity: identities[1], defaults: defaults(for: identities[1]))
        XCTAssertEqual(flow.options["Mesh_Line_Symbology"]?.values.penWidth, 3)
        let culvert = try document.specializedVectorVisualSettings(identity: identities[2], defaults: defaults(for: identities[2]))
        XCTAssertEqual(culvert.options["Culvert_Barrel_Vertex_Symbology"]?.values.pointSize, 7)
        XCTAssertEqual(try Data(contentsOf: visual), beforeRead)
    }

    func testSaveChangesOnlySelectedSpecializedDefinitionAndPreservesUnknownSourceXML() throws {
        let (directory, project, visual) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Data(contentsOf: visual)
        let document = try VisualizationDocument(projectURL: project)
        let identity = try XCTUnwrap(document.specializedVectorVisualNodes(
            mapIndex: 0, geometryName: "Reach A", geometryAssetID: "/models/Reach A.g01.h5").first)
        let defaults = defaults(for: identity)
        let snapshot = try document.specializedVectorVisualSettings(identity: identity, defaults: defaults)
        try document.add(.init(name: "Unpublished view", lowerLeft: .init(x: 0, y: 0), upperRight: .init(x: 1, y: 1)))
        var changed = try XCTUnwrap(snapshot.options["Arc_Line_Symbology"])
        changed.values.penColor = "#FFABCDEF"
        changed.conditionGroups[1].rules.append(VectorStyleRule(
            column: "NodeType", comparison: "contains", threshold: "boundary", resultValue: "8"))

        try document.saveSpecializedVectorVisualSettings(identity: identity,
            options: ["Arc_Line_Symbology": changed], defaults: defaults,
            expectedRevision: snapshot.revision)

        let saved = try XMLDocument(data: Data(contentsOf: visual), options: [.nodePreserveAll])
        XCTAssertEqual(try saved.nodes(forXPath: "//Node[@Type='ConceptualMesh']/Symbology[@ID='Arc_Line_Symbology']/@PenColor").first?.stringValue,
            "#FFABCDEF")
        XCTAssertEqual(try saved.nodes(forXPath: "//Symbology[@ID='Arc_Line_Symbology']/@Future").first?.stringValue, "keep-style")
        XCTAssertEqual(try saved.nodes(forXPath: "//Symbology[@ID='Arc_Line_Symbology']/Unknown[@Keep='yes']").count, 1)
        XCTAssertEqual(try saved.nodes(forXPath: "//Symbology[@ID='Arc_Line_Symbology']/PenWidthConditions/Condition[@Result='4']").count, 1)
        XCTAssertEqual(try saved.nodes(forXPath: "//Symbology[@ID='Node_Symbology']/PointSizeConditions/Condition[@Operator='GreaterThanOrEqual']").count, 1)
        XCTAssertEqual(try saved.nodes(forXPath: "//Node[@Type='FlowAreaLayer']/Symbology[@ID='Mesh_Line_Symbology']/@PenWidth").first?.stringValue, "3")
        XCTAssertEqual(try saved.nodes(forXPath: "/Ras/Maps/Map[2]//Symbology[@ID='Arc_Line_Symbology']/@PenWidth").first?.stringValue, "11")
        XCTAssertEqual(try saved.nodes(forXPath: "/Ras/Symbology/Global[@Keep='yes']").count, 1)
        XCTAssertEqual(try saved.nodes(forXPath: "/Ras/Views/View[@Keep='yes']").count, 1)
        XCTAssertTrue(try saved.nodes(forXPath: "/Ras/Views/View[Name='Unpublished view']").isEmpty)
        XCTAssertEqual(document.views.map(\.name), ["Unpublished view"])
        XCTAssertNotEqual(try Data(contentsOf: visual), original)
    }

    func testNoOpAndDefaultResetDoNotMaterializeLocalStyleAndKeepConditions() throws {
        let (directory, project, visual) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try VisualizationDocument(projectURL: project)
        let identity = try XCTUnwrap(document.specializedVectorVisualNodes(
            mapIndex: 0, geometryName: "Reach A", geometryAssetID: "/models/Reach A.g01.h5").first)
        let defaults = defaults(for: identity)
        let snapshot = try document.specializedVectorVisualSettings(identity: identity, defaults: defaults)
        let original = try Data(contentsOf: visual)
        try document.saveSpecializedVectorVisualSettings(identity: identity, options: snapshot.options,
            defaults: defaults, expectedRevision: snapshot.revision)
        XCTAssertEqual(try Data(contentsOf: visual), original)

        var reset = try XCTUnwrap(snapshot.options["Arc_Line_Symbology"])
        reset.values = defaults["Arc_Line_Symbology"]!
        try document.saveSpecializedVectorVisualSettings(identity: identity,
            options: ["Arc_Line_Symbology": reset], defaults: defaults,
            expectedRevision: snapshot.revision)
        let saved = try XMLDocument(data: Data(contentsOf: visual), options: [.nodePreserveAll])
        XCTAssertTrue(try saved.nodes(forXPath: "/Ras/Maps/Map[1]//Symbology[@ID='Arc_Line_Symbology']/@PenColor").isEmpty)
        XCTAssertTrue(try saved.nodes(forXPath: "/Ras/Maps/Map[1]//Symbology[@ID='Arc_Line_Symbology']/@PenWidth").isEmpty)
        XCTAssertEqual(try saved.nodes(forXPath: "/Ras/Maps/Map[1]//Symbology[@ID='Arc_Line_Symbology']/PenColorConditions/Condition[@Result='#FF010203']").count, 1)
        XCTAssertEqual(try saved.nodes(forXPath: "/Ras/Maps/Map[2]//Symbology[@ID='Arc_Line_Symbology']/@PenWidth").first?.stringValue, "11")
    }

    func testStalePathRevisionAndAmbiguousGeometryOwnerAreRejected() throws {
        let (directory, project, visual) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try VisualizationDocument(projectURL: project)
        let identity = try XCTUnwrap(document.specializedVectorVisualNodes(
            mapIndex: 0, geometryName: "Reach A", geometryAssetID: "/models/Reach A.g01.h5").first)
        let defaults = defaults(for: identity)
        let snapshot = try document.specializedVectorVisualSettings(identity: identity, defaults: defaults)
        let wrongPath = SpecializedVectorVisualNodeIdentity(mapIndex: identity.mapIndex,
            mapName: identity.mapName, mapType: identity.mapType, rootName: identity.rootName,
            geometryNodePath: identity.geometryNodePath, geometryName: identity.geometryName,
            geometryAssetID: identity.geometryAssetID, nodePath: [0, 1, 0],
            nodeType: identity.nodeType, nodeName: identity.nodeName)
        XCTAssertThrowsError(try document.specializedVectorVisualSettings(identity: wrongPath, defaults: defaults))
        XCTAssertThrowsError(try document.saveSpecializedVectorVisualSettings(identity: identity,
            options: snapshot.options, defaults: defaults, expectedRevision: "stale"))

        let changedSource = try String(contentsOf: visual, encoding: .utf8)
            .replacingOccurrences(of: "Keep=\"yes\"", with: "External=\"yes\"")
        let external = Data(changedSource.utf8)
        try external.write(to: visual)
        var changed = try XCTUnwrap(snapshot.options["Arc_Line_Symbology"])
        changed.values.penColor = "#FFABCDEF"
        XCTAssertThrowsError(try document.saveSpecializedVectorVisualSettings(identity: identity,
            options: ["Arc_Line_Symbology": changed], defaults: defaults,
            expectedRevision: snapshot.revision))
        XCTAssertEqual(try Data(contentsOf: visual), external)

        let ambiguous = changedSource.replacingOccurrences(
            of: "      </Node>\n    </Node></Nodes></Tree></Map>",
            with: "</Node><Node Type=\"Geometry\" Name=\"Reach A\"/></Node></Nodes></Tree></Map>")
        XCTAssertNotEqual(ambiguous, changedSource)
        try Data(ambiguous.utf8).write(to: visual)
        let reloaded = try VisualizationDocument(projectURL: project)
        XCTAssertThrowsError(try reloaded.specializedVectorVisualNodes(
            mapIndex: 0, geometryName: "Reach A", geometryAssetID: "/models/Reach A.g01.h5"))
    }

    func testMissingGeometryReturnsNoInferredOwner() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("Empty.ras")
        let visual = project.deletingPathExtension().appendingPathExtension("vis")
        try Data("<Ras><Maps><Map Name='M' Type='Project'><Tree><Nodes><Node Type='Root' Name='Geometries'/></Nodes></Tree></Map></Maps></Ras>".utf8)
            .write(to: visual)
        let document = try VisualizationDocument(projectURL: project)
        XCTAssertTrue(try document.specializedVectorVisualNodes(
            mapIndex: 0, geometryName: "Reach A", geometryAssetID: "/models/Reach A.g01.h5").isEmpty)
    }

    private func defaults(for identity: SpecializedVectorVisualNodeIdentity) -> [String: VectorStyleValues] {
        Dictionary(uniqueKeysWithValues: (identity.definitionIDs ?? []).compactMap { id in
            SourceVectorStyleCatalog.definition(for: id).map { (id, $0.defaultStyle) }
        })
    }

    private func makeFixture() throws -> (URL, URL, URL) {
        let directory = try makeDirectory()
        let project = directory.appendingPathComponent("Specialized.ras")
        let visual = project.deletingPathExtension().appendingPathExtension("vis")
        let xml = """
        <Ras>
          <Maps>
            <Map Name="Project Map" Type="Project"><Tree><Nodes><Node Type="Root" Name="Geometries">
              <Node Type="Geometry" Name="Reach A">
                <Node Type="ConceptualMesh" Name="Conceptual Mesh">
                  <Symbology ID="Arc_Line_Symbology" PenColor="#FF123456" PenWidth="2.5" Future="keep-style">
                    <PenColorConditions><Condition Column="FID" Operator="Equal" Threshold="0" Result="#FF010203"/></PenColorConditions>
                    <PenWidthConditions><Condition Column="Area" Operator="GreaterThan" Threshold="1" Result="4"/></PenWidthConditions>
                    <Unknown Keep="yes"/>
                  </Symbology>
                  <Symbology ID="Node_Symbology"><PointSizeConditions><Condition Column="NodeType" Operator="GreaterThanOrEqual" Threshold="1" Result="6"/></PointSizeConditions></Symbology>
                  <Symbology ID="Deletable_Node_Symbology"/>
                  <Symbology ID="Internal_Point_Symbology"/>
                </Node>
                <Node Type="FlowAreaLayer" Name="Computational Mesh"><Symbology ID="Mesh_Line_Symbology" PenWidth="3"/></Node>
                <Node Type="CulvertBarrelLayer" Name="Culvert Barrels">
                  <Symbology ID="Culvert_Barrel_Symbology" PenWidth="4"/>
                  <Symbology ID="Culvert_Barrel_Vertex_Symbology" PointSize="7"/>
                </Node>
              </Node>
            </Node></Nodes></Tree></Map>
            <Map Name="Project Map" Type="Buildable"><Tree><Nodes><Node Type="Root" Name="Geometries">
              <Node Type="Geometry" Name="Reach A"><Node Type="ConceptualMesh" Name="Conceptual Mesh">
                <Symbology ID="Arc_Line_Symbology" PenWidth="11"/>
              </Node></Node>
            </Node></Nodes></Tree></Map>
          </Maps>
          <Symbology><Global Keep="yes"/></Symbology>
          <Views><View Keep="yes"/></Views>
        </Ras>
        """
        try Data(xml.utf8).write(to: visual)
        return (directory, project, visual)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
