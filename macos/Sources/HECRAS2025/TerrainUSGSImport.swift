import Foundation
import RASWorkspaceCore
import SwiftUI

struct TerrainUSGSQueryExtent: Codable, Equatable, Sendable {
    let minX: Double
    let maxX: Double
    let minY: Double
    let maxY: Double

    init(_ extent: ViewportRequest) {
        minX = extent.lowerLeft.x
        maxX = extent.upperRight.x
        minY = extent.lowerLeft.y
        maxY = extent.upperRight.y
    }

    init(minX: Double, maxX: Double, minY: Double, maxY: Double) {
        self.minX = minX
        self.maxX = maxX
        self.minY = minY
        self.maxY = maxY
    }

    var isFiniteAndOrdered: Bool {
        minX.isFinite && maxX.isFinite && minY.isFinite && maxY.isFinite &&
            minX < maxX && minY < maxY
    }
}

struct TerrainUSGSMapPoint: Decodable, Equatable, Sendable {
    let x: Double
    let y: Double
}

struct TerrainUSGSProduct: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let publicationDate: String?
    let sizeInBytes: Int64?
    let resolution: String
    let cellSize: Double?
    let metadataUrl: String?
    let boundingBox: TerrainUSGSQueryExtent?
    let projectedBoundary: [TerrainUSGSMapPoint]?
}

struct TerrainUSGSQueryData: Decodable, Sendable {
    let state: String
    let inputId: String?
    let extent: TerrainUSGSQueryExtent
    let targetProjection: String
    let total: Int
    let products: [TerrainUSGSProduct]
    let diagnostic: String?
}

struct TerrainUSGSDownloadedFile: Decodable, Identifiable, Equatable, Sendable {
    let productId: String
    let title: String
    let filePath: String
    let sourceRevision: String
    let defaultScaleFactor: Double
    let defaultRounding: String

    var id: String { productId }
    var fileURL: URL { URL(fileURLWithPath: filePath) }
}

struct TerrainUSGSDownloadData: Decodable, Sendable {
    let state: String
    let cleanupToken: String?
    let files: [TerrainUSGSDownloadedFile]
    let assetPath: String
    let projectPath: String
    let sourceRevision: String
    let inputId: String?
    let extent: TerrainUSGSQueryExtent
    let stitchTiles: Bool
    let diagnostic: String?
}

struct TerrainUSGSCleanupData: Decodable, Sendable {
    let removed: Bool
    let warning: String?
}

struct TerrainUSGSDownloadTransfer: Equatable, Sendable {
    let cleanupToken: String
    let files: [TerrainUSGSDownloadedFile]
    let assetPath: String
    let projectPath: String
    let sourceRevision: String
    let inputId: String?
    let extent: TerrainUSGSQueryExtent
    let stitchTiles: Bool
}

private struct TerrainUSGSQueryRequest: Encodable, Sendable {
    let model: BackendModelProvider.ModelSaveRequest
    let inputId: String?
    let hintExtent: TerrainUSGSQueryExtent?
}

private struct TerrainUSGSDownloadRequest: Encodable, Sendable {
    let model: BackendModelProvider.ModelSaveRequest
    let productIds: [String]
    let inputId: String?
    let hintExtent: TerrainUSGSQueryExtent?
}

private struct TerrainUSGSCleanupModelRequest: Encodable, Sendable {
    let assetPath: String
    let kind: String
    let projectPath: String
}

private struct TerrainUSGSCleanupRequest: Encodable, Sendable {
    let model: TerrainUSGSCleanupModelRequest
    let cleanupToken: String
}

struct TerrainUSGSImportControl: Encodable, Sendable {
    let type: String
    static let cancel = Self(type: "cancel")
}

@MainActor
extension BackendModelProvider {
    func queryTerrainUSGS(capture: TerrainRasterExportCapture,
                          hintExtent: TerrainUSGSQueryExtent?) async throws -> TerrainUSGSQueryData {
        guard capture.asset.section == .terrains,
              capture.edits.sourceRevision?.isEmpty == false,
              project?.url != nil else {
            throw BackendServiceError(code: "invalidInput", message: "The selected Terrain query request is incomplete.")
        }
        let selected = capture.edits.fields[TerrainEditorContract.sourceField]
        let request = TerrainUSGSQueryRequest(model: try saveRequest(capture.asset, changes: capture.edits),
            inputId: selected.flatMap { $0.isEmpty ? nil : $0 }, hintExtent: hintExtent)
        return try await client.request("model.terrainUSGSQuery", parameters: request, as: TerrainUSGSQueryData.self)
    }

