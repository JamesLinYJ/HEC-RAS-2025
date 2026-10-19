import Foundation
import RASWorkspaceCore
import SwiftUI
import UniformTypeIdentifiers

struct GeometryVectorImportInspectRequest: Codable, Sendable {
    let model: GeometryTopologyModelRequest
    let revision: String
    let draftState: String
    let draftIdentity: String
    let paths: [String]
}

struct GeometryVectorImportApplyRequest: Codable, Sendable {
    let model: GeometryTopologyModelRequest
    let revision: String
    let draftState: String
    let draftIdentity: String
    let sources: [GeometryVectorImportSelectedSource]
    let mode: String
    let mergeContiguousArcs: Bool
    let removeExternalArcs: Bool
}

struct GeometryVectorImportSelectedSource: Codable, Sendable {
    let path: String
    let family: MapSourceFamilyCapture
}

struct GeometryVectorImportInspection: Codable, Sendable {
    let revision: String
    let draftIdentity: String
    let sources: [GeometryVectorImportSource]
    let issues: [GeometryVectorImportIssue]
}

struct GeometryVectorImportSource: Codable, Identifiable, Sendable {
    let path: String
    let name: String
    let shapeType: String
    let shapeTypeCode: Int
    let featureCount: Int
    let family: MapSourceFamilyCapture
    let features: [GeometryVectorImportFeature]
    var id: String { path }
}

struct GeometryVectorImportFeature: Codable, Identifiable, Sendable {
    let sourceOrdinal: Int
    let geometryType: String
    let points: [GeometryTopologyCoordinate]
    var id: Int { sourceOrdinal }
}

struct GeometryVectorImportIssue: Codable, Identifiable, Sendable {
    let path: String
    let message: String
    var id: String { path }
}

struct GeometryTopologyImportPayload: Codable, Sendable {
    let mode: String
    let mergeContiguousArcs: Bool
    let removeExternalArcs: Bool
    let sources: [GeometryTopologyImportSource]
    let features: [GeometryTopologyImportFeature]
}

struct GeometryTopologyImportSource: Codable, Sendable {
    let path: String
    let family: MapSourceFamilyCapture
}

struct GeometryTopologyImportFeature: Codable, Sendable {
    let geometryType: String
    let points: [GeometryTopologyCoordinate]
}

enum GeometryVectorImportMode: String, CaseIterable, Identifiable, Sendable {
    case merge = "Merge"
    case noMerge = "NoMerge"
    var id: String { rawValue }
    var title: String { self == .merge ? "Import and Merge" : "Import Without Merge" }
    var help: String {
        self == .merge
            ? "Import lines and polygons as arcs, then try to merge intersections and overlapping sections with the current topology."
            : "Import lines and polygons as arcs and leave intersections or overlaps unresolved for later editing."
    }
}

struct GeometryVectorImportOptions: Sendable {
    let mode: GeometryVectorImportMode
    let mergeContiguousArcs: Bool
    let removeExternalArcs: Bool
}

enum GeometryVectorImportSessionError: LocalizedError {
    case parentUnavailable
    case invalidSelection
    case staleContext
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .parentUnavailable:
            "The owning geometry draft is not ready for import."
        case .invalidSelection:
            "Choose one or more valid polyline or polygon Shapefiles."
        case .staleContext:
            "The geometry draft changed while the Shapefile operation was running. Reload the importer and try again."
        case .invalidResponse:
            "The source reader returned a Shapefile result for a different geometry draft."
        }
    }
}

@MainActor
struct GeometryVectorImportView: View {
    @ObservedObject var topology: GeometryTopologySession
    @ObservedObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var choosingFiles = false
    @State private var sourceURLs: [URL] = []
    @State private var inspection: GeometryVectorImportInspection?
    @State private var previewPath: String?
    @State private var mode: GeometryVectorImportMode = .merge
    @State private var mergeContiguousArcs = false
    @State private var removeExternalArcs = false
    @State private var isWorking = false
    @State private var error: String?
    @State private var work: Task<Void, Never>?
    @State private var operationID = UUID()

