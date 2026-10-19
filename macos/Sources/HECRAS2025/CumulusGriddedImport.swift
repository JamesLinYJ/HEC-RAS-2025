import CryptoKit
import Foundation
import RASWorkspaceCore
import SwiftUI
import WebKit

struct CumulusGridImportSource: Encodable, Equatable, Sendable, Identifiable {
    let id: String
    let datetimeUtc: String
    let versionUtc: String
}

struct CumulusImportExtent: Codable, Equatable, Sendable {
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

    var isValid: Bool {
        [minX, maxX, minY, maxY].allSatisfy(\.isFinite)
            && minX < maxX && minY < maxY
    }
}

/// Exact Cumulus query and target-layer selection. The model draft is supplied
/// by ModelEditorSession so import and existing edits share one save transaction.
struct CumulusGridImportSelection: Encodable, Equatable, Sendable {
    let environmentId: String
    let accessToken: String?
    let productId: String
    let afterUtc: String
    let beforeUtc: String
    let sources: [CumulusGridImportSource]
    let layerId: String
    let clipExtent: CumulusImportExtent?
    let clipProjectionWkt: String?
    let precipitationDataType: String
    let precipitationUnits: String
}

struct CumulusEnvironmentOption: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let requiresSignIn: Bool
    let authorizeEndpoint: String?
    let clientId: String?
    let redirectUri: String?
    let idpHint: String?
    let mockAccessToken: String?
    let isSelectable: Bool?
}

struct CumulusTokenResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let accessExpiresUtc: String
    let refreshExpiresUtc: String
}

struct CumulusProductOption: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let slug: String?
    let label: String?
    let parameter: String?
    let unit: String?
    let temporalResolution: Int
    let temporalDuration: Int
    let dssDatatype: String?
    let afterUtc: String?
    let beforeUtc: String?
    let isPrecip: Bool
}

struct CumulusGridSourceOption: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let datetimeUtc: String
    let versionUtc: String
}

struct CumulusGridFootprintCoordinate: Decodable, Equatable, Sendable {
    let x: Double
    let y: Double
}

struct CumulusGridFootprint: Decodable, Equatable, Sendable {
    let sourceId: String
    let datetimeUtc: String
    let versionUtc: String
    let sourceProjectionWkt: String
    let targetProjectionWkt: String
    let extent: CumulusImportExtent
    let points: [CumulusGridFootprintCoordinate]

    var isValid: Bool {
        guard points.count == 48, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              !sourceProjectionWkt.isEmpty, !targetProjectionWkt.isEmpty, extent.isValid else { return false }
        let pointBounds = [points.map(\.x).min()!, points.map(\.x).max()!,
            points.map(\.y).min()!, points.map(\.y).max()!]
        let extentBounds = [extent.minX, extent.maxX, extent.minY, extent.maxY]
        return zip(pointBounds, extentBounds).allSatisfy { point, bound in
            abs(point - bound) <= max(abs(bound), 1) * 1e-12
        }
    }
}

private struct CumulusGridFootprintRequest: Encodable, Sendable {
    let environmentId: String
    let accessToken: String?
    let productId: String
    let afterUtc: String
    let beforeUtc: String
    let sourceId: String
    let datetimeUtc: String
    let versionUtc: String
    let targetProjectionWkt: String
}

private struct CumulusGridFootprintCapture: Equatable {
    let projectSessionID: UUID
    let projectPath: String
    let editorID: UUID
    let mapID: UUID
    let environmentID: String
    let productID: String
    let afterUtc: String
    let beforeUtc: String
    let source: CumulusGridImportSource
    let targetProjectionWkt: String
}

private struct CumulusEnvironmentRequest: Encodable, Sendable { let environmentId: String? = nil }
private struct CumulusTokenExchangeRequest: Encodable, Sendable {
    let environmentId: String
    let code: String
    let verifier: String
}
private struct CumulusTokenRefreshRequest: Encodable, Sendable {
    let environmentId: String
    let refreshToken: String
}
private struct CumulusProductsRequest: Encodable, Sendable {
    let environmentId: String
    let accessToken: String?
}
private struct CumulusGridQueryRequest: Encodable, Sendable {
    let environmentId: String
    let accessToken: String?
    let productId: String
    let afterUtc: String
    let beforeUtc: String
}
private struct CumulusGridImportRequest: Encodable, Sendable {
    let model: BackendModelProvider.ModelSaveRequest
    let environmentId: String
    let accessToken: String?
    let productId: String
    let afterUtc: String
    let beforeUtc: String
    let sources: [CumulusGridImportSource]
    let layerId: String
    let clipExtent: CumulusImportExtent?
    let clipProjectionWkt: String?
    let precipitationDataType: String
    let precipitationUnits: String
}
private struct CumulusGridImportResponse: Decodable, Sendable {
    let state: String
    let snapshot: BackendModelProvider.ModelSnapshot?
    let errorMessage: String?
}
private struct CumulusImportControl: Encodable, Sendable {
    let type: String
    static let cancel = Self(type: "cancel")
}

private final class CumulusGridImportCancelSender: @unchecked Sendable {
    private let lock = NSLock()
    private let operation: BackendDuplexOperation<CumulusImportControl,
        BackendProgressUpdate, CumulusGridImportResponse>
    private var sequence: UInt64 = 0
    private var sent = false

    init(operation: BackendDuplexOperation<CumulusImportControl,
         BackendProgressUpdate, CumulusGridImportResponse>) {
        self.operation = operation
    }

    func cancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !sent else { return true }
        sequence &+= 1
        do {
            try operation.sendControl(.cancel, sequence: sequence)
            sent = true
            return true
        } catch {
            return false
        }
    }
}

@MainActor
private final class CumulusGridImportCancellation {
    static let shared = CumulusGridImportCancellation()
    private var pendingImportID: UUID?
    private var activeOperationID: String?
    private var requestCancel: (() -> Bool)?
    private var cancellationPending = false

    func begin(importID: UUID) {
        pendingImportID = importID
        activeOperationID = nil
        requestCancel = nil
        cancellationPending = false
    }

    func install(operationID: String, cancel: @escaping () -> Bool) {
        activeOperationID = operationID
        requestCancel = cancel
        if cancellationPending { _ = cancel() }
    }

    func clear(operationID: String) {
        guard activeOperationID == operationID else { return }
        activeOperationID = nil
        requestCancel = nil
    }

    func cancel(importID: UUID) -> Bool {
        guard pendingImportID == importID else { return false }
        guard let requestCancel else {
            cancellationPending = true
            return true
        }
        return requestCancel()
    }

