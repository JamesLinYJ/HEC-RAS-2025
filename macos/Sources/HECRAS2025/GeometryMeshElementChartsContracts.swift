import Foundation
import RASWorkspaceCore

struct GeometryMeshElementPropertyChartRequest: Encodable, Sendable {
    let operationID: String
    let projectSessionID: String
    let assetID: String
    let model: GeometryMeshModelRequest
    let revision: String
    let draftState: String
    let topologyDraftState: String?
    let meshDraftSHA256: String
    let topologyDraftSHA256: String
    let flowAreaID: String
    let expectedFlowAreaName: String
    let elementKind: String
    let elementIndex: Int

    init(owner: GeometryMeshToolsOwnerCapture, elementKind: GeometryMeshElementKind,
         elementIndex: Int) {
        operationID = UUID().uuidString.lowercased()
        projectSessionID = owner.projectSessionID.uuidString
        assetID = owner.assetID
        model = owner.model
        revision = owner.sourceRevision
        draftState = owner.meshDraftState
        topologyDraftState = owner.topologyDraftState
        meshDraftSHA256 = owner.meshDraftSHA256
        topologyDraftSHA256 = owner.topologyDraftSHA256
        flowAreaID = owner.flowAreaID
        expectedFlowAreaName = owner.flowAreaName
        self.elementKind = elementKind.rawValue
        self.elementIndex = elementIndex
    }

    init(operationID: String = UUID().uuidString.lowercased(), projectSessionID: String,
         assetID: String, model: GeometryMeshModelRequest, revision: String,
         draftState: String, topologyDraftState: String?, meshDraftSHA256: String,
         topologyDraftSHA256: String, flowAreaID: String, expectedFlowAreaName: String,
         elementKind: String, elementIndex: Int) {
        self.operationID = operationID
        self.projectSessionID = projectSessionID
        self.assetID = assetID
        self.model = model
        self.revision = revision
        self.draftState = draftState
        self.topologyDraftState = topologyDraftState
        self.meshDraftSHA256 = meshDraftSHA256
        self.topologyDraftSHA256 = topologyDraftSHA256
        self.flowAreaID = flowAreaID
        self.expectedFlowAreaName = expectedFlowAreaName
        self.elementKind = elementKind
        self.elementIndex = elementIndex
    }
}

struct GeometryMeshElementPropertyChartPoint: Decodable, Hashable, Sendable {
    let x: Double
    let y: Double
}

struct GeometryMeshElementPropertyChartResult: Decodable, Sendable {
    let operationID: String
    let state: String
    let message: String?
    let projectSessionID: String
    let assetID: String
    let canonicalAssetPath: String
    let sourceRevision: String
    let meshDraftSHA256: String
    let topologyDraftSHA256: String
    let flowAreaID: String
    let flowAreaName: String
    let flowAreaIndex: Int
    let meshHash: Int
    let elementKind: String
    let elementIndex: Int
    let xQuantity: String
    let xUnits: String
    let yQuantity: String
    let yUnits: String
    let points: [GeometryMeshElementPropertyChartPoint]
}

struct MapResultMeshMapTreeRequest: Encodable, Hashable, Sendable {
    let projectPath: String
    let projectXml: String
    let projectXmlSHA: String
    let mapID: String
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let expectedVisualizationRevision: String
    let resultSelectionOverrides: [MapTreeResultSelectionOverride]
    let computeReadLease: MapResultComputeReadLease?
    let projectSessionID: String
    let coreLayerContext: CoreLayerRequestContext?

    init(snapshot: MapResultSourcesSnapshot, treeContext: LayerTreeContext) {
        projectPath = snapshot.map.projectPath
        projectXml = snapshot.map.projectXml
        projectXmlSHA = snapshot.map.projectXmlSHA
        mapID = snapshot.map.mapID
        mapIndex = snapshot.map.mapIndex
        mapName = snapshot.map.mapName
        mapType = snapshot.map.mapType
        expectedVisualizationRevision = snapshot.map.expectedVisualizationRevision
        resultSelectionOverrides = treeContext.resultSelectionOverrides
        computeReadLease = snapshot.map.computeReadLease
        projectSessionID = treeContext.projectSessionID.uuidString
        coreLayerContext = snapshot.map.coreLayerContext
    }
}

