import CryptoKit
import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendSpatialPointConfigWorkflowTests {
    private struct Manifest: Decodable {
        struct Connection: Decodable { let name: String; let path: String }
        struct RemoteInput: Decodable {
            let layerId: String
            let connectionName: String
            let connectionPath: String
            let targetConnectionName: String
            let targetConnectionPath: String
        }
        struct UnconfiguredRemoteInput: Decodable {
            let layerId: String
            let connectionName: String
            let connectionPath: String
        }
        struct FunctionalInput: Decodable {
            let layerId: String
            let enabled: Bool
            let localDataType: String
            let values: [Double]
        }
        let schema: String
        let fresh: Bool
        let projectPath: String
        let boundaryHdfPath: String
        let connections: [Connection]
        let remoteInput: RemoteInput
        let unconfiguredRemoteInput: UnconfiguredRemoteInput
        let functionalInput: FunctionalInput
        let files: [String: String]
    }

    @Test @MainActor
    func bundledProviderSavesRemotePointConfigurationAndPreservesDisabledFunctionalData() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixturePath = try #require(environment["HECRAS_SPATIAL_POINT_CONFIG_ACCEPTANCE_DIRECTORY"])
        let executable = try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = URL(fileURLWithPath: fixturePath, isDirectory: true)
        let manifestData = try Data(contentsOf: fixture.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        #expect(manifest.schema == "spatial-point-config-acceptance-v1")
        #expect(manifest.fresh)
        #expect(manifest.connections.count == 2)
        #expect(manifest.remoteInput.connectionName != manifest.remoteInput.targetConnectionName)

        for (relativePath, expectedHash) in manifest.files {
            let file = try fixtureFile(relativePath, in: fixture)
            let actualHash = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02X", $0) }.joined()
            #expect(actualHash == expectedHash, "Fixture source hash differs for \(relativePath).")
        }
        #expect(manifest.files[manifest.projectPath] != nil)
        #expect(manifest.files[manifest.boundaryHdfPath] != nil)
        for connection in manifest.connections { #expect(manifest.files[connection.path] != nil) }

        let goodFolder = FileManager.default.temporaryDirectory.appendingPathComponent("spatial-point-config-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: goodFolder)
        defer { try? FileManager.default.removeItem(at: goodFolder) }
        let goodDocument = try ProjectDocument(contentsOf: goodFolder.appendingPathComponent(manifest.projectPath))
        let goodAsset = try #require(goodDocument.assets.first { $0.section == .boundaryConditions })
        let goodProjectURL = try #require(goodDocument.url)
        #expect(goodAsset.url.standardizedFileURL == goodFolder.appendingPathComponent(manifest.boundaryHdfPath).standardizedFileURL)
        let goodProvider = BackendModelProvider(client: BackendProcessClient(executableURL: URL(fileURLWithPath: executable)))
        goodProvider.setProject(goodDocument)
        let editor = ModelEditorSession(provider: goodProvider)
        let originalHDF = try Data(contentsOf: goodAsset.url)
        let originalProject = try Data(contentsOf: goodProjectURL)
        await editor.load(goodAsset, kind: .boundaryCondition)
        #expect(editor.loaded && editor.error == nil)

        let remoteData = try #require(editor.spatialPresentations[manifest.remoteInput.layerId]?.pointData)
        let remote = try #require(remoteData.inputs.first {
            editor.fields[$0.scope + "/ConnectionName"] == manifest.remoteInput.connectionName
                && editor.fields[$0.scope + "/ConnectionPath"] == manifest.remoteInput.connectionPath
        })
        let unconfiguredRemoteData = try #require(editor.spatialPresentations[manifest.unconfiguredRemoteInput.layerId]?.pointData)
        let unconfiguredRemote = try #require(unconfiguredRemoteData.inputs.first {
            editor.fields[$0.scope + "/DataLocation"] == "Remote"
                && editor.fields[$0.scope + "/ConnectionName"] == manifest.unconfiguredRemoteInput.connectionName
                && editor.fields[$0.scope + "/ConnectionPath"] == manifest.unconfiguredRemoteInput.connectionPath
        })
        #expect(editor.fields[unconfiguredRemote.scope + "/ConnectionName"] == "")
        let functionalData = try #require(editor.spatialPresentations[manifest.functionalInput.layerId]?.pointData)
        let functional = try #require(functionalData.inputs.first {
            editor.fields[$0.scope + "/LocalDataType"] == manifest.functionalInput.localDataType
                && editor.fields[$0.scope + "/IsEnabled"] == String(manifest.functionalInput.enabled)
        })
        let functionalPage = functional.scope + "/Time Series"
        let functionalTable = try #require(editor.seriesPresentations[functionalPage]?.tableID)
        let functionalRows = try #require(editor.rows[functionalTable])
        #expect(functionalRows.compactMap { Double($0.values["Value"] ?? "") } == manifest.functionalInput.values)
        #expect(editor.seriesPresentations[functionalPage]?.operations.isEmpty == true)
        #expect(editor.tablePresentations[functionalTable]?.columns.allSatisfy { $0.readOnly == true } == true)
        #expect(editor.fields[functional.scope + "/DataLocation"] == "Local")

        editor.set(remote.scope + "/ConnectionName", manifest.remoteInput.targetConnectionName)
        editor.set(remote.scope + "/ConnectionPath", manifest.remoteInput.targetConnectionPath)
        try #require(await editor.perform(.editSpatial(layerID: manifest.remoteInput.layerId, operation: "refresh", itemID: nil)))
        #expect(editor.fields[remote.scope + "/ConnectionName"] == manifest.remoteInput.targetConnectionName)
        #expect(editor.fields[remote.scope + "/ConnectionPath"] == manifest.remoteInput.targetConnectionPath)
        #expect(try Data(contentsOf: goodAsset.url) == originalHDF)
        #expect(try Data(contentsOf: goodProjectURL) == originalProject)
        try #require(await editor.saveLoadedModel(), Comment(rawValue: editor.error ?? "Parent model save failed."))
        #expect(!editor.modified && editor.error == nil)

        let reopenedProvider = BackendModelProvider(client: BackendProcessClient(executableURL: URL(fileURLWithPath: executable)))
        reopenedProvider.setProject(goodDocument)
        let reopened = try await reopenedProvider.load(goodAsset, kind: .boundaryCondition)
        let reopenedRemoteData = try #require(reopened.spatialPresentations[manifest.remoteInput.layerId]?.pointData)
        let reopenedRemote = try #require(reopenedRemoteData.inputs.first {
            reopened.fields[$0.scope + "/ConnectionName"] == manifest.remoteInput.targetConnectionName
        })
        #expect(reopened.fields[reopenedRemote.scope + "/ConnectionPath"] == manifest.remoteInput.targetConnectionPath)
        let reopenedUnconfiguredData = try #require(reopened.spatialPresentations[manifest.unconfiguredRemoteInput.layerId]?.pointData)
        let reopenedUnconfigured = try #require(reopenedUnconfiguredData.inputs.first {
            reopened.fields[$0.scope + "/DataLocation"] == "Remote"
                && reopened.fields[$0.scope + "/ConnectionName"] == manifest.unconfiguredRemoteInput.connectionName
                && reopened.fields[$0.scope + "/ConnectionPath"] == manifest.unconfiguredRemoteInput.connectionPath
        })
        #expect(reopened.fields[reopenedUnconfigured.scope + "/ConnectionName"] == "")
        #expect(reopened.fields[reopenedUnconfigured.scope + "/ConnectionPath"] == "")
        let reopenedFunctionalData = try #require(reopened.spatialPresentations[manifest.functionalInput.layerId]?.pointData)
        let reopenedFunctional = try #require(reopenedFunctionalData.inputs.first {
            reopened.fields[$0.scope + "/IsEnabled"] == "false"
                && reopened.fields[$0.scope + "/LocalDataType"] == "Functional"
        })
        let reopenedFunctionalPage = reopenedFunctional.scope + "/Time Series"
        let reopenedFunctionalTable = try #require(reopened.seriesPresentations[reopenedFunctionalPage]?.tableID)
        #expect((reopened.rows[reopenedFunctionalTable] ?? []).compactMap { Double($0.values["Value"] ?? "") } == manifest.functionalInput.values)

        let missingFolder = FileManager.default.temporaryDirectory.appendingPathComponent("spatial-point-missing-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: missingFolder)
        defer { try? FileManager.default.removeItem(at: missingFolder) }
        let missingDocument = try ProjectDocument(contentsOf: missingFolder.appendingPathComponent(manifest.projectPath))
        let missingAsset = try #require(missingDocument.assets.first { $0.section == .boundaryConditions })
        let missingProjectURL = try #require(missingDocument.url)
        let missingProvider = BackendModelProvider(client: BackendProcessClient(executableURL: URL(fileURLWithPath: executable)))
        missingProvider.setProject(missingDocument)
        let missingEditor = ModelEditorSession(provider: missingProvider)
        let missingOriginalHDF = try Data(contentsOf: missingAsset.url)
        let missingOriginalProject = try Data(contentsOf: missingProjectURL)
        await missingEditor.load(missingAsset, kind: .boundaryCondition)
        let missingRemoteData = try #require(missingEditor.spatialPresentations[manifest.remoteInput.layerId]?.pointData)
        let missingRemote = try #require(missingRemoteData.inputs.first {
            missingEditor.fields[$0.scope + "/ConnectionName"] == manifest.remoteInput.connectionName
        })
        missingEditor.set(missingRemote.scope + "/ConnectionName", "__missing_spatial_point_connection__")
        #expect(await missingEditor.saveLoadedModel() == false)
        #expect(missingEditor.error != nil)
        #expect(try Data(contentsOf: missingAsset.url) == missingOriginalHDF)
        #expect(try Data(contentsOf: missingProjectURL) == missingOriginalProject)
    }

    private func fixtureFile(_ relativePath: String, in root: URL) throws -> URL {
        let components = relativePath.split(separator: "/")
        guard !relativePath.hasPrefix("/"), !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw ProjectFileError.invalid("The spatial point fixture contains a non-relative path.")
        }
        return components.reduce(root) { $0.appendingPathComponent(String($1)) }
    }
}
