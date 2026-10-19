import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct CatalogModelPublicationTests {
    @Test @MainActor
    func secondTrashFailureRestoresFirstInputAndBothMetadataDocuments() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-publication-" + UUID().uuidString)
        let terrainDirectory = folder.appendingPathComponent("Terrains")
        try FileManager.default.createDirectory(at: terrainDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let projectURL = folder.appendingPathComponent("Project.ras")
        let assetURL = terrainDirectory.appendingPathComponent("Terrain.h5")
        let rasterURL = terrainDirectory.appendingPathComponent("elevation.tif")
        let originalHDF = Data("transaction fixture HDF payload".utf8)
        let originalRaster = Data("transaction fixture raster payload".utf8)
        try originalHDF.write(to: assetURL); try originalRaster.write(to: rasterURL)
        try Data("<Project><GeometryAssociations><GeometryAssociation Geometry='G' Terrain='Terrain' Future='keep'/></GeometryAssociations><Unknown/></Project>".utf8).write(to: projectURL)
        let project = try ProjectDocument(contentsOf: projectURL)
        let originalProjectXML = project.editorXML
        let visualURL = folder.appendingPathComponent("Project.vis")
        let visualBytes = Data("<Ras><Maps><Map Name='A' Type='Project'><Tree><Nodes><Node Type='Terrain' Name='Terrain'/><Node Type='Result' Name='R'><Node Type='Terrain' Name='Terrain'/></Node></Nodes></Tree></Map></Maps><Views/><Unknown/></Ras>".utf8)
        try visualBytes.write(to: visualURL)
        let visualization = try VisualizationDocument(projectURL: projectURL)
        try visualization.add(.init(name: "Pending", lowerLeft: .init(x: 0, y: 0), upperRight: .init(x: 1, y: 1)))
        let services = SourceWorkflowFixtureServices(recoveryFolder: folder.appendingPathComponent("Trash"))
        services.failTrashCall = 2
        let asset = try #require(project.assets.first { $0.url.lastPathComponent == "Terrain.h5" })
        let receipt = CatalogModelActionReceipt(action: "delete", kind: "Terrain",
            originalAssetPath: asset.url.path, canonicalOriginalAssetPath: asset.url.resolvingSymlinksInPath().path,
            originalName: "Terrain", originalSHA: CatalogModelActionPublisher.digest(originalHDF),
            newName: nil, newAssetPath: nil, actualClone: false, stagedTargets: [],
            metadataMutations: [.init(section: "GeometryAssociations", rowName: "GeometryAssociation", identityAttribute: "Geometry",
                identityValue: "G", attribute: "Terrain", oldValue: "Terrain", newValue: nil, removeRow: false)],
            deleteDependencies: [], stagingDirectories: [], projectXmlFingerprint: CatalogModelActionPublisher.digest(Data(originalProjectXML.utf8)),
            trashPaths: [.init(path: asset.url.path, revision: CatalogModelActionPublisher.digest(originalHDF), originalAsset: true),
                .init(path: rasterURL.path, revision: CatalogModelActionPublisher.digest(originalRaster), originalAsset: false)])
        #expect(throws: CocoaError(.fileWriteNoPermission)) {
            try CatalogModelActionPublisher.publish(receipt, asset: asset, project: project, visualization: visualization, system: services)
        }
        #expect(services.trashCalls == 2)
        #expect(try Data(contentsOf: assetURL) == originalHDF)
        #expect(try Data(contentsOf: rasterURL) == originalRaster)
        #expect(project.editorXML == originalProjectXML)
        #expect(try Data(contentsOf: visualURL) == visualBytes)
        #expect(visualization.views.first?.name == "Pending" && visualization.modified)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).allSatisfy { !$0.hasPrefix(".catalog-action-recovery-") })
    }
}