struct MapResultMeshGeometryOrigin: Encodable, Hashable, Sendable {
    let projectSessionID: String
    let assetID: String
    let model: GeometryMeshModelRequest
    let revision: String
    let draftState: String
    let topologyDraftState: String?
    let meshDraftSHA256: String
    let topologyDraftSHA256: String

    init(owner: GeometryMeshToolsOwnerCapture) {
        projectSessionID = owner.projectSessionID.uuidString
        assetID = owner.assetID
        model = owner.model
        revision = owner.sourceRevision
        draftState = owner.meshDraftState
        topologyDraftState = owner.topologyDraftState
        meshDraftSHA256 = owner.meshDraftSHA256
        topologyDraftSHA256 = owner.topologyDraftSHA256
    }
}

struct MapResultMeshResultOrigin: Encodable, Hashable, Sendable {
    let resultNode: CatalogTreeNodeLocator
    let selectionIndex: Int
    let selectedResultPath: String
    let selectedResultRevision: String
}

struct MapResultMeshTimeSeriesOwner: Encodable, Hashable, Sendable {
    let map: MapResultMeshMapTreeRequest
    let projectSessionID: String
    let contextToken: String
    let selectionOverrides: [MapResultSelectionOverride]
    let geometryOrigin: MapResultMeshGeometryOrigin?
    let resultOrigin: MapResultMeshResultOrigin?
}

struct MapResultMeshTimeSeriesInspectRequest: Encodable, Sendable {
    let owner: MapResultMeshTimeSeriesOwner
}

struct MapResultMeshTimeSeriesExecuteRequest: Encodable, Sendable {
    let operationID: String
    let owner: MapResultMeshTimeSeriesOwner
    let flowAreaIndex: Int
    let flowAreaID: String
    let expectedFlowAreaName: String
    let elementKind: String
    let elementIndex: Int
}

struct MapResultMeshFlowAreaChoice: Decodable, Hashable, Identifiable, Sendable {
    let flowAreaIndex: Int
    let flowAreaID: String
    let name: String
    let meshHash: Int
    let cellCount: Int
    let faceCount: Int
    let hasMesh: Bool
    var id: String { flowAreaID }
}

struct MapResultMeshTimeSeriesInspectResult: Decodable, Sendable {
    let state: String
    let message: String?
    let projectSessionID: String
    let projectCanonicalPath: String
    let projectRevision: String
    let projectXmlSHA: String
    let visualizationRevision: String
    let coreLayerContextIdentity: String
    let mapID: String
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let contextToken: String
    let originKind: String
    let originPath: String
    let originRevision: String
    let originMeshDraftSHA256: String
    let originTopologyDraftSHA256: String
    let originResultNode: CatalogTreeNodeLocator?
    let originSelectionIndex: Int
    let matchingResultNames: [String]
    let flowAreas: [MapResultMeshFlowAreaChoice]
    let skippedComputingResultCount: Int
}

struct MapResultMeshTimeSeriesSeries: Decodable, Sendable {
    let owners: [CatalogTreeNodeLocator]
    let selectionIndices: [Int]
    let resultPath: String
    let resultRevision: String
    let resultName: String
    let flowAreaIndex: Int
    let flowAreaName: String
    let meshHash: Int
    let variable: String
    let times: [String]
    let values: [Double]
}

