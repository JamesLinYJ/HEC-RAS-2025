import Foundation
import RASWorkspaceCore

@MainActor
final class BackendRasterCalculatorProvider {
    private let client: BackendProcessClient

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func inspect(map: MapTreeMapIdentity) async throws -> RasterCalculatorInspectResult {
        let result = try await client.request("raster.calculator.inspect",
            parameters: RasterCalculatorInspectRequest(map: map), as: RasterCalculatorInspectResult.self)
        try result.validate(matching: map)
        return result
    }

    func evaluate(map: MapTreeMapIdentity, contextToken: String,
                  recipe: RasterCalculatorRecipe, layerID: String, layerName: String,
                  profileIndex: Int, viewport: RasterMapViewExtent,
                  expectedSources: [RasterCalculatorSourceChoice]) async throws
        -> (RasterCalculatorEvaluateResult, MapRasterLayer) {
        let request = RasterCalculatorEvaluateRequest(map: map, expectedContextToken: contextToken,
            recipe: recipe, layerID: layerID, layerName: layerName,
            profileIndex: profileIndex, viewport: viewport)
        let result = try await client.request("raster.calculator.evaluate",
            parameters: request, as: RasterCalculatorEvaluateResult.self)
        let layer = try result.makeLayer(matching: map, expectedToken: contextToken,
            expectedLayerID: layerID, expectedLayerName: layerName, expectedRecipe: recipe,
            expectedProfileIndex: profileIndex,
            expectedSources: expectedSources)
        return (result, layer)
    }
}
