import Combine
import Foundation
import RASWorkspaceCore

enum FeatureQueryKind: String, Sendable {
    case nld = "NLD", nsi = "NSI", nfhl = "NFHL", osm = "OSM"
    var title: String {
        switch self { case .nld: "NLD Querier"; case .nsi: "NSI Importer"; case .nfhl: "FEMA Floodplains"; case .osm: "OSM Importer" }
    }
    var initialInfo: String {
        switch self {
        case .nld: "Click 'Query Area' to fetch selected NLD features"
        case .nsi: "Click 'Query Area' to fetch NSI structures"
        case .nfhl: "Click 'Query Area' to fetch all FEMA flood hazard zones for the current extent"
        case .osm: "Query OpenStreetMap through the Overpass API and import the matching features for the current extent."
        }
    }
}
struct FeatureQueryContext: Hashable, Sendable {
    let projectSessionID: UUID
    let mapID: UUID
    let kind: FeatureQueryKind
}
struct QueryPolygonSource: Identifiable, Sendable { let id: String; let name: String }
struct FeatureQuerySnapshot: Sendable {
    let polygonSources: [QueryPolygonSource]
    let selectedPolygonID: String?
}
struct FeatureQueryRequest: Sendable {
    let context: FeatureQueryContext
    let extent: ViewportRequest?
    let nldLayerID: String
    let useBoundaryPolygon: Bool
    let polygonSourceID: String?
    let rawQL: String
    let queryLabel: String
}
struct QueryPreviewLayer: Identifiable, Sendable {
    var id: String { layer.id }
    let layer: MapVectorLayer
    let lineColor: String
    let fillColor: String
    let lineWidth: Double
}
struct FeatureQueryResult: Sendable {
    let id: String
    let hasFeatures: Bool
    let info: String
    let layers: [QueryPreviewLayer]
}
struct FeatureQueryProgress: Sendable { let info: String; let percent: Double? }
@MainActor
protocol FeatureQueryProvider {
    func snapshot(_ context: FeatureQueryContext) async throws -> FeatureQuerySnapshot
    func query(_ request: FeatureQueryRequest, progress: @escaping @MainActor (FeatureQueryProgress) -> Void) async throws -> FeatureQueryResult
    func saveToDisk(_ resultID: String, formatID: String, context: FeatureQueryContext) async throws -> MapUpdate
    func suggest(key: String, value: String, isKey: Bool) async throws -> [String]
}

@MainActor
final class FeatureQuerySession: ObservableObject {
    @Published var nldLayerID = FeatureQueryOptions.source.nldLayers.first?.id ?? ""
    @Published var formatID = FeatureQueryOptions.source.exportFormats.first?.id ?? ""
    @Published var useBoundaryPolygon = false
    @Published var polygonID: String?
    @Published var osm = OSMQueryDraft()
    @Published private(set) var polygons: [QueryPolygonSource] = []
    @Published private(set) var result: FeatureQueryResult?
    @Published private(set) var info = ""
    @Published private(set) var progress: Double?
    @Published private(set) var querying = false
    @Published private(set) var saving = false
    @Published var error: String?
    private var task: Task<Void, Never>?
    private var revision = 0
    private var context: FeatureQueryContext?
    var busy: Bool { querying || saving }
    var canQuery: Bool { !busy && !(context?.kind == .nsi && useBoundaryPolygon && polygonID == nil) }
    var canSave: Bool { !busy && result?.hasFeatures == true }

    func load(context: FeatureQueryContext, provider: (any FeatureQueryProvider)?) async {
        cancel(); self.context = context; let captured = revision
        result = nil; info = L10n.text(context.kind.initialInfo); polygons = []; polygonID = nil; error = nil
        guard let provider else { return }
        do {
            let snapshot = try await provider.snapshot(context)
            guard captured == revision, !Task.isCancelled else { return }
            polygons = snapshot.polygonSources; polygonID = snapshot.selectedPolygonID
        } catch { if captured == revision, !Task.isCancelled { self.error = error.localizedDescription } }
    }
    @discardableResult
    func query(extent: ViewportRequest?, provider: (any FeatureQueryProvider)?) -> Task<Void, Never>? {
        guard canQuery, let context, let provider else { return nil }
        revision += 1; let captured = revision
        let request = FeatureQueryRequest(context: context, extent: extent, nldLayerID: nldLayerID,
            useBoundaryPolygon: useBoundaryPolygon, polygonSourceID: polygonID, rawQL: osm.rawQL,
            queryLabel: osm.selectedPresetID == nil ? "Custom" : osm.label)
        querying = true; result = nil; error = nil; info = L10n.text("Querying..."); progress = nil
        task = Task {
            defer { if captured == revision { querying = false; progress = nil; task = nil } }
            do {
                let response = try await provider.query(request) { update in
                    guard captured == self.revision, !Task.isCancelled else { return }
                    self.info = update.info
                    self.progress = update.percent.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil }
                }
                guard captured == revision, !Task.isCancelled else { return }
                result = response; info = response.info
            } catch {
                guard captured == revision, !Task.isCancelled else { return }
                self.error = error.localizedDescription; info = error.localizedDescription
            }
        }
        return task
    }
    func save(provider: (any FeatureQueryProvider)?) async -> MapUpdate? {
        guard canSave, let result, let context, let provider else { return nil }
        let captured = revision; saving = true; error = nil
        defer { if captured == revision { saving = false } }
        do {
            let update = try await provider.saveToDisk(result.id, formatID: formatID, context: context)
            guard captured == revision, !Task.isCancelled else { return nil }
            return update
        } catch is CancellationError { return nil }
        catch { if captured == revision, !Task.isCancelled { self.error = error.localizedDescription }; return nil }
    }
    func cancel() {
        revision += 1; task?.cancel(); task = nil; querying = false; saving = false; progress = nil
    }
    func cancelQuery() { cancel(); info = L10n.text("Query cancelled.") }
}
