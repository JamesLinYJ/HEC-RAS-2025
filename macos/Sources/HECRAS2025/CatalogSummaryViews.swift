import RASWorkspaceCore
import SwiftUI

struct CatalogSummaryDisplayField: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let value: String
}

struct CatalogSummaryDisplaySection: Identifiable, Hashable, Sendable {
    let schemaID: String
    let title: String
    let fields: [CatalogSummaryDisplayField]
    let unavailableFields: [String]
    var id: String { schemaID }
}

enum CatalogSummarySnapshotMapper {
    static func kind(for editorKind: ModelEditorKind, sourceFields: [String: String]) -> CatalogSummaryKind? {
        switch editorKind {
        case .geometry: return .geometry
        case .plan: return .plan
        case .terrain: return .terrain
        case .boundaryCondition: return .boundaryCondition
        case .result: return .result
        case .surface:
            let hasNValue = sourceFields.keys.contains { $0.hasPrefix("NValueCatalogSummary/") }
            let hasClassification = sourceFields.keys.contains {
                $0.hasPrefix("ClassificationCatalogSummary/") || $0.hasPrefix("ClassificationLayerSummary/")
            }
            switch (hasNValue, hasClassification) {
            case (true, false): return .nValue
            case (false, true): return .classification
            case (false, false), (true, true): return nil
            }
        }
    }

    static func sections(for kind: CatalogSummaryKind, sourceFields: [String: String]) -> [CatalogSummaryDisplaySection] {
        let primarySchema: String
        switch kind {
        case .project: primarySchema = "ProjectCatalogSummary"
        case .plan: primarySchema = "PlanCatalogSummary"
        case .geometry: primarySchema = "GeometryCatalogSummary"
        case .terrain: primarySchema = "TerrainCatalogSummary"
        case .nValue: primarySchema = "NValueCatalogSummary"
        case .classification: primarySchema = "ClassificationCatalogSummary"
        case .boundaryCondition: primarySchema = "BoundaryConditionCatalogSummary"
        case .result: primarySchema = "ResultCatalogSummary"
        }
        var schemaIDs = [primarySchema]
        if kind == .classification,
           sourceFields.keys.contains(where: { $0.hasPrefix("ClassificationLayerSummary/") }) {
            schemaIDs.append("ClassificationLayerSummary")
        }
        return schemaIDs.compactMap { schemaID in
            guard let schema = SourceEditorLibrary.shared.schema(schemaID) else { return nil }
            let values = schema.fields.compactMap { field -> CatalogSummaryDisplayField? in
                // A known empty description is source data; only an absent
                // key means the provider did not supply this field.
                guard let value = sourceFields[field.storageID] else { return nil }
                return CatalogSummaryDisplayField(id: field.storageID, title: field.title, value: value)
            }
            guard sourceFields.keys.contains(where: { $0.hasPrefix(schemaID + "/") }) else { return nil }
            let populatedIDs = Set(values.map(\.id))
            let unavailable = schema.fields.filter { !populatedIDs.contains($0.storageID) }.map(\.title)
            return CatalogSummaryDisplaySection(schemaID: schema.id, title: schema.title, fields: values, unavailableFields: unavailable)
        }
    }

    static func embeddedImages(from sourceImages: [String: [ImageAttachment]]) -> [ImageAttachment] {
        // Source summary headers expose the same attachment collection through
        // several editor schemas. Keep the aliases in a stable order and
        // deduplicate by the source attachment identity, retaining its name.
        let schemaAliases = SourceEditorLibrary.shared.schemas
            .flatMap(\.fields)
            .filter { $0.kind == "images" }
            .map(\.storageID)
            .sorted()
        let aliases = ["RasCatalogSummary/EmbeddedImages"] + schemaAliases
        var seen = Set<String>()
        return aliases.flatMap { sourceImages[$0] ?? [] }.filter { seen.insert($0.id).inserted }
    }
}

@MainActor
final class CatalogAssetSummarySession: ObservableObject {
    @Published private(set) var kind: CatalogSummaryKind?
    @Published private(set) var sections: [CatalogSummaryDisplaySection] = []
    @Published private(set) var images: [ImageAttachment] = []
    @Published private(set) var sourceSnapshot: EditorSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private var requestRevision = 0
    private var requestAssetID: String?
    private var requestProjectSessionID: UUID?
    private var requestAssetsRevision: Int?