    private var previewSource: GeometryVectorImportSource? {
        guard let inspection else { return nil }
        return inspection.sources.first(where: { $0.path == previewPath }) ?? inspection.sources.first
    }
    private var canImport: Bool {
        topology.canMutateTopology && !isWorking
            && inspection?.sources.contains(where: { !$0.features.isEmpty }) == true
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L10n.text("Import Vector Lines"), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(L10n.text("Cancel"), role: .cancel) { work?.cancel(); dismiss() }
                Button(L10n.text("Import into Geometry Draft")) { applyImport() }
                    .buttonStyle(.borderedProminent).disabled(!canImport)
            }
            .padding(16)
            Text(L10n.text("Imports real polyline and polygon Shapefiles into the owning geometry's unsaved topology draft. Save the parent geometry to persist the change."))
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, 12)
            Divider()

            HSplitView {
                VStack(alignment: .leading, spacing: 12) {
                    Button { choosingFiles = true } label: {
                        Label(L10n.text("Choose Shapefiles…"), systemImage: "folder.badge.plus")
                    }
                    .disabled(isWorking || !topology.canMutateTopology)

                    if let inspection {
                        if inspection.sources.isEmpty {
                            ContentUnavailableView(L10n.text("No Importable Line or Polygon Files"),
                                systemImage: "point.3.connected.trianglepath.dotted",
                                description: Text(L10n.text("Select valid polyline or polygon Shapefiles. Point and unsupported shape types are not accepted by the geometry importer.")))
                                .frame(minHeight: 180)
                        } else {
                            List(selection: $previewPath) {
                                Section(L10n.text("Included Sources")) {
                                    ForEach(inspection.sources) { source in
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(source.name).font(.body.weight(.medium))
                                            Text(L10n.format("%@ · %@ features", displayShapeType(source.shapeType), source.featureCount.formatted()))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        .tag(Optional(source.path))
                                    }
                                }
                                if !inspection.issues.isEmpty {
                                    Section(L10n.text("Files Skipped by Source Reader")) {
                                        ForEach(inspection.issues) { issue in
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(URL(fileURLWithPath: issue.path).lastPathComponent)
                                                    .font(.body.weight(.medium))
                                                Text(L10n.text(issue.message)).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                            }
                            .listStyle(.inset)
                        }
                    } else {
                        ContentUnavailableView(L10n.text("Choose Source Files"), systemImage: "point.3.connected.trianglepath.dotted",
                            description: Text(L10n.text("The retained Shapefile reader will inspect line and polygon records in the owning project's coordinate system.")))
                            .frame(minHeight: 180)
                    }

                    GroupBox(L10n.text("Import Options")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker(L10n.text("Operation"), selection: $mode) {
                                ForEach(GeometryVectorImportMode.allCases) { option in
                                    Text(L10n.text(option.title)).tag(option)
                                }
                            }
                            Text(L10n.text(mode.help)).font(.caption).foregroundStyle(.secondary)
                            Toggle(L10n.text("Merge contiguous arcs"), isOn: $mergeContiguousArcs)
                                .disabled(mode != .merge)
                            Toggle(L10n.text("Remove external arcs after completion"), isOn: $removeExternalArcs)
                                .disabled(mode != .merge)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(isWorking)
                }
                .padding(16)
                .frame(minWidth: 290, idealWidth: 350, maxWidth: 430)

                VStack(spacing: 0) {
                    if let previewSource {
                        GeometryVectorImportPreview(source: previewSource)
                            .frame(minWidth: 420, minHeight: 300)
                        HStack {
                            Text(previewSource.name).font(.headline)
                            Spacer()
                            Text(L10n.format("Project coordinates · type %d", previewSource.shapeTypeCode))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(12)
                    } else {
                        ContentUnavailableView(L10n.text("Preview Appears Here"), systemImage: "map",
                            description: Text(L10n.text("After reading the selected files, the preview uses the actual projected source features.")))
                    }
                    if isWorking { ProgressView(L10n.text("Reading source features…")).padding(12) }
                    if let error { Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).textSelection(.enabled).padding(12) }
                }
                .frame(minWidth: 470)
            }
        }
        .frame(minWidth: 840, minHeight: 600)
        .fileImporter(isPresented: $choosingFiles,
            allowedContentTypes: [UTType(filenameExtension: "shp") ?? .data], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    var seen = Set<String>()
                    sourceURLs = urls.filter { url in
                        guard url.pathExtension.lowercased() == "shp" else { return false }
                        let identity = url.resolvingSymlinksInPath().standardizedFileURL.path
                        return seen.insert(identity).inserted
                    }
                    if sourceURLs.count != urls.count {
                        error = L10n.text("Only .shp source files can be imported; their matching .shx/.dbf files are read automatically.")
                    }
                    inspectSources()
                case .failure(let failure):
                    if !(failure is CancellationError) { error = L10n.text(failure.localizedDescription) }
                }
            }
        .onDisappear { work?.cancel() }
    }

    private func inspectSources() {
        work?.cancel()
        inspection = nil
        previewPath = nil
        guard !sourceURLs.isEmpty else { return }
        let requestID = UUID()
        operationID = requestID
        isWorking = true
        error = nil
        work = Task { @MainActor in
            let scopedURLs = sourceURLs.map { ($0, $0.startAccessingSecurityScopedResource()) }
            defer {
                for (url, scoped) in scopedURLs where scoped { url.stopAccessingSecurityScopedResource() }
                if operationID == requestID { isWorking = false }
            }
            do {
                let result = try await topology.inspectVectorImport(paths: sourceURLs.map(\.path))
                guard operationID == requestID, !Task.isCancelled else { return }
                inspection = result
                previewPath = result.sources.first?.path
                if result.sources.isEmpty, error == nil {
                    error = result.issues.first?.message ?? "No supported line or polygon features were found."
                }
            } catch {
                guard operationID == requestID, !Task.isCancelled else { return }
                self.error = L10n.text(error.localizedDescription)
            }
        }
    }

    private func applyImport() {
        guard let inspection, canImport else { return }
        work?.cancel()
        let requestID = UUID()
        operationID = requestID
        isWorking = true
        error = nil
        work = Task { @MainActor in
            let selected = Set(inspection.sources.map(\.path))
            let scopes = sourceURLs.map { ($0, $0.startAccessingSecurityScopedResource()) }
            defer {
                for (url, scoped) in scopes where scoped { url.stopAccessingSecurityScopedResource() }
                if operationID == requestID { isWorking = false }
            }
            do {
                let succeeded = try await topology.applyVectorImport(inspection,
                    sourcePaths: inspection.sources.filter { selected.contains($0.path) }.map(\.path),
                    options: GeometryVectorImportOptions(mode: mode,
                        mergeContiguousArcs: mergeContiguousArcs,
                        removeExternalArcs: removeExternalArcs))
                guard operationID == requestID, !Task.isCancelled else { return }
                if succeeded { dismiss() }
            } catch {
                guard operationID == requestID, !Task.isCancelled else { return }
                self.error = L10n.text(error.localizedDescription)
            }
        }
    }

    private func displayShapeType(_ shapeType: String) -> String {
        switch shapeType {
        case "Polyline", "Polygon": L10n.text(shapeType)
        default: shapeType
        }
    }
}