struct MapResultMeshTimeSeriesResult: Decodable, Sendable {
    let operationID: String
    let state: String
    let message: String?
    let projectSessionID: String
    let projectCanonicalPath: String
    let projectRevision: String
    let projectXmlSHA: String
    let visualizationRevision: String
    let coreLayerContextIdentity: String
    let mapID: String
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let contextToken: String
    let originKind: String
    let originPath: String
    let originRevision: String
    let originMeshDraftSHA256: String
    let originTopologyDraftSHA256: String
    let originResultNode: CatalogTreeNodeLocator?
    let originSelectionIndex: Int
    let flowAreaIndex: Int
    let flowAreaID: String
    let flowAreaName: String
    let meshHash: Int
    let elementKind: String
    let elementIndex: Int
    let variable: String
    let units: String
    let series: [MapResultMeshTimeSeriesSeries]
    let skippedComputingResultCount: Int
}

struct MapResultMeshTimeSeriesCapture: Hashable, Sendable {
    let owner: MapResultMeshTimeSeriesOwner
    let mapID: UUID
    let projectSessionID: UUID
    let mapSourceWorkflowIdentity: String
    let sourceSnapshotIdentity: String
    let originIdentity: String

    var identity: String {
        [owner.projectSessionID, owner.map.mapID, owner.contextToken,
         mapSourceWorkflowIdentity, sourceSnapshotIdentity, originIdentity]
            .joined(separator: "|")
    }
}

struct MapResultMeshTimeSeriesChartData: Sendable {
    let samples: [ChartSample]
    let presentation: SeriesEditorPresentation

    @MainActor
    static func make(_ result: MapResultMeshTimeSeriesResult) -> Self? {
        guard result.state == "ready", !result.series.isEmpty,
              result.elementKind == "Cell" || result.elementKind == "Face",
              result.elementIndex >= 0,
              result.series.allSatisfy({ $0.variable == result.variable }) else { return nil }
        var samples: [ChartSample] = []
        var datasets: [PlotDatasetPresentation] = []
        var seen = Set<String>()
        for item in result.series {
            let datasetID = SourceFilePaths.canonical(URL(fileURLWithPath: item.resultPath))
            guard seen.insert(datasetID).inserted,
                  item.values.count == item.times.count,
                  item.meshHash == result.meshHash,
                  item.flowAreaIndex == result.flowAreaIndex else { return nil }
            let displayName = item.resultName.isEmpty
                ? URL(fileURLWithPath: item.resultPath).deletingPathExtension().lastPathComponent
                : item.resultName
            datasets.append(.init(id: datasetID, name: displayName,
                xAxisID: "time", yAxisID: "value"))
            for index in item.values.indices {
                guard let date = MapResultCulvertTimeSeriesChartData.sourceDate(item.times[index]) else { return nil }
                samples.append(ChartSample(id: "\(datasetID)/\(index)",
                    x: date.timeIntervalSince1970, y: item.values[index],
                    series: displayName, datasetID: datasetID))
            }
        }
        let variableTitle = result.variable == "Depth" ? "Depth" : "Velocity"
        let elementName = result.elementKind == "Cell" ? "Cell" : "Face"
        let chart = SeriesChartPresentation(title: L10n.format("%@ %d · %@", elementName,
            result.elementIndex, variableTitle), axes: [
                .init(id: "time", direction: .x, title: "Time", isDate: true),
                .init(id: "value", direction: .y, title: variableTitle, units: result.units)
            ], datasets: datasets)
        return Self(samples: samples, presentation: SeriesEditorPresentation(
            xTitle: "Time", yTitle: variableTitle, xIsDate: true, chart: chart))
    }
}

@MainActor
protocol GeometryMeshElementChartProviding: AnyObject {
    func load(_ request: GeometryMeshElementPropertyChartRequest,
        progress: @escaping @MainActor (BackendProgressUpdate) -> Void) async throws
        -> GeometryMeshElementPropertyChartResult
    @discardableResult func cancel(operationID: String) -> Bool
}

