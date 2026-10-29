import CryptoKit
import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@Suite(.serialized)
struct BackendGeometryMeshToolsWorkflowTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_MESH_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func bundledHostFindsExactMeshElementsAndReturnsCommittedShapefileReceipts() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixturePath = try #require(environment["HECRAS_MESH_ACCEPTANCE_DIRECTORY"])
        let executable = try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixtureURL = URL(fileURLWithPath: fixturePath, isDirectory: true)
        let fixtureDigest = try meshToolsDirectoryDigest(fixtureURL)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("geometry-mesh-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workingCopy = root.appendingPathComponent("project", isDirectory: true)
        let outputDirectory = root.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.copyItem(at: fixtureURL, to: workingCopy)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let projectURL = workingCopy.appendingPathComponent("Mesh editor.ras")
        let project = try ProjectDocument(contentsOf: projectURL)
        let asset = try #require(project.assets.first { $0.section == .geometries })
        let sourceProjectBytes = try Data(contentsOf: projectURL)
        let sourceGeometryBytes = try Data(contentsOf: asset.url)
        let client = BackendProcessClient(executableURL: URL(fileURLWithPath: executable))
        let modelProvider = BackendModelProvider(client: client)
        modelProvider.setProject(project)
        let parent = ModelEditorSession(provider: modelProvider)
        await parent.load(asset, kind: .geometry)
        #expect(parent.loaded && parent.error == nil)
        await parent.ensureGeometryTopologyLoaded()
        let topology = try #require(parent.geometryTopology)
        await topology.setField(featureKind: "region", fid: 0, fieldID: "PatchType", value: "TrianglePaver")
        await topology.setField(featureKind: "region", fid: 0, fieldID: "ConstantSize", value: "4")
        await topology.setField(featureKind: "region", fid: 0, fieldID: "SecondaryConstantSize", value: "4")
        await parent.ensureGeometryMeshLoaded()
        let session = try #require(parent.geometryMesh)
        #expect(session.flowAreas.isEmpty)
        await session.generateMesh()
        let row = try #require(session.flowAreas.first { $0.hasMesh && $0.cellCount > 0
            && $0.faceCount > 0 && $0.nodeCount > 0 })
        session.selectFlowArea(row.id)
        let projectContext = GeometryMeshToolsProjectContext(projectSessionID: UUID(), coreLayerContext: nil)
        let capture = try #require(session.meshToolsOwnerCapture(flowAreaID: row.id,
            projectContext: projectContext))
        let toolsProvider = BackendGeometryMeshElementToolsProvider(client: client)

        for (kind, coordinateCount) in [
            (GeometryMeshElementKind.cell, 3),
            (GeometryMeshElementKind.face, 2),
            (GeometryMeshElementKind.node, 1)
        ] {
            let found = await session.findElement(flowAreaID: row.id, elementKind: kind, index: 0,
                currentProjectContext: { projectContext }, provider: toolsProvider)
            #expect(found)
            let presentation = try #require(session.meshElementFind)
            let result = presentation.result
            #expect(presentation.owner == capture)
            #expect(result.elementKind == kind.rawValue && result.index == 0)
            #expect(result.flowAreaID == row.id && result.flowAreaName == row.name)
            #expect(result.sourceRevision == capture.sourceRevision)
            #expect(result.meshDraftSHA256 == capture.meshDraftSHA256)
            #expect(result.topologyDraftSHA256 == capture.topologyDraftSHA256)
            #expect(result.coordinates.count >= coordinateCount)
            #expect(result.coordinates.allSatisfy { $0.x.isFinite && $0.y.isFinite })
            #expect(result.viewport.minX < result.viewport.maxX && result.viewport.minY < result.viewport.maxY)
            #expect(GeometryMeshElementToolsValidation.find(result, matches: GeometryMeshElementFindRequest(
                model: capture.model, revision: capture.sourceRevision, draftState: capture.meshDraftState,
                topologyDraftState: capture.topologyDraftState, meshDraftSHA256: capture.meshDraftSHA256,
                topologyDraftSHA256: capture.topologyDraftSHA256, flowAreaID: row.id,
                expectedFlowAreaName: row.name, elementKind: kind.rawValue, index: 0)))
        }

        for kind in GeometryMeshShapefileExportKind.allCases {
            let suffix = kind == .cellCenters ? "cell-centers" : "perimeter-faces"
            let outputURL = outputDirectory.appendingPathComponent("\(suffix).shp")
            await session.exportShapefile(flowAreaID: row.id, exportKind: kind, outputURL: outputURL,
                currentProjectContext: { projectContext }, provider: toolsProvider)
            #expect(session.meshToolsError == nil)
            let receipt = try #require(session.meshShapefileExportReceipts.first {
                $0.result.exportKind == kind.rawValue
            })
            #expect(receipt.result.state == "completed")
            #expect(receipt.result.flowAreaID == row.id && receipt.result.flowAreaName == row.name)
            #expect(receipt.result.sourceRevision == capture.sourceRevision)
            #expect(receipt.result.meshDraftSHA256 == capture.meshDraftSHA256)
            #expect(receipt.result.topologyDraftSHA256 == capture.topologyDraftSHA256)
            #expect(receipt.result.featureCount > 0)
            #expect(Set(receipt.result.artifacts.map { URL(fileURLWithPath: $0.path).pathExtension.lowercased() })
                .isSuperset(of: ["shp", "shx", "dbf"]))
            for artifact in receipt.result.artifacts {
                let file = URL(fileURLWithPath: artifact.path)
                let bytes = try Data(contentsOf: file)
                #expect(Int64(bytes.count) == artifact.sizeBytes)
                #expect(meshToolsSHA256(bytes).caseInsensitiveCompare(artifact.sha256) == .orderedSame)
            }
        }

        #expect(try Data(contentsOf: asset.url) == sourceGeometryBytes)
        #expect(try Data(contentsOf: projectURL) == sourceProjectBytes)
        #expect(try meshToolsDirectoryDigest(fixtureURL) == fixtureDigest)
    }
}

private func meshToolsSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
}

private func meshToolsDirectoryDigest(_ directory: URL) throws -> String {
    let enumerator = FileManager.default.enumerator(at: directory,
        includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsPackageDescendants])
    var entries: [(String, String)] = []
    while let url = enumerator?.nextObject() as? URL {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { continue }
        let path = String(url.path.dropFirst(directory.path.count + 1))
        entries.append((path, meshToolsSHA256(try Data(contentsOf: url))))
    }
    let canonical = entries.sorted { $0.0 < $1.0 }
        .map { $0.0 + "\0" + $0.1 + "\n" }.joined()
    return meshToolsSHA256(Data(canonical.utf8))
}
