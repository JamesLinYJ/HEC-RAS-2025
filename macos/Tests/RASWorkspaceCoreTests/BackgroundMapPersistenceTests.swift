import Foundation
import XCTest
@testable import RASWorkspaceCore

final class BackgroundMapPersistenceTests: XCTestCase {
    func testExactMapOptionsPreserveUnknownXMLAndUnpublishedViews() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("background-persistence-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appendingPathComponent("Project.ras")
        let file = project.deletingPathExtension().appendingPathExtension("vis")
        let original = "<Ras Unknown=\"keep\"><Extra>retained</Extra><Maps><Map Name=\"Duplicate\" Type=\"Project\"><UseOSM>true</UseOSM><UnknownChild>first</UnknownChild></Map><Map Name=\"Duplicate\" Type=\"Project\"><UseOSM>false</UseOSM><UnknownChild>second</UnknownChild></Map></Maps></Ras>"
        try Data(original.utf8).write(to: file)
        let document = try VisualizationDocument(projectURL: project)
        let draft = SavedMapView(name: "Unsaved view", lowerLeft: .init(x: 0, y: 0), upperRight: .init(x: 5, y: 5))
        try document.add(draft)
        let first = document.maps[0], second = document.maps[1]
        _ = try document.saveBackgroundMapOptions(["UseOSM": "true", "UseSatellite": "true", "OsmDensity": "3"], map: second)
        XCTAssertEqual(try document.backgroundMapOptions(map: first)["UseSatellite"], nil)
        XCTAssertEqual(try document.backgroundMapOptions(map: second)["UseSatellite"], "true")
        XCTAssertEqual(document.views.map(\.id), [draft.id])
        XCTAssertTrue(document.modified)
        let disk = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(disk.contains("Unknown=\"keep\""))
        XCTAssertTrue(disk.contains("<Extra>retained</Extra>"))
        XCTAssertTrue(disk.contains("<UnknownChild>first</UnknownChild>"))
        XCTAssertTrue(disk.contains("<UnknownChild>second</UnknownChild>"))
        XCTAssertFalse(disk.contains("Unsaved view"))
        try document.save()
        let reopened = try VisualizationDocument(projectURL: project)
        XCTAssertEqual(reopened.views.map(\.name), ["Unsaved view"])
        XCTAssertEqual(try reopened.backgroundMapOptions(map: reopened.maps[1])["OsmDensity"], "3")
    }

    func testExternalChangeAndStaleMapIdentityRejectWithoutOverwriting() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("background-stale-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appendingPathComponent("Project.ras")
        let file = project.deletingPathExtension().appendingPathExtension("vis")
        let original = Data("<Ras><Maps><Map Name=\"Map\" Type=\"Project\" /></Maps></Ras>".utf8)
        try original.write(to: file)
        let document = try VisualizationDocument(projectURL: project)
        XCTAssertThrowsError(try document.saveBackgroundMapOptions(["UseOSM": "true"],
            map: .init(index: 0, name: "Another", type: "Project")))
        XCTAssertEqual(try Data(contentsOf: file), original)
        let external = Data("<Ras><Maps><Map Name=\"External\" Type=\"Project\" /></Maps></Ras>".utf8)
        try external.write(to: file)
        XCTAssertThrowsError(try document.saveBackgroundMapOptions(["UseOSM": "true"], map: document.maps[0]))
        XCTAssertEqual(try Data(contentsOf: file), external)
    }

    func testFirstBackgroundSettingsCreateSourceProjectMapWithoutPublishingViewDraft() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("background-first-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appendingPathComponent("Project.ras")
        let document = try VisualizationDocument(projectURL: project)
        let draft = SavedMapView(name: "Draft", lowerLeft: .init(x: 1, y: 2), upperRight: .init(x: 4, y: 6))
        try document.add(draft)
        let created = try document.saveBackgroundMapOptions(["AreBackgroundMapsOn": "true", "UseOSM": "true"], map: nil)
        XCTAssertEqual(created.index, 0)
        XCTAssertEqual(created.name, "Map")
        XCTAssertEqual(created.type, "Project")
        XCTAssertEqual(document.maps.count, 1)
        XCTAssertEqual(document.views.map(\.id), [draft.id])
        let disk = try VisualizationDocument(projectURL: project)
        XCTAssertTrue(disk.views.isEmpty)
        XCTAssertEqual(try disk.backgroundMapOptions(map: disk.maps[0])["AreBackgroundMapsOn"], "true")
    }
}