@MainActor
final class BackendGeometryMeshElementChartProvider: GeometryMeshElementChartProviding {
    private typealias Operation = BackendDuplexOperation<GeometryMeshOperationControl,
        BackendProgressUpdate, GeometryMeshElementPropertyChartResult>
    private let client: BackendProcessClient
    private var operations: [String: Operation] = [:]
    private var sequences: [String: UInt64] = [:]

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func load(_ request: GeometryMeshElementPropertyChartRequest,
        progress: @escaping @MainActor (BackendProgressUpdate) -> Void) async throws
        -> GeometryMeshElementPropertyChartResult {
        let operation = try client.startDuplex("geometry.mesh.elementPropertyChart", parameters: request,
            control: GeometryMeshOperationControl.self, event: BackendProgressUpdate.self,
            as: GeometryMeshElementPropertyChartResult.self)
        operations[request.operationID] = operation
        sequences[request.operationID] = 0
        defer { operations[request.operationID] = nil; sequences[request.operationID] = nil }
        var eventError: Error?
        do {
            for try await update in operation.events { progress(update) }
        } catch { eventError = error }
        let result = try await operation.value()
        if let eventError, result.state != "ready", result.state != "requiresPropertyTables",
           result.state != "cancelled" {
            throw eventError
        }
        return result
    }

    @discardableResult
    func cancel(operationID: String) -> Bool {
        guard let operation = operations[operationID] else { return false }
        let sequence = (sequences[operationID] ?? 0) &+ 1
        sequences[operationID] = sequence
        do { try operation.sendControl(.cancel, sequence: sequence); return true }
        catch { return false }
    }
}

@MainActor
protocol MapResultMeshTimeSeriesProviding: AnyObject {
    func inspect(_ request: MapResultMeshTimeSeriesInspectRequest) async throws
        -> MapResultMeshTimeSeriesInspectResult
    func execute(_ request: MapResultMeshTimeSeriesExecuteRequest,
        progress: @escaping @MainActor (BackendProgressUpdate) -> Void) async throws
        -> MapResultMeshTimeSeriesResult
    @discardableResult func cancel(operationID: String) -> Bool
}

@MainActor
final class BackendMapResultMeshTimeSeriesProvider: MapResultMeshTimeSeriesProviding {
    private typealias Operation = BackendDuplexOperation<GeometryMeshOperationControl,
        BackendProgressUpdate, MapResultMeshTimeSeriesResult>
    private let client: BackendProcessClient
    private var operations: [String: Operation] = [:]
    private var sequences: [String: UInt64] = [:]

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func inspect(_ request: MapResultMeshTimeSeriesInspectRequest) async throws
        -> MapResultMeshTimeSeriesInspectResult {
        try await client.request("map.result.meshTimeSeries.inspect", parameters: request,
            as: MapResultMeshTimeSeriesInspectResult.self)
    }

    func execute(_ request: MapResultMeshTimeSeriesExecuteRequest,
        progress: @escaping @MainActor (BackendProgressUpdate) -> Void) async throws
        -> MapResultMeshTimeSeriesResult {
        let operation = try client.startDuplex("map.result.meshTimeSeries.execute", parameters: request,
            control: GeometryMeshOperationControl.self, event: BackendProgressUpdate.self,
            as: MapResultMeshTimeSeriesResult.self)
        operations[request.operationID] = operation
        sequences[request.operationID] = 0
        defer { operations[request.operationID] = nil; sequences[request.operationID] = nil }
        var eventError: Error?
        do {
            for try await update in operation.events { progress(update) }
        } catch { eventError = error }
        let result = try await operation.value()
        if let eventError, result.state != "ready", result.state != "cancelled" {
            throw eventError
        }
        return result
    }

    @discardableResult
    func cancel(operationID: String) -> Bool {
        guard let operation = operations[operationID] else { return false }
        let sequence = (sequences[operationID] ?? 0) &+ 1
        sequences[operationID] = sequence
        do { try operation.sendControl(.cancel, sequence: sequence); return true }
        catch { return false }
    }
}
