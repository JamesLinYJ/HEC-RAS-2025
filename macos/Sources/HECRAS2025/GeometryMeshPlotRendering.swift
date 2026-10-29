import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import RASWorkspaceCore
import SwiftUI

struct GeometryMeshPlotViewport: Codable, Equatable, Sendable {
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double

    var isFiniteAndOrdered: Bool {
        [minX, minY, maxX, maxY].allSatisfy(\.isFinite) && minX < maxX && minY < maxY
    }

    var identity: String {
        [minX, minY, maxX, maxY].map { String($0.bitPattern, radix: 16) }.joined(separator: ":")
    }
}

struct GeometryMeshPlotCoordinate: Decodable, Equatable, Sendable {
    let x: Double
    let y: Double
}

struct GeometryMeshPlotLabel: Decodable, Equatable, Sendable {
    let text: String
    let point: GeometryMeshPlotCoordinate
    let polyline: [GeometryMeshPlotCoordinate]
}

struct GeometryMeshPlotEnumChoice: Decodable, Identifiable, Equatable, Sendable {
    let value: String
    let label: String
    var id: String { value }
}

struct GeometryMeshPlotOptionDescriptor: Decodable, Identifiable, Equatable, Sendable {
    let propertyName: String
    let name: String
    let label: String
    let kind: String
    let value: String
    let enumValues: [GeometryMeshPlotEnumChoice]
    let isEnabled: Bool
    let enabledIf: String?
    let hasDrawingImplementation: Bool
    let implementationNote: String?
    var id: String { propertyName }
}

struct GeometryMeshPlotStylePacket: Equatable, Sendable {
    enum Scope: String, Equatable, Sendable {
        case localVis
        case global
        case sourceDefault
    }

    let scope: Scope
    let revision: String
    let globalRevision: UInt64
    let styles: [String: VectorStyleValues]

    static let sourceDefaults = GeometryMeshPlotStylePacket(
        scope: .sourceDefault, revision: "", globalRevision: 0, styles: [:])

    var packetSHA256: String {
        let canonical = styles.keys.sorted().map { key in
            let style = styles[key]!
            return [key, style.penColor.uppercased(), Self.doubleBits(style.penWidth),
                style.fillColor.uppercased(), String(style.pointSize), style.haloColor.uppercased(),
                Self.doubleBits(style.haloThickness), String(style.textEmphasis)].joined(separator: "|")
        }.joined(separator: "\n")
        return Self.digest(canonical)
    }

    func identity(sourceIdentity: String, ownerIdentity: String, mapID: String,
                  mapContextToken: String, geometryNodeIdentity: String,
                  projectRevision: String, visualizationRevision: String,
                  sourceRevision: String) -> String {
        Self.digest([
            "geometry-mesh-plot-style-v1", sourceIdentity, ownerIdentity, mapID,
            mapContextToken, geometryNodeIdentity, projectRevision, visualizationRevision,
            sourceRevision, scope.rawValue, revision, String(globalRevision), packetSHA256
        ].joined(separator: "\n"))
    }

