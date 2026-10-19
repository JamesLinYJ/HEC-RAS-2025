import Foundation
import RASWorkspaceCore

/// The retained chart caller captures selected source rows and the exact
/// Result owner together. `lineIDs` are opaque BoundaryEditorService IDs;
/// they are never ordinals or display names.
struct MapBoundaryLineTimeSeriesRequest: Codable, Hashable, Sendable {
    let map: MapResultChartMapRequest
    let boundaryNode: CatalogTreeNodeLocator
    let expectedBoundaryRevision: String
    let boundarySourceState: String
    let expectedBoundaryContextToken: String
    let resultOwner: MapResultOwnerSelection
    let lineIDs: [String]
    let variable: String
}

struct BoundaryLineTimeSeriesLineIdentity: Codable, Hashable, Sendable {
    let id: String
    let sourceOrdinal: Int
    let name: String
}

/// Codable value passed to a dedicated WindowGroup. The request and owner
/// identities are immutable for the life of that chart window.
struct BoundaryLineTimeSeriesWindowRoute: Codable, Hashable, Sendable {
    let request: MapBoundaryLineTimeSeriesRequest
    let expectedLines: [BoundaryLineTimeSeriesLineIdentity]
    let projectSessionID: UUID
    let mapWorkflowIdentity: String
    let mapSourceWorkflowIdentity: String
    let boundaryCaptureIdentity: String

    init(request: MapBoundaryLineTimeSeriesRequest,
         expectedLines: [BoundaryLineTimeSeriesLineIdentity],
         projectSessionID: UUID, mapWorkflowIdentity: String,
         mapSourceWorkflowIdentity: String, boundaryCaptureIdentity: String) throws {
        let ids = expectedLines.map(\.id)
        guard request.resultOwner.isValid,
              !mapWorkflowIdentity.isEmpty, !mapSourceWorkflowIdentity.isEmpty,
              !boundaryCaptureIdentity.isEmpty,
              request.expectedBoundaryRevision.count == 64,
              request.expectedBoundaryContextToken.count == 64,
              !request.boundarySourceState.isEmpty,
              request.variable == "Flow" || request.variable == "Stage",
              !expectedLines.isEmpty,
              Set(ids).count == ids.count,
              ids == request.lineIDs,
              expectedLines.allSatisfy({ !$0.id.isEmpty && $0.sourceOrdinal >= 0 }) else {
            throw BoundaryMapError.incompleteIdentity
        }
        self.request = request
        self.expectedLines = expectedLines
        self.projectSessionID = projectSessionID
        self.mapWorkflowIdentity = mapWorkflowIdentity
        self.mapSourceWorkflowIdentity = mapSourceWorkflowIdentity
        self.boundaryCaptureIdentity = boundaryCaptureIdentity
    }

    var mapID: UUID? { UUID(uuidString: request.map.mapID) }

    var identity: String {
        [projectSessionID.uuidString, mapWorkflowIdentity, mapSourceWorkflowIdentity,
         boundaryCaptureIdentity, request.map.mapID, request.map.expectedVisualizationRevision,
         request.expectedBoundaryRevision, request.expectedBoundaryContextToken,
         request.resultOwner.identity, request.variable,
         expectedLines.map { "\($0.id):\($0.sourceOrdinal)" }.joined(separator: "\u{1e}")]
            .joined(separator: "|")
    }
}

struct MapBoundaryLineTimeSeriesPoint: Decodable, Sendable {
    let time: String
    let value: Double?
}

struct MapBoundaryLineTimeSeriesDataset: Decodable, Sendable {
    let id: String
    let name: String
    let kind: String
    let sourceOrdinal: Int
    let colorRGBA: String
    let strokeWidth: Double
    let points: [MapBoundaryLineTimeSeriesPoint]
}

struct MapBoundaryLineTimeSeriesSnapshot: Decodable, Sendable {
    let projectCanonicalPath: String
    let projectRevision: String
    let projectXmlSHA: String?
    let visualizationRevision: String
    let mapID: String
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let resultContextToken: String
    let boundaryContextToken: String
    let boundaryNode: CatalogTreeNodeLocator
    let boundaryPath: String
    let boundaryRevision: String
    let resultOwner: BoundaryMapResultOwnerReceipt
    let variable: String
    let datasets: [MapBoundaryLineTimeSeriesDataset]
}

@MainActor
enum BoundaryLineTimeSeriesChartData {
    static func make(from snapshot: MapBoundaryLineTimeSeriesSnapshot,
                     variable: String) -> (samples: [ChartSample], presentation: SeriesEditorPresentation)? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.isLenient = false
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSS"

        var samples: [ChartSample] = []
        var datasets: [PlotDatasetPresentation] = []
        var datasetIDs = Set<String>()
        for dataset in snapshot.datasets {
            guard datasetIDs.insert(dataset.id).inserted,
                  ["Simulated", "Payload"].contains(dataset.kind),
                  dataset.sourceOrdinal >= 0,
                  dataset.strokeWidth.isFinite, dataset.strokeWidth > 0,
                  dataset.colorRGBA.count == 8,
                  UInt32(dataset.colorRGBA, radix: 16) != nil else { return nil }
            datasets.append(.init(id: dataset.id, name: dataset.name,
                xAxisID: "time", yAxisID: "value", colorRGBA: dataset.colorRGBA))
            for (index, point) in dataset.points.enumerated() {
                guard let date = formatter.date(from: point.time),
                      point.value.map({ $0.isFinite }) ?? true else { return nil }
                samples.append(ChartSample(id: "\(dataset.id)/\(index)",
                    x: date.timeIntervalSince1970, y: point.value ?? .nan,
                    series: dataset.name, datasetID: dataset.id))
            }
        }
        let axisTitle = L10n.text(variable)
        let chart = SeriesChartPresentation(title: L10n.text(variable == "Flow"
            ? "Flow Time Series" : "Stage Time Series"), axes: [
                .init(id: "time", direction: .x, title: L10n.text("Time"), isDate: true),
                .init(id: "value", direction: .y, title: axisTitle)
            ], datasets: datasets)
        let presentation = SeriesEditorPresentation(xTitle: L10n.text("Time"),
            yTitle: axisTitle, xIsDate: true, chart: chart)
        return (samples, presentation)
    }
}
