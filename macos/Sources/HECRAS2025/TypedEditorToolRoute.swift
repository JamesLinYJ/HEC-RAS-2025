import RASWorkspaceCore
import SwiftUI

/// Chooses an exact existing model before handing a global import/tag action
/// to that model's primary editor and its existing draft lifecycle.
@MainActor
struct TypedEditorToolRoute: View {
    @ObservedObject var store: WorkspaceStore
    let action: ToolKind

    @Environment(\.dismiss) private var dismiss
    @StateObject private var surfaceCatalog = SurfaceCatalogSession()
    @State private var capturedProjectSessionID: UUID
    @State private var projectWasReplaced = false
    @State private var selectedAssetID: String?
    @State private var selectedFeatureKind: String?
    @State private var isSubmitting = false
    @State private var failure: String?
    @State private var loadedSurfaceCatalogKey: TypedEditorSurfaceCatalogKey?
    @State private var surfaceCatalogUnavailable = false

    init(store: WorkspaceStore, action: ToolKind) {
        self.store = store
        self.action = action
        _capturedProjectSessionID = State(initialValue: store.projectSessionID)
    }

    private var targetSection: ProjectSection? {
        switch action {
        case .terrainImport: .terrains
        case .classificationImport: .surfaceLayers
        case .griddedImport, .initialConditions, .spatialImport: .boundaryConditions
        case .tagCreate, .tagEdit: .geometries
        case .topology, .topologyRecipe, .arcPoints, .tagFilter, .vectorImport: .geometries
        default: nil
        }
    }

    private var isTagAction: Bool { action == .tagCreate || action == .tagEdit }
    private var isGeometryEditorAction: Bool {
        [.topology, .topologyRecipe, .arcPoints, .tagFilter, .vectorImport].contains(action)
    }

    private var headerSymbol: String {
        switch action {
        case .tagCreate, .tagEdit: "tag"
        case .topology: "point.3.connected.trianglepath.dotted"
        case .topologyRecipe: "list.bullet.rectangle.portrait"
        case .arcPoints: "point.topleft.down.to.point.bottomright.curvepath"
        case .tagFilter: "line.3.horizontal.decrease"
        default: "square.and.arrow.down"
        }
    }

    private var routingHelp: String? {
        switch action {
        case .initialConditions:
            "Attach initial conditions to the selected Boundary Condition."
        case .topology:
            "Topology settings for the selected Geometry."
        case .topologyRecipe:
            "Select control points on the Regions page to edit their recipe."
        case .arcPoints:
            "Select one arc on the Arcs page to edit its points."
        case .tagFilter:
            "Filter arcs or control points by properties and tags."
        default: nil
        }
    }

    private var surfaceModelAssets: [ProjectAsset] {
        store.assets.filter { $0.section == .surfaceLayers && $0.isModelFile }
    }

    private var surfaceCatalogKey: TypedEditorSurfaceCatalogKey {
        .init(projectSessionID: store.projectSessionID, assetsRevision: store.assetsRevision,
            paths: surfaceModelAssets.map { "\($0.id)|\(SourceFilePaths.canonical($0.url))" }.sorted())
    }