private struct GeometryVectorImportPreview: View {
    let source: GeometryVectorImportSource

    var body: some View {
        Canvas { context, size in
            let allPoints = source.features.flatMap(\.points)
            guard !allPoints.isEmpty else { return }
            let minX = allPoints.map(\.x).min() ?? 0
            let maxX = allPoints.map(\.x).max() ?? minX + 1
            let minY = allPoints.map(\.y).min() ?? 0
            let maxY = allPoints.map(\.y).max() ?? minY + 1
            let spanX = max(maxX - minX, 1e-12)
            let spanY = max(maxY - minY, 1e-12)
            let inset: CGFloat = 20
            let scale = Double(min(max(1, size.width - inset * 2) / CGFloat(spanX),
                                   max(1, size.height - inset * 2) / CGFloat(spanY)))
            let drawWidth = CGFloat(spanX * scale)
            let drawHeight = CGFloat(spanY * scale)
            let originX = (size.width - drawWidth) / 2
            let originY = (size.height - drawHeight) / 2
            func point(_ value: GeometryTopologyCoordinate) -> CGPoint {
                CGPoint(x: originX + CGFloat((value.x - minX) * scale),
                        y: size.height - originY - CGFloat((value.y - minY) * scale))
            }
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(nsColor: .windowBackgroundColor)))
            for feature in source.features {
                guard let first = feature.points.first else { continue }
                var path = Path()
                path.move(to: point(first))
                for vertex in feature.points.dropFirst() { path.addLine(to: point(vertex)) }
                if feature.geometryType == "polygon" {
                    path.closeSubpath()
                    context.fill(path, with: .color(Color.accentColor.opacity(0.12)))
                }
                context.stroke(path, with: .color(Color.accentColor), lineWidth: 1.5)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(12)
    }
}

