import Combine
import Foundation
import RASWorkspaceCore

struct GdbMapImportItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: String
    let detail: String
    let canImport: Bool
    let unsupportedReason: String?
}

@MainActor
final class GdbMapImportSession: ObservableObject, Identifiable {
    let id = UUID()
    let projectSessionID: UUID
    let mapID: UUID
    let sourceURL: URL

    @Published private(set) var catalog: [GdbMapImportItem] = []
    @Published private(set) var isBusy = false
    @Published private(set) var isImporting = false
    @Published private(set) var errorMessage: String?

    var canImport: Bool {
        !isBusy && !isImporting && catalog.contains(where: \.canImport)
    }

    private weak var store: WorkspaceStore?
    private weak var capturedMapState: MapState?
    private let capturedProjectURL: URL
    private let capturedProjectRevision: String
    private let capturedMapWorkflowIdentity: String
    private let capturedTreeContext: LayerTreeContext
    private let provider: BackendGdbMapSourceProvider
    private var loadedCatalog: GdbMapCatalogResponse?
    private var catalogGeneration = UUID()
    private var retired = false

    init?(store: WorkspaceStore, sourceURL: URL, mapID: UUID,
          provider: BackendGdbMapSourceProvider? = nil) {
        let normalized = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        guard GdbFileGeodatabasePath.root(for: normalized) == normalized,
              let document = store.document, let projectURL = document.url,
              let projectRevision = document.sourceRevision,
              let runtimeInfoClient = store.runtimeInfoClient,
              !store.isRunningProjectTool, !store.isOpeningProject,
              !store.isSavingAll, !store.isClosingTab else { return nil }
        let mapState = store.mapState(for: mapID)
        guard mapState.kind != .unsupported,
              let sourceType = store.mapDocument(for: mapID)?.sourceType ?? mapState.kind.defaultSourceType,
              ["Project", "Buildable", "Geometry", "Plan"].contains(sourceType) else { return nil }

        self.store = store
        self.projectSessionID = store.projectSessionID
        self.mapID = mapID
        self.sourceURL = normalized
        self.capturedProjectURL = projectURL.standardizedFileURL
        self.capturedProjectRevision = projectRevision
        self.capturedMapState = mapState
        self.capturedMapWorkflowIdentity = store.mapWorkflowIdentity(mapID)
        self.capturedTreeContext = store.sourceMapTreeContext(mapID)
        self.provider = provider ?? BackendGdbMapSourceProvider(client: runtimeInfoClient)
    }

    func isCurrent(in candidateStore: WorkspaceStore) -> Bool {
        guard !retired, store === candidateStore,
              candidateStore.pendingGdbMapImport === self,
              candidateStore.projectSessionID == projectSessionID,
              candidateStore.document?.url?.standardizedFileURL == capturedProjectURL,
              candidateStore.existingMapState(for: mapID) === capturedMapState,
              candidateStore.mapWorkflowIdentity(mapID) == capturedMapWorkflowIdentity,
              GdbFileGeodatabasePath.root(for: sourceURL) == sourceURL else { return false }
        return !candidateStore.isRunningProjectTool || (isImporting && candidateStore.isRunningMapMutation)
    }