    func load(asset: ProjectAsset, projectSessionID: UUID, assetsRevision: Int, editorKind: ModelEditorKind, provider: (any ModelEditorProvider)?) async {
        requestRevision += 1
        let revision = requestRevision
        requestAssetID = asset.id; requestProjectSessionID = projectSessionID; requestAssetsRevision = assetsRevision
        kind = nil; sections = []; images = []; sourceSnapshot = nil; error = nil; isLoading = false
        guard let provider else {
            error = "Model metadata provider is unavailable."
            return
        }
        isLoading = true
        defer { if requestRevision == revision { isLoading = false } }
        do {
            // This read-only provider call does not create or reuse an editor
            // draft, and the returned values are never submitted for saving.
            let snapshot = try await provider.load(asset, kind: editorKind)
            guard requestRevision == revision, !Task.isCancelled,
                  requestAssetID == asset.id,
                  requestProjectSessionID == projectSessionID,
                  requestAssetsRevision == assetsRevision else { return }
            sourceSnapshot = snapshot
            images = CatalogSummarySnapshotMapper.embeddedImages(from: snapshot.images)
            guard let summaryKind = CatalogSummarySnapshotMapper.kind(for: editorKind, sourceFields: snapshot.fields) else {
                error = "The provider did not return one unambiguous source summary schema for this asset."
                return
            }
            let mappedSections = CatalogSummarySnapshotMapper.sections(for: summaryKind, sourceFields: snapshot.fields)
            guard !mappedSections.isEmpty else {
                kind = summaryKind
                error = "The provider returned no values for the selected source summary schema."
                return
            }
            kind = summaryKind
            sections = mappedSections
        } catch {
            guard requestRevision == revision, !Task.isCancelled,
                  requestAssetID == asset.id,
                  requestProjectSessionID == projectSessionID,
                  requestAssetsRevision == assetsRevision else { return }
            self.error = L10n.text(error.localizedDescription)
        }
    }

    func invalidate() {
        requestRevision += 1
        requestAssetID = nil; requestProjectSessionID = nil; requestAssetsRevision = nil
        kind = nil; sections = []; images = []; sourceSnapshot = nil; error = nil; isLoading = false
    }
}

struct CatalogSummaryHeaderView: View {
    let kind: CatalogSummaryKind
    let name: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(name, systemImage: symbol)
                .font(.headline)
                .textSelection(.enabled)
            Text(L10n.text(kind.title))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct CatalogSummaryRouter: View {
    let kind: CatalogSummaryKind
    let node: LayerTreeNode
    let store: WorkspaceStore
    var assetPath: String?

    var body: some View {
        switch kind {
        case .project: ProjectCatalogSummaryView(node: node, store: store, assetPath: assetPath)
        case .plan: PlanCatalogSummaryView(node: node, store: store, assetPath: assetPath)
        case .geometry: GeometryCatalogSummaryView(node: node, store: store, assetPath: assetPath)
        case .terrain: TerrainCatalogSummaryView(node: node, store: store, assetPath: assetPath)
        case .nValue: NValueCatalogSummaryView(node: node, store: store, assetPath: assetPath)
        case .classification: ClassificationCatalogSummaryView(node: node, store: store, assetPath: assetPath)
        case .boundaryCondition: BoundaryConditionCatalogSummaryView(node: node, store: store, assetPath: assetPath)
        case .result: ResultCatalogSummaryView(node: node, store: store, assetPath: assetPath)
        }
    }
}

private struct CatalogSummaryScaffold: View {
    let kind: CatalogSummaryKind
    let node: LayerTreeNode
    let store: WorkspaceStore
    var assetPath: String?

