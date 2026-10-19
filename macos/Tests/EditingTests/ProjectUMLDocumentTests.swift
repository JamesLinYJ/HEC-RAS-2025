import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct ProjectUMLDocumentTests {
    @Test
    func positionSaveReopensAndPreservesUnknownVisualizationXML() throws {
        let fixture = try ProjectUMLFileFixture(xml: """
        <?xml version="1.0" encoding="UTF-8"?>
        <Ras version="source">
          <!-- outside UML -->
          <Maps><Map Name="Reach A"><VendorSetting enabled="yes">keep text</VendorSetting></Map></Maps>
          <OpaqueSourceData vendor="unknown"><Nested value="retain"/></OpaqueSourceData>
          <UML vendor="retain">
            <Nodes marker="retain">
              <!-- node comment -->
              <Node ID="Geometry.hdf-Geo" Left="12" Top="24" custom="keep"/>
              <VendorNode flag="keep"/>
            </Nodes>
            <VendorUMLData value="keep"/>
          </UML>
          <SavedViews><View Name="Draft view"/></SavedViews>
        </Ras>
        """)
        defer { fixture.remove() }

        let before = try Data(contentsOf: fixture.visualizationURL)
        let beforeNonUML = try nonUMLChildXML(in: before)
        let oldRevision = digest(before)
        let positions = [
            ProjectUMLPosition(id: "geometry-asset", sourceID: "Geometry.hdf-Geo", left: 80.5, top: 44),
            ProjectUMLPosition(id: "plan-asset", sourceID: "Plan.p##-Plan", left: 510, top: 210)
        ]

        let newRevision = try ProjectUMLVisualizationFile.savePositions(projectURL: fixture.projectURL,
            positions: positions, expectedPreviousRevision: oldRevision)
        let after = try Data(contentsOf: fixture.visualizationURL)
        #expect(newRevision == digest(after))
        #expect(newRevision != oldRevision)
        #expect(try ProjectUMLVisualizationFile.loadPositions(projectURL: fixture.projectURL) == [
            ProjectUMLSavedPosition(sourceID: "Geometry.hdf-Geo", left: 80.5, top: 44),
            ProjectUMLSavedPosition(sourceID: "Plan.p##-Plan", left: 510, top: 210)
        ])
        #expect(try nonUMLChildXML(in: after) == beforeNonUML,
            "A UML position save must preserve unknown, map, saved-view, and outside-section XML nodes.")

        let document = try XMLDocument(data: after, options: [.nodePreserveAll])
        let root = try #require(document.rootElement())
        let uml = try #require(root.elements(forName: "UML").first)
        #expect(uml.attribute(forName: "vendor")?.stringValue == "retain")
        #expect(uml.elements(forName: "VendorUMLData").first?.attribute(forName: "value")?.stringValue == "keep")
        let nodes = try #require(uml.elements(forName: "Nodes").first)
        #expect(nodes.elements(forName: "VendorNode").first?.attribute(forName: "flag")?.stringValue == "keep")
        #expect(nodes.elements(forName: "Node").first?.attribute(forName: "custom")?.stringValue == "keep")
    }

    @Test
    func stalePositionSaveIsRejectedWithoutChangingVisualizationBytes() throws {
        let fixture = try ProjectUMLFileFixture(xml: "<Ras><Unknown preserve=\"byte-for-byte\"/><UML><Nodes/></UML></Ras>")
        defer { fixture.remove() }
        let before = try Data(contentsOf: fixture.visualizationURL)

        do {
            _ = try ProjectUMLVisualizationFile.savePositions(projectURL: fixture.projectURL,
                positions: [ProjectUMLPosition(id: "asset", sourceID: "Model-Plan", left: 25, top: 50)],
                expectedPreviousRevision: "stale-revision")
            Issue.record("A stale .vis revision must be rejected.")
        } catch ProjectFileError.modifiedExternally {
            // Expected: do not overwrite a concurrent visualization edit.
        }

        #expect(try Data(contentsOf: fixture.visualizationURL) == before)
    }

    @Test
    func duplicateSerializedIDsAndDuplicateLiveIDsAreRejected() throws {
        let duplicateSource = "<Ras><UML><Nodes><Node ID=\"same-Geo\" Left=\"1\" Top=\"2\"/><Node ID=\"same-Geo\" Left=\"3\" Top=\"4\"/></Nodes></UML></Ras>"
        let fixture = try ProjectUMLFileFixture(xml: duplicateSource)
        defer { fixture.remove() }
        let before = try Data(contentsOf: fixture.visualizationURL)

        do {
            _ = try ProjectUMLVisualizationFile.loadPositions(projectURL: fixture.projectURL)
            Issue.record("Duplicate serialized UML IDs must not be assigned to an arbitrary model.")
        } catch ProjectFileError.invalid(_) {
            // Expected: the source schema has no unique identity for these rows.
        }
        do {
            _ = try ProjectUMLVisualizationFile.savePositions(projectURL: fixture.projectURL,
                positions: [ProjectUMLPosition(id: "asset-a", sourceID: "duplicate-Geo", left: 1, top: 2),
                    ProjectUMLPosition(id: "asset-b", sourceID: "duplicate-Geo", left: 3, top: 4)],
                expectedPreviousRevision: digest(before))
            Issue.record("Duplicate live source IDs must not overwrite one serialized UML row.")
        } catch ProjectFileError.invalid(_) {
            // Expected: fail before writing any position.
        }
        #expect(try Data(contentsOf: fixture.visualizationURL) == before)
    }

    @Test
    func associationIdentityUsesProjectNameAndKindAndRejectsAmbiguousEndpoints() {
        let candidates = [
            ProjectUMLAssociationCandidate(nodeID: "/models/Geometry A.hdf", projectName: "Geometry A.hdf", kind: "geometry"),
            ProjectUMLAssociationCandidate(nodeID: "/models/Geometry B.hdf", projectName: "Geometry B.hdf", kind: "geometry"),
            ProjectUMLAssociationCandidate(nodeID: "/models/Terrain A.hdf", projectName: "Geometry A.hdf", kind: "terrain")
        ]
        #expect(ProjectUMLAssociationIdentity.resolve(named: "Geometry A.hdf", kind: "geometry", among: candidates)
            == .resolved(nodeID: "/models/Geometry A.hdf"))
        #expect(ProjectUMLAssociationIdentity.resolve(named: "Geometry A.hdf", kind: "plan", among: candidates)
            == .missing)
        let duplicate = candidates + [ProjectUMLAssociationCandidate(nodeID: "/archive/Geometry A.hdf",
            projectName: "Geometry A.hdf", kind: "geometry")]
        let sourceResolution = ProjectUMLAssociationIdentity.resolve(named: "Geometry A.hdf",
            kind: "geometry", among: duplicate)
        let destinationResolution = ProjectUMLAssociationIdentity.resolve(named: "Geometry A.hdf",
            kind: "geometry", among: duplicate)
        #expect(sourceResolution == .ambiguous(matches: 2))
        #expect(destinationResolution == .ambiguous(matches: 2))
    }
}

private struct ProjectUMLFileFixture {
    let root: URL
    let projectURL: URL
    let visualizationURL: URL

    init(xml: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-uml-document-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        projectURL = root.appendingPathComponent("Project.prj")
        visualizationURL = projectURL.deletingPathExtension().appendingPathExtension("vis")
        try Data(xml.utf8).write(to: visualizationURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func nonUMLChildXML(in bytes: Data) throws -> [String] {
    let document = try XMLDocument(data: bytes, options: [.nodePreserveAll])
    let root = try #require(document.rootElement())
    return (root.children ?? []).filter { $0.name != "UML" }.map(\.xmlString)
}

private func digest(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02X", $0) }.joined()
}