    func end(importID: UUID) {
        guard pendingImportID == importID else { return }
        pendingImportID = nil
        activeOperationID = nil
        requestCancel = nil
        cancellationPending = false
    }
}

@MainActor
extension BackendModelProvider {
    func cumulusEnvironments() async throws -> [CumulusEnvironmentOption] {
        try await client.request("cumulus.environments", parameters: CumulusEnvironmentRequest(),
            as: [CumulusEnvironmentOption].self)
    }

    func exchangeCumulusToken(environmentId: String, code: String, verifier: String) async throws -> CumulusTokenResponse {
        try await client.request("cumulus.token.exchange",
            parameters: CumulusTokenExchangeRequest(environmentId: environmentId, code: code, verifier: verifier),
            as: CumulusTokenResponse.self)
    }

    func refreshCumulusToken(environmentId: String, refreshToken: String) async throws -> CumulusTokenResponse {
        try await client.request("cumulus.token.refresh",
            parameters: CumulusTokenRefreshRequest(environmentId: environmentId, refreshToken: refreshToken),
            as: CumulusTokenResponse.self)
    }

    func cumulusProducts(environmentId: String, accessToken: String?) async throws -> [CumulusProductOption] {
        try await client.request("cumulus.products",
            parameters: CumulusProductsRequest(environmentId: environmentId, accessToken: accessToken),
            as: [CumulusProductOption].self)
    }

    func queryCumulusGrids(environmentId: String, accessToken: String?, productId: String,
                           afterUtc: String, beforeUtc: String) async throws -> [CumulusGridSourceOption] {
        try await client.request("cumulus.grids.query",
            parameters: CumulusGridQueryRequest(environmentId: environmentId, accessToken: accessToken,
                productId: productId, afterUtc: afterUtc, beforeUtc: beforeUtc),
            as: [CumulusGridSourceOption].self)
    }

    func probeCumulusGridFootprint(environmentId: String, accessToken: String?, productId: String,
                                   afterUtc: String, beforeUtc: String,
                                   source: CumulusGridImportSource,
                                   targetProjectionWkt: String) async throws -> CumulusGridFootprint {
        let footprint = try await client.request("cumulus.grids.footprint",
            parameters: CumulusGridFootprintRequest(environmentId: environmentId,
                accessToken: accessToken, productId: productId, afterUtc: afterUtc,
                beforeUtc: beforeUtc, sourceId: source.id, datetimeUtc: source.datetimeUtc,
                versionUtc: source.versionUtc, targetProjectionWkt: targetProjectionWkt),
            as: CumulusGridFootprint.self)
        guard footprint.isValid, footprint.sourceId == source.id,
              footprint.datetimeUtc == source.datetimeUtc, footprint.versionUtc == source.versionUtc,
              footprint.targetProjectionWkt == targetProjectionWkt else {
            throw BackendServiceError(code: "protocolFailure",
                message: "The Cumulus footprint did not match the selected source and map projection.")
        }
        return footprint
    }

    func importCumulusGrid(_ asset: ProjectAsset, edits: EditorEdits,
                           selection: CumulusGridImportSelection,
                           progress: @escaping @MainActor (BackendProgressUpdate) -> Void) async throws -> EditorSaveResult {
        guard asset.section == .boundaryConditions,
              !selection.environmentId.isEmpty, !selection.productId.isEmpty,
              !selection.layerId.isEmpty, !selection.sources.isEmpty else {
            throw BackendServiceError(code: "invalidInput", message: "Choose a Cumulus product, source times, and Boundary Condition layer.")
        }
        if let clip = selection.clipExtent, !clip.isValid {
            throw BackendServiceError(code: "invalidInput", message: "The Cumulus download area must be a finite, non-empty extent.")
        }
        if selection.clipExtent != nil, selection.clipProjectionWkt?.isEmpty != false {
            throw BackendServiceError(code: "invalidInput", message: "The drawn Cumulus area has no captured map projection.")
        }
        let request = CumulusGridImportRequest(model: try saveRequest(asset, changes: edits),
            environmentId: selection.environmentId, accessToken: selection.accessToken,
            productId: selection.productId, afterUtc: selection.afterUtc, beforeUtc: selection.beforeUtc,
            sources: selection.sources, layerId: selection.layerId, clipExtent: selection.clipExtent,
            clipProjectionWkt: selection.clipProjectionWkt,
            precipitationDataType: selection.precipitationDataType,
            precipitationUnits: selection.precipitationUnits)
        try Task.checkCancellation()
        let operation = try client.startDuplex("model.cumulusGridImport", parameters: request,
            control: CumulusImportControl.self, event: BackendProgressUpdate.self,
            as: CumulusGridImportResponse.self)
        let cancelSender = CumulusGridImportCancelSender(operation: operation)
        CumulusGridImportCancellation.shared.install(operationID: operation.id) {
            cancelSender.cancel()
        }
        defer { CumulusGridImportCancellation.shared.clear(operationID: operation.id) }
        // Drain the duplex stream and terminal result in an independent task.
        // Cancelling the owning editor task sends the backend's cooperative
        // cancel control, but must not cancel the child process: it may already
        // have atomically published the model and need to return that snapshot.
        let importTask = Task.detached(priority: .userInitiated) {
            do {
                for try await update in operation.events {
                    await progress(update)
                }
            } catch {
                // The terminal result remains authoritative. In particular, a
                // successfully published snapshot must still be acknowledged.
            }
            return try await operation.value()
        }
        let result = try await withTaskCancellationHandler {
            try await importTask.value
        } onCancel: {
            _ = cancelSender.cancel()
        }
        switch result.state {
        case "completed":
            guard let snapshot = result.snapshot else {
                throw BackendServiceError(code: "protocolFailure", message: "The Cumulus import completed without a saved model snapshot.")
            }
            return EditorSaveResult(sourceRevision: snapshot.revision,
                snapshot: try snapshot.editorSnapshot)
        case "cancelled": throw CancellationError()
        default:
            throw BackendServiceError(code: "processFailure",
                message: result.errorMessage ?? "The Cumulus grid import did not complete.")
        }
    }
}

struct CumulusSourceTimeGroup: Identifiable, Sendable {
    let datetimeUtc: String
    let options: [CumulusGridSourceOption]
    var id: String { datetimeUtc }
}

