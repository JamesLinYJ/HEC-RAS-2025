import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import XCTest
@testable import RASWorkspaceCore

final class ProjectModelMetadataTests: XCTestCase {
    func testRenameChangesOnlyAffectedAssociationsAndCanRollBackWithoutSaving() throws {
        let (folder, projectURL) = try fixture("<Project Future='keep'><Description>Original</Description><PlanAssociations><PlanAssociation Plan='P' Geometry='G' Future='keep'/><PlanAssociation Plan='Other' Geometry='Other'/></PlanAssociations><Unknown/></Project>")
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = try ProjectDocument(contentsOf: projectURL)
        let disk = try Data(contentsOf: projectURL)
        let xml = document.editorXML
        let change = try document.prepareModelMetadataMutations([
            .init(section: "PlanAssociations", rowName: "PlanAssociation", identityAttribute: "Plan", identityValue: "P",
                attribute: "Geometry", oldValue: "G", newValue: "Renamed")
        ])
        XCTAssertEqual(document.editorXML, xml)
        try change.apply()
        XCTAssertEqual(document.associationRows(group: "PlanAssociations").first { $0.name == "P" }?.fields["Geometry"], "Renamed")
        let root = try XCTUnwrap(XMLDocument(xmlString: document.editorXML).rootElement())
        XCTAssertEqual(root.attribute(forName: "Future")?.stringValue, "keep")
        let rows = try root.nodes(forXPath: "PlanAssociations/PlanAssociation[@Plan='P']")
        XCTAssertEqual((rows.first as? XMLElement)?.attribute(forName: "Future")?.stringValue, "keep")
        XCTAssertEqual(try Data(contentsOf: projectURL), disk)
        change.rollback()
        XCTAssertEqual(document.editorXML, xml)
    }

    func testOmittedSourceAssociationCanBeExplicitlyCreatedAndRolledBack() throws {
        let (folder, projectURL) = try fixture("<Project><Description>Draft</Description><Unknown/></Project>")
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = try ProjectDocument(contentsOf: projectURL)
        let original = document.editorXML
        let change = try document.prepareModelMetadataMutations([
            .init(section: "GeometryAssociations", rowName: "GeometryAssociation", identityAttribute: "Geometry", identityValue: "G",
                attribute: "Geometry", oldValue: nil, newValue: "G"),
            .init(section: "GeometryAssociations", rowName: "GeometryAssociation", identityAttribute: "Geometry", identityValue: "G",
                attribute: "Terrain", oldValue: nil, newValue: "New Terrain"),
            .init(section: "Project", rowName: "DefaultTerrain", identityAttribute: "", identityValue: "",
                attribute: "#text", oldValue: nil, newValue: "New Terrain")
        ])
        XCTAssertEqual(document.editorXML, original)
        try change.apply()
        XCTAssertEqual(document.defaultTerrain, "New Terrain")
        XCTAssertEqual(document.associationRows(group: "GeometryAssociations").first?.fields["Terrain"], "New Terrain")
        change.rollback()
        XCTAssertEqual(document.editorXML, original)
    }

    func testStaleAssociationBatchAndChangesAfterPreparationAreRejected() throws {
        let (folder, projectURL) = try fixture("<Project><PlanAssociations><PlanAssociation Plan='P' Geometry='G' BoundaryCondition='B'/></PlanAssociations></Project>")
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = try ProjectDocument(contentsOf: projectURL)
        let valid = ProjectModelMetadataMutation(section: "PlanAssociations", rowName: "PlanAssociation",
            identityAttribute: "Plan", identityValue: "P", attribute: "Geometry", oldValue: "G", newValue: "New")
        let invalid = ProjectModelMetadataMutation(section: "PlanAssociations", rowName: "PlanAssociation",
            identityAttribute: "Plan", identityValue: "P", attribute: "BoundaryCondition", oldValue: "Stale", newValue: "New")
        let original = document.editorXML
        XCTAssertThrowsError(try document.prepareModelMetadataMutations([valid, invalid]))
        XCTAssertEqual(document.editorXML, original)
        let prepared = try document.prepareModelMetadataMutations([valid])
        document.description = "New draft"
        XCTAssertThrowsError(try prepared.apply())
        XCTAssertEqual(document.associationRows(group: "PlanAssociations").first?.fields["Geometry"], "G")
        XCTAssertEqual(document.description, "New draft")
    }

    private func fixture(_ xml: String) throws -> (URL, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let projectURL = folder.appendingPathComponent("Project.ras")
        try Data(xml.utf8).write(to: projectURL)
        return (folder, projectURL)
    }
}
