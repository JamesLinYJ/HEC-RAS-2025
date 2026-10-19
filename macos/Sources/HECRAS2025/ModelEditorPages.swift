import RASWorkspaceCore
import SwiftUI

// Page/container counterparts are separate from individual field rendering.
// Source: GeometryEditor, TopologyControl, PlanEditorControl, TerrainEditor,
// BoundaryConditionEditor and the result/context controls in the renamed UI.
struct ModelPageContent: View {
    let kind: ModelEditorKind
    let page: ModelEditorPage
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @Binding var spatialTarget: SpatialBoundaryLayer?
    let navigate: (String) -> Void
    var isDetached = false
    var geometryChoices: [ProjectAsset] = []
    var selectGeometry: (String?) -> Void = { _ in }
    var body: some View {
        switch (kind, page.title) {
        case (.plan, "Summary"):
            PlanCatalogSummary(session: session, store: store)
        case (.plan, "General Options"):
            PlanSettingsPage(session: session, store: store)
        case (.plan, "Advanced Options"):
            PlanComputeSettingsPage(session: session, store: store)
        case (.geometry, "Summary"):
            GeometrySummaryWorkspacePage(session: session, store: store, navigate: navigate,
                                         geometryChoices: geometryChoices, selectGeometry: selectGeometry)
        case (.geometry, "Topology"):
            topologySummaryPage
        case (.geometry, "Arcs"):
            GeometryFeatureWorkspaceRoutePage(featureKind: "arc", session: session, store: store, isDetached: isDetached)
        case (.geometry, "Regions"):
            GeometryFeatureWorkspaceRoutePage(featureKind: "region", session: session, store: store, isDetached: isDetached)
        case (.geometry, "Nodes"):
            topologyPage("node")
        case (.geometry, "Mesh"):
            GeometryMeshPage(session: session, store: store, navigate: navigate,
                selectTopologyFeatures: { featureKind, ids in
                    let assetID = session.modelAssetID
                    Task {
                        await session.ensureGeometryTopologyLoaded()
                        guard session.modelAssetID == assetID else { return }
                        session.geometryTopology?.select(Set(ids), featureKind: featureKind)
                    }
                })
        case (.geometry, "Culverts"):
            GeometryCulvertsPage(session: session, store: store, navigate: navigate)
        case (.geometry, "Barrel Properties"), (.geometry, "Opening Properties"):
            GeometryCulvertPropertiesPage(page: page, session: session, store: store, navigate: navigate)
        case (.terrain, "Terrain Modifications"):
            TerrainModificationsPage(session: session, store: store)
        case (.surface, "Summary"):
            SurfaceOverviewPage(session: session, store: store)
        case (.surface, "Manning’s n"):
            if session.fields["ManningsNEditor/NValueLayer_Mode"] != nil { ManningEditorPage(session: session, store: store) }
            else { ContentUnavailableView("Select a Manning layer", systemImage: "square.3.layers.3d", description: Text("Choose a Manning model from the surface layer picker.")) }
        case (.result, "Plan Settings"):
            ResultPlanSettingsRoute(session: session, store: store)
        case (.result, _):
            ResultEditorPageContent(page: page, session: session, store: store)
        default:
            switch page.layout {
            case .form:
                if kind == .boundaryCondition {
                    BoundaryGeneralPage(session: session, store: store, navigateToLines: { navigate("Boundary Lines") }, navigateToSpatial: {
                        spatialTarget = $0; navigate("Spatial")
                    })
                } else { SourceForm(page: page, session: session, store: store) }
            case .table:
                if kind == .boundaryCondition { BoundaryLinesPage(page: page, session: session, store: store) }
                else if kind == .surface && page.title == "Classifications" { ClassificationLayersPage(session: session, store: store) }
                else if kind == .terrain && page.title == "Terrain Inputs" { TerrainInputsPage(session: session, store: store) }
                else { ModelTablePage(page: page, session: session, store: store) }
            case .timeSeries: TimeSeriesPage(page: page, session: session, store: store)
            case .compute: ComputePage(session: session, store: store)
            case .spatial: BoundarySpatialPage(session: session, store: store, target: $spatialTarget)
            }
        }
    }
    @ViewBuilder private var topologySummaryPage: some View {
        if let topology = session.geometryTopology {
            GeometryTopologySummaryWorkspacePage(session: session, topology: topology,
                store: store, navigate: navigate)
                .task(id: session.geometryTopologyIdentity) { await session.ensureGeometryTopologyLoaded() }
        } else {
            ContentUnavailableView("Topology unavailable", systemImage: "point.3.connected.trianglepath.dotted",
                description: Text("The geometry topology service is unavailable."))
        }
    }
    @ViewBuilder private func topologyPage(_ featureKind: String) -> some View {
        if let topology = session.geometryTopology {
            GeometryTopologyWorkspacePage(featureKind: featureKind, session: topology, store: store)
                .task(id: session.geometryTopologyIdentity) { await session.ensureGeometryTopologyLoaded() }
        } else {
            ContentUnavailableView("Topology unavailable", systemImage: "point.3.connected.trianglepath.dotted",
                description: Text("The geometry topology service is unavailable."))
        }
    }
}

