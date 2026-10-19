import AppKit
import CoreGraphics
import Foundation
import RASWorkspaceCore
import SwiftUI

@MainActor
final class RasterLayerImportSession: ObservableObject {
    @Published private(set) var sourceURL: URL?
    @Published private(set) var inspection: MapRasterLayerInspectResult?
    @Published private(set) var preview: MapRasterLayerImagePayload?
    @Published var selectedMapLayerType = ""
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?

    private weak var store: WorkspaceStore?
    private let provider: BackendMapRasterLayerProvider
    private var generation: UInt64 = 0
    private var previewGeneration: UInt64 = 0

    init(store: WorkspaceStore, provider: BackendMapRasterLayerProvider? = nil) {
        self.store = store
        self.provider = provider ?? BackendMapRasterLayerProvider(client: store.runtimeInfoClient)
    }

    func choose(_ url: URL?, mapID: UUID) {
        generation &+= 1
        let current = generation
        previewGeneration &+= 1
        let currentPreview = previewGeneration
        sourceURL = url?.standardizedFileURL
        inspection = nil
        preview = nil
        selectedMapLayerType = ""
        isBusy = false
        errorMessage = nil
        guard let url, url.isFileURL, let store,
              let projectURL = store.document?.url,
              let projectXML = store.document?.editorXML(overridingDescription: store.descriptionDraft) else {
            if url != nil { errorMessage = L10n.text("Open a project and select a local raster file.") }
            return
        }
        isBusy = true
        let sessionID = store.projectSessionID
        let mapIdentity = store.mapWorkflowIdentity(mapID)
        let coreLayerContext = store.captureCoreLayerRequestContext()
        Task { @MainActor in
            defer { if current == generation { isBusy = false } }
            do {
                let result = try await provider.inspect(sourcePath: url.standardizedFileURL.path)
                guard current == generation, store.projectSessionID == sessionID,
                      store.document?.url == projectURL, store.mapWorkflowIdentity(mapID) == mapIdentity,
                      store.captureCoreLayerRequestContext() == coreLayerContext else { return }
                inspection = result
                selectedMapLayerType = result.mapLayerType
                if result.canRenderPreview {
                    let rendered = try await provider.preview(result, mapLayerType: result.mapLayerType,
                        projectPath: projectURL.path, projectXml: projectXML,
                        coreLayerContext: coreLayerContext)
                    guard current == generation, currentPreview == previewGeneration,
                          store.projectSessionID == sessionID,
                          store.mapWorkflowIdentity(mapID) == mapIdentity,
                          store.captureCoreLayerRequestContext() == coreLayerContext else { return }
                    preview = rendered
                }
            } catch is CancellationError {
                return
            } catch {
                guard current == generation, store.projectSessionID == sessionID,
                      store.document?.url == projectURL,
                      store.mapWorkflowIdentity(mapID) == mapIdentity,
                      store.captureCoreLayerRequestContext() == coreLayerContext else { return }
                errorMessage = L10n.text(error.localizedDescription)
            }
        }
    }

    func selectMapLayerType(_ value: String, mapID: UUID) {
        selectedMapLayerType = value
        previewGeneration &+= 1
        let currentPreview = previewGeneration
        guard let source = inspection, source.canRenderPreview,
              source.supportedMapLayerTypes.contains(value),
              let store, let projectURL = store.document?.url,
              let projectXML = store.document?.editorXML(overridingDescription: store.descriptionDraft) else {
            preview = nil
            errorMessage = nil
            return
        }
        let current = generation
        let sessionID = store.projectSessionID
        let mapIdentity = store.mapWorkflowIdentity(mapID)
        let coreLayerContext = store.captureCoreLayerRequestContext()
        preview = nil
        errorMessage = nil
        Task { @MainActor in
            do {
                let rendered = try await provider.preview(source, mapLayerType: value,
                    projectPath: projectURL.path, projectXml: projectXML,
                    coreLayerContext: coreLayerContext)
                guard current == generation, currentPreview == previewGeneration,
                      selectedMapLayerType == value,
                      store.projectSessionID == sessionID, store.document?.url == projectURL,
                      store.mapWorkflowIdentity(mapID) == mapIdentity,
                      store.captureCoreLayerRequestContext() == coreLayerContext else { return }
                preview = rendered
            } catch {
                guard current == generation, currentPreview == previewGeneration,
                      store.projectSessionID == sessionID, store.document?.url == projectURL,
                      store.mapWorkflowIdentity(mapID) == mapIdentity,
                      store.captureCoreLayerRequestContext() == coreLayerContext else { return }
                errorMessage = L10n.text(error.localizedDescription)
            }
        }
    }

    func importSelected(mapID: UUID) async -> Bool {
        guard let store, let sourceURL, let inspection,
              inspection.supportedMapLayerTypes.contains(selectedMapLayerType),
              !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        let generationAtStart = generation
        let coreLayerContext = store.captureCoreLayerRequestContext()
        let sessionID = store.projectSessionID
        let mapIdentity = store.mapWorkflowIdentity(mapID)
        let imported = await store.connectRasterSource(sourceURL, for: mapID,
            expectedSourceRevision: inspection.sourceRevision,
            mapLayerType: selectedMapLayerType,
            inspection: inspection)
        guard generation == generationAtStart, store.projectSessionID == sessionID,
              store.mapWorkflowIdentity(mapID) == mapIdentity,
              store.captureCoreLayerRequestContext() == coreLayerContext else { return false }
        if !imported { errorMessage = L10n.text("The GDAL raster could not be added to the selected map.") }
        return imported
    }
}