    func startTerrainUSGSDownload(capture: TerrainRasterExportCapture,
                                  productIds: [String], hintExtent: TerrainUSGSQueryExtent?) throws
        -> BackendDuplexOperation<TerrainUSGSImportControl, BackendProgressUpdate, TerrainUSGSDownloadData> {
        guard capture.asset.section == .terrains,
              capture.edits.sourceRevision?.isEmpty == false,
              project?.url != nil,
              !productIds.isEmpty,
              Set(productIds).count == productIds.count else {
            throw BackendServiceError(code: "invalidInput", message: "Choose one or more unique USGS terrain products.")
        }
        let selected = capture.edits.fields[TerrainEditorContract.sourceField]
        let request = TerrainUSGSDownloadRequest(model: try saveRequest(capture.asset, changes: capture.edits),
            productIds: productIds, inputId: selected.flatMap { $0.isEmpty ? nil : $0 }, hintExtent: hintExtent)
        return try client.startDuplex("model.terrainUSGSDownload", parameters: request,
            control: TerrainUSGSImportControl.self, event: BackendProgressUpdate.self,
            as: TerrainUSGSDownloadData.self)
    }

    func cleanupTerrainUSGS(_ transfer: TerrainUSGSDownloadTransfer) async throws -> TerrainUSGSCleanupData {
        let request = TerrainUSGSCleanupRequest(
            model: TerrainUSGSCleanupModelRequest(assetPath: transfer.assetPath, kind: "Terrain",
                projectPath: transfer.projectPath), cleanupToken: transfer.cleanupToken)
        return try await client.request("model.terrainUSGSCleanup", parameters: request, as: TerrainUSGSCleanupData.self)
    }
}