    private var choices: [ProjectAsset] {
        guard let targetSection else { return [] }
        var matches = store.assets.filter { $0.section == targetSection && $0.isModelFile }
        if action == .classificationImport {
            guard !projectWasReplaced,
                  store.projectSessionID == capturedProjectSessionID,
                  loadedSurfaceCatalogKey == surfaceCatalogKey else { return [] }
            matches = matches.filter { asset in
                guard let entry = surfaceCatalog.entries[asset.id] else { return false }
                return entry.category == CatalogGroup.classifications.rawValue && entry.error == nil
            }
        }
        return matches
            .sorted {
                let nameOrder = $0.name.localizedStandardCompare($1.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return $0.url.standardizedFileURL.path.localizedStandardCompare(
                    $1.url.standardizedFileURL.path) == .orderedAscending
            }
    }

    private var selectedAsset: ProjectAsset? {
        guard !projectWasReplaced,
              store.projectSessionID == capturedProjectSessionID,
              let selectedAssetID else { return nil }
        let matches = choices.filter { $0.id == selectedAssetID }
        return matches.count == 1 ? matches[0] : nil
    }

    private var canOpen: Bool {
        guard selectedAsset != nil, !isSubmitting, !projectWasReplaced,
              store.projectSessionID == capturedProjectSessionID else { return false }
        return !isTagAction || selectedFeatureKind == "arc" || selectedFeatureKind == "region"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: headerSymbol)
                Text(verbatim: action.localizedTitle).font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(20)
            Divider()

            if targetSection == nil {
                ContentUnavailableView(L10n.text("This action does not have a typed editor route."),
                    systemImage: "questionmark.folder")
            } else if projectWasReplaced || store.projectSessionID != capturedProjectSessionID {
                ContentUnavailableView(L10n.text("The project changed while this chooser was open."),
                    systemImage: "arrow.triangle.2.circlepath",
                    description: Text(L10n.text("Close this chooser and start the action again for the current project.")))
            } else {
                Form {
                    Section(L10n.text("Target model")) {
                        Picker(L10n.text("Model"), selection: $selectedAssetID) {
                            Text(L10n.text("Choose a model…")).tag(Optional<String>.none)
                            ForEach(choices) { asset in
                                Text(verbatim: "\(asset.name) — \(asset.url.standardizedFileURL.path)")
                                    .tag(Optional(asset.id))
                            }
                        }
                        .pickerStyle(.menu)

                        if let selectedAsset {
                            LabeledContent(L10n.text("Model path")) {
                                Text(verbatim: selectedAsset.url.standardizedFileURL.path)
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                            }
                        }

                        if choices.isEmpty {
                            if action == .classificationImport && surfaceCatalog.busy {
                                HStack(spacing: 10) {
                                    ProgressView().controlSize(.small)
                                    Text(L10n.text("Checking surface layer sources…"))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 90)
                            } else if action == .classificationImport && surfaceCatalogUnavailable {
                                catalogFailure("The surface layer catalog is unavailable.")
                            } else if action == .classificationImport, let catalogError = surfaceCatalog.error {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(verbatim: catalogError)
                                        .foregroundStyle(.red)
                                        .textSelection(.enabled)
                                    Button(L10n.text("Retry surface layer check")) {
                                        Task { await loadSurfaceCatalog() }
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
                            } else {
                                VStack(spacing: 8) {
                                    ContentUnavailableView(L10n.text(action == .classificationImport
                                        ? "No Classification model files are available."
                                        : "No matching model files are available."),
                                        systemImage: "doc.badge.questionmark",
                                        description: Text(L10n.text(action == .classificationImport
                                            ? "Only files identified as Classification layers can be selected."
                                            : "Choose an existing model in the required project section.")))
                                    if action == .classificationImport {
                                        Button(L10n.text("Retry surface layer check")) {
                                            Task { await loadSurfaceCatalog() }
                                        }
                                        .disabled(store.modelProvider == nil || surfaceCatalog.busy)
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: 110)
                            }
                        }
                    }

                    if isTagAction {
                        Section(L10n.text("Feature table")) {
                            Picker(L10n.text("Feature type"), selection: $selectedFeatureKind) {
                                Text(L10n.text("Choose a feature type…")).tag(Optional<String>.none)
                                Text(L10n.text("Arcs")).tag(Optional("arc"))
                                Text(L10n.text("Regions")).tag(Optional("region"))
                            }
                            .pickerStyle(.segmented)
                            Text(L10n.text("Tags can be created or assigned on Arc and Region features."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if action == .griddedImport {
                        Section(L10n.text("Gridded layer")) {
                            Text(L10n.text("Choose the exact Boundary Condition model here, then choose its Gridded layer in the editor."))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if isGeometryEditorAction, let routingHelp {
                        Section(L10n.text("Geometry action")) {
                            Text(L10n.text(routingHelp))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let failure {
                        Section {
                            Label(failure, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                }
                .formStyle(.grouped)
                .padding(.horizontal, 12)
            }

            Divider()
            HStack {
                Button(L10n.text("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.text("Open in Editor"), action: openInEditor)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canOpen)
            }
            .padding(16)
        }
        .frame(minWidth: 620, idealWidth: 760, minHeight: 400, idealHeight: 510)
        .task(id: surfaceCatalogKey) {
            guard action == .classificationImport else { return }
            await loadSurfaceCatalog()
        }
        .onChange(of: store.projectSessionID) { _, _ in
            projectWasReplaced = true
            selectedAssetID = nil
            selectedFeatureKind = nil
            failure = nil
            loadedSurfaceCatalogKey = nil
            surfaceCatalog.invalidate()
        }
        .onChange(of: store.assetsRevision) { _, _ in
            guard action == .classificationImport,
                  store.projectSessionID == capturedProjectSessionID else { return }
            selectedAssetID = nil
            loadedSurfaceCatalogKey = nil
            surfaceCatalogUnavailable = false
        }
        .onChange(of: selectedAssetID) { _, _ in failure = nil }
        .onChange(of: selectedFeatureKind) { _, _ in failure = nil }
        .onDisappear { surfaceCatalog.invalidate() }
    }

    private func catalogFailure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text(message)).foregroundStyle(.red)
            Button(L10n.text("Retry surface layer check")) {
                Task { await loadSurfaceCatalog() }
            }
            .disabled(store.modelProvider == nil || surfaceCatalog.busy)
        }
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
    }

    private func loadSurfaceCatalog() async {
        guard action == .classificationImport,
              !projectWasReplaced,
              store.projectSessionID == capturedProjectSessionID else { return }
        let expectedKey = surfaceCatalogKey
        let expectedProject = store.projectSessionID
        let expectedAssetsRevision = store.assetsRevision
        let expectedPaths = surfaceModelAssets.map { SourceFilePaths.canonical($0.url) }.sorted()
        guard let provider = store.modelProvider else {
            surfaceCatalogUnavailable = true
            loadedSurfaceCatalogKey = expectedKey
            return
        }
        surfaceCatalogUnavailable = false
        await surfaceCatalog.load(surfaceModelAssets, provider: provider)
        guard !Task.isCancelled,
              store.projectSessionID == expectedProject,
              expectedProject == capturedProjectSessionID,
              store.assetsRevision == expectedAssetsRevision,
              surfaceModelAssets.map({ SourceFilePaths.canonical($0.url) }).sorted() == expectedPaths,
              surfaceCatalogKey == expectedKey else { return }
        loadedSurfaceCatalogKey = expectedKey
        if let selectedAssetID, !choices.contains(where: { $0.id == selectedAssetID }) {
            self.selectedAssetID = nil
        }
    }

    private func openInEditor() {
        guard canOpen,
              store.projectSessionID == capturedProjectSessionID,
              let asset = selectedAsset,
              let targetSection,
              asset.section == targetSection,
              asset.id == selectedAssetID,
              asset.isModelFile else {
            failure = L10n.text("Select one existing model file in the required section.")
            return
        }

        isSubmitting = true
        defer { isSubmitting = false }
        let accepted = store.requestEditorToolPresentation(action: action, assetID: asset.id,
            spatialLayerID: nil,
            featureKind: isTagAction ? selectedFeatureKind : (action == .arcPoints ? "arc" : nil))
        guard accepted else {
            failure = L10n.text("The primary editor could not accept this action for the selected model.")
            return
        }
        dismiss()
    }
}

private struct TypedEditorSurfaceCatalogKey: Hashable {
    let projectSessionID: UUID
    let assetsRevision: Int
    let paths: [String]
}