struct RasterLayerImportView: View {
    @ObservedObject var store: WorkspaceStore
    @StateObject private var session: RasterLayerImportSession

    init(store: WorkspaceStore) {
        self.store = store
        _session = StateObject(wrappedValue: RasterLayerImportSession(store: store))
    }

    private var mapID: UUID { store.lastActiveMapID }
    private var selectedType: Binding<String> {
        Binding(get: { session.selectedMapLayerType }, set: { value in
            session.selectMapLayerType(value, mapID: mapID)
        })
    }

    var body: some View {
        HSplitView {
            Form {
                Section(L10n.text("GDAL Raster Source")) {
                    HStack {
                        Label(L10n.text("Source Raster"), systemImage: "square.3.layers.3d")
                        Spacer()
                        Button(L10n.text("Choose Raster…"), systemImage: "folder") {
                            let chosen = store.system.chooseInputFiles().first(where: \.isFileURL)
                            session.choose(chosen, mapID: mapID)
                        }
                        .disabled(session.isBusy || store.document == nil)
                    }
                    if let sourceURL = session.sourceURL {
                        Text(sourceURL.path).font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled).lineLimit(2)
                    } else {
                        Text(L10n.text("Choose any raster file readable by the retained GDAL backend."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let inspection = session.inspection {
                    Section(L10n.text("Detected Raster")) {
                        LabeledContent(L10n.text("Driver"), value: inspection.driver)
                        LabeledContent(L10n.text("Cell Type"), value: inspection.dataType)
                        LabeledContent(L10n.text("Dimensions"), value: "\(inspection.width) × \(inspection.height)")
                        LabeledContent(L10n.text("Bands"), value: String(inspection.bandCount))
                        LabeledContent(L10n.text("Cell Size"), value: inspection.info.cellSize ?? "—")
                        LabeledContent(L10n.text("Projection"), value: inspection.info.projectionFriendlyText ?? "—")
                        Picker(L10n.text("Map Layer Type"), selection: selectedType) {
                            ForEach(inspection.supportedMapLayerTypes, id: \.self) { type in
                                Text(Self.label(for: type)).tag(type)
                            }
                        }
                        if !inspection.canRenderPreview {
                            Label(L10n.text("This raster is too large for an in-dialog preview."), systemImage: "info.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section(L10n.text("Raster Statistics")) {
                        LabeledContent(L10n.text("Minimum"), value: inspection.stats.min)
                        LabeledContent(L10n.text("Maximum"), value: inspection.stats.max)
                        LabeledContent(L10n.text("Mean"), value: inspection.stats.mean)
                        LabeledContent(L10n.text("Standard Deviation"), value: inspection.stats.standardDeviation)
                    }
                }
                Section {
                    Button(L10n.text("Add Raster Layer")) {
                        Task { _ = await session.importSelected(mapID: mapID) }
                    }
                    .disabled(session.isBusy || session.inspection == nil || store.document == nil ||
                        !session.inspection!.supportedMapLayerTypes.contains(session.selectedMapLayerType) ||
                        session.sourceURL == nil)
                }
                if let error = session.errorMessage {
                    Section { Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 390, idealWidth: 470, maxWidth: 540)

            Group {
                if session.isBusy && session.preview == nil {
                    ProgressView(L10n.text("Reading GDAL raster…"))
                } else if let preview = session.preview, let image = Self.image(preview) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.text("Source Preview")).font(.headline)
                        image.resizable().interpolation(.high).scaledToFit()
                            .accessibilityLabel(L10n.text("GDAL raster preview"))
                        Text("\(preview.width) × \(preview.height) · \(Self.label(for: session.selectedMapLayerType))")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding()
                } else {
                    ContentUnavailableView(L10n.text("Raster Preview"), systemImage: "square.3.layers.3d",
                        description: Text(L10n.text("A source-rendered preview appears here when the selected raster is small enough.")))
                }
            }
            .frame(minWidth: 360, idealWidth: 540, minHeight: 430)
        }
        .alert(L10n.text("HEC-RAS 2025"), isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
            Button(L10n.text("OK")) { session.errorMessage = nil }
        } message: { Text(session.errorMessage ?? "") }
    }

    private static func label(for type: String) -> String {
        switch type {
        case "SingleBandRasterMapLayer": L10n.text("Continuous Raster")
        case "ImageRasterMapLayer": L10n.text("Three-Band Image")
        case "DiscreteRasterMapLayer": L10n.text("Discrete Raster")
        default: type
        }
    }

    private static func image(_ payload: MapRasterLayerImagePayload) -> Image? {
        guard payload.width > 0, payload.height > 0,
              payload.rgba.count == payload.width * payload.height * 4,
              let provider = CGDataProvider(data: payload.rgba as CFData),
              let cgImage = CGImage(width: payload.width, height: payload.height,
                  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: payload.width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return Image(decorative: cgImage, scale: 1)
    }
}