    private var summary: CatalogNodeSummaryData { node.catalogSummary ?? CatalogNodeSummaryData() }
    private var displayedName: String {
        summary.name ?? (node.localizeName ? L10n.text(node.name) : node.name)
    }
    private var filename: String? { assetPath ?? summary.filename }
    private var additionalProperties: [LayerTreeNode.Property] {
        let standard = Set(["Name", "Filename", "DateCreated", "DateLastModified", "Description"])
        return node.properties.filter { !standard.contains($0.id) }
    }
    private var hasSourceMetadata: Bool {
        summary.dateCreated != nil || summary.dateLastModified != nil || summary.description != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CatalogSummaryHeaderView(kind: kind, name: displayedName, symbol: node.symbol)
            CatalogLayerDiagnosticsSummary(node: node, store: store)
            if kind == .result {
                ResultComputeStatusDetails(node: node, store: store, assetPath: filename)
            }
            if let filename {
                CatalogFilePath(title: "Filename", path: filename, store: store)
            }
            if let dateCreated = summary.dateCreated {
                PropertyValue("Date Created", value: dateCreated)
            }
            if let dateLastModified = summary.dateLastModified {
                PropertyValue("Date Last Modified", value: dateLastModified)
            }
            if let description = summary.description {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Description").font(.caption).foregroundStyle(.secondary)
                    Text(description).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !additionalProperties.isEmpty {
                SharedVisualMetadataPropertiesRepeater(properties: additionalProperties.map {
                    .init(id: $0.id, key: L10n.text($0.label), value: $0.value)
                })
            }
            if !hasSourceMetadata && node.properties.isEmpty {
                CatalogSummaryUnavailableNotice(
                    title: "Summary metadata unavailable",
                    detail: filename == nil
                        ? "The selected catalog snapshot does not include filename, dates, or description values."
                        : "The selected catalog snapshot does not include source dates or description values."
                )
            }
            if kind.showsMapPreview {
                CatalogSummaryUnavailableNotice(
                    title: "Selected-node map preview unavailable",
                    detail: "The catalog snapshot does not provide renderable geometry, raster, or result-profile state."
                )
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private func sourceField(_ suffix: String, in sections: [CatalogSummaryDisplaySection]) -> CatalogSummaryDisplayField? {
    sections.lazy.flatMap(\.fields).first { $0.id.hasSuffix(suffix) }
}

@MainActor private func catalogSummaryFields(
    _ sections: [CatalogSummaryDisplaySection],
    excluding suffixes: Set<String>
) -> [SharedVisualMetadataProperty] {
    sections.flatMap(\.fields).filter { field in
        !suffixes.contains(where: { field.id.hasSuffix($0) })
    }.map { .init(id: $0.id, key: L10n.text($0.title), value: $0.value) }
}

private struct CatalogSummaryImageGrid: View {
    let images: [ImageAttachment]

    var body: some View {
        if !images.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Images").font(.subheadline.weight(.medium))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], spacing: 8) {
                    ForEach(images) { image in
                        VStack(spacing: 5) {
                            OriginalEmbeddedImagePreview(item: image)
                            Text(image.name).font(.caption).lineLimit(1)
                        }
                        .padding(7)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }
        }
    }
}

struct ProjectCatalogSummaryView: View {
    let node: LayerTreeNode
    @ObservedObject var store: WorkspaceStore
    var assetPath: String? = nil
    @State private var showsProjectUML = false
    @State private var projectUMLURL: URL? = nil
    @State private var projectUMLSessionID: UUID? = nil

    private var summary: CatalogNodeSummaryData { node.catalogSummary ?? CatalogNodeSummaryData() }
    private var properties: [LayerTreeNode.Property] { node.properties }
    private func value(_ id: String) -> String? { properties.first { $0.id == id }?.value }
    private var counts: [LayerTreeNode.Property] { properties.filter { $0.id.hasPrefix("ProjectCount/") } }
    private var activeProjectDescription: Bool {
        guard let currentPath = store.document?.url?.path,
              let summarizedPath = assetPath ?? summary.filename else { return false }
        return Self.canonicalPath(currentPath) == Self.canonicalPath(summarizedPath)
    }
    private var descriptionHasChanges: Bool {
        guard activeProjectDescription else { return false }
        return store.descriptionDraft != (store.document?.description ?? "")
    }
    private var descriptionActionsAreBusy: Bool {
        store.isSavingAll || store.isClosingTab || store.isOpeningProject || store.isRunningProjectTool
    }

    private static func canonicalPath(_ path: String) -> String {
        SourceFilePaths.canonical(URL(fileURLWithPath: path))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CatalogSummaryHeaderView(kind: .project, name: summary.name ?? node.name, symbol: node.symbol)
            CatalogLayerDiagnosticsSummary(node: node, store: store)
            if let filename = assetPath ?? summary.filename {
                CatalogFilePath(title: "Filename", path: filename, store: store)
            }
            if activeProjectDescription, let projectURL = store.document?.url {
                Button("Open Project UML", systemImage: "point.3.connected.trianglepath.dotted") {
                    projectUMLURL = projectURL
                    projectUMLSessionID = store.projectSessionID
                    showsProjectUML = true
                }
                .disabled(descriptionActionsAreBusy)
                .sheet(isPresented: $showsProjectUML) {
                    if let projectUMLURL, let projectUMLSessionID {
                        ProjectUMLWorkspaceView(store: store, projectURL: projectUMLURL,
                            projectSessionID: projectUMLSessionID)
                    }
                }
            }
            if activeProjectDescription {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Description").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $store.descriptionDraft)
                        .font(.body)
                        .frame(minHeight: 90, idealHeight: 120)
                        .accessibilityLabel(L10n.text("Project description"))
                        .disabled(descriptionActionsAreBusy)
                    HStack(spacing: 10) {
                        if descriptionHasChanges {
                            Label(L10n.text("Unsaved description"), systemImage: "pencil.circle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Spacer(minLength: 0)
                        Button("Discard Description", systemImage: "arrow.uturn.backward") {
                            store.descriptionDraft = store.document?.description ?? ""
                        }
                        .disabled(!descriptionHasChanges || descriptionActionsAreBusy)
                        Button("Save All", systemImage: "square.and.arrow.down") {
                            Task { _ = await store.saveAll() }
                        }
                        .disabled(!store.hasUnsavedChanges || descriptionActionsAreBusy)
                    }
                }
            } else if let description = summary.description, !description.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Description").font(.caption).foregroundStyle(.secondary)
                    Text(description).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if counts.count == 7 {
                Section("Components") {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                        ForEach(counts) { item in
                            GridRow {
                                Text(L10n.text(item.label)).foregroundStyle(.secondary)
                                Text(item.value).monospacedDigit().textSelection(.enabled)
                            }
                        }
                    }
                }
            } else {
                CatalogSummaryUnavailableNotice(
                    title: "Project model counts unavailable",
                    detail: "The catalog snapshot does not include all source project layer counts."
                )
            }
            if let units = value("Project/Units"), let projection = value("Project/ProjectionName") {
                Section("Projection") {
                    LabeledContent("Units", value: L10n.text(units))
                    LabeledContent("Projection", value: projection)
                    if let wkt = value("Project/ProjectionWKT"), !wkt.isEmpty {
                        DisclosureGroup("Well-Known Text") {
                            Text(wkt).font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            } else {
                CatalogSummaryUnavailableNotice(
                    title: "Project coordinate system unavailable",
                    detail: "The source project does not provide a complete unit and projection summary."
                )
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct CatalogConnectionCatalogSummaryView: View {
    let node: LayerTreeNode
    let connection: ProjectConnection?
    @ObservedObject var store: WorkspaceStore

    private var isFile: Bool { node.sourceClass == "ExternalFileConnectionCatalogNode" }
    private var symbol: String { isFile ? "doc.text" : "folder.badge.gearshape" }
    private var title: String { L10n.text(isFile ? "External File Connection" : "External Connection") }
    private var targetPath: String? {
        guard let connection else { return nil }
        return connection.relativePath.isEmpty ? connection.absolutePath : connection.relativePath
    }
    private var sourceFilenamePattern: String? {
        node.properties.first { $0.id == "SearchPattern" }?.value
    }
    private var sourceIncludesSubfolders: String? {
        node.properties.first { $0.id == "Recurse" }?.value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Label {
                    Text(connection?.name ?? node.name)
                        .font(.headline).textSelection(.enabled)
                } icon: {
                    CatalogNodeIconView(symbol: symbol, filePath: isFile ? connection?.absolutePath : nil)
                }
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let connection {
                Section("Connection Details") {
                    LabeledContent("Type", value: L10n.text(connection.type))
                    if let targetPath {
                        CatalogFilePath(title: isFile ? "Filename" : "Path", path: targetPath, store: store)
                    }
                    if !connection.description.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Description").font(.caption).foregroundStyle(.secondary)
                            Text(connection.description).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if let sourceFilenamePattern {
                        LabeledContent("Filename Pattern", value: sourceFilenamePattern)
                    }
                    if let sourceIncludesSubfolders {
                        let includes = sourceIncludesSubfolders.lowercased() == "true"
                        LabeledContent("Include Subfolders", value: L10n.text(includes ? "Yes" : "No"))
                    }
                }
                HStack {
                    Button("Manage Connections…") {
                        store.selectConnection(connection)
                        store.showConnectionManager = true
                    }
                    Button("Show in Finder", systemImage: "folder") { store.revealConnection(connection) }
                }
            } else {
                CatalogSummaryUnavailableNotice(
                    title: "Connection details unavailable",
                    detail: "The selected connection node no longer matches a project connection with the same identity and type."
                )
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct PlanCatalogSummaryView: View {
    let node: LayerTreeNode
    let store: WorkspaceStore
    var assetPath: String? = nil
    var sourceSections: [CatalogSummaryDisplaySection] = []
    var images: [ImageAttachment] = []
    var isLoading = false
    var sourceError: String? = nil
    var onRefresh: (() -> Void)? = nil

    private var summary: CatalogNodeSummaryData { node.catalogSummary ?? CatalogNodeSummaryData() }
    private var properties: [LayerTreeNode.Property] { node.properties.filter { $0.id.hasPrefix("PlanAssociation/") } }
    private var name: String { sourceField("/Context_Name", in: sourceSections)?.value ?? summary.name ?? node.name }
    private var filename: String? { sourceField("/Context_Filename", in: sourceSections)?.value ?? assetPath ?? summary.filename }
    private var metadata: [SharedVisualMetadataProperty] {
        catalogSummaryFields(sourceSections, excluding: ["/Context_Name", "/Context_Filename"])
    }
    private var unavailableFields: [String] { sourceSections.flatMap(\.unavailableFields) }
    private var fallbackMetadata: [SharedVisualMetadataProperty] {
        [("Date Created", summary.dateCreated), ("Date Last Modified", summary.dateLastModified), ("Description", summary.description)]
            .compactMap { title, value in value.map { .init(id: "Plan/\(title)", key: L10n.text(title), value: $0) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                CatalogSummaryHeaderView(kind: .plan, name: name, symbol: node.symbol)
                Spacer(minLength: 8)
                if let onRefresh {
                    Button("Refresh", systemImage: "arrow.clockwise", action: onRefresh)
                        .disabled(isLoading)
                        .help("Refresh source summary")
                }
            }
            CatalogLayerDiagnosticsSummary(node: node, store: store)
            if let filename { CatalogFilePath(title: "Filename", path: filename, store: store) }
            if !metadata.isEmpty {
                SharedVisualMetadataPropertiesRepeater(properties: metadata)
            } else if !fallbackMetadata.isEmpty {
                SharedVisualMetadataPropertiesRepeater(properties: fallbackMetadata)
            }
            if isLoading { ProgressView("Loading source summary…").controlSize(.small) }
            if let sourceError {
                CatalogSummaryUnavailableNotice(title: "Source summary unavailable", detail: sourceError)
            }
            if !unavailableFields.isEmpty {
                CatalogSummaryUnavailableNotice(
                    title: "Some source summary fields are unavailable",
                    detail: L10n.format("Unavailable: %@", unavailableFields.map(L10n.text).joined(separator: ", "))
                )
            }
            if properties.count == 3 {
                Section("Associations") {
                    SharedVisualMetadataPropertiesRepeater(properties: properties.map {
                        .init(id: $0.id, key: L10n.text($0.label), value: $0.value.isEmpty ? L10n.text("Not associated") : $0.value)
                    })
                }
            } else {
                CatalogSummaryUnavailableNotice(
                    title: "Plan associations unavailable",
                    detail: "The selected plan node does not include its source geometry, N-value, and classification associations."
                )
            }
            CatalogSummaryImageGrid(images: images)
        }
        .accessibilityElement(children: .contain)
    }
}

struct GeometryCatalogSummaryView: View {
    let node: LayerTreeNode
    let store: WorkspaceStore
    var assetPath: String? = nil
    var body: some View { CatalogSummaryScaffold(kind: .geometry, node: node, store: store, assetPath: assetPath) }
}

struct TerrainCatalogSummaryView: View {
    let node: LayerTreeNode
    let store: WorkspaceStore
    var assetPath: String? = nil
    var body: some View { CatalogSummaryScaffold(kind: .terrain, node: node, store: store, assetPath: assetPath) }
}

struct NValueCatalogSummaryView: View {
    let node: LayerTreeNode
    let store: WorkspaceStore
    var assetPath: String? = nil
    var body: some View { CatalogSummaryScaffold(kind: .nValue, node: node, store: store, assetPath: assetPath) }
}

struct ClassificationCatalogSummaryView: View {
    let node: LayerTreeNode
    let store: WorkspaceStore
    var assetPath: String? = nil
    var body: some View { CatalogSummaryScaffold(kind: .classification, node: node, store: store, assetPath: assetPath) }
}

struct BoundaryConditionCatalogSummaryView: View {
    let node: LayerTreeNode
    let store: WorkspaceStore
    var assetPath: String? = nil
    var sourceSections: [CatalogSummaryDisplaySection] = []
    var images: [ImageAttachment] = []
    var isLoading = false
    var sourceError: String? = nil
    var onRefresh: (() -> Void)? = nil

    private var summary: CatalogNodeSummaryData { node.catalogSummary ?? CatalogNodeSummaryData() }
    private var properties: [LayerTreeNode.Property] { node.properties.filter { $0.id.hasPrefix("BoundaryCondition/") } }
    private var name: String { sourceField("/Context_Name", in: sourceSections)?.value ?? summary.name ?? node.name }
    private var filename: String? { sourceField("/Context_Filename", in: sourceSections)?.value ?? assetPath ?? summary.filename }
    private var metadata: [SharedVisualMetadataProperty] {
        catalogSummaryFields(sourceSections, excluding: ["/Context_Name", "/Context_Filename"])
    }
    private var unavailableFields: [String] { sourceSections.flatMap(\.unavailableFields) }
    private var fallbackMetadata: [SharedVisualMetadataProperty] {
        [("Date Created", summary.dateCreated), ("Date Last Modified", summary.dateLastModified), ("Description", summary.description)]
            .compactMap { title, value in value.map { .init(id: "BoundaryCondition/\(title)", key: L10n.text(title), value: $0) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                CatalogSummaryHeaderView(kind: .boundaryCondition, name: name, symbol: node.symbol)
                Spacer(minLength: 8)
                if let onRefresh {
                    Button("Refresh", systemImage: "arrow.clockwise", action: onRefresh)
                        .disabled(isLoading)
                        .help("Refresh source summary")
                }
            }
            CatalogLayerDiagnosticsSummary(node: node, store: store)
            if let filename { CatalogFilePath(title: "Filename", path: filename, store: store) }
            if !metadata.isEmpty {
                SharedVisualMetadataPropertiesRepeater(properties: metadata)
            } else if !fallbackMetadata.isEmpty {
                SharedVisualMetadataPropertiesRepeater(properties: fallbackMetadata)
            }
            if isLoading { ProgressView("Loading source summary…").controlSize(.small) }
            if let sourceError {
                CatalogSummaryUnavailableNotice(title: "Source summary unavailable", detail: sourceError)
            }
            if !unavailableFields.isEmpty {
                CatalogSummaryUnavailableNotice(
                    title: "Some source summary fields are unavailable",
                    detail: L10n.format("Unavailable: %@", unavailableFields.map(L10n.text).joined(separator: ", "))
                )
            }
            if properties.count == 2 {
                Section("Time Window") {
                    SharedVisualMetadataPropertiesRepeater(properties: properties.map {
                        .init(id: $0.id, key: L10n.text($0.label), value: $0.value)
                    })
                }
            } else {
                CatalogSummaryUnavailableNotice(
                    title: "Boundary condition times unavailable",
                    detail: "The selected boundary condition node does not include its source start and end times."
                )
            }
            CatalogSummaryImageGrid(images: images)
        }
        .accessibilityElement(children: .contain)
    }
}

struct ResultCatalogSummaryView: View {
    let node: LayerTreeNode
    let store: WorkspaceStore
    var assetPath: String? = nil
    var body: some View { CatalogSummaryScaffold(kind: .result, node: node, store: store, assetPath: assetPath) }
}

struct CatalogSummaryUnavailableNotice: View {
    let title: String
    let detail: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text(title)).font(.caption.weight(.medium))
                Text(L10n.text(detail)).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct CatalogAssetSummaryRequestKey: Hashable {
    let projectSessionID: UUID
    let assetsRevision: Int
    let assetID: String
    let editorKind: String
}

struct CatalogAssetInspectorSummaryView: View {
    let asset: ProjectAsset
    let node: LayerTreeNode
    @ObservedObject var store: WorkspaceStore
    @StateObject private var session = CatalogAssetSummarySession()

    private var editorKind: ModelEditorKind? {
        switch asset.section {
        case .geometries: .geometry
        case .plans: .plan
        case .terrains: .terrain
        case .boundaryConditions: .boundaryCondition
        case .results: .result
        case .surfaceLayers: .surface
        case .mapLayers, .features: nil
        }
    }
    private var kind: CatalogSummaryKind? {
        if let kind = session.kind { return kind }
        return switch editorKind {
        case .some(.geometry): .geometry
        case .some(.plan): .plan
        case .some(.terrain): .terrain
        case .some(.boundaryCondition): .boundaryCondition
        case .some(.result): .result
        case .some(.surface), .none: nil
        }
    }
    private var sourceName: String? {
        session.sections.lazy.flatMap(\.fields).first {
            $0.id.hasSuffix("/Context_Name") || $0.id.hasSuffix("/ClassificationLayer_Name")
        }?.value
    }
    private var sourceFilename: String? {
        session.sections.lazy.flatMap(\.fields).first { $0.id.hasSuffix("/Context_Filename") }?.value
    }
    private var requestKey: CatalogAssetSummaryRequestKey? {
        guard let editorKind else { return nil }
        return CatalogAssetSummaryRequestKey(projectSessionID: store.projectSessionID, assetsRevision: store.assetsRevision,
                                             assetID: asset.id, editorKind: editorKind.rawValue)
    }
    private var previewRequestRevision: String {
        [store.projectSessionID.uuidString, String(store.assetsRevision), asset.id,
         asset.url.standardizedFileURL.resolvingSymlinksInPath().path,
         store.document?.url?.standardizedFileURL.resolvingSymlinksInPath().path ?? "",
         store.document?.editorXML(overridingDescription: store.descriptionDraft) ?? "",
         session.sourceSnapshot?.sourceRevision ?? "snapshot-unavailable"].joined(separator: "\n")
    }

    private var sourcePreviewRequestIdentity: String {
        [store.projectSessionID.uuidString, String(store.assetsRevision), asset.id,
         SourceFilePaths.canonical(asset.url),
         store.document?.url.map { SourceFilePaths.canonical($0) } ?? ""].joined(separator: "\n")
    }

    private var modelActionKind: String? {
        switch kind {
        case .geometry: "Geometry"
        case .plan: "Plan"
        case .terrain: "Terrain"
        case .boundaryCondition: "BoundaryCondition"
        case .nValue: "NValue"
        case .classification: "Classification"
        default: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let modelActionKind {
                CatalogModelActionBar(asset: asset, kind: modelActionKind, store: store)
            }
            summaryContent
        }
        .task(id: requestKey) { await loadCurrentSummary() }
        .onDisappear { session.invalidate() }
    }

    private var summaryContent: some View {
        Group {
            switch kind {
            case .plan:
                PlanCatalogSummaryView(
                    node: node, store: store, assetPath: asset.url.path,
                    sourceSections: session.sections, images: session.images,
                    isLoading: session.isLoading, sourceError: session.error,
                    onRefresh: { Task { await loadCurrentSummary() } }
                )
            case .boundaryCondition:
                BoundaryConditionCatalogSummaryView(
                    node: node, store: store, assetPath: asset.url.path,
                    sourceSections: session.sections, images: session.images,
                    isLoading: session.isLoading, sourceError: session.error,
                    onRefresh: { Task { await loadCurrentSummary() } }
                )
            default:
                genericSummary
            }
        }
    }

    private var genericSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                if let kind {
                    CatalogSummaryHeaderView(kind: kind, name: sourceName ?? asset.name, symbol: asset.section.symbol)
                } else {
                    Label(asset.name, systemImage: asset.section.symbol).font(.headline).textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await loadCurrentSummary() }
                }
                .disabled(editorKind == nil || store.modelProvider == nil || session.isLoading)
                .help("Refresh source summary")
            }
            CatalogFilePath(title: "Filename", path: sourceFilename ?? asset.url.path, store: store)
            if asset.section == .results {
                ResultComputeStatusDetails(node: node, store: store, assetPath: asset.url.path)
            }
            if asset.section != .results || !(store.modelProvider is BackendModelProvider) {
                CatalogLayerDiagnosticsSummary(node: node, store: store)
            }
            if asset.section == .results, let backend = store.modelProvider as? BackendModelProvider {
                ResultCatalogActionsPanel(
                    asset: asset,
                    store: store,
                    provider: BackendResultInspectorProvider(client: backend.client)
                )
            }
            if session.isLoading {
                ProgressView("Loading source summary…").controlSize(.small)
            } else if !session.sections.isEmpty {
                ForEach(session.sections) { section in
                    VStack(alignment: .leading, spacing: 7) {
                        if session.sections.count > 1 { Text(L10n.text(section.title)).font(.subheadline.weight(.medium)) }
                        let fields = section.fields.filter {
                            !$0.id.hasSuffix("/Context_Name")
                                && !$0.id.hasSuffix("/ClassificationLayer_Name")
                                && !$0.id.hasSuffix("/Context_Filename")
                        }
                        if !fields.isEmpty {
                            SharedVisualMetadataPropertiesRepeater(properties: fields.map {
                                .init(id: $0.id, key: L10n.text($0.title), value: $0.value)
                            })
                        }
                        if !section.unavailableFields.isEmpty {
                            CatalogSummaryUnavailableNotice(
                                title: "Some source summary fields are unavailable",
                                detail: L10n.format("Unavailable: %@", section.unavailableFields.map(L10n.text).joined(separator: ", "))
                            )
                        }
                    }
                }
            } else if let error = session.error {
                CatalogSummaryUnavailableNotice(title: "Source summary unavailable", detail: error)
            }
            CatalogSummaryImageGrid(images: session.images)
            if kind?.showsMapPreview == true {
                if let backend = store.modelProvider as? BackendModelProvider {
                    switch kind {
                    case .some(.geometry) where asset.section == .geometries:
                        CatalogGeometryMeshPreviewView(asset: asset, projectURL: store.document?.url,
                            requestIdentity: sourcePreviewRequestIdentity,
                            client: backend.client)
                    case .some(.terrain) where asset.section == .terrains:
                        CatalogModelRasterSummaryPreviewView(asset: asset, kind: .terrain,
                            snapshot: session.sourceSnapshot, requestRevision: previewRequestRevision,
                            isSourceLoading: session.isLoading, sourceError: session.error,
                            provider: backend)
                    case .some(.classification) where asset.section == .surfaceLayers:
                        CatalogModelRasterSummaryPreviewView(asset: asset, kind: .classification,
                            snapshot: session.sourceSnapshot, requestRevision: previewRequestRevision,
                            isSourceLoading: session.isLoading, sourceError: session.error,
                            provider: backend)
                    case .some(.result) where asset.section == .results:
                        CatalogResultProfilesDisclosureView(asset: asset, store: store, client: backend.client)
                    case .some(.nValue) where asset.section == .surfaceLayers:
                        CatalogNValuePreviewView(asset: asset, projectURL: store.document?.url,
                            requestIdentity: sourcePreviewRequestIdentity,
                            client: backend.client)
                    case .some(.geometry), .some(.terrain), .some(.classification), .some(.result), .some(.nValue),
                         .none, .some(.project), .some(.plan), .some(.boundaryCondition):
                        CatalogSummaryUnavailableNotice(
                            title: "Selected-node map preview unavailable",
                            detail: "The selected catalog node does not have a matching source asset renderer."
                        )
                    }
                } else {
                    CatalogSummaryUnavailableNotice(
                        title: "Selected-node map preview unavailable",
                        detail: "The model snapshot does not provide a source-backed geometry, raster, or result-profile renderer."
                    )
                }
            }
        }
    }

    @MainActor
    private func loadCurrentSummary() async {
        guard let editorKind else { return }
        await session.load(asset: asset, projectSessionID: store.projectSessionID,
                           assetsRevision: store.assetsRevision, editorKind: editorKind,
                           provider: store.modelProvider)
    }
}

struct ProjectDocumentCatalogSummaryHeaderView: View {
    let name: String

    var body: some View {
        CatalogSummaryHeaderView(kind: .project, name: name, symbol: "folder")
    }
}
