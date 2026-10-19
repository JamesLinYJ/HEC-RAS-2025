import Foundation
import RASWorkspaceCore

@MainActor
struct BackendMapResultChartProvider: MapResultChartProvider {
    let client: BackendProcessClient

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func loadSources(map: MapResultChartMapRequest,
                     selectionOverrides: [MapResultSelectionOverride]) async throws -> MapResultChartSources {
        let request = MapResultChartSourcesRequest(map: map, selectionOverrides: selectionOverrides)
        return try await client.request("map.resultSources", parameters: request, as: MapResultChartSources.self)
    }

    func selectSources(map: MapResultChartMapRequest, expectedContextToken: String,
                       currentSelectionOverrides: [MapResultSelectionOverride],
                       selectionOverrides: [MapResultSelectionOverride]) async throws -> MapResultChartSources {
        let request = MapResultChartSelectionRequest(map: map, expectedContextToken: expectedContextToken,
            currentSelectionOverrides: currentSelectionOverrides, selectionOverrides: selectionOverrides)
        return try await client.request("map.resultSelection", parameters: request, as: MapResultChartSources.self)
    }

    func compute(_ request: MapResultChartSampleLineRequest,
                 progress: @escaping @Sendable (BackendProgressUpdate) -> Void) async throws -> MapResultChartSeries {
        try await client.request("map.resultSampleLine", parameters: request,
            as: MapResultChartSeries.self, progress: progress)
    }
}
