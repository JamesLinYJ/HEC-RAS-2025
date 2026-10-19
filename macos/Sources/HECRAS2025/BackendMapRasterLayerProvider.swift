import CryptoKit
import Foundation
import RASWorkspaceCore

@MainActor
final class BackendMapRasterLayerProvider {
    private let client: BackendProcessClient

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func inspect(sourcePath: String) async throws -> MapRasterLayerInspectResult {
        let result: MapRasterLayerInspectResult = try await client.request("map.raster.layer.inspect",
            parameters: MapRasterLayerInspectRequest(sourcePath: sourcePath),
            as: MapRasterLayerInspectResult.self)
        guard SourceFilePaths.canonical(URL(fileURLWithPath: result.sourcePath))
                == SourceFilePaths.canonical(URL(fileURLWithPath: sourcePath)),
              result.sourceRevision.count == 64, result.sourceRevision.allSatisfy(\.isHexDigit),
              result.width > 0, result.height > 0, result.bandCount > 0,
              result.supportedMapLayerTypes.contains(result.mapLayerType),
              result.supportedMapLayerTypes.count == 1,
              result.info.fileName == URL(fileURLWithPath: sourcePath).lastPathComponent else {
            throw BackendServiceError(code: "protocolFailure", message: "The GDAL raster inspection did not match the selected file.")
        }
        return result
    }

    func preview(_ source: MapRasterLayerInspectResult, mapLayerType: String,
                 projectPath: String, projectXml: String?,
                 coreLayerContext: CoreLayerRequestContext? = nil) async throws -> MapRasterLayerImagePayload {
        guard source.supportedMapLayerTypes.contains(mapLayerType), source.canRenderPreview else {
            throw BackendServiceError(code: "unsupported", message: "This raster type does not support an in-dialog preview.")
        }
        let xmlSHA = projectXml.map { sha256(Data($0.utf8)) }
        let result: MapRasterLayerPreviewResult = try await client.request("map.raster.layer.preview",
            parameters: MapRasterLayerPreviewRequest(sourcePath: source.sourceCanonicalPath,
                sourceRevision: source.sourceRevision, mapLayerType: mapLayerType,
                projectPath: projectPath, projectXml: projectXml, projectXmlSHA: xmlSHA,
                viewport: nil, coreLayerContext: coreLayerContext), as: MapRasterLayerPreviewResult.self)
        let image = result.raster
        guard image.sourceMapID == nil, image.width > 0, image.height > 0,
              image.rgba.count == image.width * image.height * 4,
              image.id == "preview:" + source.sourceRevision else {
            throw BackendServiceError(code: "protocolFailure", message: "The GDAL preview does not match the inspected raster revision.")
        }
        return image
    }

    private func sha256(_ data: Data) -> String {
        importCryptoHash(data)
    }
}

private func importCryptoHash(_ data: Data) -> String {
    // Keep the wire hash identical to the backend's uppercase SHA-256 format.
    SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
}
