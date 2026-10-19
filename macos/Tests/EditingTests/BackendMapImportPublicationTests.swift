import CryptoKit
import Foundation
import Testing
import RASWorkspaceCore
@testable import HECRAS2025

struct BackendMapImportPublicationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil))
    @MainActor
    func committedFirstImportReturnsReceiptWhenWorkspaceRefreshFails() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("map-import-publication-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let projectDirectory = root.appendingPathComponent("Project", isDirectory: true)
        let externalDirectory = root.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: true)

        let projectURL = projectDirectory.appendingPathComponent("Publication.ras")
        let project = try ProjectDocument(name: "Publication", units: "SI")
        try project.save(to: projectURL)
        let originalProjectBytes = try Data(contentsOf: projectURL)
        project.description = "Unpublished description draft"

        let sourceURL = externalDirectory.appendingPathComponent("Channel.geojson")
        let sourceBytes = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"name":"Channel"},"geometry":{"type":"LineString","coordinates":[[0,0],[1,1]]}}]}"#.utf8)
        try sourceBytes.write(to: sourceURL)
        let stagedXML = try project.editorXML(connectingFile: sourceURL,
            overridingDescription: project.description)

        let sessionID = UUID()
        let maps: [CatalogMapDocument] = []
        var mutationRunning = false
        var didPublishCount = 0
        var refreshAttemptCount = 0
        let provider = BackendMapTreeProvider(
            client: BackendProcessClient(executableURL: URL(fileURLWithPath: executable)),
            projectXML: { project.editorXML },
            mapDocuments: { maps },
            isContextCurrent: { context in
                context.projectSessionID == sessionID && context.projectURL == projectURL
            },
            visualizationRevision: { nil },
            beginMapMutation: {
                guard !mutationRunning else { return false }
                mutationRunning = true
                return true
            },
            endMapMutation: { mutationRunning = false },
            acceptMapChange: { _, _ in
                refreshAttemptCount += 1
                throw BackendServiceError(code: "refreshFailed", message: "Injected visualization refresh failure")
            })

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let mapsJSON = String(decoding: try encoder.encode(maps), as: UTF8.self)
        let context = LayerTreeContext(projectSessionID: sessionID, projectURL: projectURL,
            mapID: MapState.projectMapID, mode: "Project", focusedGeometryIDs: [], focusedPlanIDs: [],
            projectRevision: project.editorXML + "\n" + mapsJSON)
        let projectRevision = try #require(project.sourceRevision)

        let receipt = try await provider.importGeoJSONVector(
            sourcePath: SourceFilePaths.canonical(sourceURL),
            revision: digest(sourceBytes),
            projectXML: stagedXML,
            projectRevision: projectRevision,
            context: context,
            didPublish: {
                didPublishCount += 1
                try project.connectFile(sourceURL)
            })

        #expect(receipt.map.mapIndex == 0)
        #expect(receipt.map.mapName == "Map")
        #expect(receipt.map.mapType == "Project")
        #expect(receipt.map.previousVisualizationRevision == nil)
        #expect(receipt.map.visualizationRevision == digest(try Data(contentsOf: projectURL.deletingPathExtension().appendingPathExtension("vis"))))
        #expect(receipt.refreshWarning == "Injected visualization refresh failure")
        #expect(didPublishCount == 1)
        #expect(refreshAttemptCount == 1)
        #expect(!mutationRunning)

        let imported = try VisualizationDocument(projectURL: projectURL)
        #expect(imported.maps.count == 1)
        #expect(imported.maps.first?.type == "Project")
        #expect(project.connections.count == 1)
        #expect(SourceFilePaths.canonical(try #require(project.connections.first).resolve(
            relativeTo: try #require(project.directory), mappings: [])) == SourceFilePaths.canonical(sourceURL))
        #expect(project.description == "Unpublished description draft")
        #expect(try Data(contentsOf: projectURL) == originalProjectBytes)
        #expect(try Data(contentsOf: sourceURL) == sourceBytes)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil))
    @MainActor
    func geoJSONSymlinkKeepsLogicalAliasWhileImportingCanonicalTarget() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("map-import-symlink-alias-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let projectDirectory = root.appendingPathComponent("Project", isDirectory: true)
        let externalDirectory = root.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: true)

        let projectURL = projectDirectory.appendingPathComponent("Alias.ras")
        let project = try ProjectDocument(name: "Alias", units: "SI")
        try project.save(to: projectURL)
        let originalProjectBytes = try Data(contentsOf: projectURL)

        let targetURL = externalDirectory.appendingPathComponent("Channel.data")
        let aliasURL = externalDirectory.appendingPathComponent("Channel.geojson")
        let sourceBytes = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"name":"Channel"},"geometry":{"type":"LineString","coordinates":[[0,0],[1,1]]}}]}"#.utf8)
        try sourceBytes.write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: targetURL)
        let logicalAliasPath = aliasURL.standardizedFileURL.path
        let canonicalTargetPath = SourceFilePaths.canonical(aliasURL)
        #expect(logicalAliasPath != canonicalTargetPath)
        #expect(canonicalTargetPath == SourceFilePaths.canonical(targetURL))

        let stagedXML = try project.editorXML(connectingFile: aliasURL,
            overridingDescription: project.description)
        let sessionID = UUID()
        let maps: [CatalogMapDocument] = []
        var mutationRunning = false
        var didPublishCount = 0
        var acceptedRevision: String?
        let provider = BackendMapTreeProvider(
            client: BackendProcessClient(executableURL: URL(fileURLWithPath: executable)),
            projectXML: { project.editorXML },
            mapDocuments: { maps },
            isContextCurrent: { context in
                context.projectSessionID == sessionID && context.projectURL == projectURL
            },
            visualizationRevision: { acceptedRevision },
            beginMapMutation: {
                guard !mutationRunning else { return false }
                mutationRunning = true
                return true
            },
            endMapMutation: { mutationRunning = false },
            acceptMapChange: { previous, current in
                guard previous == acceptedRevision else {
                    throw BackendServiceError(code: "sourceChanged", message: "Visualization changed during import.")
                }
                acceptedRevision = current
            })

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let mapsJSON = String(decoding: try encoder.encode(maps), as: UTF8.self)
        let context = LayerTreeContext(projectSessionID: sessionID, projectURL: projectURL,
            mapID: MapState.projectMapID, mode: "Project", focusedGeometryIDs: [], focusedPlanIDs: [],
            projectRevision: project.editorXML + "\n" + mapsJSON)
        let projectRevision = try #require(project.sourceRevision)

        let receipt = try await provider.importGeoJSONVector(
            sourcePath: logicalAliasPath,
            revision: digest(sourceBytes),
            projectXML: stagedXML,
            projectRevision: projectRevision,
            context: context,
            didPublish: {
                didPublishCount += 1
                try project.connectFile(aliasURL)
            })

        #expect(receipt.map.mapIndex == 0)
        #expect(receipt.map.mapName == "Map")
        #expect(receipt.map.mapType == "Project")
        #expect(receipt.refreshWarning == nil)
        #expect(didPublishCount == 1)
        #expect(!mutationRunning)
        #expect(receipt.map.visualizationRevision == digest(try Data(contentsOf: projectURL
            .deletingPathExtension().appendingPathExtension("vis"))))

        let visualizationURL = projectURL.deletingPathExtension().appendingPathExtension("vis")
        let visualizationXML = try XMLDocument(data: Data(contentsOf: visualizationURL),
            options: [.nodeLoadExternalEntitiesNever])
        let importedFilename = try #require(visualizationXML.nodes(forXPath: "//Node[@Type='MapLayer']/@Filename")
            .compactMap(\.stringValue).first)
        #expect(importedFilename == logicalAliasPath)
        #expect(SourceFilePaths.canonical(URL(fileURLWithPath: importedFilename)) == canonicalTargetPath)

        let imported = try VisualizationDocument(projectURL: projectURL)
        #expect(imported.maps.count == 1)
        #expect(imported.maps.first?.type == "Project")
        #expect(project.connections.count == 1)
        #expect(SourceFilePaths.canonical(try #require(project.connections.first).resolve(
            relativeTo: try #require(project.directory), mappings: [])) == canonicalTargetPath)
        #expect(try Data(contentsOf: aliasURL) == sourceBytes)
        #expect(try Data(contentsOf: targetURL) == sourceBytes)
        #expect(try Data(contentsOf: projectURL) == originalProjectBytes)
    }

    private func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02X", $0) }.joined()
    }
}
