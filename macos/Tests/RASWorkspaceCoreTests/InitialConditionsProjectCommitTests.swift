import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import RASWorkspaceCore
import XCTest

final class InitialConditionsProjectCommitTests: XCTestCase {
    func testAcceptsExactDiskCommitAndPreservesExistingConnectionIdentityAndUnknownXML() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let oldConnectionID = try XCTUnwrap(fixture.document.connections.first { $0.name == "Existing" }?.id)
        let receipt = Data(fixture.committedXML.utf8)
        try receipt.write(to: fixture.projectURL, options: .atomic)

        let hasRemainingDraft = try accept(fixture, xml: fixture.committedXML)

        XCTAssertFalse(hasRemainingDraft)
        XCTAssertEqual(fixture.document.description, "Captured description")
        XCTAssertEqual(fixture.document.sourceRevision, revision(of: receipt))
        XCTAssertEqual(try Data(contentsOf: fixture.projectURL), receipt)
        XCTAssertEqual(try Data(contentsOf: fixture.inputFile), fixture.inputBytes)

        let connections = fixture.document.connections
        let oldConnection = try XCTUnwrap(connections.first { $0.name == "Existing" })
        let appended = try XCTUnwrap(connections.first { $0.name == fixture.connectionName })
        XCTAssertEqual(oldConnection.id, oldConnectionID)
        XCTAssertEqual(oldConnection.type, "File")
        XCTAssertEqual(appended.type, "File")
        XCTAssertEqual(appended.relativePath, fixture.inputFile.lastPathComponent)
        XCTAssertEqual(appended.absolutePath, fixture.inputFile.path)
        XCTAssertEqual(connections.count, 2)