enum CumulusGridSourceProjection {
    static func groups(_ sources: [CumulusGridSourceOption]) -> [CumulusSourceTimeGroup] {
        Dictionary(grouping: sources, by: \.datetimeUtc).map { key, items in
            CumulusSourceTimeGroup(datetimeUtc: key,
                options: items.sorted { ($0.versionUtc, $0.id) > ($1.versionUtc, $1.id) })
        }.sorted { $0.datetimeUtc < $1.datetimeUtc }
    }

    static func defaultSelections(_ sources: [CumulusGridSourceOption]) -> [String: String] {
        Dictionary(grouping: sources, by: \.datetimeUtc).compactMapValues { items in
            items.sorted { ($0.versionUtc, $0.id) > ($1.versionUtc, $1.id) }.first?.id
        }
    }

    static func selectedSources(in groups: [CumulusSourceTimeGroup], selections: [String: String]) -> [CumulusGridImportSource] {
        groups.compactMap { group in
            guard let id = selections[group.id],
                  let source = group.options.first(where: { $0.id == id }) else { return nil }
            return CumulusGridImportSource(id: source.id, datetimeUtc: source.datetimeUtc,
                versionUtc: source.versionUtc)
        }
    }
}

@MainActor
struct CumulusGriddedImportRoute: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var session: ModelEditorSession
    let assetID: String
    let layerID: String
    let mapID: UUID
    let initialExtent: ViewportRequest?
    let isImportingChanged: (Bool) -> Void

    @State private var environments: [CumulusEnvironmentOption] = []
    @State private var selectedEnvironmentID = ""
    @State private var products: [CumulusProductOption] = []
    @State private var selectedProductID = ""
    @State private var sources: [CumulusGridSourceOption] = []
    @State private var selectedSourceByTime: [String: String] = [:]
    @State private var footprint: CumulusGridFootprint?
    @State private var footprintCapture: CumulusGridFootprintCapture?
    @State private var isProbingFootprint = false
    @State private var footprintError: String?
    @State private var footprintProbeID = UUID()
    @State private var afterDate = Self.utcDayStart(Calendar(identifier: .gregorian).date(byAdding: .month, value: -1, to: Date()) ?? Date())
    @State private var beforeDate = Self.utcDayStart(Date())
    @State private var queriedProductID: String?
    @State private var queriedEnvironmentID: String?
    @State private var queriedAfterUtc: String?
    @State private var queriedBeforeUtc: String?
    @State private var clipArea: ViewportRequest?
    @State private var clipProjectionWkt: String?
    @State private var precipitationDataType = "per-cum"
    @State private var precipitationUnits = "mm"
    @State private var accessToken: String?
    @State private var refreshToken: String?
    @State private var accessExpiresUtc: String?
    @State private var authorizationURL: URL?
    @State private var expectedRedirectURI: String?
    @State private var pkceVerifier: String?
    @State private var expectedOAuthState: String?
    @State private var showingAuthorization = false
    @State private var progress: BackendProgressUpdate?
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var isLoadingEnvironments = false
    @State private var isLoadingProducts = false
    @State private var isExchangingToken = false
    @State private var isQuerying = false
    @State private var isImporting = false
    @State private var isCancelling = false
    @State private var activeTask: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var environmentSelectionGeneration = UUID()
    @State private var importID = UUID()

    private let capturedProjectSessionID: UUID
    private let capturedEditorID: UUID
    private let capturedProjectPath: String?
    private let backend: BackendModelProvider?

    init(store: WorkspaceStore, session: ModelEditorSession, assetID: String, layerID: String,
         mapID: UUID, initialExtent: ViewportRequest?, isImportingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.store = store
        self.session = session
        self.assetID = assetID
        self.layerID = layerID
        self.mapID = mapID
        self.initialExtent = initialExtent
        self.isImportingChanged = isImportingChanged
        capturedProjectSessionID = store.projectSessionID
        capturedEditorID = session.id
        capturedProjectPath = store.document?.url.map { Self.canonicalPath($0.path) }
        backend = store.modelProvider as? BackendModelProvider
    }

    private var selectedEnvironment: CumulusEnvironmentOption? {
        environments.first { $0.id == selectedEnvironmentID }
    }
    private var layerTitle: String {
        switch layerID {
        case "precipitation": L10n.text("Precipitation")
        case "wind": L10n.text("Wind")
        case "airPressure": L10n.text("Air Pressure")
        case "airDensity": L10n.text("Air Density")
        default: L10n.format("Unsupported layer: %@", layerID)
        }
    }
    private var selectedProduct: CumulusProductOption? {
        products.first { $0.id == selectedProductID }
    }
    private var timeGroups: [CumulusSourceTimeGroup] {
        CumulusGridSourceProjection.groups(sources)
    }
    private var chosenSources: [CumulusGridImportSource] {
        CumulusGridSourceProjection.selectedSources(in: timeGroups, selections: selectedSourceByTime)
    }
    private var currentFootprintCapture: CumulusGridFootprintCapture? {
        guard let environment = selectedEnvironment, let product = selectedProduct,
              let source = chosenSources.last, queryMatchesCurrentInputs, mapIsCurrent,
              let projectPath = capturedProjectPath,
              let targetProjectionWkt = store.document?.projectionValue,
              !targetProjectionWkt.isEmpty else { return nil }
        return CumulusGridFootprintCapture(projectSessionID: capturedProjectSessionID,
            projectPath: projectPath, editorID: capturedEditorID, mapID: mapID,
            environmentID: environment.id, productID: product.id,
            afterUtc: Self.utcString(Self.utcDayStart(afterDate)),
            beforeUtc: Self.utcString(Self.utcDayEnd(beforeDate)),
            source: source, targetProjectionWkt: targetProjectionWkt)
    }
    private var currentFootprint: CumulusGridFootprint? {
        guard let footprint, footprintCapture == currentFootprintCapture else { return nil }
        return footprint
    }
    private var hasValidRange: Bool {
        let start = Self.utcDayStart(afterDate)
        let end = Self.utcDayEnd(beforeDate)
        return start < end && (Calendar(identifier: .gregorian).date(byAdding: .month, value: 6, to: start) ?? .distantPast) >= end
    }
    private var hasCurrentOwner: Bool {
        guard store.projectSessionID == capturedProjectSessionID,
              let capturedProjectPath, let currentProjectPath = store.document?.url?.path,
              Self.canonicalPath(currentProjectPath) == capturedProjectPath,
              store.assets.contains(where: { $0.id == assetID && $0.section == .boundaryConditions }),
              session.id == capturedEditorID, session.modelAssetID == assetID,
              store.spatialImportEditorSession(assetID: assetID)?.id == session.id,
              store.activeSpatialImportLayerID == layerID,
              store.activeSpatialImportEditorID == session.id else { return false }
        return true
    }
    private var mapIsCurrent: Bool { store.lastActiveMapID == mapID }
    private var canQuery: Bool {
        hasCurrentOwner && !isLoadingProducts && !isQuerying && !isImporting && !isProbingFootprint
            && selectedEnvironment?.isSelectable != false && selectedProduct != nil
            && hasValidRange && accessToken != nil
    }
    private var canImport: Bool {
        hasCurrentOwner && !isLoadingEnvironments && !isLoadingProducts && !isQuerying && !isImporting
            && selectedProduct != nil && queryMatchesCurrentInputs && !chosenSources.isEmpty && accessToken != nil
            && selectedEnvironment?.isSelectable != false
            && (clipArea == nil || mapIsCurrent && clipProjectionWkt?.isEmpty == false
                && clipProjectionWkt == store.document?.projectionValue)
    }
    private var queryMatchesCurrentInputs: Bool {
        guard let product = selectedProduct, let environment = selectedEnvironment,
              let queriedProductID, let queriedEnvironmentID, let queriedAfterUtc, let queriedBeforeUtc else { return false }
        return queriedProductID == product.id && queriedEnvironmentID == environment.id
            && queriedAfterUtc == Self.utcString(Self.utcDayStart(afterDate))
            && queriedBeforeUtc == Self.utcString(Self.utcDayEnd(beforeDate))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L10n.text("Cumulus Gridded Data Import"), systemImage: "cloud.arrow.down")
                    .font(.headline)
                Spacer()
                if isImporting {
                    Button(L10n.text(isCancelling ? "Cancelling…" : "Cancel Import"), systemImage: "xmark.circle") {
                        cancelImport()
                    }.disabled(isCancelling)
                }
            }
            .padding(.horizontal, 14).padding(.top, 14)
            if backend == nil {
                ContentUnavailableView(L10n.text("Cumulus import backend unavailable."),
                    systemImage: "cloud.slash", description: Text(L10n.text("The bundled Cumulus provider is not connected.")))
                    .frame(minHeight: 330)
            } else if !hasCurrentOwner {
                ContentUnavailableView(L10n.text("Spatial import editor unavailable"),
                    systemImage: "square.stack.3d.up.slash",
                    description: Text(L10n.text("Reopen the gridded import from its owning boundary condition.")))
                    .frame(minHeight: 330)
            } else if isImporting {
                progressContent
            } else {
                importForm
            }
        }
        .frame(minWidth: 700, minHeight: 560)
        .task { await loadEnvironments() }
        .sheet(isPresented: $showingAuthorization, onDismiss: { clearPendingAuthorization() }) {
            if let authorizationURL, let expectedRedirectURI {
                CumulusAuthorizationSheet(authorizationURL: authorizationURL,
                    redirectURI: expectedRedirectURI, onRedirect: handleAuthorizationRedirect)
                    .frame(minWidth: 700, minHeight: 560)
            }
        }
        .interactiveDismissDisabled(isImporting)
        .onChange(of: store.projectSessionID) { _, _ in
            if isImporting {
                cancelImport()
            } else {
                activeTask?.cancel()
                activeTask = nil
            }
            generation = UUID()
            clearAuthenticationAndResults()
            errorMessage = L10n.text("The project changed. Reopen this tool for the current project.")
        }
        .onChange(of: selectedEnvironmentID) { _, _ in
            environmentDidChange()
        }
        .onChange(of: selectedProductID) { _, _ in clearQueriedIdentity() }
        .onChange(of: selectedSourceByTime) { _, _ in
            if !isQuerying {
                footprintError = nil
                invalidateFootprintProbe()
            }
        }
        .onChange(of: afterDate) { _, _ in clearQueriedIdentity() }
        .onChange(of: beforeDate) { _, _ in clearQueriedIdentity() }
        .onChange(of: store.lastActiveMapID) { _, _ in
            if clipArea != nil { statusMessage = L10n.text("The selected map changed. Reopen the download area before importing.") }
        }
        .onDisappear {
            generation = UUID()
            if isImporting { cancelImport() }
            else { activeTask?.cancel(); activeTask = nil }
        }
    }

    private var importForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                connectionSection
                querySection
                sourceSection
                downloadAreaSection
                precipitationSection
                if let statusMessage {
                    Label(L10n.text(statusMessage), systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Label(L10n.text(errorMessage), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button(L10n.text("Import Selected Grids"), systemImage: "square.and.arrow.down.fill") {
                        startImport()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canImport)
                }
            }
            .padding(14)
        }
    }

    private var connectionSection: some View {
        GroupBox(L10n.text("Cumulus Connection")) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Picker(L10n.text("Environment"), selection: $selectedEnvironmentID) {
                        ForEach(environments) { environment in
                            Text(environment.name).tag(environment.id)
                                .disabled(environment.isSelectable == false)
                        }
                    }
                    .disabled(isLoadingEnvironments || isLoadingProducts || isExchangingToken || isQuerying || isImporting)
                    Button(L10n.text(accessToken == nil ? "Connect to Cumulus" : "Refresh Products"),
                        systemImage: accessToken == nil ? "person.crop.circle.badge.checkmark" : "arrow.clockwise") {
                        connectOrRefresh()
                    }
                    .disabled(selectedEnvironment == nil || isLoadingEnvironments || isLoadingProducts
                        || isExchangingToken || isQuerying || isImporting
                        || selectedEnvironment?.isSelectable == false)
                }
                if isLoadingEnvironments || isLoadingProducts || isExchangingToken {
                    ProgressView(L10n.text(isLoadingEnvironments ? "Loading Cumulus environments…"
                        : isExchangingToken ? "Completing Cumulus sign in…" : "Loading Cumulus products…"))
                } else if accessToken != nil {
                    Label(L10n.text("Connected for this session"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if selectedEnvironment?.requiresSignIn == true {
                    Text(L10n.text("Sign in through the Cumulus authorization page to query products."))
                        .font(.caption).foregroundStyle(.secondary)
                } else if !environments.isEmpty {
                    Text(L10n.text("Connect to load available Cumulus products."))
                        .font(.caption).foregroundStyle(.secondary)
                } else if errorMessage != nil {
                    Button(L10n.text("Retry Loading Environments"), systemImage: "arrow.clockwise") {
                        Task { await loadEnvironments() }
                    }
                    .disabled(isLoadingEnvironments || !hasCurrentOwner)
                }
            }
        }
    }

    private var querySection: some View {
        GroupBox(L10n.text("Product and Time Range")) {
            VStack(alignment: .leading, spacing: 9) {
                LabeledContent(L10n.text("Target Boundary Condition layer"), value: layerTitle)
                Picker(L10n.text("Product"), selection: $selectedProductID) {
                    Text(L10n.text("Choose a product")).tag("")
                    ForEach(products) { product in
                        Text(product.name).tag(product.id)
                    }
                }
                .disabled(products.isEmpty || isLoadingProducts || isQuerying || isImporting)
                if let product = selectedProduct {
                    let details = [product.parameter, product.unit, product.dssDatatype]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                    if !details.isEmpty { Text(details).font(.caption).foregroundStyle(.secondary) }
                    if product.temporalResolution > 0 {
                        Text(L10n.format("Temporal resolution: %d; duration: %d",
                            product.temporalResolution, product.temporalDuration))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    DatePicker(L10n.text("After"), selection: $afterDate, displayedComponents: [.date])
                        .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                        .disabled(isQuerying || isImporting)
                    DatePicker(L10n.text("Before"), selection: $beforeDate, displayedComponents: [.date])
                        .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                        .disabled(isQuerying || isImporting)
                }
                HStack {
                    Text(L10n.text("Query up to six months at a time."))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.text("Query Grids"), systemImage: "magnifyingglass") { queryGrids() }
                        .disabled(!canQuery)
                }
                if !hasValidRange {
                    Text(L10n.text("End date must follow start date and the range cannot exceed six months."))
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder private var sourceSection: some View {
        GroupBox(L10n.text("Source Times and Versions")) {
            VStack(alignment: .leading, spacing: 8) {
                if isQuerying {
                    ProgressView(L10n.text("Querying Cumulus grid sources…"))
                } else if sources.isEmpty {
                    ContentUnavailableView(L10n.text("No grids have been queried."),
                        systemImage: "square.stack.3d.up", description: Text(L10n.text("Connect, choose a product and time range, then query source grids.")))
                        .frame(minHeight: 110)
                } else {
                    Text(L10n.text("Choose one available version for each valid time. The selected rows import as a time series."))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(timeGroups) { group in
                        Picker(selection: sourceBinding(for: group)) {
                            Text(L10n.text("Skip this time")).tag("")
                            ForEach(group.options) { source in
                                Text("\(source.versionUtc) · \(source.id)").tag(source.id)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.datetimeUtc).font(.body.monospacedDigit())
                                Text(L10n.text("Valid time")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(isImporting)
                        Divider()
                    }
                    Text(L10n.format("%d of %d valid times selected", chosenSources.count, timeGroups.count))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var downloadAreaSection: some View {
        GroupBox(L10n.text("Download Area")) {
            VStack(alignment: .leading, spacing: 8) {
                if mapIsCurrent {
                    footprintPreview
                    CumulusDownloadAreaEditor(store: store, extent: clipArea, setExtent: setClipArea)
                        .frame(minHeight: 200, idealHeight: 240)
                        .disabled(isImporting)
                    if let clipArea {
                        Text(L10n.format("Clip extent: %g, %g to %g, %g", clipArea.lowerLeft.x,
                            clipArea.lowerLeft.y, clipArea.upperRight.x, clipArea.upperRight.y))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    } else {
                        Text(L10n.text("No area is selected; the source COGs will be used without clipping."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    ContentUnavailableView(L10n.text("Activate the captured map to draw a download area."),
                        systemImage: "map", description: Text(L10n.text("A saved area belongs to the map and projection that were active when it was drawn.")))
                        .frame(minHeight: 130)
                }
            }
        }
    }

    @ViewBuilder private var footprintPreview: some View {
        if let capture = currentFootprintCapture {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label(L10n.text("Selected COG Footprint"), systemImage: "map")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button(L10n.text(isProbingFootprint ? "Reading COG footprint…" : "Read Selected COG Footprint"),
                        systemImage: "scope") {
                        startFootprintProbe(capture)
                    }
                    .disabled(isProbingFootprint || isQuerying || isImporting)
                }
                if isProbingFootprint {
                    ProgressView(L10n.text("Reading the selected COG extent and projection…"))
                } else if let currentFootprint, let previewMapState = store.existingMapState(for: mapID) {
                    CumulusGridFootprintMapPreview(store: store, mapState: previewMapState,
                        footprint: currentFootprint, clipExtent: clipArea)
                        .frame(height: 150)
                    Text(L10n.format("COG %@ · valid %@ · version %@",
                        capture.source.id, capture.source.datetimeUtc, capture.source.versionUtc))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    Text(L10n.format("Coverage in map coordinates: %g, %g to %g, %g",
                        currentFootprint.extent.minX, currentFootprint.extent.minY,
                        currentFootprint.extent.maxX, currentFootprint.extent.maxY))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button(L10n.text("Frame Map to COG Footprint"), systemImage: "viewfinder") {
                        frameMap(to: currentFootprint.extent)
                    }
                } else if let footprintError {
                    Label(L10n.text(footprintError), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                } else {
                    Text(L10n.text("The selected source footprint has not been read."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(L10n.text("The footprint comes from the selected remote COG and is transformed to this map’s projection."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        } else if sources.isEmpty {
            Text(L10n.text("Query source grids to read their geographic footprint."))
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text(L10n.text("Activate the captured map and select a source time before reading its footprint."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var precipitationSection: some View {
        if layerID == "precipitation" {
            GroupBox(L10n.text("Precipitation Conversion")) {
                HStack {
                    Picker(L10n.text("Data Type"), selection: $precipitationDataType) {
                        Text(L10n.text("Cumulative")).tag("per-cum")
                        Text(L10n.text("Average Rate")).tag("per-avg")
                    }
                    Picker(L10n.text("Length Units"), selection: $precipitationUnits) {
                        Text(L10n.text("Millimeters")).tag("mm")
                        Text(L10n.text("Inches")).tag("in")
                    }
                }
                .disabled(isImporting)
            }
        }
    }

    private var progressContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            OperationProgressView(title: L10n.text("Importing Cumulus Grids"),
                message: L10n.text(progress?.message ?? progress?.taskName ?? "Preparing selected Cumulus sources…"),
                fraction: progress?.fraction, cancelling: isCancelling,
                cancel: isCancelling ? nil : { cancelImport() })
            Text(L10n.text("The selected model draft and grid import are saved together; the operation remains open until the source transaction finishes."))
                .font(.caption).foregroundStyle(.secondary)
            if let errorMessage {
                Label(L10n.text(errorMessage), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).textSelection(.enabled)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func sourceBinding(for group: CumulusSourceTimeGroup) -> Binding<String> {
        Binding(get: { selectedSourceByTime[group.id] ?? "" }, set: { selectedSourceByTime[group.id] = $0 })
    }

    private func setClipArea(_ area: ViewportRequest?) {
        guard hasCurrentOwner, mapIsCurrent else {
            statusMessage = L10n.text("The captured map is not active; its download area was not changed.")
            return
        }
        clipArea = area
        clipProjectionWkt = area == nil ? nil : store.document?.projectionValue
        if area != nil && clipProjectionWkt?.isEmpty != false {
            errorMessage = L10n.text("The drawn Cumulus area has no captured map projection.")
        } else {
            errorMessage = nil
        }
    }

    private func loadEnvironments() async {
        guard !isLoadingEnvironments, let backend, hasCurrentOwner else { return }
        let currentGeneration = generation
        isLoadingEnvironments = true
        defer { isLoadingEnvironments = false }
        do {
            let result = try await backend.cumulusEnvironments()
            guard generation == currentGeneration, hasCurrentOwner else { return }
            let previousSelection = selectedEnvironmentID
            environments = result
            if !result.contains(where: { $0.id == selectedEnvironmentID }) {
                selectedEnvironmentID = result.first?.id ?? ""
            }
            if selectedEnvironmentID == previousSelection {
                applyMockTokenForSelectedEnvironment()
                if !selectedEnvironmentID.isEmpty { connectOrRefresh() }
            }
        } catch {
            guard generation == currentGeneration else { return }
            errorMessage = L10n.text(error.localizedDescription)
        }
    }

    /// Mirrors the source environment setter: invalidate the previous token,
    /// product list, and source query before connecting to the selected
    /// environment and refreshing its products.
    private func environmentDidChange() {
        let selectedID = selectedEnvironmentID
        let selectionGeneration = UUID()
        environmentSelectionGeneration = selectionGeneration
        let previousTask = activeTask
        previousTask?.cancel()
        generation = UUID()
        clearAuthenticationAndResults()
        showingAuthorization = false
        clearPendingAuthorization()
        applyMockTokenForSelectedEnvironment()
        errorMessage = nil
        statusMessage = nil

        Task { @MainActor in
            if let previousTask { await previousTask.value }
            guard environmentSelectionGeneration == selectionGeneration,
                  selectedEnvironmentID == selectedID, hasCurrentOwner else { return }
            isLoadingProducts = false
            isExchangingToken = false
            isQuerying = false
            activeTask = nil
            guard !selectedID.isEmpty else { return }
            connectOrRefresh()
        }
    }

    private func connectOrRefresh() {
        guard !isLoadingProducts, !isExchangingToken, !isImporting, hasCurrentOwner,
              let environment = selectedEnvironment, environment.isSelectable != false, let backend else { return }
        let selectionGeneration = environmentSelectionGeneration
        activeTask = Task { @MainActor in
            errorMessage = nil
            statusMessage = nil
            do {
                if let mockToken = environment.mockAccessToken {
                    accessToken = mockToken
                    refreshToken = nil
                    accessExpiresUtc = nil
                    try await loadProducts(backend: backend, environment: environment)
                } else if accessToken == nil {
                    try beginAuthorization(environment)
                } else {
                    try await loadProducts(backend: backend, environment: environment)
                }
            } catch {
                guard environmentSelectionGeneration == selectionGeneration,
                      selectedEnvironmentID == environment.id else { return }
                errorMessage = L10n.text(error.localizedDescription)
            }
        }
    }

    private func beginAuthorization(_ environment: CumulusEnvironmentOption) throws {
        guard environment.requiresSignIn,
              let endpoint = environment.authorizeEndpoint, let clientId = environment.clientId,
              let redirect = environment.redirectUri, URL(string: endpoint) != nil,
              URL(string: redirect) != nil else {
            throw BackendServiceError(code: "invalidInput", message: "The selected Cumulus environment has incomplete sign-in settings.")
        }
        let verifier = Self.randomURLToken(byteCount: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        let state = Self.randomURLToken(byteCount: 32)
        var components = URLComponents(string: endpoint)
        var query = components?.queryItems ?? []
        query.append(contentsOf: [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "openid profile"),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ])
        if let hint = environment.idpHint, !hint.isEmpty {
            query.append(URLQueryItem(name: "kc-idp-hint", value: hint))
        }
        components?.queryItems = query
        guard let url = components?.url else {
            throw BackendServiceError(code: "invalidInput", message: "The Cumulus authorization URL could not be formed.")
        }
        expectedOAuthState = state
        pkceVerifier = verifier
        expectedRedirectURI = redirect
        authorizationURL = url
        showingAuthorization = true
    }

    private func handleAuthorizationRedirect(_ url: URL) {
        guard showingAuthorization, hasCurrentOwner,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let actualState = components.queryItems?.first(where: { $0.name == "state" })?.value,
              actualState == expectedOAuthState else {
            errorMessage = L10n.text("The Cumulus sign-in response did not match this authorization request.")
            showingAuthorization = false
            clearPendingAuthorization()
            return
        }
        if let oauthError = components.queryItems?.first(where: { $0.name == "error" })?.value {
            errorMessage = L10n.format("Cumulus sign-in failed: %@", oauthError)
            showingAuthorization = false
            clearPendingAuthorization()
            return
        }
        guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty, let verifier = pkceVerifier, let environment = selectedEnvironment,
              let backend else {
            errorMessage = L10n.text("The Cumulus sign-in response did not contain an authorization code.")
            showingAuthorization = false
            clearPendingAuthorization()
            return
        }
        showingAuthorization = false
        let currentGeneration = generation
        isExchangingToken = true
        activeTask = Task { @MainActor in
            defer { if generation == currentGeneration { isExchangingToken = false } }
            do {
                let tokens = try await backend.exchangeCumulusToken(environmentId: environment.id,
                    code: code, verifier: verifier)
                guard hasCurrentOwner, selectedEnvironmentID == environment.id else { return }
                install(tokens)
                clearPendingAuthorization()
                try await loadProducts(backend: backend, environment: environment)
            } catch {
                errorMessage = L10n.text(error.localizedDescription)
                clearPendingAuthorization()
            }
        }
    }

    private func loadProducts(backend: BackendModelProvider, environment: CumulusEnvironmentOption) async throws {
        guard hasCurrentOwner else { throw CancellationError() }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        let token = try await usableAccessToken(backend: backend, environment: environment)
        let loaded = try await backend.cumulusProducts(environmentId: environment.id, accessToken: token)
        guard hasCurrentOwner, selectedEnvironmentID == environment.id else { throw CancellationError() }
        products = loaded
        if !loaded.contains(where: { $0.id == selectedProductID }) { selectedProductID = loaded.first?.id ?? "" }
        clearQueriedIdentity()
        statusMessage = L10n.format("Loaded %d Cumulus products.", loaded.count)
    }

    private func queryGrids() {
        guard canQuery, let backend, let environment = selectedEnvironment,
              let product = selectedProduct else { return }
        let currentGeneration = UUID()
        generation = currentGeneration
        isQuerying = true
        errorMessage = nil
        statusMessage = nil
        footprint = nil
        footprintCapture = nil
        footprintError = nil
        clearQueriedIdentity()
        let requestAfterUtc = Self.utcString(Self.utcDayStart(afterDate))
        let requestBeforeUtc = Self.utcString(Self.utcDayEnd(beforeDate))
        activeTask = Task { @MainActor in
            defer { if generation == currentGeneration { isQuerying = false } }
            do {
                let token = try await usableAccessToken(backend: backend, environment: environment)
                let result = try await backend.queryCumulusGrids(environmentId: environment.id,
                    accessToken: token, productId: product.id,
                    afterUtc: requestAfterUtc, beforeUtc: requestBeforeUtc)
                guard generation == currentGeneration, hasCurrentOwner,
                      selectedProductID == product.id, selectedEnvironmentID == environment.id,
                      Self.utcString(Self.utcDayStart(afterDate)) == requestAfterUtc,
                      Self.utcString(Self.utcDayEnd(beforeDate)) == requestBeforeUtc else { return }
                guard Set(result.map(\.id)).count == result.count else {
                    throw BackendServiceError(code: "protocolFailure", message: "Cumulus returned duplicate grid IDs; refresh the query before importing.")
                }
                sources = result
                selectedSourceByTime = CumulusGridSourceProjection.defaultSelections(result)
                queriedProductID = product.id
                queriedEnvironmentID = environment.id
                queriedAfterUtc = requestAfterUtc
                queriedBeforeUtc = requestBeforeUtc
                statusMessage = L10n.format("Loaded %d source grids across %d valid times.", result.count, timeGroups.count)
                if result.isEmpty { statusMessage = L10n.text("No Cumulus grids were available for this query.") }
                else if let capture = currentFootprintCapture {
                    await readFootprint(capture, backend: backend, environment: environment)
                }
            } catch is CancellationError {
                // Query cancellation is silent; no stale response is installed.
            } catch {
                guard generation == currentGeneration else { return }
                errorMessage = L10n.text(error.localizedDescription)
            }
        }
    }

    private func startFootprintProbe(_ capture: CumulusGridFootprintCapture) {
        guard let backend, let environment = selectedEnvironment,
              isCurrentFootprintCapture(capture), !isProbingFootprint else { return }
        activeTask?.cancel()
        activeTask = Task { @MainActor in
            await readFootprint(capture, backend: backend, environment: environment)
        }
    }

    private func readFootprint(_ capture: CumulusGridFootprintCapture,
                               backend: BackendModelProvider,
                               environment: CumulusEnvironmentOption) async {
        guard isCurrentFootprintCapture(capture), environment.id == capture.environmentID else { return }
        let requestID = UUID()
        footprintProbeID = requestID
        isProbingFootprint = true
        footprintError = nil
        defer {
            if footprintProbeID == requestID { isProbingFootprint = false }
        }
        do {
            let token = try await usableAccessToken(backend: backend, environment: environment)
            try Task.checkCancellation()
            guard isCurrentFootprintCapture(capture) else { return }
            let result = try await backend.probeCumulusGridFootprint(
                environmentId: capture.environmentID, accessToken: token,
                productId: capture.productID, afterUtc: capture.afterUtc,
                beforeUtc: capture.beforeUtc, source: capture.source,
                targetProjectionWkt: capture.targetProjectionWkt)
            try Task.checkCancellation()
            guard isCurrentFootprintCapture(capture) else { return }
            footprint = result
            footprintCapture = capture
            footprintError = nil
            frameMap(to: result.extent, capture: capture)
        } catch is CancellationError {
            // A late probe is ignored after the route, project, map, or source changes.
        } catch {
            guard isCurrentFootprintCapture(capture) else { return }
            footprint = nil
            footprintCapture = nil
            footprintError = error.localizedDescription
        }
    }

    private func isCurrentFootprintCapture(_ capture: CumulusGridFootprintCapture) -> Bool {
        capture == currentFootprintCapture && hasCurrentOwner && mapIsCurrent
            && store.projectSessionID == capture.projectSessionID
            && Self.canonicalPath(store.document?.url?.path ?? "") == capture.projectPath
            && session.id == capture.editorID
            && store.document?.projectionValue == capture.targetProjectionWkt
    }

    private func frameMap(to extent: CumulusImportExtent,
                          capture: CumulusGridFootprintCapture? = nil) {
        if let capture, !isCurrentFootprintCapture(capture) { return }
        guard hasCurrentOwner, mapIsCurrent, extent.isValid else { return }
        let width = extent.maxX - extent.minX
        let height = extent.maxY - extent.minY
        let marginX = width * 0.05
        let marginY = height * 0.05
        store.mapState(for: mapID).viewport = ViewportRequest(
            lowerLeft: MapPoint(x: extent.minX - marginX, y: extent.minY - marginY),
            upperRight: MapPoint(x: extent.maxX + marginX, y: extent.maxY + marginY),
            animated: true, padding: 0)
    }

    private func invalidateFootprintProbe() {
        guard isProbingFootprint else { return }
        footprintProbeID = UUID()
        activeTask?.cancel()
        activeTask = nil
        isProbingFootprint = false
    }

    private func usableAccessToken(backend: BackendModelProvider,
                                   environment: CumulusEnvironmentOption) async throws -> String? {
        if let token = environment.mockAccessToken { return token }
        guard let token = accessToken, !token.isEmpty else {
            throw BackendServiceError(code: "unauthorized", message: "Sign in to the selected Cumulus environment first.")
        }
        if let expiry = accessExpiresUtc.flatMap(Self.parseUTC), expiry <= Date().addingTimeInterval(45) {
            guard let refreshToken, !refreshToken.isEmpty else {
                clearAuthenticationAndResults()
                throw BackendServiceError(code: "unauthorized", message: "The Cumulus sign-in expired. Connect again.")
            }
            let refreshed = try await backend.refreshCumulusToken(environmentId: environment.id,
                refreshToken: refreshToken)
            guard hasCurrentOwner, selectedEnvironmentID == environment.id else { throw CancellationError() }
            install(refreshed)
            return refreshed.accessToken
        }
        return token
    }

    private func startImport() {
        guard canImport, let selection = makeSelection(), hasCurrentOwner else { return }
        let activeImportID = UUID()
        importID = activeImportID
        CumulusGridImportCancellation.shared.begin(importID: activeImportID)
        isImporting = true
        isCancelling = false
        progress = nil
        errorMessage = nil
        statusMessage = nil
        isImportingChanged(true)
        activeTask = Task { @MainActor in
            defer {
                if importID == activeImportID {
                    CumulusGridImportCancellation.shared.end(importID: activeImportID)
                    activeTask = nil
                    isImporting = false
                    isCancelling = false
                    isImportingChanged(false)
                }
            }
            let succeeded = await store.performCumulusGridImport(session: session, assetID: assetID,
                mapID: mapID, selection: selection) { update in
                    guard importID == activeImportID, hasCurrentOwner else { return }
                    progress = update
                }
            guard importID == activeImportID, hasCurrentOwner else { return }
            if succeeded {
                statusMessage = L10n.text("Cumulus grids were imported and the Boundary Condition was saved.")
                store.activeTool = nil
            } else if isCancelling || Task.isCancelled {
                statusMessage = L10n.text("Cumulus grid import cancelled; the model source was not committed.")
            } else {
                errorMessage = L10n.text(session.error ?? store.errorMessage ?? "The Cumulus grid import did not complete.")
            }
        }
    }

    private func makeSelection() -> CumulusGridImportSelection? {
        guard hasCurrentOwner, let product = selectedProduct,
              let selectedEnvironment = selectedEnvironment,
              let accessToken, hasValidRange, queryMatchesCurrentInputs, !chosenSources.isEmpty else { return nil }
        let clip: CumulusImportExtent?
        if let clipArea {
            guard mapIsCurrent, let wkt = clipProjectionWkt, !wkt.isEmpty,
                  CumulusImportExtent(clipArea).isValid else { return nil }
            clip = CumulusImportExtent(clipArea)
        } else {
            clip = nil
        }
        return CumulusGridImportSelection(environmentId: selectedEnvironment.id,
            accessToken: accessToken, productId: product.id,
            afterUtc: Self.utcString(Self.utcDayStart(afterDate)),
            beforeUtc: Self.utcString(Self.utcDayEnd(beforeDate)),
            sources: chosenSources, layerId: layerID, clipExtent: clip,
            clipProjectionWkt: clip == nil ? nil : clipProjectionWkt,
            precipitationDataType: precipitationDataType,
            precipitationUnits: precipitationUnits)
    }

    private func cancelImport() {
        guard isImporting, !isCancelling else { return }
        guard CumulusGridImportCancellation.shared.cancel(importID: importID) else {
            errorMessage = L10n.text("The Cumulus importer could not accept the cancellation request.")
            return
        }
        isCancelling = true
    }

    private func applyMockTokenForSelectedEnvironment() {
        guard let environment = selectedEnvironment else {
            clearAuthenticationAndResults()
            return
        }
        if let mockToken = environment.mockAccessToken {
            accessToken = mockToken
            refreshToken = nil
            accessExpiresUtc = nil
        } else {
            clearAuthenticationAndResults()
        }
    }

    private func install(_ tokens: CumulusTokenResponse) {
        accessToken = tokens.accessToken
        refreshToken = tokens.refreshToken
        accessExpiresUtc = tokens.accessExpiresUtc
    }

    private func clearAuthenticationAndResults() {
        accessToken = nil
        refreshToken = nil
        accessExpiresUtc = nil
        products = []
        selectedProductID = ""
        clearQueriedIdentity()
    }

    private func clearQueriedIdentity() {
        invalidateFootprintProbe()
        sources = []
        selectedSourceByTime = [:]
        footprint = nil
        footprintCapture = nil
        footprintError = nil
        queriedProductID = nil
        queriedEnvironmentID = nil
        queriedAfterUtc = nil
        queriedBeforeUtc = nil
    }

    private func clearPendingAuthorization() {
        authorizationURL = nil
        expectedRedirectURI = nil
        pkceVerifier = nil
        expectedOAuthState = nil
    }

    private static func randomURLToken(byteCount: Int) -> String {
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max) }
        return Data(bytes).base64URLEncodedString()
    }

    private static func utcString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func utcDayStart(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.startOfDay(for: date)
    }

    private static func utcDayEnd(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date
        return calendar.date(byAdding: .second, value: -1, to: nextDay) ?? date
    }

    private static func parseUTC(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct CumulusAuthorizationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let authorizationURL: URL
    let redirectURI: String
    let onRedirect: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L10n.text("Cumulus Sign In"), systemImage: "person.crop.circle.badge.checkmark")
                    .font(.headline)
                Spacer()
                Text(L10n.text("Complete sign in in this window to return an authorization code."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L10n.text("Cancel Sign In"), systemImage: "xmark") { dismiss() }
            }
            .padding(12)
            Divider()
            CumulusAuthorizationWebView(authorizationURL: authorizationURL,
                redirectURI: redirectURI, onRedirect: onRedirect)
        }
    }
}

private struct CumulusAuthorizationWebView: NSViewRepresentable {
    let authorizationURL: URL
    let redirectURI: String
    let onRedirect: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(redirectURI: redirectURI, onRedirect: onRedirect) }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: authorizationURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.redirectURI = redirectURI
        context.coordinator.onRedirect = onRedirect
        if webView.url == nil { webView.load(URLRequest(url: authorizationURL)) }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var redirectURI: String
        var onRedirect: (URL) -> Void
        private var delivered = false

        init(redirectURI: String, onRedirect: @escaping (URL) -> Void) {
            self.redirectURI = redirectURI
            self.onRedirect = onRedirect
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if matchesRedirect(url, configured: redirectURI) {
                decisionHandler(.cancel)
                guard !delivered else { return }
                delivered = true
                onRedirect(url)
            } else {
                decisionHandler(.allow)
            }
        }

        private func matchesRedirect(_ candidate: URL, configured: String) -> Bool {
            guard let expected = URLComponents(string: configured),
                  let actual = URLComponents(url: candidate, resolvingAgainstBaseURL: false) else { return false }
            return actual.scheme?.lowercased() == expected.scheme?.lowercased()
                && actual.host?.lowercased() == expected.host?.lowercased()
                && actual.port == expected.port
                && actual.path == expected.path
        }
    }
}