    private static func doubleBits(_ value: Double) -> String {
        String(value.bitPattern, radix: 16)
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct GeometryMeshPlotRenderRequest: Encodable, Sendable {
    let model: GeometryMeshModelRequest
    let sourceIdentity: String
    let mapID: String
    let mapContextToken: String
    let geometryNodeIdentity: String
    let projectRevision: String
    let visualizationRevision: String
    let sourceRevision: String
    let meshDraftState: String
    let meshDraftSHA256: String
    let topologyDraftState: String?
    let topologyDraftSHA256: String
    let ownerMode: String
    let viewport: GeometryMeshPlotViewport
    let pixelWidth: Int
    let pixelHeight: Int
    let renderScale: Double
    let pixelSamplingScale: Double
    let styleScope: String
    let styleRevision: String
    let globalStyleRevision: UInt64
    let stylePacketSHA256: String
    let styleIdentity: String
    let styles: [String: VectorStyleValues]
    let rendererFamily: String
    let options: [String: String]
}

struct GeometryMeshPlotRenderResponse: Decodable, Sendable {
    let sourceIdentity: String
    let ownerIdentity: String
    let mapID: String
    let mapContextToken: String
    let geometryNodeIdentity: String
    let projectRevision: String
    let visualizationRevision: String
    let sourceRevision: String
    let meshDraftSHA256: String
    let topologyDraftSHA256: String
    let ownerMode: String
    let viewport: GeometryMeshPlotViewport
    let pixelWidth: Int
    let pixelHeight: Int
    let renderScale: Double
    let pixelSamplingScale: Double
    let sourceRenderScale: Double
    let stylePacketSHA256: String
    let styleIdentity: String
    let appliedStyles: [String: VectorStyleValues]
    let rasterExtent: GeometryMeshPlotViewport
    let rendererFamily: String
    let status: String
    let paintedPixels: Bool
    let pixelsRGBA: String
    let labels: [GeometryMeshPlotLabel]
    let options: [GeometryMeshPlotOptionDescriptor]
}

enum GeometryMeshPlotRendererFamily: String, CaseIterable, Identifiable, Sendable {
    case mesh = "Mesh"
    case conceptualMesh = "ConceptualMesh"
    case topologyTIN = "TopologyTIN"

    var id: String { rawValue }
    @MainActor
    var title: String {
        switch self {
        case .mesh: L10n.text("Mesh")
        case .conceptualMesh: L10n.text("Conceptual Mesh")
        case .topologyTIN: L10n.text("Topology TIN")
        }
    }

    var sourceOptionNames: Set<String> {
        switch self {
        case .mesh:
            ["LabelCells", "LabelFaces", "LabelFacePoints", "RenderPerimeter", "RenderQuality"]
        case .conceptualMesh:
            ["ShowArcIndexing", "ShowDirectionArrows", "ShowArcVertices", "ShowRegionIndexing",
             "ShowGlobalSizeFunction", "ShowSizeFunctionEdges", "ShowArcCellSizes",
             "ShowRegionCellSizes", "ShowRegionSizePreviews"]
        case .topologyTIN:
            ["RenderEdges", "RenderPoints", "LabelTris", "LabelEdges", "LabelPoints"]
        }
    }

    var sourceOptionsWithoutDrawingImplementation: Set<String> {
        self == .topologyTIN ? ["LabelPoints"] : []
    }
}

enum GeometryMeshPlotOwnerMode: String, Equatable, Sendable {
    case parentDraft
    case savedSource
}

enum GeometryMeshPlotEditorOwnerPolicy {
    static func ownerMode(forEditorCount count: Int) -> GeometryMeshPlotOwnerMode? {
        switch count {
        case 0: return .savedSource
        case 1: return .parentDraft
        default: return nil
        }
    }
}

struct GeometryMeshPlotRenderIntent: Sendable {
    let request: GeometryMeshPlotRenderRequest
    let ownerIdentity: String
    let identity: String
    let ownerMode: GeometryMeshPlotOwnerMode
    let projectSessionID: UUID

    init(source: ProjectGeometryMapSourceState,
         owner: GeometryMeshPlotOwnerCapture,
         ownerMode: GeometryMeshPlotOwnerMode = .parentDraft,
         family: GeometryMeshPlotRendererFamily,
         viewport: GeometryMeshPlotViewport,
         pixelWidth: Int,
         pixelHeight: Int,
         renderScale: Double,
         pixelSamplingScale: Double,
         stylePacket: GeometryMeshPlotStylePacket,
         options: [String: String]) {
        let snapshot = source.snapshot!
        self.ownerMode = ownerMode
        projectSessionID = source.capture.projectSessionID
        let styleIdentity = stylePacket.identity(sourceIdentity: source.capture.identity,
            ownerIdentity: owner.ownerIdentity, mapID: source.capture.mapID.uuidString,
            mapContextToken: snapshot.contextToken,
            geometryNodeIdentity: source.capture.geometryNode.sourceIdentity,
            projectRevision: snapshot.projectRevision,
            visualizationRevision: snapshot.visualizationRevision,
            sourceRevision: snapshot.geometryRevision)
        request = GeometryMeshPlotRenderRequest(
            model: owner.model,
            sourceIdentity: source.capture.identity,
            mapID: source.capture.mapID.uuidString,
            mapContextToken: snapshot.contextToken,
            geometryNodeIdentity: source.capture.geometryNode.sourceIdentity,
            projectRevision: snapshot.projectRevision,
            visualizationRevision: snapshot.visualizationRevision,
            sourceRevision: snapshot.geometryRevision,
            meshDraftState: owner.meshDraftState,
            meshDraftSHA256: owner.meshDraftSHA256,
            topologyDraftState: owner.topologyDraftState,
            topologyDraftSHA256: owner.topologyDraftSHA256,
            ownerMode: ownerMode.rawValue,
            viewport: viewport,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            renderScale: renderScale,
            pixelSamplingScale: pixelSamplingScale,
            styleScope: stylePacket.scope.rawValue,
            styleRevision: stylePacket.revision,
            globalStyleRevision: stylePacket.globalRevision,
            stylePacketSHA256: stylePacket.packetSHA256,
            styleIdentity: styleIdentity,
            styles: stylePacket.styles,
            rendererFamily: family.rawValue,
            options: options)
        ownerIdentity = owner.ownerIdentity
        let optionIdentity = options.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        identity = [source.capture.identity, snapshot.contextToken, snapshot.projectRevision,
            snapshot.visualizationRevision, snapshot.geometryRevision, ownerMode.rawValue, owner.ownerIdentity,
            family.rawValue, viewport.identity, "\(pixelWidth)x\(pixelHeight)",
            String(renderScale.bitPattern, radix: 16),
            String(pixelSamplingScale.bitPattern, radix: 16), styleIdentity, optionIdentity]
            .joined(separator: "|")
    }
}

struct GeometryMeshPlotRenderedOutput {
    let identity: String
    let response: GeometryMeshPlotRenderResponse
    let image: CGImage
}

struct GeometryMeshPlotOutputCache {
    private var outputs: [GeometryMeshPlotRendererFamily: GeometryMeshPlotRenderedOutput] = [:]

    mutating func insert(_ output: GeometryMeshPlotRenderedOutput,
                         for family: GeometryMeshPlotRendererFamily) {
        outputs[family] = output
    }

    func output(for family: GeometryMeshPlotRendererFamily,
                matching identity: String) -> GeometryMeshPlotRenderedOutput? {
        guard let output = outputs[family], output.identity == identity,
              output.response.rendererFamily == family.rawValue else { return nil }
        return output
    }

    mutating func remove(_ family: GeometryMeshPlotRendererFamily) {
        outputs.removeValue(forKey: family)
    }

    mutating func removeAll() {
        outputs.removeAll()
    }
}

enum GeometryMeshPlotFramePolicy {
    static func familyToSuppressBaseLayer(
        output: GeometryMeshPlotRenderedOutput?,
        requestedIdentity: String?,
        requestedFamily: GeometryMeshPlotRendererFamily?
    ) -> GeometryMeshPlotRendererFamily? {
        guard let output, let requestedIdentity, let requestedFamily,
              output.identity == requestedIdentity,
              output.response.rendererFamily == requestedFamily.rawValue else { return nil }
        return requestedFamily
    }
}

@MainActor
final class GeometryMeshPlotRenderingProvider {
    private let client: BackendProcessClient

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func render(_ request: GeometryMeshPlotRenderRequest) async throws -> GeometryMeshPlotRenderResponse {
        try await client.request("geometry.mesh.plotRender", parameters: request,
            as: GeometryMeshPlotRenderResponse.self)
    }
}

/// Runtime options and exact render replies for one Geometry map capture.
/// The owner is map scoped and never writes these settings to .vis.
@MainActor
final class GeometryMeshPlotSession: ObservableObject {
    static let retiredSession = GeometryMeshPlotSession(owner: nil, captureIdentity: "", retired: true)

    @Published private(set) var rendererFamily: GeometryMeshPlotRendererFamily = .conceptualMesh
    @Published private(set) var isRendering = false
    @Published private(set) var error: String?
    @Published private(set) var optionDescriptors: [GeometryMeshPlotRendererFamily: [GeometryMeshPlotOptionDescriptor]] = [:]

    var onChange: @MainActor () -> Void = {}

    private weak var owner: ProjectGeometryMapSession?
    private weak var geometryMeshOwner: GeometryMeshSession?
    private weak var workspaceStore: WorkspaceStore?
    private let captureIdentity: String
    private let isRetired: Bool
    private let provider: GeometryMeshPlotRenderingProvider
    private var optionOverrides: [GeometryMeshPlotRendererFamily: [String: String]] = [:]
    private var renderedOutputs = GeometryMeshPlotOutputCache()
    private var preferredFamilyInstalled = false
    private var familySelectionWasExplicit = false
    private var activeIntentIdentity: String?
    private var lastIntent: GeometryMeshPlotRenderIntent?
    private var renderGeneration: UInt64 = 0
    private var renderTask: Task<Void, Never>?

    init(owner: ProjectGeometryMapSession?, captureIdentity: String,
         provider: GeometryMeshPlotRenderingProvider = GeometryMeshPlotRenderingProvider(),
         retired: Bool = false) {
        self.owner = owner
        self.captureIdentity = captureIdentity
        self.provider = provider
        isRetired = retired
    }

    var isActive: Bool {
        guard !isRetired, let owner else { return false }
        return owner.containsGeometryPlotCapture(captureIdentity)
    }

    func suggestRendererFamily(for row: MapSourceRenderRecord) {
        guard isActive, !familySelectionWasExplicit, !preferredFamilyInstalled else { return }
        if row.payloadKind == "FlowAreaLayer" { rendererFamily = .mesh }
        else { rendererFamily = .conceptualMesh }
        preferredFamilyInstalled = true
        onChange()
    }

    func selectRendererFamily(_ family: GeometryMeshPlotRendererFamily) {
        guard isActive, rendererFamily != family else { return }
        familySelectionWasExplicit = true
        rendererFamily = family
        error = nil
        onChange()
    }

    func descriptors(for family: GeometryMeshPlotRendererFamily) -> [GeometryMeshPlotOptionDescriptor] {
        optionDescriptors[family] ?? []
    }

    func value(for descriptor: GeometryMeshPlotOptionDescriptor,
               family: GeometryMeshPlotRendererFamily) -> String {
        optionOverrides[family]?[descriptor.propertyName] ?? descriptor.value
    }

    func setOption(_ descriptor: GeometryMeshPlotOptionDescriptor,
                   family: GeometryMeshPlotRendererFamily,
                   value: String) {
        guard isActive, descriptor.isEnabled,
              descriptor.hasDrawingImplementation,
              family.sourceOptionNames.contains(descriptor.propertyName),
              descriptor.kind == "bool" ? Bool(value) != nil
                : descriptor.kind == "enum" && descriptor.enumValues.contains(where: { $0.value == value }) else { return }
        if value == descriptor.value {
            optionOverrides[family]?.removeValue(forKey: descriptor.propertyName)
        } else {
            optionOverrides[family, default: [:]][descriptor.propertyName] = value
        }
        error = nil
        onChange()
    }

    func renderIntent(source: ProjectGeometryMapSourceState,
                      mapState: MapState,
                      store: WorkspaceStore,
                      viewport: GeometryMeshPlotViewport,
                      pixelWidth: Int,
                      pixelHeight: Int,
                      renderScale: Double,
                      pixelSamplingScale: Double,
                      stylePacket: GeometryMeshPlotStylePacket) -> GeometryMeshPlotRenderIntent? {
        guard isActive, owner?.ownsPlotSnapshot(source) == true,
              source.capture.identity == captureIdentity,
              source.capture.projectSessionID == store.projectSessionID,
              source.capture.mapID == mapState.id,
              source.snapshot?.geometryEffectiveVisible == true,
              viewport.isFiniteAndOrdered,
              renderScale.isFinite, renderScale > 0,
              pixelSamplingScale.isFinite, pixelSamplingScale > 0,
              (renderScale * pixelSamplingScale).isFinite,
              renderScale * pixelSamplingScale <= 64,
              pixelWidth > 0, pixelHeight > 0,
              let snapshot = source.snapshot,
              snapshot.projectXmlSHA?.caseInsensitiveCompare(source.capture.map.projectXmlSHA) == .orderedSame,
              Self.digest(source.capture.map.projectXml) == source.capture.map.projectXmlSHA.lowercased() else { return nil }

        let ownerCapture: GeometryMeshPlotOwnerCapture
        let ownerMode: GeometryMeshPlotOwnerMode
        let editorCount = store.geometryMeshEditorCount(for: source.capture.geometryCanonicalPath)
        guard let selectedOwnerMode = GeometryMeshPlotEditorOwnerPolicy.ownerMode(forEditorCount: editorCount) else {
            // Multiple registered editor owners are ambiguous. In particular,
            // never select one loaded draft while another editor is still loading.
            return nil
        }
        ownerMode = selectedOwnerMode
        switch selectedOwnerMode {
        case .parentDraft:
            guard let mesh = store.geometryMeshSession(assetID: source.capture.geometryCanonicalPath,
                    projectSessionID: source.capture.projectSessionID),
                  let liveCapture = mesh.plotRenderingOwnerCapture(
                    for: source.capture.geometryCanonicalPath, expectedRevision: snapshot.geometryRevision) else {
                // A registered editor that is not yet an exact loaded owner
                // must wait; it cannot fall back to the saved model.
                return nil
            }
            ownerCapture = liveCapture
            geometryMeshOwner = mesh
        case .savedSource:
            // No editor is registered for this asset, so the immutable saved
            // ModelContext is the only valid Geometry owner for this request.
            let model = GeometryMeshModelRequest(
                assetPath: source.capture.geometryCanonicalPath,
                kind: "Geometry",
                projectPath: source.capture.map.projectPath,
                projectXml: source.capture.map.projectXml,
                coreLayerContext: source.capture.map.coreLayerContext)
            let emptyDraft = ""
            let emptyDigest = Self.digest(emptyDraft)
            let ownerIdentity = [SourceFilePaths.canonical(URL(fileURLWithPath: model.assetPath)),
                model.kind, model.projectPath ?? "", Self.digest(model.projectXml ?? ""),
                model.coreLayerContext?.identityToken ?? "",
                snapshot.geometryRevision, emptyDigest, emptyDigest].joined(separator: "|")
            ownerCapture = GeometryMeshPlotOwnerCapture(model: model,
                sourceRevision: snapshot.geometryRevision, meshDraftState: emptyDraft,
                topologyDraftState: nil, meshDraftSHA256: emptyDigest,
                topologyDraftSHA256: emptyDigest, ownerIdentity: ownerIdentity)
            geometryMeshOwner = nil
        }
        workspaceStore = store
        return GeometryMeshPlotRenderIntent(source: source, owner: ownerCapture, ownerMode: ownerMode,
            family: rendererFamily, viewport: viewport, pixelWidth: pixelWidth,
            pixelHeight: pixelHeight, renderScale: renderScale,
            pixelSamplingScale: pixelSamplingScale, stylePacket: stylePacket,
            options: optionOverrides[rendererFamily] ?? [:])
    }

    func requestRender(_ intent: GeometryMeshPlotRenderIntent?) {
        guard isActive else { retire(); return }
        guard let intent else {
            renderGeneration &+= 1
            renderTask?.cancel()
            renderTask = nil
            activeIntentIdentity = nil
            lastIntent = nil
            geometryMeshOwner = nil
            workspaceStore = nil
            isRendering = false
            error = nil
            renderedOutputs.removeAll()
            onChange()
            return
        }
        guard activeIntentIdentity != intent.identity else { return }
        renderGeneration &+= 1
        let generation = renderGeneration
        activeIntentIdentity = intent.identity
        lastIntent = intent
        renderTask?.cancel()
        renderTask = nil
        isRendering = true
        error = nil
        if let family = GeometryMeshPlotRendererFamily(rawValue: intent.request.rendererFamily) {
            renderedOutputs.remove(family)
        }
        onChange()
        renderTask = Task { [weak self] in
            await self?.perform(intent, generation: generation)
        }
    }

    func retry() {
        guard isActive, let lastIntent else { return }
        activeIntentIdentity = nil
        requestRender(lastIntent)
    }

    func output(for family: GeometryMeshPlotRendererFamily,
                matching identity: String) -> GeometryMeshPlotRenderedOutput? {
        guard isActive else { return nil }
        return renderedOutputs.output(for: family, matching: identity)
    }

    func retire() {
        guard !isRetired else { return }
        renderGeneration &+= 1
        renderTask?.cancel()
        renderTask = nil
        activeIntentIdentity = nil
        lastIntent = nil
        isRendering = false
        error = nil
        renderedOutputs.removeAll()
        optionOverrides.removeAll()
        optionDescriptors.removeAll()
        geometryMeshOwner = nil
        workspaceStore = nil
        onChange()
        owner = nil
    }

    private func perform(_ intent: GeometryMeshPlotRenderIntent, generation: UInt64) async {
        do {
            guard isActive,
                  owner?.ownsPlotIntent(intent, captureIdentity: captureIdentity) == true,
                  ownsCurrentRenderOwner(intent) else {
                discardStaleRender(generation: generation)
                return
            }
            let response = try await provider.render(intent.request)
            try Task.checkCancellation()
            guard renderGeneration == generation else { return }
            guard isActive,
                  owner?.ownsPlotIntent(intent, captureIdentity: captureIdentity) == true,
                  ownsCurrentRenderOwner(intent) else {
                discardStaleRender(generation: generation)
                return
            }
            guard isActive, renderGeneration == generation,
                  activeIntentIdentity == intent.identity,
                  let owner,
                  owner.ownsPlotReply(response, intent: intent, captureIdentity: captureIdentity) else { return }
            let image = try Self.validate(response, against: intent)
            let family = GeometryMeshPlotRendererFamily(rawValue: response.rendererFamily)!
            optionDescriptors[family] = response.options
            renderedOutputs.insert(GeometryMeshPlotRenderedOutput(identity: intent.identity,
                response: response, image: image), for: family)
            isRendering = false
            renderTask = nil
            error = nil
            onChange()
        } catch is CancellationError {
            guard renderGeneration == generation else { return }
            isRendering = false
            renderTask = nil
            onChange()
        } catch {
            guard renderGeneration == generation, isActive else { return }
            isRendering = false
            renderTask = nil
            self.error = error.localizedDescription
            onChange()
        }
    }

    private static func validate(_ response: GeometryMeshPlotRenderResponse,
                                 against intent: GeometryMeshPlotRenderIntent) throws -> CGImage {
        let request = intent.request
        let family = GeometryMeshPlotRendererFamily(rawValue: request.rendererFamily)!
        guard response.status == "rendered",
              response.sourceIdentity == request.sourceIdentity,
              response.ownerIdentity == intent.ownerIdentity,
              response.mapID == request.mapID,
              response.mapContextToken == request.mapContextToken,
              response.geometryNodeIdentity == request.geometryNodeIdentity,
              response.projectRevision == request.projectRevision,
              response.visualizationRevision == request.visualizationRevision,
              response.sourceRevision == request.sourceRevision,
              response.meshDraftSHA256.caseInsensitiveCompare(request.meshDraftSHA256) == .orderedSame,
              response.topologyDraftSHA256.caseInsensitiveCompare(request.topologyDraftSHA256) == .orderedSame,
              response.ownerMode == request.ownerMode,
              response.viewport == request.viewport,
              response.pixelWidth == request.pixelWidth,
              response.pixelHeight == request.pixelHeight,
              response.renderScale.bitPattern == request.renderScale.bitPattern,
              response.pixelSamplingScale.bitPattern == request.pixelSamplingScale.bitPattern,
              response.sourceRenderScale.bitPattern
                  == (request.renderScale * request.pixelSamplingScale).bitPattern,
              response.stylePacketSHA256 == request.stylePacketSHA256,
              response.styleIdentity == request.styleIdentity,
              response.appliedStyles == request.styles,
              response.rendererFamily == request.rendererFamily,
              response.rasterExtent.isFiniteAndOrdered,
              response.options.count == family.sourceOptionNames.count,
              Set(response.options.map(\.propertyName)) == family.sourceOptionNames,
              response.options.allSatisfy({ option in
                  option.kind == "bool" ? Bool(option.value) != nil
                    : option.kind == "enum" && option.enumValues.contains(where: { $0.value == option.value })
              }),
              response.options.allSatisfy({ option in
                  option.hasDrawingImplementation
                      == !family.sourceOptionsWithoutDrawingImplementation.contains(option.propertyName)
                      && (option.hasDrawingImplementation || !option.isEnabled)
              }),
              let bytes = Data(base64Encoded: response.pixelsRGBA),
              bytes.count == request.pixelWidth * request.pixelHeight * 4,
              response.labels.allSatisfy({ label in
                  !label.text.isEmpty && label.point.x.isFinite && label.point.y.isFinite
                      && label.polyline.allSatisfy { $0.x.isFinite && $0.y.isFinite }
              }) else {
            throw BackendServiceError(code: "geometryPlotMismatch",
                message: L10n.text("The Geometry renderer returned data for a different map context."))
        }
        guard let image = GeometryMeshPlotImage.make(pixels: bytes,
                width: request.pixelWidth, height: request.pixelHeight) else {
            throw BackendServiceError(code: "geometryPlotMismatch",
                message: L10n.text("The Geometry renderer returned data for a different map context."))
        }
        return image
    }

    private func ownsCurrentRenderOwner(_ intent: GeometryMeshPlotRenderIntent) -> Bool {
        switch intent.ownerMode {
        case .parentDraft:
            guard let workspaceStore,
                  workspaceStore.projectSessionID == intent.projectSessionID,
                  workspaceStore.geometryMeshEditorCount(for: intent.request.model.assetPath) == 1,
                  let geometryMeshOwner,
                  let currentOwner = geometryMeshOwner.plotRenderingOwnerCapture(
                    for: intent.request.model.assetPath,
                    expectedRevision: intent.request.sourceRevision) else { return false }
            return currentOwner.ownerIdentity == intent.ownerIdentity
                && currentOwner.meshDraftSHA256.caseInsensitiveCompare(
                    intent.request.meshDraftSHA256) == .orderedSame
                && currentOwner.topologyDraftSHA256.caseInsensitiveCompare(
                    intent.request.topologyDraftSHA256) == .orderedSame
        case .savedSource:
            guard geometryMeshOwner == nil,
                  let workspaceStore,
                  workspaceStore.projectSessionID == intent.projectSessionID,
                  workspaceStore.geometryMeshEditorCount(for: intent.request.model.assetPath) == 0 else { return false }
            return true
        }
    }

    private func discardStaleRender(generation: UInt64) {
        guard renderGeneration == generation else { return }
        activeIntentIdentity = nil
        renderedOutputs.removeAll()
        isRendering = false
        renderTask = nil
        onChange()
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension ProjectGeometryMapSession {
    func containsGeometryPlotCapture(_ identity: String) -> Bool {
        isConfigured && sources.contains(where: { $0.capture.identity == identity })
    }

    fileprivate func ownsPlotIntent(_ intent: GeometryMeshPlotRenderIntent,
                                    captureIdentity: String) -> Bool {
        guard containsGeometryPlotCapture(captureIdentity),
              let current = sources.first(where: { $0.capture.identity == captureIdentity }),
              ownsPlotSnapshot(current),
              let snapshot = current.snapshot else { return false }
        let request = intent.request
        guard intent.projectSessionID == current.capture.projectSessionID,
              request.ownerMode == intent.ownerMode.rawValue,
              request.sourceIdentity == current.capture.identity,
              request.mapID == current.capture.mapID.uuidString,
              request.mapContextToken == snapshot.contextToken,
              request.geometryNodeIdentity == current.capture.geometryNode.sourceIdentity,
              request.projectRevision == snapshot.projectRevision,
              request.visualizationRevision == snapshot.visualizationRevision,
              request.sourceRevision == snapshot.geometryRevision,
              request.model.kind == "Geometry",
              SourceFilePaths.canonical(URL(fileURLWithPath: request.model.assetPath))
                == current.capture.geometryCanonicalPath,
              let requestProjectPath = request.model.projectPath,
              SourceFilePaths.canonical(URL(fileURLWithPath: requestProjectPath))
                == SourceFilePaths.canonical(URL(fileURLWithPath: current.capture.map.projectPath)) else {
            return false
        }
        if intent.ownerMode == .savedSource {
            return request.model.projectXml == current.capture.map.projectXml
                && request.meshDraftState.isEmpty
                && request.topologyDraftState == nil
        }
        return true
    }

    fileprivate func ownsPlotReply(_ response: GeometryMeshPlotRenderResponse,
                                   intent: GeometryMeshPlotRenderIntent,
                                   captureIdentity: String) -> Bool {
        guard ownsPlotIntent(intent, captureIdentity: captureIdentity),
              let current = sources.first(where: { $0.capture.identity == captureIdentity }),
              let snapshot = current.snapshot else { return false }
        let request = intent.request
        return response.sourceIdentity == current.capture.identity
            && response.mapID == current.capture.mapID.uuidString
            && response.mapContextToken == snapshot.contextToken
            && response.geometryNodeIdentity == current.capture.geometryNode.sourceIdentity
            && response.projectRevision == snapshot.projectRevision
            && response.visualizationRevision == snapshot.visualizationRevision
            && response.sourceRevision == snapshot.geometryRevision
            && request.sourceIdentity == current.capture.identity
    }
}

struct GeometryPlotOptionsView: View {
    @ObservedObject private var store: WorkspaceStore
    @ObservedObject private var mapState: MapState
    @ObservedObject private var plotSession: GeometryMeshPlotSession
    private let source: ProjectGeometryMapSourceState
    private let row: MapSourceRenderRecord

    init(source: ProjectGeometryMapSourceState,
         row: MapSourceRenderRecord,
         store: WorkspaceStore,
         mapState: MapState,
         plotSession: GeometryMeshPlotSession) {
        self.source = source
        self.row = row
        self._store = ObservedObject(wrappedValue: store)
        self._mapState = ObservedObject(wrappedValue: mapState)
        self._plotSession = ObservedObject(wrappedValue: plotSession)
    }

    private var descriptors: [GeometryMeshPlotOptionDescriptor] {
        plotSession.descriptors(for: plotSession.rendererFamily)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.text("Geometry Plot Options"))
                    .font(.subheadline.weight(.medium))
                Spacer()
                if plotSession.isRendering {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(L10n.text("Rendering Geometry plot"))
                }
            }
            Picker(L10n.text("Renderer"), selection: Binding(
                get: { plotSession.rendererFamily },
                set: { plotSession.selectRendererFamily($0) }
            )) {
                ForEach(GeometryMeshPlotRendererFamily.allCases) { family in
                    Text(family.title).tag(family)
                        .disabled(!rendererIsAvailable(family))
                }
            }
            .pickerStyle(.segmented)
            .disabled(!plotSession.isActive)

            if !plotSession.isActive || row.mapID != mapState.id || source.capture.mapID != mapState.id {
                Text(L10n.text("Geometry plot options are unavailable for this map owner."))
                    .font(.caption).foregroundStyle(.secondary)
            } else if !GeometryMeshPlotRendererFamily.allCases.contains(where: rendererIsAvailable) {
                Text(L10n.text("No source Geometry renderer is available for this map layer."))
                    .font(.caption).foregroundStyle(.secondary)
            } else if let mesh = store.geometryMeshSession(assetID: source.capture.geometryCanonicalPath,
                projectSessionID: source.capture.projectSessionID) {
                GeometryMeshPlotOptionsControls(plotSession: plotSession,
                    family: plotSession.rendererFamily, descriptors: descriptors,
                    parentEditorBusy: mesh.isLoading || mesh.isEditing || mesh.isGeneratingMesh
                        || mesh.isComputingPropertyTables || mesh.isScanningDegreeErrors
                        || mesh.parentSaveInProgress)
            } else if store.hasGeometryMeshEditor(for: source.capture.geometryCanonicalPath) {
                VStack(alignment: .leading, spacing: 5) {
                    GeometryMeshPlotOptionsControls(plotSession: plotSession,
                        family: plotSession.rendererFamily, descriptors: descriptors,
                        parentEditorBusy: true)
                    Text(L10n.text("Rendering waits for the active Geometry edit to finish."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                GeometryMeshPlotOptionsControls(plotSession: plotSession,
                    family: plotSession.rendererFamily, descriptors: descriptors,
                    parentEditorBusy: false)
            }
        }
        .onAppear {
            plotSession.suggestRendererFamily(for: row)
            if !rendererIsAvailable(plotSession.rendererFamily),
               let available = GeometryMeshPlotRendererFamily.allCases.first(where: rendererIsAvailable) {
                plotSession.selectRendererFamily(available)
            }
        }
        .padding(.vertical, 3)
    }

    private func rendererIsAvailable(_ family: GeometryMeshPlotRendererFamily) -> Bool {
        switch family {
        case .mesh:
            source.presentsFlowAreaData
        case .conceptualMesh, .topologyTIN:
            source.snapshot?.topologyState.status.hasSourceData == true
        }
    }
}

private struct GeometryMeshPlotOptionsControls: View {
    @ObservedObject var plotSession: GeometryMeshPlotSession
    let family: GeometryMeshPlotRendererFamily
    let descriptors: [GeometryMeshPlotOptionDescriptor]
    let parentEditorBusy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if descriptors.isEmpty {
                Text(plotSession.isRendering
                    ? L10n.text("Loading source PlotOptions…")
                    : L10n.text("Waiting for the source renderer."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(descriptors) { descriptor in optionControl(descriptor) }
            }
            if let error = plotSession.error {
                HStack(alignment: .firstTextBaseline) {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button(L10n.text("Retry")) { plotSession.retry() }
                        .buttonStyle(.link).font(.caption)
                }
            }
            if parentEditorBusy {
                Text(L10n.text("Rendering waits for the active Geometry edit to finish."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(parentEditorBusy)
    }

    @ViewBuilder
    private func optionControl(_ descriptor: GeometryMeshPlotOptionDescriptor) -> some View {
        if !descriptor.hasDrawingImplementation {
            HStack {
                Text(L10n.text(descriptor.label))
                Spacer()
                Text(L10n.text("Not implemented"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let note = descriptor.implementationNote {
                Text(L10n.text(note)).font(.caption).foregroundStyle(.secondary)
            }
        } else if descriptor.kind == "bool" {
            Toggle(L10n.text(descriptor.label), isOn: Binding(
                get: { plotSession.value(for: descriptor, family: family) == "true" },
                set: { plotSession.setOption(descriptor, family: family, value: $0 ? "true" : "false") }
            ))
            .disabled(!descriptor.isEnabled)
            .help(descriptor.enabledIf.map { L10n.format("Available when %@ is enabled.", $0) } ?? "")
        } else if descriptor.kind == "enum" {
            Picker(L10n.text(descriptor.label), selection: Binding(
                get: { plotSession.value(for: descriptor, family: family) },
                set: { plotSession.setOption(descriptor, family: family, value: $0) }
            )) {
                ForEach(descriptor.enumValues) { value in
                    Text(L10n.text(value.label)).tag(value.value)
                }
            }
            .disabled(!descriptor.isEnabled)
        }
    }
}

enum GeometryMeshPlotImage {
    static func make(pixels: Data, width: Int, height: Int) -> CGImage? {
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        guard width > 0, height > 0,
              !pixelOverflow, !byteOverflow, !rowOverflow,
              pixels.count == byteCount,
              let provider = CGDataProvider(data: pixels as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