private struct ResultPlanSettingsRoute: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore

    private var asset: ProjectAsset? {
        guard let id = session.modelAssetID else { return nil }
        return store.assets.first { $0.id == id && $0.section == .results && $0.isModelFile }
    }
    private var projectXML: String? {
        guard let document = store.document else { return nil }
        return document.editorXML(overridingDescription: store.descriptionDraft)
    }
    private var sourceContextRevision: String {
        "\(store.projectSessionID):\(store.assetsRevision)"
    }
    private var inspectionIdentity: String {
        [asset?.url.standardizedFileURL.path ?? "", store.document?.url?.standardizedFileURL.path ?? "",
         sourceContextRevision, session.sourceFileRevision ?? "", projectXML ?? "",
         session.isSaving ? "saving" : "idle"].joined(separator: "\n")
    }
    private var currentInspection: ResultInspectorSnapshot? {
        guard let asset, let snapshot = session.resultInspector?.snapshot,
              SourceFilePaths.canonical(URL(fileURLWithPath: snapshot.resultPath)) == SourceFilePaths.canonical(asset.url),
              snapshot.revision.count == 64,
              session.sourceFileRevision?.caseInsensitiveCompare(snapshot.revision) == .orderedSame else { return nil }
        return snapshot
    }

    private func bindCurrentPlanSettingsContext() {
        let editorSession = session
        let workspaceStore = store
        editorSession.currentResultPlanSettingsContext = { [weak editorSession, weak workspaceStore] in
            guard let session = editorSession, let store = workspaceStore,
                  let resultID = session.modelAssetID,
                  let result = store.assets.first(where: { $0.id == resultID && $0.section == .results && $0.isModelFile }),
                  let inspection = session.resultInspector?.snapshot,
                  inspection.revision.count == 64,
                  session.sourceFileRevision?.caseInsensitiveCompare(inspection.revision) == .orderedSame,
                  SourceFilePaths.canonical(URL(fileURLWithPath: inspection.resultPath)) == SourceFilePaths.canonical(result.url),
                  let document = store.document, let projectURL = document.url,
                  let projectRevision = document.sourceRevision else { return nil }
            let contextRevision = "\(store.projectSessionID):\(store.assetsRevision)"
            let contextID = "\(store.projectSessionID.uuidString)|\(result.id)|\(contextRevision)"
            return PlanSettingsResultCapture(owner: PlanSettingsResultOwner(
                projectSessionID: store.projectSessionID,
                resultAssetID: result.id,
                resultPath: SourceFilePaths.canonical(result.url),
                resultRevision: inspection.revision,
                sourceContextID: contextID),
                resultName: result.name,
                assetsRevision: store.assetsRevision,
                projectPath: SourceFilePaths.canonical(projectURL),
                projectRevision: projectRevision,
                projectXML: document.editorXML(overridingDescription: store.descriptionDraft))
        }
    }

    var body: some View {
        Group {
            if let asset, let child = session.resultPlanSettings, let inspection = currentInspection {
                ResultPlanSettingsPage(store: store, result: asset,
                    expectedResultRevision: inspection.revision,
                    projectSessionID: store.projectSessionID,
                    sourceContextID: "\(store.projectSessionID.uuidString)|\(asset.id)|\(sourceContextRevision)",
                    session: child)
            } else if session.resultInspector?.isLoading == true {
                ProgressView(L10n.text("Loading Result source…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = session.resultInspector?.error {
                ContentUnavailableView(L10n.text("Result source unavailable"), systemImage: "externaldrive.badge.questionmark",
                    description: Text(L10n.text(error)))
            } else if asset == nil || session.resultPlanSettings == nil {
                ContentUnavailableView(L10n.text("Embedded Plan settings are unavailable"), systemImage: "doc.badge.gearshape",
                    description: Text(L10n.text("Open a saved project Result to edit its embedded Plan.")))
            } else {
                ProgressView(L10n.text("Loading Result source…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: inspectionIdentity) {
            guard !session.isSaving else { return }
            await session.resultInspector?.ensureLoaded(asset: asset,
                projectPath: store.document?.url, projectXML: projectXML,
                sourceContextRevision: sourceContextRevision)
        }
        .onAppear(perform: bindCurrentPlanSettingsContext)
    }
}

/// Keeps the newer map-backed topology editor as the default surface while
/// making the existing table/profile/tag workspaces reachable. Tool requests
/// for tag operations switch to the source table without dropping topology
/// editing from the page.
private struct GeometryFeatureWorkspaceRoutePage: View {
    let featureKind: String
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    let isDetached: Bool
    @State private var surface = "Topology"
    @State private var tagRequestIssueID: UUID?

    private var pageFeatureKind: String { featureKind == "arc" ? "arc" : "region" }
    private var topology: GeometryTopologySession? { session.geometryTopology }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $surface) {
                Text("Topology").tag("Topology")
                Text("Table").tag("Table")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
            .padding(10)

            Group {
                if surface == "Table" {
                    if featureKind == "arc" {
                        GeometryTopologyArcsWorkspacePage(session: session, store: store)
                    } else {
                        GeometryTopologyRegionsWorkspacePage(session: session, store: store)
                    }
                } else if let topology {
                    GeometryTopologyWorkspacePage(featureKind: pageFeatureKind, session: topology, store: store)
                } else {
                    ContentUnavailableView("Topology unavailable", systemImage: "point.3.connected.trianglepath.dotted",
                        description: Text("The geometry topology service is unavailable."))
                }
            }
        }
        .task(id: session.geometryTopologyIdentity) {
            await session.ensureGeometryTopologyLoaded()
            routeMatchingToolRequestIfReady()
            if let request = matchingTagRequest, topology?.snapshot == nil {
                tagRequestIssueID = request.id
            }
        }
        .onAppear(perform: routeMatchingToolRequestIfReady)
        .onChange(of: store.editorToolPresentationRequest?.id) { _, _ in
            tagRequestIssueID = nil
            loadAndRouteMatchingToolRequest()
        }
        .onChange(of: session.modelAssetID) { _, _ in
            surface = "Topology"
            tagRequestIssueID = nil
            routeMatchingToolRequestIfReady()
        }
        .overlay(alignment: .bottom) {
            if let tagRequestIssueID, matchingTagRequest?.id == tagRequestIssueID {
                EditorToolPresentationNotice(message: L10n.text("Topology tags unavailable"),
                    detail: topology?.error, retry: retryTopologyForTagRequest,
                    cancel: { cancelTagRequest(tagRequestIssueID) })
            }
        }
    }

    private var matchingTagRequest: EditorToolPresentationRequest? {
        guard !isDetached, store.primaryEditorSession(.geometry).id == session.id,
              let request = store.editorToolPresentationRequest,
              request.projectSessionID == store.projectSessionID,
              request.assetID == session.modelAssetID,
              request.featureKind == featureKind,
              request.action == .tagCreate || request.action == .tagEdit else { return nil }
        return request
    }

    private var matchingArcPointsRequest: EditorToolPresentationRequest? {
        guard !isDetached, featureKind == "arc", store.primaryEditorSession(.geometry).id == session.id,
              let request = store.editorToolPresentationRequest,
              request.projectSessionID == store.projectSessionID,
              request.assetID == session.modelAssetID,
              request.featureKind == "arc", request.action == .arcPoints else { return nil }
        return request
    }

    private func routeMatchingToolRequestIfReady() {
        if matchingTagRequest != nil, topology?.snapshot != nil {
            tagRequestIssueID = nil
            surface = "Table"
        } else if matchingArcPointsRequest != nil, topology?.snapshot != nil {
            surface = "Topology"
        }
    }

    private func loadAndRouteMatchingToolRequest() {
        guard matchingTagRequest != nil || matchingArcPointsRequest != nil else { return }
        routeMatchingToolRequestIfReady()
        guard topology?.snapshot == nil else { return }
        Task {
            await session.ensureGeometryTopologyLoaded()
            if topology?.snapshot != nil {
                routeMatchingToolRequestIfReady()
            } else if let request = matchingTagRequest {
                tagRequestIssueID = request.id
            }
        }
    }

    private func retryTopologyForTagRequest() {
        tagRequestIssueID = nil
        Task {
            await session.ensureGeometryTopologyLoaded()
            if topology?.snapshot != nil {
                routeMatchingToolRequestIfReady()
            } else if let request = matchingTagRequest {
                tagRequestIssueID = request.id
            }
        }
    }

    private func cancelTagRequest(_ id: UUID) {
        guard store.editorToolPresentationRequest?.id == id else { return }
        store.consumeEditorToolPresentationRequest(id)
        tagRequestIssueID = nil
    }
}

struct SchemaFields: View {
    let schema: String
    var excluding: Set<String> = []
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    var body: some View {
        SourceFieldRows(fields: (SourceEditorLibrary.shared.schema(schema)?.fields ?? []).filter { !excluding.contains($0.id) }, session: session, store: store)
    }
}

struct SchemaValues: View {
    let schema: String
    @ObservedObject var session: ModelEditorSession
    var body: some View {
        ForEach(SourceEditorLibrary.shared.schema(schema)?.fields ?? []) { field in
            LabeledContent(LocalizedStringKey(field.title), value: displayValue(field))
                .textSelection(.enabled)
        }
    }
    private func displayValue(_ field: SourceEditorField) -> String {
        let value = session.fields[field.storageID] ?? "—"
        return field.id == "MetDataIncluded" ? BoundaryMeteorologicalSummaryPresentation.text(sourceValue: value) : value
    }
}

// Compatibility entry used by the UI acceptance surface; the application
// and acceptance host render the same source-rewritten page.
struct PlanSummaryPage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    var body: some View { PlanCatalogSummary(session: session, store: store) }
}

struct GeometryOverviewPage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    let navigate: (String) -> Void
    @State private var diagnosticsOpen = false
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Geometry") { SchemaFields(schema: "GeometryCatalogSummary", session: session, store: store) }
                Section("Associations") { SchemaFields(schema: "GeometryAssociationsPicker", session: session, store: store) }
                Section("Images") {
                    SchemaFields(schema: "GeometrySummaryPage", excluding: ["ViewModel_SelectedGeometryVisualContext_Context_Description"], session: session, store: store)
                }
                Section("Prepare Geometry") { SchemaValues(schema: "GeometryPrepareSummaryControl", session: session) }
            }.formStyle(.grouped)
            Divider()
            HStack {
                Button("Topology") { navigate("Topology") }
                Button("Mesh") { navigate("Mesh") }
                Spacer()
                Button("Mesh Diagnostics") { diagnosticsOpen = true }
            }.padding(12)
        }.sheet(isPresented: $diagnosticsOpen) {
            ModelDiagnosticsView(session: session, store: store).frame(minWidth: 720, minHeight: 480)
        }
    }
}

struct GeometryTopologyPage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @State private var title = "Topology"
    private var page: ModelEditorPage {
        ModelEditorKind.geometry.pages.first { $0.title == title } ?? ModelEditorKind.geometry.pages[0]
    }
    var body: some View {
        ModelPageContent(kind: .geometry, page: page, session: session, store: store,
                         spatialTarget: .constant(nil), navigate: { title = $0 })
    }
}

struct ResultMapsPage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    var body: some View { ResultMapEditorPage(session: session, store: store) }
}

struct RasterCalculatorEntry: View {
    @ObservedObject var store: WorkspaceStore
    var body: some View {
        VStack(spacing: 16) {
            Label("Raster Calculator", systemImage: "function").font(.title2)
            Text("Build an expression from map layers and named constants.").foregroundStyle(.secondary)
            Button("Open Raster Calculator") { store.activeTool = .rasterCalculator }.buttonStyle(.glassProminent)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
