import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import RASWorkspaceCore
import XCTest

final class ProjectUMLVisualizationMergeTests: XCTestCase {
    func testUMLReceiptPreservesPendingViewsAndOtherSavedSectionsThroughLaterSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("Project.ras"), visual = directory.appendingPathComponent("Project.vis")
        let original = Data("<Ras Custom='keep'><Maps><Map Name='A' Type='Project'/></Maps><UML><Nodes><Node ID='a-Geo' Left='1' Top='2'/></Nodes></UML><Views/><Future Keep='yes'/><!--keep--></Ras>".utf8)
        try original.write(to: visual)
        let document = try VisualizationDocument(projectURL: project)
        try document.add(.init(name: "Pending 中文", lowerLeft: .init(x: 0, y: 0), upperRight: .init(x: 4, y: 5)))
        let previous = document.sourceRevision
        let mutation = try XMLDocument(data: original, options: [.nodePreserveAll])
        let node = try XCTUnwrap(mutation.nodes(forXPath: "/Ras/UML/Nodes/Node").first as? XMLElement)
        node.attribute(forName: "Left")?.stringValue = "340"
        let saved = mutation.xmlData(options: [.nodePreserveAll]); try saved.write(to: visual)
        try document.acceptExternalProjectUMLChange(expectedPreviousRevision: previous, newRevision: revision(saved))
        XCTAssertTrue(document.modified)
        XCTAssertEqual(document.views.first?.name, "Pending 中文")
        XCTAssertEqual(try Data(contentsOf: visual), saved)
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("Pending 中文"))
        try document.save()
        let reopened = try XMLDocument(contentsOf: visual)
        XCTAssertEqual(try reopened.nodes(forXPath: "/Ras/UML/Nodes/Node/@Left").first?.stringValue, "340")
        XCTAssertEqual(try reopened.nodes(forXPath: "/Ras/Maps/Map/@Name").first?.stringValue, "A")
        XCTAssertEqual(try reopened.nodes(forXPath: "/Ras/Future/@Keep").first?.stringValue, "yes")
        XCTAssertEqual(try VisualizationDocument(projectURL: project).views.first?.name, "Pending 中文")
    }

    func testUMLReceiptRejectsUnrelatedChangesStaleRevisionsAndDuplicateSections() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("Project.ras"), visual = directory.appendingPathComponent("Project.vis")
        let original = Data("<Ras><Maps/><Views/><UML><Nodes/></UML></Ras>".utf8)
        try original.write(to: visual)
        let document = try VisualizationDocument(projectURL: project)
        let previous = document.sourceRevision
        for changed in ["<Ras><Maps Changed='yes'/><Views/><UML><Nodes/></UML></Ras>",
                        "<Ras><Maps/><Views/><UML/><UML/></Ras>"] {
            let bytes = Data(changed.utf8); try bytes.write(to: visual)
            XCTAssertThrowsError(try document.acceptExternalProjectUMLChange(expectedPreviousRevision: previous, newRevision: revision(bytes)))
            XCTAssertEqual(document.sourceRevision, previous)
        }
        try original.write(to: visual)
        XCTAssertThrowsError(try document.acceptExternalProjectUMLChange(expectedPreviousRevision: "stale", newRevision: revision(original)))
        XCTAssertThrowsError(try document.acceptExternalProjectUMLChange(expectedPreviousRevision: previous, newRevision: "wrong-disk"))
        XCTAssertEqual(document.sourceRevision, previous)
    }

    func testFirstUMLFileAdoptionKeepsPendingViewsUnpublished() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = directory.appendingPathComponent("New.ras"), visual = directory.appendingPathComponent("New.vis")
        let document = try VisualizationDocument(projectURL: project)
        try document.add(.init(name: "Pending", lowerLeft: .init(x: 0, y: 0), upperRight: .init(x: 2, y: 3)))
        let bytes = Data("<Ras><UML><Nodes><Node ID='p-Plan' Left='1' Top='2'/></Nodes></UML><Future/></Ras>".utf8)
        try bytes.write(to: visual)
        try document.acceptExternalProjectUMLChange(expectedPreviousRevision: nil, newRevision: revision(bytes))
        XCTAssertTrue(document.modified)
        XCTAssertEqual(document.views.first?.name, "Pending")
        XCTAssertEqual(try Data(contentsOf: visual), bytes)
        try document.save()
        let restored = try XMLDocument(contentsOf: visual)
        XCTAssertEqual(try restored.nodes(forXPath: "/Ras/UML/Nodes/Node").count, 1)
        XCTAssertEqual(try VisualizationDocument(projectURL: project).views.first?.name, "Pending")
    }
    private func revision(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}