/// Uses the existing source-backed grid importer. Layer selection remains
/// explicit when the generic tool route has no spatial owner layer.
@MainActor
struct SpatialBoundaryImportRouteView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var session: ModelEditorSession
    let assetID: String
    let layerID: String?
    @State private var selectedLayer: SpatialBoundaryLayer?

    private var availableLayers: [SpatialBoundaryLayer] {
        SpatialBoundaryImportLayerRoute.supportedLayers.filter { layer in
            guard let enabledField = layer.enabledField, session.fields[enabledField.storageID] != nil,
                  let typeField = layer.typeField, session.fields[typeField.storageID] != nil else { return false }
            return true
        }
    }
    private var explicitLayer: SpatialBoundaryLayer? {
        SpatialBoundaryImportLayerRoute.resolve(layerID: layerID, selectedLayer: selectedLayer)
    }
    private var targetLayer: SpatialBoundaryLayer? {
        explicitLayer
    }
    private var requestedLayerIsUnsupported: Bool {
        guard layerID != nil else { return false }
        return explicitLayer == nil
    }
    private var requestedLayerIsUnavailable: Bool {
        layerID != nil && explicitLayer.map { !availableLayers.contains($0) } == true
    }
    private var parentIsCurrent: Bool {
        guard session.modelAssetID == assetID else { return false }
        guard store.assets.contains(where: { $0.id == assetID && $0.section == .boundaryConditions }),
              store.editorSession(session.id) === session else { return false }
        let activeOwner = store.spatialImportEditorSession(assetID: assetID)
        let primaryOwner = store.primaryEditorSession(.boundaryCondition)
        return activeOwner.map { $0 === session } == true || primaryOwner === session
    }

    var body: some View {
        Group {
            if !parentIsCurrent {
                ContentUnavailableView(L10n.text("Spatial Import Owner Unavailable"), systemImage: "square.stack.3d.up.slash",
                    description: Text(L10n.text("Open this tool from the boundary condition that owns the selected spatial data.")))
            } else if requestedLayerIsUnsupported {
                ContentUnavailableView(L10n.text("Grid Import Not Supported for This Layer"), systemImage: "square.stack.3d.up.slash",
                    description: Text(L10n.text("The retained local-raster importer supports precipitation, wind, air pressure, and air density.")))
            } else if requestedLayerIsUnavailable {
                ContentUnavailableView(L10n.text("Grid Import Layer Unavailable"), systemImage: "square.stack.3d.up.slash",
                    description: Text(L10n.text("This boundary model does not expose the selected grid layer.")))
            } else if let targetLayer, availableLayers.contains(targetLayer) {
                SpatialGridImportSheet(layer: targetLayer, session: session, store: store,
                    openCumulusImporter: {
                        store.startSpatialImport(layerID: targetLayer.id, assetID: assetID,
                            tool: .griddedImport, editorID: session.id)
                    })
            } else if availableLayers.isEmpty {
                ContentUnavailableView(L10n.text("No Grid Import Layer Available"), systemImage: "square.stack.3d.up.slash",
                    description: Text(L10n.text("The current boundary model has no source-supported spatial layer for local grid import.")))
            } else {
                Form {
                    Section(L10n.text("Choose Boundary Layer")) {
                        Picker(L10n.text("Spatial layer"), selection: $selectedLayer) {
                            Text(L10n.text("Select a layer…")).tag(SpatialBoundaryLayer?.none)
                            ForEach(availableLayers) { layer in
                                Label(L10n.text(layer.title), systemImage: layer.symbol).tag(Optional(layer))
                            }
                        }
                        Text(L10n.text("The importer will save this boundary model's current edits together with the selected grids."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .frame(minWidth: 440, minHeight: 220)
            }
        }
        .onAppear {
            guard layerID != nil else {
                selectedLayer = nil
                return
            }
            if let explicitLayer, availableLayers.contains(explicitLayer) {
                selectedLayer = explicitLayer
            }
        }
        .onChange(of: layerID) { _, newLayerID in
            guard let newLayerID else { selectedLayer = nil; return }
            guard let resolved = SpatialBoundaryLayer(rawValue: newLayerID),
                  availableLayers.contains(resolved) else {
                selectedLayer = nil
                return
            }
            selectedLayer = resolved
        }
    }
}

enum SpatialBoundaryImportLayerRoute {
    static let supportedLayers: [SpatialBoundaryLayer] = [
        .precipitation, .wind, .airPressure, .airDensity
    ]

    static func resolve(layerID: String?, selectedLayer: SpatialBoundaryLayer?) -> SpatialBoundaryLayer? {
        let candidate: SpatialBoundaryLayer?
        if let layerID {
            candidate = SpatialBoundaryLayer(rawValue: layerID)
        } else {
            candidate = selectedLayer
        }
        guard let candidate, supportedLayers.contains(candidate) else { return nil }
        return candidate
    }
}