        let root = try XCTUnwrap(XMLDocument(xmlString: fixture.document.editorXML).rootElement())
        XCTAssertEqual(root.attribute(forName: "Future")?.stringValue, "preserve")
        XCTAssertEqual(root.elements(forName: "Unknown").first?.attribute(forName: "Mode")?.stringValue, "keep")
        let connectionsNode = try XCTUnwrap(root.elements(forName: "Connections").first)
        XCTAssertEqual(connectionsNode.attribute(forName: "Future")?.stringValue, "connection list metadata")
        let rows = connectionsNode.elements(forName: "Connection")
        let oldNode = try XCTUnwrap(rows.first { $0.attribute(forName: "Name")?.stringValue == "Existing" })
        XCTAssertEqual(oldNode.attribute(forName: "Future")?.stringValue, "old metadata")
        XCTAssertEqual(oldNode.elements(forName: "CustomConnectionProperty").first?.stringValue, "preserve me")
        XCTAssertTrue(fixture.document.editorXML.contains("root comment"))
        XCTAssertTrue(fixture.document.editorXML.contains("unknown comment"))
        XCTAssertTrue(fixture.document.editorXML.contains("connection comment"))
    }

    func testPreservesNewerLiveDescriptionAndProjectDraftAndReportsRemainingDraft() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        fixture.document.description = "Newer description draft"
        fixture.document.defaultTerrain = "Newer terrain draft"
        let committedBytes = Data(fixture.committedXML.utf8)
        try committedBytes.write(to: fixture.projectURL, options: .atomic)

        let hasRemainingDraft = try accept(fixture, xml: fixture.committedXML)

        XCTAssertTrue(hasRemainingDraft)
        XCTAssertEqual(fixture.document.description, "Newer description draft")
        XCTAssertEqual(fixture.document.defaultTerrain, "Newer terrain draft")
        XCTAssertEqual(fixture.document.sourceRevision, revision(of: committedBytes))
        XCTAssertEqual(try Data(contentsOf: fixture.projectURL), committedBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.inputFile), fixture.inputBytes)
        XCTAssertEqual(fixture.document.connections.filter { $0.name == fixture.connectionName }.count, 1)
    }

    func testAcceptingTheSameReceiptTwiceIsIdempotent() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let receipt = Data(fixture.committedXML.utf8)
        try receipt.write(to: fixture.projectURL, options: .atomic)

        XCTAssertFalse(try accept(fixture, xml: fixture.committedXML))
        let firstIDs = Dictionary(uniqueKeysWithValues: fixture.document.connections.map { ($0.name, $0.id) })
        XCTAssertFalse(try accept(fixture, xml: fixture.committedXML))

        XCTAssertEqual(fixture.document.connections.count, 2)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: fixture.document.connections.map { ($0.name, $0.id) }), firstIDs)
        XCTAssertEqual(try Data(contentsOf: fixture.projectURL), receipt)
        XCTAssertEqual(try Data(contentsOf: fixture.inputFile), fixture.inputBytes)
    }

    func testRejectsReceiptWhenCommittedRevisionDoesNotMatchItsXML() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let beforeXML = fixture.document.editorXML
        let beforeIDs = connectionIDs(fixture.document)
        let beforeRevision = fixture.document.sourceRevision
        let receipt = Data(fixture.committedXML.utf8)
        try receipt.write(to: fixture.projectURL, options: .atomic)

        XCTAssertThrowsError(try fixture.document.acceptInitialConditionsCommit(
            expectedSourceRevision: fixture.initialRevision,
            capturedDocumentXML: fixture.capturedDocumentXML,
            capturedDraftXML: fixture.capturedDraftXML,
            committedProjectXML: fixture.committedXML,
            committedProjectRevision: "NOT-THE-RECEIPT-SHA",
            connectionName: fixture.connectionName
        ))

        XCTAssertEqual(fixture.document.editorXML, beforeXML)
        XCTAssertEqual(connectionIDs(fixture.document), beforeIDs)
        XCTAssertEqual(fixture.document.sourceRevision, beforeRevision)
        XCTAssertEqual(try Data(contentsOf: fixture.projectURL), receipt)
        XCTAssertEqual(try Data(contentsOf: fixture.inputFile), fixture.inputBytes)
    }

    func testRejectsCommittedReceiptThatChangesUnrelatedProjectMetadata() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let beforeXML = fixture.document.editorXML
        let beforeIDs = connectionIDs(fixture.document)
        let beforeRevision = fixture.document.sourceRevision
        let alteredXML = try changingRootAttribute("Future", to: "tampered", in: fixture.committedXML)
        let alteredBytes = Data(alteredXML.utf8)
        try alteredBytes.write(to: fixture.projectURL, options: .atomic)

        XCTAssertThrowsError(try accept(fixture, xml: alteredXML))

        XCTAssertEqual(fixture.document.editorXML, beforeXML)
        XCTAssertEqual(connectionIDs(fixture.document), beforeIDs)
        XCTAssertEqual(fixture.document.sourceRevision, beforeRevision)
        XCTAssertEqual(try Data(contentsOf: fixture.projectURL), alteredBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.inputFile), fixture.inputBytes)
    }

    func testRejectsNameCollisionWithNewerLiveConnectionWithoutMutation() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        try fixture.document.connectFile(fixture.conflictingFile, name: fixture.connectionName)
        let beforeXML = fixture.document.editorXML
        let beforeIDs = Dictionary(uniqueKeysWithValues: fixture.document.connections.map { ($0.name, $0.id) })
        let beforeRevision = fixture.document.sourceRevision
        let receipt = Data(fixture.committedXML.utf8)
        try receipt.write(to: fixture.projectURL, options: .atomic)

        XCTAssertThrowsError(try accept(fixture, xml: fixture.committedXML))

        XCTAssertEqual(fixture.document.editorXML, beforeXML)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: fixture.document.connections.map { ($0.name, $0.id) }), beforeIDs)
        XCTAssertEqual(fixture.document.sourceRevision, beforeRevision)
        XCTAssertEqual(try Data(contentsOf: fixture.projectURL), receipt)
        XCTAssertEqual(try Data(contentsOf: fixture.inputFile), fixture.inputBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.conflictingFile), fixture.conflictingBytes)
    }

    func testRejectsStaleChangedProjectFileWithoutMutatingLiveDocumentOrInputs() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let beforeXML = fixture.document.editorXML
        let beforeIDs = connectionIDs(fixture.document)
        let beforeRevision = fixture.document.sourceRevision
        let staleDiskBytes = Data("<Project Future=\"external edit\"><Unknown/></Project>".utf8)
        try staleDiskBytes.write(to: fixture.projectURL, options: .atomic)

        XCTAssertThrowsError(try accept(fixture, xml: fixture.committedXML))

        XCTAssertEqual(fixture.document.editorXML, beforeXML)
        XCTAssertEqual(connectionIDs(fixture.document), beforeIDs)
        XCTAssertEqual(fixture.document.sourceRevision, beforeRevision)
        XCTAssertEqual(try Data(contentsOf: fixture.projectURL), staleDiskBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.inputFile), fixture.inputBytes)
    }

    private func makeFixture() throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let projectURL = folder.appendingPathComponent("InitialConditions.ras")
        let inputFile = folder.appendingPathComponent("InitialConditions.h5")
        let conflictingFile = folder.appendingPathComponent("OtherInput.h5")
        let inputBytes = Data("actual initial conditions input".utf8)
        let conflictingBytes = Data("different actual input".utf8)
        try inputBytes.write(to: inputFile)
        try conflictingBytes.write(to: conflictingFile)
        let originalXML = """
        <Project Future="preserve">
          <!-- root comment -->
          <Description>Original description</Description>
          <DefaultTerrain>Original terrain</DefaultTerrain>
          <Unknown Mode="keep">unknown value<!-- unknown comment --></Unknown>
          <Connections Future="connection list metadata">
            <Connection Name="Existing" Type="File" Future="old metadata">
              <!-- connection comment -->
              <RelativePath>previous.h5</RelativePath>
              <AbsolutePath>/previous/previous.h5</AbsolutePath>
              <Description>existing connection description</Description>
              <CustomConnectionProperty Mode="retain">preserve me</CustomConnectionProperty>
            </Connection>
          </Connections>
        </Project>
        """
        try Data(originalXML.utf8).write(to: projectURL)
        let document = try ProjectDocument(contentsOf: projectURL)
        let capturedDocumentXML = document.editorXML
        let capturedDraftXML = document.editorXML(overridingDescription: "Captured description")
        let committedXML = try document.editorXML(connectingFile: inputFile, overridingDescription: "Captured description")
        return Fixture(
            folder: folder,
            projectURL: projectURL,
            inputFile: inputFile,
            conflictingFile: conflictingFile,
            inputBytes: inputBytes,
            conflictingBytes: conflictingBytes,
            document: document,
            initialRevision: try XCTUnwrap(document.sourceRevision),
            capturedDocumentXML: capturedDocumentXML,
            capturedDraftXML: capturedDraftXML,
            committedXML: committedXML,
            connectionName: inputFile.deletingPathExtension().lastPathComponent
        )
    }

    private func accept(_ fixture: Fixture, xml: String) throws -> Bool {
        try fixture.document.acceptInitialConditionsCommit(
            expectedSourceRevision: fixture.initialRevision,
            capturedDocumentXML: fixture.capturedDocumentXML,
            capturedDraftXML: fixture.capturedDraftXML,
            committedProjectXML: xml,
            committedProjectRevision: revision(of: Data(xml.utf8)),
            connectionName: fixture.connectionName
        )
    }

    private func changingRootAttribute(_ name: String, to value: String, in xml: String) throws -> String {
        let document = try XMLDocument(xmlString: xml, options: [.nodePreserveAll])
        let root = try XCTUnwrap(document.rootElement())
        let attribute = try XCTUnwrap(root.attribute(forName: name))
        attribute.stringValue = value
        return document.xmlString(options: [.nodePrettyPrint])
    }

    private func revision(of bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02X", $0) }.joined()
    }

    private func connectionIDs(_ document: ProjectDocument) -> [String: String] {
        Dictionary(uniqueKeysWithValues: document.connections.map { ($0.name, $0.id) })
    }

    private struct Fixture {
        let folder: URL
        let projectURL: URL
        let inputFile: URL
        let conflictingFile: URL
        let inputBytes: Data
        let conflictingBytes: Data
        let document: ProjectDocument
        let initialRevision: String
        let capturedDocumentXML: String
        let capturedDraftXML: String
        let committedXML: String
        let connectionName: String
    }
}