    func loadCatalog() async {
        guard !isBusy, !isImporting, loadedCatalog == nil,
              let store, isCurrent(in: store) else { return }
        let generation = UUID()
        catalogGeneration = generation
        isBusy = true
        errorMessage = nil
        defer {
            if catalogGeneration == generation { isBusy = false }
        }
        do {
            let response = try await provider.catalog(sourcePath: SourceFilePaths.canonical(sourceURL),
                                                       expectedSourceRevision: nil)
            try response.source.validate(expectedPath: sourceURL)
            guard catalogGeneration == generation, !Task.isCancelled,
                  isCurrent(in: store) else { return }
            let vectorItems = response.layers.map { layer in
                GdbMapImportItem(id: "vector|\(layer.id)", name: layer.name, kind: "Vector",
                    detail: L10n.format("%lld features · %@", layer.featureCount,
                                        layer.geometryType as CVarArg),
                    canImport: (try? layer.validate()) != nil, unsupportedReason: nil)
            }
            let rasterItems = response.rasterSubdatasets.map { raster in
                let canImport = raster.isImportable
                let unavailableReason = raster.diagnostic ?? L10n.text("This raster subdataset is not supported for map rendering.")
                return GdbMapImportItem(id: "raster|\(raster.connectionString)", name: raster.name, kind: "Raster",
                    detail: L10n.format("%d × %d pixels · %d bands · %@", raster.width, raster.height,
                                        raster.bandCount, raster.dataType as CVarArg),
                    canImport: canImport, unsupportedReason: canImport ? nil : unavailableReason)
            }
            loadedCatalog = response
            catalog = vectorItems + rasterItems
        } catch is CancellationError {
            return
        } catch {
            guard catalogGeneration == generation, !Task.isCancelled,
                  isCurrent(in: store) else { return }
            errorMessage = L10n.text(error.localizedDescription)
        }
    }

    /// Imports the complete set of currently supported vector/raster source
    /// children. The backend validates the full directory manifest again in
    /// its single `.vis` mutation; unsupported raster subdatasets remain
    /// visible in the catalog but are never reported as imported.
    func importSelected() async -> Bool {
        guard let store, let catalogSnapshot = loadedCatalog,
              canImport, isCurrent(in: store),
              catalogSnapshot.source.sourcePath == SourceFilePaths.canonical(sourceURL),
              store.document?.sourceRevision == capturedProjectRevision,
              let provider = store.layerTreeProvider as? BackendMapTreeProvider else { return false }
        isBusy = true
        isImporting = true
        errorMessage = nil
        defer { isBusy = false; isImporting = false }

        do {
            let outcome = try await provider.importGdb(sourcePath: SourceFilePaths.canonical(sourceURL),
                source: catalogSnapshot.source, catalog: catalogSnapshot,
                expectedProjectRevision: capturedProjectRevision, context: capturedTreeContext)
            let receipt = outcome.response.receipt
            let isCommittedOwnerCurrent = store.projectSessionID == projectSessionID
                && store.document?.url?.standardizedFileURL == capturedProjectURL
                && store.existingMapState(for: mapID) === capturedMapState
                && store.catalogMapDocuments.contains(where: {
                    $0.id.caseInsensitiveCompare(mapID.uuidString) == .orderedSame
                        && $0.sourceIndex == receipt.mapIndex
                        && $0.name == receipt.mapName
                        && $0.kind == receipt.mapType
                        && $0.visualizationRevision?.caseInsensitiveCompare(receipt.visualizationRevision) == .orderedSame
                })

            if isCommittedOwnerCurrent {
                await store.configureMapResultSources(mapID)
                if let map = store.mapDocument(for: mapID) { store.openMapDocument(map) }
            }
            if let warning = outcome.refreshWarning, store.projectSessionID == projectSessionID {
                store.errorMessage = L10n.format("The File Geodatabase was added, but the map refresh needs attention: %@", warning)
            }
            store.retireGdbMapImport(self)
            retired = true
            return true
        } catch {
            guard store.projectSessionID == projectSessionID,
                  store.document?.url?.standardizedFileURL == capturedProjectURL else { return false }
            errorMessage = L10n.text(error.localizedDescription)
            return false
        }
    }

    /// Cancel read-only discovery and retire this presentation. Once the
    /// backend `.vis` mutation has begun, do not cancel its one-shot process:
    /// it must drain and return the commit receipt to the owning project.
    func cancel() {
        retired = true
        catalogGeneration = UUID()
        if !isImporting { isBusy = false }
        store?.retireGdbMapImport(self)
    }

}