struct TerrainUSGSImportView: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    let hintExtent: ViewportRequest?
    let onDownload: @MainActor (TerrainUSGSDownloadTransfer) -> Void

    @State private var products: [TerrainUSGSProduct] = []
    @State private var selectedProductIDs: Set<String> = []
    @State private var queryExtent: TerrainUSGSQueryExtent?
    @State private var queryInputID: String?
    @State private var progress: BackendProgressUpdate?
    @State private var error: String?
    @State private var isQuerying = false
    @State private var isDownloading = false
    @State private var isCancelling = false
    @State private var cancelRequested = false
    @State private var activeDownload: BackendDuplexOperation<TerrainUSGSImportControl,
        BackendProgressUpdate, TerrainUSGSDownloadData>?
    @State private var controlSequence: UInt64 = 0
    @State private var requestGeneration = UUID()
    @State private var overlayOwnerID = UUID()
    @State private var overlayTicket: TerrainUSGSTileOverlayTicket?

    private var backend: BackendModelProvider? { store.modelProvider as? BackendModelProvider }
    private var currentCapture: TerrainRasterExportCapture? {
        guard store.assets.contains(where: { $0.id == session.modelAssetID }),
              let capture = session.captureTerrainRasterExportContext(),
              session.isCurrentTerrainRasterExportContext(capture) else { return nil }
        return capture
    }
    private var selectedProducts: [TerrainUSGSProduct] {
        products.filter { selectedProductIDs.contains($0.id) }
    }

    private var productList: some View {
        List(products, selection: $selectedProductIDs) { product in
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(product.title).lineLimit(2)
                    HStack(spacing: 8) {
                        Text(product.resolution)
                        if let cellSize = product.cellSize, cellSize.isFinite, cellSize > 0 {
                            Text(L10n.format("%g m cell size", cellSize))
                        }
                        if let publicationDate = product.publicationDate {
                            Text(publicationDate)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let bytes = product.sizeInBytes, bytes >= 0 {
                    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .tag(product.id)
        }
        .frame(minHeight: 180)
    }


    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L10n.text("USGS Terrain Products"), systemImage: "mountain.2.circle")
                    .font(.headline)
                Spacer()
                Button(L10n.text("Query USGS")) { Task { await queryProducts() } }
                    .disabled(isQuerying || isDownloading || backend == nil || currentCapture == nil)
                Button(L10n.text("Download Selected")) { Task { await downloadSelected() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(isQuerying || isDownloading || selectedProducts.isEmpty || backend == nil || currentCapture == nil)
            }
            Text(L10n.text("Queries real USGS elevation products for the selected terrain extent. Source TIFFs are staged through the terrain importer."))
                .font(.caption).foregroundStyle(.secondary)
            if isQuerying {
                ProgressView(L10n.text("Querying USGS terrain products…"))
            }
            if isDownloading {
                OperationProgressView(title: "Preparing USGS terrain files…",
                    message: L10n.text(progress?.message ?? progress?.taskName ?? "Downloading and validating terrain products…"),
                    fraction: progress?.fraction, cancelling: isCancelling,
                    cancel: isCancelling ? nil : { cancelDownload() })
            }
            if let error {
                Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).textSelection(.enabled)
            }
            if products.isEmpty && !isQuerying {
                ContentUnavailableView(L10n.text("No USGS Products"), systemImage: "mountain.2",
                    description: Text(L10n.text("Query a finite terrain or map extent to list available elevation products.")))
                    .frame(minHeight: 140)
            } else {
                productList
                HStack {
                    Text(L10n.format("%d products", products.count)).foregroundStyle(.secondary)
                    Text(L10n.format("%d selected", selectedProductIDs.count)).foregroundStyle(.secondary)
                    Spacer()
                    if let queryExtent {
                        Text(L10n.format("Extent: %g, %g to %g, %g", queryExtent.minX, queryExtent.minY,
                            queryExtent.maxX, queryExtent.maxY))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .padding(12)
        .onChange(of: selectedProductIDs) { _, selectedIDs in
            guard let overlayTicket else { return }
            store.terrainUSGSTileOverlay.select(selectedIDs, matching: overlayTicket)
        }
        .onChange(of: store.projectSessionID) { _, _ in invalidateQueryOverlayIfNeeded() }
        .onChange(of: store.lastActiveMapID) { _, _ in invalidateQueryOverlayIfNeeded() }
        .onChange(of: store.mapWorkflowIdentity(store.lastActiveMapID)) { _, _ in
            invalidateQueryOverlayIfNeeded()
        }
        .onChange(of: currentCapture?.id ?? "unavailable") { _, _ in
            invalidateQueryOverlayIfNeeded()
        }
        .onDisappear {
            requestGeneration = UUID()
            isQuerying = false
            if let overlayTicket {
                store.terrainUSGSTileOverlay.clear(matching: overlayTicket)
                self.overlayTicket = nil
            }
            if isDownloading { cancelDownload() }
        }
    }

    @MainActor
    private func invalidateQueryOverlayIfNeeded() {
        guard let overlayTicket else { return }
        store.terrainUSGSTileOverlay.clear(matching: overlayTicket)
        self.overlayTicket = nil
        if isQuerying && !isDownloading {
            requestGeneration = UUID()
            isQuerying = false
        }
    }

    @MainActor
    private func queryProducts() async {
        guard !isQuerying, !isDownloading, let backend, let capture = currentCapture else { return }
        let capturedProjectSessionID = store.projectSessionID
        let capturedMapID = store.lastActiveMapID
        let capturedMapWorkflowIdentity = store.mapWorkflowIdentity(capturedMapID)
        if let oldTicket = overlayTicket { store.terrainUSGSTileOverlay.clear(matching: oldTicket) }
        let generation = UUID()
        requestGeneration = generation
        let ticket: TerrainUSGSTileOverlayTicket?
        if store.mapIdentityRequest(for: capturedMapID) != nil,
           let capturedSourceRevision = capture.edits.sourceRevision,
           !capturedSourceRevision.isEmpty {
            let newTicket = TerrainUSGSTileOverlayTicket(ownerID: overlayOwnerID,
                requestID: generation, projectSessionID: capturedProjectSessionID,
                editorID: capture.editorID, captureID: capture.id,
                mapID: capturedMapID, mapWorkflowIdentity: capturedMapWorkflowIdentity,
                terrainAssetPath: SourceFilePaths.canonical(capture.asset.url),
                terrainSourceRevision: capturedSourceRevision)
            ticket = newTicket
            overlayTicket = newTicket
            store.terrainUSGSTileOverlay.begin(newTicket)
        } else {
            ticket = nil
            overlayTicket = nil
        }
        isQuerying = true
        error = nil
        products = []
        selectedProductIDs = []
        queryExtent = nil
        queryInputID = nil
        defer { if requestGeneration == generation { isQuerying = false } }
        do {
            let extent = hintExtent.flatMap { TerrainUSGSQueryExtent($0).isFiniteAndOrdered ? TerrainUSGSQueryExtent($0) : nil }
            let result = try await backend.queryTerrainUSGS(capture: capture, hintExtent: extent)
            guard requestGeneration == generation, !Task.isCancelled,
                  store.projectSessionID == capturedProjectSessionID,
                  store.assets.contains(where: { $0.id == capture.asset.id }),
                  session.isCurrentTerrainRasterExportContext(capture) else {
                if let ticket {
                    store.terrainUSGSTileOverlay.clear(matching: ticket)
                    if overlayTicket == ticket { overlayTicket = nil }
                }
                return
            }
            guard result.state == "completed", result.total >= 0,
                  result.extent.isFiniteAndOrdered,
                  result.products.allSatisfy({ !$0.id.isEmpty && !$0.title.isEmpty }) else {
                throw ProjectFileError.invalid(result.diagnostic ?? "The USGS query response is incomplete.")
            }
            products = result.products
            queryExtent = result.extent
            queryInputID = result.inputId
            if let ticket {
                guard store.projectSessionID == ticket.projectSessionID,
                      store.lastActiveMapID == ticket.mapID,
                      store.mapWorkflowIdentity(ticket.mapID) == ticket.mapWorkflowIdentity else {
                    store.terrainUSGSTileOverlay.clear(matching: ticket)
                    if overlayTicket == ticket { overlayTicket = nil }
                    return
                }
                let snapshot = TerrainUSGSTileOverlaySnapshot(ticket: ticket,
                    targetProjectionWkt: result.targetProjection, extent: result.extent,
                    products: result.products, selectedProductIDs: selectedProductIDs)
                guard store.terrainUSGSTileOverlay.install(snapshot, matching: ticket) else { return }
            }
            if let diagnostic = result.diagnostic, !diagnostic.isEmpty { error = diagnostic }
        } catch {
            guard requestGeneration == generation else { return }
            if let ticket {
                store.terrainUSGSTileOverlay.clear(matching: ticket)
                if overlayTicket == ticket { overlayTicket = nil }
            }
            self.error = L10n.text(error.localizedDescription)
        }
    }

    @MainActor
    private func downloadSelected() async {
        guard !isQuerying, !isDownloading, !selectedProducts.isEmpty,
              let backend, let capture = currentCapture,
              let queryExtent else {
            error = L10n.text("Refresh the USGS query after the selected terrain changes.")
            return
        }
        let generation = UUID()
        requestGeneration = generation
        let capturedProjectPath = backend.project?.url?.path ?? ""
        let productIDs = selectedProducts.map(\.id)
        isDownloading = true
        isCancelling = false
        cancelRequested = false
        controlSequence = 0
        progress = nil
        error = nil
        defer {
            activeDownload = nil
            isDownloading = false
            isCancelling = false
            cancelRequested = false
        }
        do {
            let operation = try backend.startTerrainUSGSDownload(capture: capture,
                productIds: productIDs,
                hintExtent: queryExtent)
            activeDownload = operation
            var sentCancel = false
            if requestGeneration != generation || cancelRequested {
                sentCancel = sendCancel(to: operation)
            }
            for try await update in operation.events {
                if requestGeneration == generation {
                    progress = update
                } else if (requestGeneration != generation || cancelRequested) && !sentCancel {
                    sentCancel = sendCancel(to: operation)
                }
            }
            let result = try await operation.value()
            if result.state == "cancelled" || requestGeneration != generation || cancelRequested {
                try? await cleanupIfPresent(result, backend: backend, capture: capture,
                    projectPath: capturedProjectPath)
                return
            }
            guard requestGeneration == generation, !Task.isCancelled,
                  store.assets.contains(where: { $0.id == capture.asset.id }),
                  session.isCurrentTerrainRasterExportContext(capture) else {
                try? await cleanupIfPresent(result, backend: backend, capture: capture,
                    projectPath: capturedProjectPath)
                return
            }
            guard result.state == "completed", let token = result.cleanupToken,
                  !token.isEmpty, result.files.count == productIDs.count,
                  Set(result.files.map(\.productId)) == Set(productIDs),
                  result.files.allSatisfy({ file in
                      file.sourceRevision.count == 64 && file.sourceRevision.allSatisfy { $0.isHexDigit } &&
                          file.defaultScaleFactor.isFinite && file.defaultScaleFactor > 0 &&
                          file.defaultRounding == "ThirtySeconds" &&
                          file.fileURL.pathExtension.lowercased() == "tif" &&
                          FileManager.default.fileExists(atPath: file.filePath)
                  }),
                  result.sourceRevision.caseInsensitiveCompare(capture.edits.sourceRevision ?? "") == .orderedSame,
                  canonicalPath(result.assetPath) == canonicalPath(capture.asset.url.path),
                  canonicalPath(result.projectPath) == canonicalPath(capturedProjectPath),
                  result.extent.isFiniteAndOrdered,
                  result.extent == queryExtent,
                  result.stitchTiles,
                  result.inputId == queryInputID else {
                try? await cleanupIfPresent(result, backend: backend, capture: capture,
                    projectPath: capturedProjectPath)
                throw ProjectFileError.invalid(result.diagnostic ?? "The USGS download response does not match the selected terrain query.")
            }
            let transfer = TerrainUSGSDownloadTransfer(cleanupToken: token, files: result.files,
                assetPath: result.assetPath, projectPath: result.projectPath,
                sourceRevision: result.sourceRevision, inputId: result.inputId,
                extent: result.extent, stitchTiles: result.stitchTiles)
            activeDownload = nil
            isDownloading = false
            isCancelling = false
            cancelRequested = false
            onDownload(transfer)
        } catch {
            guard requestGeneration == generation else { return }
            self.error = L10n.text(error.localizedDescription)
        }
    }

    @MainActor
    private func cancelDownload() {
        guard isDownloading, !isCancelling else { return }
        cancelRequested = true
        guard let activeDownload else {
            isCancelling = true
            return
        }
        _ = sendCancel(to: activeDownload)
    }

    @MainActor
    @discardableResult
    private func sendCancel(to operation: BackendDuplexOperation<TerrainUSGSImportControl,
                              BackendProgressUpdate, TerrainUSGSDownloadData>) -> Bool {
        guard !isCancelling || cancelRequested else { return isCancelling }
        controlSequence &+= 1
        do {
            try operation.sendControl(.cancel, sequence: controlSequence)
            isCancelling = true
        } catch {
            self.error = L10n.text(error.localizedDescription)
            return false
        }
        return true
    }

    @MainActor
    private func cleanupIfPresent(_ result: TerrainUSGSDownloadData,
                                  backend: BackendModelProvider, capture: TerrainRasterExportCapture,
                                  projectPath: String) async throws {
        guard let token = result.cleanupToken, !token.isEmpty,
              !projectPath.isEmpty,
              canonicalPath(result.assetPath) == canonicalPath(capture.asset.url.path),
              canonicalPath(result.projectPath) == canonicalPath(projectPath) else { return }
        let transfer = TerrainUSGSDownloadTransfer(cleanupToken: token, files: result.files,
            assetPath: capture.asset.url.path, projectPath: projectPath,
            sourceRevision: result.sourceRevision, inputId: result.inputId,
            extent: result.extent,
            stitchTiles: result.stitchTiles)
        session.terrainUSGSImportCleanup.enqueue(transfer, provider: backend, after: session)
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
