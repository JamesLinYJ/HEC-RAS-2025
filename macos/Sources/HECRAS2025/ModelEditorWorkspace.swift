import AppKit
import RASWorkspaceCore
import SwiftUI

// Native counterparts of PlanEditorControl, GeometryEditor and
// BoundaryConditionEditor. Their source navigation order is preserved.
struct ModelEditorWorkspace: View {
    @ObservedObject var store: WorkspaceStore
    @Environment(\.openWindow) private var openWindow
    let kind: ModelEditorKind
    let isDetached: Bool
    @StateObject private var session = ModelEditorSession()
    @State private var selectedPage: String?
    @State private var assetID: String?
    @State private var pendingAssetID: String?
    @State private var pendingEditorToolRequestID: UUID?
    @State private var pendingPlanDiagnosticNavigationTaskID: UUID?
    @State private var showModelChange = false
    @State private var confirmsCoreLayerDraftReload = false
    @State private var spatialTarget: SpatialBoundaryLayer?
    @State private var editorToolImportPresentation: EditorToolImportPresentation?
    @State private var editorToolPresentationIssue: String?
    @State private var editorToolPresentationIssueRequestID: UUID?
    init(store: WorkspaceStore, kind: ModelEditorKind, isDetached: Bool = false) {
        self.store = store; self.kind = kind; self.isDetached = isDetached
        _session = StateObject(wrappedValue: isDetached ? ModelEditorSession(provider: store.modelProvider) : store.primaryEditorSession(kind))
    }
    private var assets: [ProjectAsset] { store.assets.filter { $0.section == kind.section && $0.isModelFile } }
    private var selectedAsset: ProjectAsset? { assets.first { $0.id == assetID } }
    private var page: ModelEditorPage { kind.pages.first { $0.id == selectedPage } ?? kind.pages[0] }
    private var editorContent: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(LocalizedStringKey(kind.rawValue), selection: Binding(get: { assetID }, set: chooseAsset)) {
                    Text("None").tag(nil as String?)
                    ForEach(assets) { Text($0.name).tag(Optional($0.id)) }
                }
                .disabled(session.isBusy)
                if kind == .plan, let selectedAsset { PlanAssociationHeader(store: store, plan: selectedAsset).disabled(store.isRunningPlanCompute) }
                if session.isRefreshingContext { ProgressView().controlSize(.small).accessibilityLabel("Refresh") }
                Spacer(minLength: 12)
                if kind == .plan {
                    ComputeButton(session: session, openComputeLog: { selectedPage = "Compute" })
                    Button {
                        selectedPage = "Compute"
                        Task { await session.perform(.compute) }
                    } label: { Label("Compute", systemImage: "play.fill") }
                    .disabled(!session.loaded || !session.availableOperations.contains(.compute)
                        || session.planCompute?.isAvailable != true || session.isBusy
                        || session.hasIncompleteEditorInput || session.planCompute?.isInspecting == true
                        || session.hasCoreLayerReferenceConflict)
                    Menu {
                        Button("Export Plan") { openTool(.planExport) }
                        Divider()
                        Button("Compare Plans…") {
                            if let route = store.planDiffWindowRoute(preferredEditorID: session.id) {
                                openWindow(value: route)
                            }
                        }
                        .disabled(store.isRunningProjectTool || store.hasBusyModelEditors)
                        Button("Ready-to-Run Matrix…") {
                            if let selectedAsset,
                               let route = store.planMatrixWindowRoute(plan: selectedAsset, preferredEditorID: session.id) {
                                openWindow(value: route)
                            }
                        }
                        .disabled(store.isRunningProjectTool || store.hasBusyModelEditors)
                    } label: { Label("Plan Actions", systemImage: "ellipsis.circle") }.menuIndicator(.hidden).disabled(selectedAsset == nil || session.isBusy)
                } else if kind == .geometry {
                    Button("Prepare Geometry") {
                        Task {
                            guard !session.hasIncompleteEditorInput else {
                                session.error = session.incompleteEditorInputIssue
                                return
                            }
                            await session.ensureGeometryMeshLoaded()
                            guard !session.hasIncompleteEditorInput else {
                                session.error = session.incompleteEditorInputIssue
                                return
                            }
                            guard let mesh = session.geometryMesh, await mesh.requestPrepare() else { return }
                            _ = await session.saveLoadedModel()
                        }
                    }
                    .disabled(!session.loaded || !session.canEdit || session.isBusy
                        || session.hasIncompleteEditorInput || session.geometryMesh?.isLoading == true)
                    .help("Prepare and save all current geometry edits together.")
                }
                if kind == .boundaryCondition {
                    Button("Attach Initial Conditions") {
                        editorToolImportPresentation = .initialConditions(requestID: UUID(), consumesHandoff: false)
                    }
                    .disabled(!session.loaded || !session.canEdit || session.isBusy || selectedAsset == nil
                        || session.hasCoreLayerReferenceConflict
                        || store.initialConditionsProvider == nil || store.isRunningProjectTool)
                }
                Button { Task { await session.save(selectedAsset) } } label: { Label("Save", systemImage: "square.and.arrow.down") }
                    .disabled(!session.canSave)
            }.padding(12)
            if let warning = session.saveWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            if let conflict = session.coreLayerReferenceConflict {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("External Core Layer Conflict").font(.headline)
                        Text(conflict).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("Discard Draft and Reload…") { confirmsCoreLayerDraftReload = true }
                        .tint(.red)
                        .disabled(selectedAsset == nil)
                }
                .padding(12)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            Divider()
            HSplitView {
                List(kind.pages, selection: $selectedPage) { page in
                    HStack {
                        Label(LocalizedStringKey(kind == .boundaryCondition && page.id == "Boundary Lines" ? "Lines" : page.title), systemImage: pageSymbol(page))
                        Spacer(minLength: 0)
                    }.tag(page.id)
                }
                .listStyle(.sidebar).frame(minWidth: 145, idealWidth: 185, maxWidth: 240)
                .disabled(session.geometryCulvert?.hasActiveSketch == true)
                VStack(spacing: 0) {
                    if let selectedAsset {
                        HStack {
                            Label(selectedAsset.name, systemImage: kind.symbol).font(.headline)
                            Spacer()
                            if !session.loaded { Label("Model data unavailable", systemImage: "externaldrive.badge.questionmark").font(.caption).foregroundStyle(.secondary) }
                        }.padding(12)
                        Divider()
                    }
                    ModelPageContent(kind: kind, page: page, session: session, store: store,
                        spatialTarget: $spatialTarget, navigate: { selectedPage = $0 },
                        isDetached: isDetached,
                        geometryChoices: kind == .geometry ? assets : [], selectGeometry: chooseAsset)
                        .disabled(session.hasCoreLayerReferenceConflict
                            || (store.isRunningPlanCompute && !(kind == .plan && page.id == "Compute")))
                }.frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var lifecycleContent: some View {
        editorContent
        .onAppear {
            store.registerEditor(session)
            selectedPage = selectedPage ?? kind.pages[0].id
            if assetID == nil {
                assetID = assets.first(where: { $0.id == session.modelAssetID })?.id ?? assets.first(where: { $0.id == store.selectedAssetID })?.id ?? assets.first?.id
            }
            if !isDetached, let requested = store.editorAssetRequests[kind], requested != assetID { chooseAsset(requested) }
            handleEditorToolPresentationRequest()
            handlePlanDiagnosticNavigationRequest()
        }
        .task(id: assetID) {
            await session.ensureLoaded(selectedAsset, kind: kind)
            handleEditorToolPresentationRequest(loadAttemptFinished: true)
            handlePlanDiagnosticNavigationRequest()
        }
        .onChange(of: store.editorAssetRequests[kind]) { _, requested in
            if !isDetached, let requested { chooseAsset(requested) }
        }
        .onChange(of: store.editorToolPresentationRequest?.id) { _, _ in
            editorToolPresentationIssue = nil
            editorToolPresentationIssueRequestID = nil
            handleEditorToolPresentationRequest()
        }
        .onChange(of: store.pendingPlanDiagnosticNavigation) { _, _ in
            handlePlanDiagnosticNavigationRequest()
        }
        .onChange(of: store.activeTab) { _, _ in
            handlePlanDiagnosticNavigationRequest()
        }
        .onChange(of: store.projectSessionID) { _, _ in
            if let request = store.pendingPlanDiagnosticNavigation,
               request.projectSessionID != store.projectSessionID {
                store.finishPlanDiagnosticNavigation(request)
            }
            if let presentation = editorToolImportPresentation {
                editorToolImportPresentation = nil
                if store.editorToolPresentationRequest?.id == presentation.id {
                    store.consumeEditorToolPresentationRequest(presentation.id)
                }
            }
            handleEditorToolPresentationRequest()
        }
        .onChange(of: editorToolImportPresentation?.id) { oldID, newID in
            if oldID != nil, newID == nil { handleEditorToolPresentationRequest() }
        }
        .onChange(of: session.loaded) { _, loaded in
            if loaded {
                handleEditorToolPresentationRequest()
                handlePlanDiagnosticNavigationRequest()
            }
        }
        .onChange(of: session.isBusy) { _, isBusy in
            if !isBusy {
                handleEditorToolPresentationRequest()
                handlePlanDiagnosticNavigationRequest()
            }
        }
        .onChange(of: session.loadingSelection) { _, loading in
            if !loading {
                handleEditorToolPresentationRequest()
                handlePlanDiagnosticNavigationRequest()
            }
        }
        .onChange(of: showModelChange) { _, isShowing in
            if !isShowing {
                handleEditorToolPresentationRequest()
                handlePlanDiagnosticNavigationRequest()
            }
        }
        .background { if isDetached { WindowLifecycleGuard(store: store, session: session).frame(width: 0, height: 0) } }
        // An unfinished local sketch blocks close/save/model replacement, but
        // its Apply and Cancel controls must remain interactive.
        .disabled(session.isSaving || session.isPerforming || session.hasPendingTopologyEdit
            || session.geometryMesh?.isEditing == true || session.geometryMesh?.isSavingDiagnosticsPreferences == true
            || session.geometryCulvert?.isEditing == true
            || store.isSavingAll || store.isClosingTab || store.isRunningInitialConditionsCommit)
    }

    var body: some View {
        lifecycleContent
        .safeAreaInset(edge: .top, spacing: 0) {
            if store.hasPendingInitialConditionsOperation(for: session) {
                HStack {
                    Label("Initial Conditions Operation", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    Button("Review Operation") {
                        editorToolImportPresentation = .initialConditions(requestID: UUID(), consumesHandoff: false)
                    }
                }
                .padding(12)
                .background(.bar)
            }
        }
        .sheet(item: $editorToolImportPresentation) { presentation in
            EditorToolPresentationSheet(presentation: presentation, session: session, store: store,
                onAccepted: acceptEditorToolPresentation, onCancel: cancelEditorToolPresentation)
                .id(presentation.id)
        }
        .overlay(alignment: .bottom) {
            if let editorToolPresentationIssue {
                EditorToolPresentationNotice(message: L10n.text(editorToolPresentationIssue),
                    detail: session.error, retry: retryEditorToolPresentation,
                    cancel: cancelEditorToolPresentationIssue)
            }
        }
        .alert("Save changes to this model?", isPresented: $showModelChange) {
            if !session.hasCoreLayerReferenceConflict {
                Button("Save") {
                    Task {
                        let targetID = pendingAssetID
                        let requestID = pendingEditorToolRequestID
                        let projectID = store.projectSessionID
                        let sourceID = session.modelAssetID
                        let saved = await session.save(selectedAsset)
                        guard store.projectSessionID == projectID, session.modelAssetID == sourceID,
                              pendingAssetID == targetID, pendingEditorToolRequestID == requestID else { return }
                        pendingAssetID = nil
                        pendingEditorToolRequestID = nil
                        if saved, !session.hasUnsavedEditorChanges {
                            assetID = targetID
                        } else if let requestID, store.editorToolPresentationRequest?.id == requestID {
                            setEditorToolPresentationIssue(
                                "The current model could not be saved. Resolve its pending input or error, then retry.",
                                requestID: requestID)
                        }
                    }
                }
            }
            Button("Discard", role: .destructive) {
                if session.hasCoreLayerReferenceConflict {
                    let targetID = pendingAssetID
                    if let targetID {
                        guard let target = assets.first(where: { $0.id == targetID }) else { return }
                        assetID = targetID
                        pendingAssetID = nil
                        pendingEditorToolRequestID = nil
                        Task { await session.load(target, kind: kind) }
                    } else {
                        assetID = nil
                        pendingAssetID = nil
                        pendingEditorToolRequestID = nil
                        Task {
                            await session.load(nil, kind: kind)
                            session.clearCoreLayerReferenceConflictAfterExplicitDiscard()
                        }
                    }
                    return
                }
                session.discardEdits()
                guard !session.hasUnsavedEditorChanges else { return }
                assetID = pendingAssetID; pendingAssetID = nil; pendingEditorToolRequestID = nil
            }
            Button("Cancel", role: .cancel) {
                if let request = store.pendingPlanDiagnosticNavigation,
                   request.destinationKind == kind,
                   pendingAssetID == request.destinationAssetID {
                    store.finishPlanDiagnosticNavigation(request)
                }
                cancelEditorToolPresentationForPendingModelChange()
                pendingAssetID = nil; pendingEditorToolRequestID = nil
            }
        } message: { Text("Changing the selected model will replace the current editor contents.") }
        .alert("HEC-RAS 2025", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
            Button("OK") { session.error = nil }
        } message: { Text(session.error ?? "") }
        .confirmationDialog("Reload This Model from Its Current Source?", isPresented: $confirmsCoreLayerDraftReload,
                            titleVisibility: .visible) {
            Button("Discard Draft and Reload", role: .destructive) {
                guard let selectedAsset else { return }
                Task { await session.load(selectedAsset, kind: kind) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current editor draft will be discarded. The project session has a new capture for this source, so reloading adopts that source and clears the conflict.")
        }
    }
    private func chooseAsset(_ id: String?) {
        guard id != assetID, !session.isBusy else { return }
        guard session.geometryCulvert?.hasActiveSketch != true else {
            session.error = L10n.text("Finish or cancel the active culvert map preview before changing the geometry.")
            return
        }
        if session.hasUnsavedEditorChanges { pendingAssetID = id; showModelChange = true }
        else { assetID = id }
    }

    private func handlePlanDiagnosticNavigationRequest() {
        guard !isDetached, let request = store.pendingPlanDiagnosticNavigation else { return }
        guard request.projectSessionID == store.projectSessionID else {
            store.finishPlanDiagnosticNavigation(request)
            return
        }
        guard request.phase == .ready,
              request.destinationKind == kind,
              store.activeTab == .editor(kind) else { return }

        guard assetID == request.destinationAssetID else {
            guard !showModelChange, !session.isBusy else { return }
            chooseAsset(request.destinationAssetID)
            return
        }
        guard selectedAsset?.id == request.destinationAssetID,
              store.primaryEditorSession(kind) === session,
              session.loaded, session.modelAssetID == request.destinationAssetID,
              !session.loadingSelection, !session.isBusy, !showModelChange,
              pendingPlanDiagnosticNavigationTaskID != request.id else { return }

        pendingPlanDiagnosticNavigationTaskID = request.id
        Task {
            defer {
                if pendingPlanDiagnosticNavigationTaskID == request.id {
                    pendingPlanDiagnosticNavigationTaskID = nil
                    handlePlanDiagnosticNavigationRequest()
                }
            }
            await performPlanDiagnosticNavigation(request)
        }
    }

    @MainActor
    private func performPlanDiagnosticNavigation(_ request: PlanDiagnosticNavigationRequest) async {
        guard store.isCurrentPlanDiagnosticNavigation(request),
              store.activeTab == .editor(kind),
              session.loaded, session.modelAssetID == request.destinationAssetID,
              session.sourceFileRevision?.caseInsensitiveCompare(request.target.assetRevision) == .orderedSame else {
            store.failPlanDiagnosticNavigation(request, in: session)
            return
        }

        selectedPage = request.destinationPageID
        if request.action == .computeGeometryPropertyTables {
            await session.ensureGeometryMeshLoaded()
            guard !Task.isCancelled, request.target.kind == "geometry",
                  store.activeTab == .editor(kind), selectedPage == request.destinationPageID,
                  store.isCurrentPlanDiagnosticNavigation(request),
                  session.loaded, session.modelAssetID == request.destinationAssetID,
                  session.sourceFileRevision?.caseInsensitiveCompare(request.target.assetRevision) == .orderedSame,
                  let mesh = session.geometryMesh,
                  mesh.snapshot?.revision.caseInsensitiveCompare(request.target.assetRevision) == .orderedSame,
                  !session.isBusy, await store.verifyPlanDiagnosticNavigation(request),
                  store.activeTab == .editor(kind), selectedPage == request.destinationPageID,
                  store.isCurrentPlanDiagnosticNavigation(request),
                  session.modelAssetID == request.destinationAssetID,
                  session.sourceFileRevision?.caseInsensitiveCompare(request.target.assetRevision) == .orderedSame else {
                store.failPlanDiagnosticNavigation(request, in: session)
                return
            }
            store.finishPlanDiagnosticNavigation(request)
            _ = await mesh.computePropertyTables()
            return
        }
        if request.target.kind == "flowArea" {
            await session.ensureGeometryMeshLoaded()
            guard !Task.isCancelled,
                  store.activeTab == .editor(kind),
                  selectedPage == request.destinationPageID,
                  store.isCurrentPlanDiagnosticNavigation(request),
                  session.loaded, session.modelAssetID == request.destinationAssetID,
                  session.sourceFileRevision?.caseInsensitiveCompare(request.target.assetRevision) == .orderedSame,
                  let mesh = session.geometryMesh,
                  mesh.snapshot?.revision.caseInsensitiveCompare(request.target.assetRevision) == .orderedSame else {
                store.failPlanDiagnosticNavigation(request, in: session)
                return
            }
            guard let index = planDiagnosticFeatureIndex(request.target.featureID, prefix: "flow-area-row:"),
                  mesh.flowAreas.indices.contains(index),
                  let featureName = request.target.featureName,
                  PlanDiagnosticNavigationIdentity.uniqueFeatureRow(index: index,
                      name: featureName, names: mesh.flowAreas.map(\.name)),
                  let row = mesh.flowAreas.first(where: { $0.rowIndex == index }),
                  row.id == request.target.featureID,
                  row.name == featureName else {
                store.failPlanDiagnosticNavigation(request, in: session)
                return
            }
            guard !session.isBusy else { return }
            guard await store.verifyPlanDiagnosticNavigation(request),
                  store.activeTab == .editor(kind),
                  selectedPage == request.destinationPageID,
                  store.isCurrentPlanDiagnosticNavigation(request),
                  session.modelAssetID == request.destinationAssetID,
                  session.sourceFileRevision?.caseInsensitiveCompare(request.target.assetRevision) == .orderedSame,
                  mesh.snapshot?.revision.caseInsensitiveCompare(request.target.assetRevision) == .orderedSame,
                  mesh.flowAreas.indices.contains(index),
                  PlanDiagnosticNavigationIdentity.uniqueFeatureRow(index: index,
                      name: featureName, names: mesh.flowAreas.map(\.name)),
                  mesh.flowAreas.first(where: { $0.rowIndex == index && $0.id == request.target.featureID })?.name == featureName else {
                store.failPlanDiagnosticNavigation(request, in: session)
                return
            }
            mesh.selectFlowArea(row.id)
            guard mesh.selectedFlowArea?.id == row.id else {
                store.failPlanDiagnosticNavigation(request, in: session)
                return
            }
            store.finishPlanDiagnosticNavigation(request)
            return
        }

        if request.target.kind == "boundaryConditionLine" {
            guard let index = planDiagnosticFeatureIndex(request.target.featureID, prefix: "boundary-line-row:"),
                  let rows = session.boundaryLines?.lines,
                  rows.indices.contains(index),
                  let featureName = request.target.featureName,
                  PlanDiagnosticNavigationIdentity.uniqueFeatureRow(index: index, name: featureName,
                      names: rows.map { session.boundaryLineName($0) }),
                  session.boundaryLineName(rows[index]) == featureName else {
                store.failPlanDiagnosticNavigation(request, in: session)
                return
            }
            guard !session.isBusy else { return }
            guard await store.verifyPlanDiagnosticNavigation(request),
                  store.activeTab == .editor(kind),
                  selectedPage == request.destinationPageID,
                  store.isCurrentPlanDiagnosticNavigation(request),
                  session.loaded, session.modelAssetID == request.destinationAssetID,
                  session.sourceFileRevision?.caseInsensitiveCompare(request.target.assetRevision) == .orderedSame,
                  let currentRows = session.boundaryLines?.lines,
                  currentRows.indices.contains(index),
                  PlanDiagnosticNavigationIdentity.uniqueFeatureRow(index: index, name: featureName,
                      names: currentRows.map { session.boundaryLineName($0) }),
                  session.boundaryLineName(currentRows[index]) == featureName else {
                store.failPlanDiagnosticNavigation(request, in: session)
                return
            }
            let runtimeRowID = currentRows[index].id
            session.selectBoundaryLine(runtimeRowID)
            guard session.selectedBoundaryLineID == runtimeRowID else {
                store.failPlanDiagnosticNavigation(request, in: session)
                return
            }
            store.finishPlanDiagnosticNavigation(request)
            return
        }

        guard await store.verifyPlanDiagnosticNavigation(request),
              store.activeTab == .editor(kind),
              selectedPage == request.destinationPageID,
              store.isCurrentPlanDiagnosticNavigation(request),
              session.modelAssetID == request.destinationAssetID,
              session.sourceFileRevision?.caseInsensitiveCompare(request.target.assetRevision) == .orderedSame else {
            store.failPlanDiagnosticNavigation(request, in: session)
            return
        }
        store.finishPlanDiagnosticNavigation(request)
    }

    private func planDiagnosticFeatureIndex(_ token: String?, prefix: String) -> Int? {
        guard let token, token.hasPrefix(prefix) else { return nil }
        let suffix = String(token.dropFirst(prefix.count))
        guard let index = Int(suffix), index >= 0, String(index) == suffix else { return nil }
        return index
    }

    private func handleEditorToolPresentationRequest(loadAttemptFinished: Bool = false) {
        guard !isDetached, let request = store.editorToolPresentationRequest,
              expectedEditorKind(for: request.action) == kind else { return }
        guard request.projectSessionID == store.projectSessionID else {
            // A request belongs to the old project session and can never be
            // applied to the newly opened project.
            store.consumeEditorToolPresentationRequest(request.id)
            clearEditorToolPresentationIssue(for: request.id)
            if pendingEditorToolRequestID == request.id { pendingEditorToolRequestID = nil }
            return
        }
        guard store.document != nil,
              assets.contains(where: { $0.id == request.assetID }) else {
            setEditorToolPresentationIssue("The requested model is not available in the current project.", requestID: request.id)
            return
        }
        if request.action == .griddedImport, store.activeSpatialImportLayerID != nil {
            // Cumulus has its own DataTool route, scoped by startSpatialImport.
            return
        }
        guard editorToolImportPresentation == nil else { return }
        guard !showModelChange else {
            if pendingAssetID == request.assetID { pendingEditorToolRequestID = request.id }
            return
        }
        if request.assetID != assetID {
            if pendingAssetID != request.assetID { chooseAsset(request.assetID) }
            if showModelChange, pendingAssetID == request.assetID {
                pendingEditorToolRequestID = request.id
            }
            return
        }
        guard session.modelAssetID == request.assetID else { return }
        guard session.loaded else {
            if loadAttemptFinished || session.error != nil {
                setEditorToolPresentationIssue("The model could not be loaded. Retry or cancel this request.", requestID: request.id)
            }
            return
        }
        guard session.canEdit else {
            setEditorToolPresentationIssue("This model cannot be edited for the requested import.", requestID: request.id)
            return
        }
        guard !session.isBusy, !session.loadingSelection else { return }

        editorToolPresentationIssue = nil
        editorToolPresentationIssueRequestID = nil
        switch request.action {
        case .initialConditions:
            editorToolImportPresentation = .initialConditions(requestID: request.id, consumesHandoff: true)
        case .terrainImport:
            guard session.sourceCollections[TerrainEditorContract.sourceField]?.canImport == true else {
                setEditorToolPresentationIssue("This model does not support terrain import.", requestID: request.id)
                return
            }
            selectedPage = ModelEditorKind.terrain.pages.first?.id
            editorToolImportPresentation = .terrain(requestID: request.id)
        case .classificationImport:
            guard session.sourceCollections[ClassificationEditorContract.sourceField]?.canImport == true else {
                setEditorToolPresentationIssue("This model does not support classification import.", requestID: request.id)
                return
            }
            selectedPage = ModelEditorKind.surface.pages.first?.id
            editorToolImportPresentation = .classification(requestID: request.id)
        case .spatialImport:
            selectedPage = "Spatial"
            editorToolImportPresentation = .spatialBoundary(requestID: request.id,
                assetID: request.assetID, layerID: request.spatialLayerID)
        case .griddedImport:
            let layers = availableGriddedLayers
            if let requestedLayerID = request.spatialLayerID {
                guard let layer = layers.first(where: { $0.id == requestedLayerID }) else {
                    setEditorToolPresentationIssue("The requested Gridded layer is not available in this boundary model.", requestID: request.id)
                    return
                }
                selectedPage = "Spatial"
                editorToolImportPresentation = .gridded(requestID: request.id, layer: layer)
            } else if !layers.isEmpty {
                selectedPage = "Spatial"
                editorToolImportPresentation = .chooseGridded(requestID: request.id, layers: layers)
            } else {
                setEditorToolPresentationIssue("No Gridded spatial layers are available in this boundary model.", requestID: request.id)
            }
        case .tagCreate, .tagEdit:
            guard let featureKind = request.featureKind else {
                setEditorToolPresentationIssue("Select Arcs or Regions to continue with this tag request.", requestID: request.id)
                return
            }
            switch featureKind {
            case "arc": selectedPage = "Arcs"
            case "region": selectedPage = "Regions"
            default:
                setEditorToolPresentationIssue("Select Arcs or Regions to continue with this tag request.", requestID: request.id)
                return
            }
            // The feature metadata view owns tag sheet presentation and
            // consumes this exact request after it accepts the request.
        case .topology, .topologyRecipe, .arcPoints, .tagFilter, .vectorImport:
            guard kind == .geometry,
                  let destination = request.geometryEditorDestination else { return }
            selectedPage = destination.pageID
            // The exact primary topology workspace consumes the request only
            // after its source snapshot and any required real selection exist.
        default:
            return
        }
    }
    private var availableGriddedLayers: [SpatialBoundaryLayer] {
        SpatialBoundaryLayer.available(debug: store.isDebugMode, fields: session.fields).filter { layer in
            session.spatialPresentations[layer.id] != nil && layer.selectedType(in: session.fields) == "Gridded"
        }
    }
    private func expectedEditorKind(for action: ToolKind) -> ModelEditorKind? {
        switch action {
        case .terrainImport: .terrain
        case .classificationImport: .surface
        case .griddedImport, .initialConditions, .spatialImport: .boundaryCondition
        case .tagCreate, .tagEdit, .topology, .topologyRecipe, .arcPoints, .tagFilter, .vectorImport: .geometry
        default: nil
        }
    }
    private func acceptEditorToolPresentation(_ id: UUID) {
        guard !isDetached, let request = store.editorToolPresentationRequest,
              request.id == id, request.projectSessionID == store.projectSessionID,
              request.assetID == session.modelAssetID, session.loaded, session.canEdit else {
            editorToolImportPresentation = nil
            return
        }
        store.consumeEditorToolPresentationRequest(id)
        clearEditorToolPresentationIssue(for: id)
    }
    private func cancelEditorToolPresentation(_ id: UUID) {
        store.consumeEditorToolPresentationRequest(id)
        clearEditorToolPresentationIssue(for: id)
        if editorToolImportPresentation?.id == id { editorToolImportPresentation = nil }
    }
    private func cancelEditorToolPresentationForPendingModelChange() {
        guard let requestID = pendingEditorToolRequestID,
              store.editorToolPresentationRequest?.id == requestID else { return }
        store.consumeEditorToolPresentationRequest(requestID)
        clearEditorToolPresentationIssue(for: requestID)
    }
    private func setEditorToolPresentationIssue(_ message: String, requestID: UUID) {
        editorToolPresentationIssue = message
        editorToolPresentationIssueRequestID = requestID
    }
    private func clearEditorToolPresentationIssue(for id: UUID) {
        guard editorToolPresentationIssueRequestID == id else { return }
        editorToolPresentationIssue = nil
        editorToolPresentationIssueRequestID = nil
    }
    private func retryEditorToolPresentation() {
        guard let request = store.editorToolPresentationRequest,
              request.id == editorToolPresentationIssueRequestID else { return }
        editorToolPresentationIssue = nil
        editorToolPresentationIssueRequestID = nil
        if request.assetID != assetID {
            chooseAsset(request.assetID)
            return
        }
        Task {
            await session.ensureLoaded(selectedAsset, kind: kind)
            handleEditorToolPresentationRequest(loadAttemptFinished: true)
        }
    }
    private func cancelEditorToolPresentationIssue() {
        guard let id = editorToolPresentationIssueRequestID else { return }
        cancelEditorToolPresentation(id)
    }
    private func openTool(_ kind: ToolKind) {
        if let selectedAsset { store.select(selectedAsset) }
        store.activeTool = kind
    }
    private func pageSymbol(_ page: ModelEditorPage) -> String {
        switch page.layout { case .form: "slider.horizontal.3"; case .table: "tablecells"; case .timeSeries: "chart.xyaxis.line"; case .compute: "gauge.with.dots.needle.67percent"; case .spatial: "cloud.rain" }
    }
}

struct PlanAssociationHeader: View {
    @ObservedObject var store: WorkspaceStore
    let plan: ProjectAsset
    var body: some View {
        if let row = store.document?.associationRows(group: "PlanAssociations").first(where: { $0.name == plan.name }) {
            HStack(spacing: 8) {
                associationPicker("Geometry", row: row)
                boundaryConditionPicker(row: row)
            }
        }
    }

    @ViewBuilder
    private func associationPicker(_ field: String, row: ProjectAssociation) -> some View {
        Picker(LocalizedStringKey(field), selection: Binding(
            get: { row.fields[field] ?? "" }, set: { store.setAssociation(row, field: field, value: $0) }
        )) {
            Text("None").tag("")
            ForEach(store.assets.filter { $0.section == .geometries && $0.isModelFile }) { asset in Text(asset.name).tag(asset.name) }
            if let existing = row.fields[field], !existing.isEmpty,
               !store.assets.contains(where: { $0.section == .geometries && $0.isModelFile && $0.name == existing }) {
                Text(existing).tag(existing)
            }
        }
        .frame(maxWidth: 200)
    }

    private func boundaryConditionPicker(row: ProjectAssociation) -> some View {
        let field = "BoundaryCondition"
        let selection = row.fields[field] ?? ""
        let assets = store.assets.filter { $0.section == .boundaryConditions && $0.isModelFile }
        var choices = assets.map { EditorChoice(id: $0.name, title: $0.name, titleIsUserData: true) }
        if !selection.isEmpty, !choices.contains(where: { $0.id == selection }) {
            choices.append(EditorChoice(id: selection, title: selection, titleIsUserData: true))
        }
        let selectedAsset = assets.first(where: { $0.name == selection })
        return BoundaryConditionPickerControl(
            choices: choices,
            selection: Binding(get: { row.fields[field] ?? "" }, set: { store.setAssociation(row, field: field, value: $0) }),
            selectionIsUninitialized: row.fields[field] == nil,
            isEnabled: !store.isSavingAll && !store.isClosingTab,
            emptySelectionTitle: "None",
            openEditor: selectedAsset.map { asset in
                { store.openEditor(.boundaryCondition, assetID: asset.id) }
            }
        )
        .frame(maxWidth: 240)
    }
}

struct SourceForm: View {
    let page: ModelEditorPage
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    private var schemas: [SourceEditorSchema] { page.schemaIDs.compactMap { SourceEditorLibrary.shared.schema($0) }.map { schema in
        SourceEditorSchema(id: schema.id, title: schema.title, source: schema.source, fields: schema.fields.map { $0.inScope(page.scopePrefix) }, children: schema.children, groups: schema.groups, preferredColumnWidth: schema.preferredColumnWidth)
    } }
    private struct FormGroup: Identifiable {
        let id: String
        let title: String
        let fields: [SourceEditorField]
    }
    private var visibleGroups: [FormGroup] {
        schemas.flatMap { schema in groups(schema).enumerated().compactMap { index, group in
            let fields = group.fields.compactMap { id in schema.fields.first { $0.id == id } }.filter(isVisible)
            return fields.isEmpty ? nil : FormGroup(id: schema.id + "/" + String(index), title: group.title, fields: fields)
        } }
    }
    private var columnWidth: Double? { schemas.count == 1 ? schemas.first?.preferredColumnWidth : nil }
    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Text(LocalizedStringKey(page.title)).font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                if let width = columnWidth, width >= 200, width < 4000,
                   proxy.size.width >= width * 2, visibleGroups.count > 1 {
                    // Preserve DualPanelLayout's column threshold and
                    // contiguous group order. Native Form row sizes determine
                    // the final appearance; grouped content stays together.
                    HSplitView {
                        form(Array(visibleGroups.prefix(columnBoundary)))
                        form(Array(visibleGroups.dropFirst(columnBoundary)))
                    }
                } else { form(visibleGroups) }
            }
        }
    }
    private var columnBoundary: Int {
        let records = visibleGroups
        let weights = records.map { group in group.fields.reduce(2) { sum, field in
            sum + (field.kind == "multiline" || field.kind == "images" ? 4 : 1)
        } }
        let total = weights.reduce(0, +)
        var left = 0, bestDifference = Int.max, boundary = 1
        for index in 0..<max(weights.count - 1, 0) {
            left += weights[index]
            let difference = abs(total - left * 2)
            if difference < bestDifference { bestDifference = difference; boundary = index + 1 }
        }
        return boundary
    }
    private func form(_ records: [FormGroup]) -> some View {
        Form {
            ForEach(records) { group in
                Section {
                    SourceFieldRows(fields: group.fields, session: session, store: store)
                } header: {
                    Text(L10n.text(group.title))
                }
            }
            if schemas.isEmpty {
                Section { Label("No model selected", systemImage: "cursorarrow.click").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }
    private func groups(_ schema: SourceEditorSchema) -> [SourceEditorGroup] {
        schema.groups.isEmpty ? [SourceEditorGroup(title: schema.title, fields: schema.fields.map(\.id))] : schema.groups
    }
    private func isVisible(_ field: SourceEditorField) -> Bool {
        !field.visibleBy.contains { route in
            let value = session.fields[field.scoped(route)]?.lowercased()
            if route.contains("IsDebugMode") { return !store.isDebugMode && value != "visible" && value != "true" }
            return value == "collapsed" || value == "hidden" || value == "false"
        }
    }
}

struct SourceField: View {
    let field: SourceEditorField
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @State private var validation: String?
    @State private var sourceValidation: [SharedVisualValidationMessage] = []
    private var text: Binding<String> { field.draftBinding(in: session) }
    private var sourceValidationIdentity: String? { session.sourcePropertyValidationIdentity(for: field) }
    private var geometryInputState: (value: String, isMixed: Bool)? {
        guard field.errorValidationSource == "ConceptualMeshControlPointEditor" else { return nil }
        return session.geometryRegionInputState(for: field)
    }
    private var canContinueGeometryInputWhilePending: Bool {
        geometryInputState != nil && session.canContinueGeometryRegionInput(field)
    }
    private var geometryInputBinding: Binding<String>? {
        guard geometryInputState != nil else { return nil }
        return Binding(get: { session.geometryRegionInputState(for: field)?.value ?? "" },
                       set: { session.setGeometryRegionInput(field, value: $0) })
    }
    private var prompt: Text { Text(field.mixedBy.flatMap { session.fields[field.scoped($0)] }?.lowercased() == "true" ? LocalizedStringKey("Mixed values") : LocalizedStringKey(field.placeholder.isEmpty ? "—" : field.placeholder)) }
    private var sliderRange: ClosedRange<Double> {
        let lower = field.minimum ?? 0
        let upper = field.maximum ?? 1
        return lower...max(lower, upper)
    }
    private var choices: [EditorChoice] {
        if let options = session.choiceOptions[field.storageID] { return options.filter { store.isDebugMode || $0.debugOnly != true } }
        if !field.choices.isEmpty { return field.choices.filter { store.isDebugMode || $0.debugOnly != true } }
        let sections: [String: ProjectSection] = ["ObservablePlan": .plans, "ObservableGeometry": .geometries, "ObservableTerrain": .terrains, "ObservableNValueLayer": .surfaceLayers, "ObservableClassificationLayer": .surfaceLayers, "ObservableBoundaryCondition": .boundaryConditions, "ObservableResult": .results]
        // ResultMapVisualContext and TerrainInputWithMapContext are not model
        // file pickers. Their exact options must come from the source adapter.
        return sections[field.sourceType].map { section in store.assets.filter { $0.section == section }.map { EditorChoice(id: $0.name, title: $0.name, titleIsUserData: true) } } ?? []
    }
    var body: some View {
        Group {
            fieldContent
            if let validation { validationContent(validation) }
            if !sourceValidation.isEmpty {
                SharedVisualValidationErrorList(errors: sourceValidation)
                    .font(.caption)
            }
        }
        .help(L10n.text(field.help))
        .disabled(!(field.readOnly || field.isReadOnly == true || session.readOnlyFieldIDs.contains(field.storageID)) &&
            (!session.canEdit || !hasSourceValue || (session.isBusy && !canContinueGeometryInputWhilePending) || session.loadingSelection || store.isSavingAll ||
             field.enabledBy.contains(where: { session.fields[field.scoped($0)]?.lowercased() == "false" })))
        .task(id: sourceValidationIdentity) {
            sourceValidation = []
            guard let identity = sourceValidationIdentity else { return }
            if let messages = await session.validateSourceProperty(field, expectedIdentity: identity) {
                sourceValidation = messages
            }
        }
    }
    @ViewBuilder private var fieldContent: some View {
        if field.kind == "catalogTitle" {
            Text(session.fields[field.storageID] ?? "—").font(.title3.weight(.semibold)).textSelection(.enabled)
        } else if field.kind == "catalogFile" {
            CatalogFilePath(title: field.title, path: session.fields[field.storageID] ?? "", store: store)
        } else if field.readOnly || field.isReadOnly == true || session.readOnlyFieldIDs.contains(field.storageID) {
            readOnlyContent
        } else {
            editableContent
        }
    }
    @ViewBuilder private var readOnlyContent: some View {
        if field.sourceControl.localizedCaseInsensitiveContains("dynamiciconheader") {
            OriginalDynamicIconHeaderPropertyItem(title: field.title, text: displayValue)
        } else if field.sourceControl.localizedCaseInsensitiveContains("paragraphpropertyitem") || field.sourceSetter.contains("ParagraphPropertyItem") {
            OriginalParagraphPropertyItem(title: field.title, value: displayValue)
        } else if field.sourceControl.localizedCaseInsensitiveContains("textpropertyitem") || field.sourceSetter.contains("TextPropertyItem_TextValue") {
            OriginalTextPropertyItem(title: field.title, value: displayValue)
        } else {
            LabeledContent(LocalizedStringKey(field.title), value: displayValue).textSelection(.enabled)
        }
    }
    private var displayValue: String {
        let value = session.fields[field.storageID] ?? "—"
        // Context_TypeName is a source-provided presentation category;
        // ordinary read-only names, paths and user data stay verbatim.
        return field.id == "Context_TypeName" ? L10n.text(value) : value
    }
    @ViewBuilder private var editableContent: some View {
        switch field.kind {
        case "recipe": RecipeField(field: field, session: session, store: store)
        case "layerSource": LayerSourceField(field: field, session: session, store: store)
        case "connection":
            VStack(alignment: .leading) {
                ExternalConnectionField(field: field, session: session, store: store)
                OriginalExternalConnectionIndicator(field: field, session: session, store: store)
            }
        case "externalPath":
            VStack(alignment: .leading) {
                ExternalPathField(field: field, session: session, store: store)
                OriginalExternalConnectionIndicator(field: field, session: session, store: store)
            }
        case "images": Attachments(field: field, session: session, store: store)
        case "classificationMapping": ClassificationMappingField(field: field, session: session)
        case "duration": IntervalField(field: field, session: session)
        case "color": OriginalColorPickerPropertyItem(field: field, session: session, store: store)
        case "toggle": OriginalMixedTogglePropertyItem(field: field, session: session)
        case "choice": OriginalChoicePropertyItem(field: field, choices: choices, session: session, store: store) { choice in
            if field.forceSetCommand.flatMap(GeometryArcForceSetCommand.init(rawValue:)) != nil,
               field.hasMixedDraft(in: session) {
                guard let identity = session.captureGeometryArcForceSetIdentity(field: field, value: choice.id) else {
                    session.error = L10n.text("The selected Arc rows changed. Select them again before applying this value.")
                    return
                }
                Task { @MainActor in _ = await session.forceSetGeometryArcChoice(identity) }
            } else if field.forceSetCommand == "forceSetMode" || field.forceSetCommand == "forceSetModType",
                      field.hasMixedDraft(in: session) {
                guard let identity = session.captureLeveeForceSetIdentity(field: field, value: choice.id) else {
                    session.error = L10n.text("The selected Levee property sets changed. Select them again before applying this value.")
                    return
                }
                Task { @MainActor in _ = await session.forceSetLeveeProperty(identity) }
            } else if field.forceSetCommand == "forceSetPatchType" {
                session.forceSetGeometryRegionPatchType(field, value: choice.id)
            } else {
                field.setDraftValue(choice.id, in: session)
            }
        }
        case "date": OriginalDateTimePropertyItem(field: field, session: session)
        case "multiline": OriginalInputTextPropertyItem(field: field, session: session, store: store, acceptsReturn: true)
        case "slider": OriginalSliderPropertyItem(field: field, session: session)
        case "number":
            if field.scope.hasSuffix("ClassificationVisualizationOptions") &&
                field.id == "EditModeOpacityForward" &&
                field.sourceSetter.contains("SliderPropertyItem_Value") {
                ClassificationOpacityPropertyItem(field: field, title: "Edit Mode Opacity", session: session, store: store)
            } else if field.sourceSetter.contains("NumericPropertyItem_") {
                OriginalNumericPropertyItem(field: field, session: session)
            } else if field.sourceControl.localizedCaseInsensitiveContains("numberbox") ||
                        field.sourceSetter.contains("NumberBox_Number") {
                OriginalNumberBoxPropertyItem(field: field, session: session, store: store)
            } else {
                defaultContent
            }
        default: defaultContent
        }
    }
    @ViewBuilder private var defaultContent: some View {
        if field.sourceSetter.contains("DoubleClickValidateableTextBox_") {
            DoubleClickText(title: field.title, text: text, prompt: prompt, suggestions: session.textSuggestions[field.storageID] ?? [])
        } else if ["secret", "password", "token"].contains(where: { field.title.localizedCaseInsensitiveContains($0) }) {
            SecureField(LocalizedStringKey(field.title), text: text, prompt: prompt)
        } else if field.sourceControl.localizedCaseInsensitiveContains("numberbox") || field.sourceSetter.contains("NumberBox_Number") || field.sourceSetter.contains("InputTextPropertyItem_TextValue") || field.sourceSetter.contains("ValidateableTextBox_Text") {
            OriginalInputTextPropertyItem(
                field: field,
                session: session,
                store: store,
                acceptsReturn: field.kind == "multiline",
                showsClearButton: field.showClearButton == true && (geometryInputState?.isMixed ?? field.hasMixedDraft(in: session)),
                clearAction: field.clearCommand == nil ? nil : { clearSourceField() },
                onSubmit: numericSubmit,
                textBinding: geometryInputBinding,
                mixedValue: geometryInputState?.isMixed,
                onEscape: { session.setGeometryRegionInput(field, value: $0) },
                allowsPendingGeometryRegionInput: geometryInputState != nil
            )
        } else {
            TextField(LocalizedStringKey(field.title), text: text, prompt: prompt)
                .textInputSuggestions {
                    ForEach(Array((session.textSuggestions[field.storageID] ?? []).enumerated()), id: \.offset) { _, suggestion in
                        Text(suggestion).textInputCompletion(suggestion)
                    }
                }
                .onSubmit { validateNumber() }
        }
    }
    private var numericSubmit: (() -> Void)? {
        guard field.kind == "number" else { return nil }
        return { validateNumber() }
    }
    @ViewBuilder private func validationContent(_ message: String) -> some View {
        SharedVisualValidationErrorList(errors: [.init(id: field.storageID, text: message, level: .error)])
            .font(.caption)
    }
    private var hasSourceValue: Bool {
        session.fields[field.storageID] != nil || session.images[field.storageID] != nil || session.rows[field.storageID] != nil || session.sourceCollections[field.storageID] != nil
    }
    private func clearSourceField() {
        if geometryInputState != nil {
            session.resetGeometryRegionInput(field)
        } else if field.clearCommand == GeometryArcClearCommand.resetBias.rawValue {
            guard let identity = session.captureGeometryArcBiasResetIdentity(field: field) else {
                session.error = L10n.text("The selected Arc rows changed. Select them again before applying this value.")
                return
            }
            Task { @MainActor in _ = await session.resetGeometryArcBias(identity) }
        } else if field.clearCommand?.hasPrefix("forceReset") == true {
            // The original Levee setters parse an empty value to NaN. They
            // remain on the normal parent draft/save path.
            field.setDraftValue("", in: session)
        }
    }
    private func validateNumber() {
        guard field.kind == "number", let raw = session.fields[field.storageID], !raw.isEmpty else { validation = nil; return }
        guard let value = Double(raw), value.isFinite else { validation = L10n.text("Enter a finite number."); return }
        if let minimum = field.minimum, value < minimum { validation = L10n.format("Enter a value greater than or equal to %@.", minimum.formatted()); return }
        if let maximum = field.maximum, value > maximum { validation = L10n.format("Enter a value less than or equal to %@.", maximum.formatted()); return }
        validation = nil
    }
    private var toggleSources: [Binding<Bool>] {
        let isMixed = field.mixedBy.flatMap { session.fields[field.scoped($0)] }?.lowercased() == "true"
        return (isMixed ? [true, false] : [session.fields[field.storageID]?.lowercased() == "true"]).map { value in
            Binding(get: { value }, set: { session.set(field.storageID, String($0)); session.clearMixedFlag(field.mixedBy.map { field.scoped($0) }) })
        }
    }
}

struct TableSort: SortComparator {
    var order = SortOrder.forward
    let columnID: String
    let numeric: Bool
    func compare(_ lhs: EditorRow, _ rhs: EditorRow) -> ComparisonResult {
        let left = lhs.values[columnID] ?? "", right = rhs.values[columnID] ?? ""
        let result: ComparisonResult
        if numeric, let a = Double(left), let b = Double(right), a.isFinite, b.isFinite {
            result = a == b ? .orderedSame : a < b ? .orderedAscending : .orderedDescending
        } else { result = left.localizedStandardCompare(right) }
        if order == .forward { return result }
        return result == .orderedAscending ? .orderedDescending : result == .orderedDescending ? .orderedAscending : .orderedSame
    }
}

struct ModelTablePage: View {
    let page: ModelEditorPage
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    var showsSelectionDetail = true
    @State private var localSelection: Set<String> = []
    @State private var filter = ""
    @State private var filterColumnID: String?
    @State private var showsFilterBar = true
    @State private var expressionMode = false
    @StateObject private var expressionFilter = TableExpressionFilterSession()
    @State private var sortOrder: [TableSort] = []
    @State private var gridCellSelection = NativeDataGridSelection()
    @State private var tablePasteError: String?
    @State private var topologyFeatureActionError: String?
    @State private var topologyProfileActionCapture: GeometryTopologyFeatureActionCapture?
    private var tableSortOrder: Binding<[TableSort]> {
        Binding(get: { sortOrder.filter { order in columns.contains { $0.id == order.columnID && $0.sortable != false } } }, set: { order in
            guard order.allSatisfy({ sort in columns.contains { $0.id == sort.columnID && $0.sortable != false } }) else { return }
            sortOrder = order
        })
    }
    private var displayedRows: [EditorRow] {
        let rows = tableRows.filter { row in
            if expressionMode { return expressionFilter.matchingRowIDs?.contains(row.id) ?? true }
            return filter.isEmpty || columns.filter { $0.filterable != false && (filterColumnID == nil || $0.id == filterColumnID) }
                .contains { (row.values[$0.id] ?? "").localizedCaseInsensitiveContains(filter) }
        }
        let allowedOrder = sortOrder.filter { order in columns.contains { $0.id == order.columnID && $0.sortable != false } }
        return allowedOrder.isEmpty ? rows : rows.sorted(using: allowedOrder)
    }
    private var tableID: String {
        switch page.title {
        case "Arcs": "ObservableBaseArc"
        case "Regions": "ObservableConceptualMeshControlPoint"
        case "Nodes": "ObservableNode"
        case "Culverts": "ObservableCulvertBarrel"
        case "Barrel Properties": "ObservableBarrelProperties"
        case "Opening Properties": "ObservableOpeningProperties"
        case "Terrain Inputs": "ObservableTerrainInput"
        case "Classifications": "ObservableConstantClassificationInput"
        default: "ObservableBoundaryConditionLine"
        }
    }
    private var columns: [SourceTableColumn] {
        let baseColumns: [SourceTableColumn]
        if let presentation = session.tablePresentations[page.id] {
            baseColumns = presentation.columns.filter { $0.visible != false }
        } else if page.title == "Arc Points" {
            baseColumns = [SourceTableColumn(id: "Type", title: "Type", sourceType: "string", readOnly: true),
                SourceTableColumn(id: "X", title: "X", sourceType: "double"), SourceTableColumn(id: "Y", title: "Y", sourceType: "double")]
        } else {
            baseColumns = SourceEditorLibrary.shared.tables.first { $0.id == tableID }?.columns ?? []
        }
        let existingIDs = Set(baseColumns.map { $0.id.lowercased() })
        return baseColumns + topologyManagedColumns.filter { !existingIDs.contains($0.id.lowercased()) }
    }
    private var topologyManagedColumns: [SourceTableColumn] {
        guard let featureKind = topologyFeatureKind,
              let topology = session.geometryTopology,
              topology.snapshot != nil else { return [] }
        return topology.table(for: featureKind).columns.filter { $0.isUserDefined == true }.map { column in
            SourceTableColumn(id: column.id, title: column.title, sourceType: column.sourceType,
                readOnly: true, filterable: true, titleIsUserData: true)
        }
    }
    private var tableRows: [EditorRow] {
        let rows = session.rows[page.id] ?? []
        guard let featureKind = topologyFeatureKind,
              let topology = session.geometryTopology,
              topology.snapshot != nil else { return rows }
        let topologyRows = Dictionary(uniqueKeysWithValues: topology.table(for: featureKind).rows.map { ($0.fid, $0) })
        return rows.map { row in
            guard let rawFID = row.values["FID"],
                  let fid = Int(rawFID.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let topologyRow = topologyRows[fid] else { return row }
            var merged = row
            for column in topologyManagedColumns {
                merged.values[column.id] = topologyRow.values[column.id] ?? ""
            }
            return merged
        }
    }
    private var presentation: EditorTablePresentation? { session.tablePresentations[page.id] }
    private var filterCapture: TableFilterCapture {
        TableFilterCapture(owner: [store.projectSessionID.uuidString, session.id.uuidString,
            session.modelAssetID ?? "", session.sourceFileRevision ?? "", page.id].joined(separator: "|"),
            columns: columns.map { .init(id: $0.id, name: $0.title, sourceType: $0.sourceType,
                filterable: $0.filterable != false) },
            rows: tableRows.map { .init(id: $0.id, values: $0.values) })
    }
    private var selection: Set<String> { presentation?.selection?.rowIDs ?? localSelection }
    private var tableSelection: Binding<Set<String>> {
        Binding(get: { selection }, set: { ids in
            if presentation?.selection != nil {
                Task {
                    guard await session.perform(.selectTableRows(table: page.id, ids: ids)) else { return }
                    synchronizeTopologySelection(ids)
                }
            } else {
                localSelection = ids
                synchronizeTopologySelection(ids)
            }
        })
    }
    private var topologyFeatureKind: String? {
        switch page.title {
        case "Arcs": "arc"
        case "Regions": "region"
        case "Nodes": "node"
        default: nil
        }
    }
    private func columnTitle(_ column: SourceTableColumn) -> String { column.titleIsUserData == true ? column.title : L10n.text(column.title) }
    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text(LocalizedStringKey(page.title)).font(.headline)
                    Picker("Filter Mode", selection: $expressionMode) {
                        Text("Search").tag(false)
                        Text("Expression").tag(true)
                    }.pickerStyle(.segmented).frame(maxWidth: 180)
                    if !expressionMode && showsFilterBar {
                        SharedVisualFilterSearchBar(searchText: $filter, placeholder: "Filter rows",
                        filterIsActive: filterColumnID != nil,
                        clearFilters: { filter = ""; filterColumnID = nil }) {
                            Picker("Search Column", selection: $filterColumnID) {
                                Text("All Columns").tag(Optional<String>.none)
                                ForEach(columns.filter { $0.filterable != false }) { column in
                                    Text(columnTitle(column)).tag(Optional(column.id))
                                }
                            }
                        }
                            .frame(maxWidth: 230)
                    }
                    Spacer()
                    if let featureKind = topologyFeatureKind,
                       let columnKind = GeometryTopologyMetadataColumnKind(rawValue: featureKind),
                       let topology = session.geometryTopology {
                        GeometryTopologyMetadataColumnMenu(featureKind: columnKind,
                            columns: topology.table(for: featureKind).columns, session: topology,
                            openGlobalTool: { kind, column in openColumnTool(kind, column: column) })
                    } else if presentation?.canAddColumns == true || presentation?.renameableColumnIDs.isEmpty == false {
                        Menu("Columns") {
                            Button("Add Column") { openColumnTool(.addAttribute, column: nil) }.disabled(presentation?.canAddColumns != true)
                            Menu("Rename Column") {
                                ForEach(columns.filter { presentation?.renameableColumnIDs.contains($0.id) == true }) { column in
                                    Button(columnTitle(column)) { openColumnTool(.renameAttribute, column: column.id) }
                                }
                            }
                        }.disabled(!session.canEdit)
                    }
                    Button { copySelection() } label: { Label("Copy Table", systemImage: "doc.on.clipboard") }.disabled(selection.isEmpty)
                    ControlGroup {
                        Button { Task { await session.perform(.addRow(table: page.id)) } } label: { Label("Add", systemImage: "plus") }.disabled(presentation?.canAddRows != true)
                        Button { Task { await session.perform(.copyRows(table: page.id, ids: selection)) } } label: { Label("Copy", systemImage: "doc.on.doc") }.disabled(selection.isEmpty || presentation?.canCopyRows != true)
                        Button(role: .destructive) { Task { await session.perform(.removeRows(table: page.id, ids: selection)) } } label: { Label("Remove", systemImage: "minus") }.disabled(selection.isEmpty || presentation?.canDeleteRows != true)
                    }.disabled(!session.canEdit || session.loadingSelection)
                }.padding(12)
                if expressionMode { TableExpressionFilterBar(session: expressionFilter, capture: filterCapture) }
                NativeDataGrid(
                    identity: [session.id.uuidString, session.modelAssetID ?? "", session.sourceFileRevision ?? "", page.id].joined(separator: "|"),
                    rows: displayedRows,
                    columns: columns,
                    selectionRowIDs: session.rows[page.id]?.map(\.id) ?? [],
                    selectionColumnIDs: columns.map(\.id),
                    selection: $gridCellSelection,
                    rowSelection: tableSelection,
                    initialWidth: { $0.width.flatMap { $0 > 0 && $0.isFinite ? CGFloat($0) : nil } ?? 130 },
                    isReadOnly: { $0.readOnly == true },
                    value: { row, column in row.values[column.id] ?? "" },
                    header: { column in
                        AnyView(Button {
                            let numeric = ["double", "float", "int", "long"].contains(column.sourceType)
                            let current = tableSortOrder.wrappedValue.first(where: { $0.columnID == column.id })
                            let nextOrder = current.map { $0.order == .forward ? SortOrder.reverse : SortOrder.forward } ?? .forward
                            tableSortOrder.wrappedValue = [.init(order: nextOrder, columnID: column.id, numeric: numeric)]
                        } label: {
                            HStack(spacing: 5) {
                                Text(columnTitle(column)).lineLimit(1)
                                if let current = tableSortOrder.wrappedValue.first(where: { $0.columnID == column.id }) {
                                    Image(systemName: current.order == .forward ? "arrow.up" : "arrow.down").font(.caption2)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).disabled(column.sortable == false))
                    },
                    cell: { row, column in AnyView(TableCell(column: column, rowID: row.id, tableID: page.id, session: session, store: store)) },
                    contextMenu: { context in
                        AnyView(Group {
                            if let columnID = context.columnID, let column = columns.first(where: { $0.id == columnID }) {
                                if column.sortable != false {
                                    Button("Sort Ascending") { tableSortOrder.wrappedValue = [.init(columnID: column.id, numeric: ["double", "float", "int", "long"].contains(column.sourceType))] }
                                    Button("Sort Descending") { tableSortOrder.wrappedValue = [.init(order: .reverse, columnID: column.id, numeric: ["double", "float", "int", "long"].contains(column.sourceType))] }
                                    if !tableSortOrder.wrappedValue.isEmpty { Button("Clear Sort") { tableSortOrder.wrappedValue = [] } }
                                }
                                if column.filterable != false {
                                    Button(showsFilterBar ? "Hide Filter Bar" : "Show Filter Bar") { showsFilterBar.toggle() }
                                    if !filter.isEmpty || filterColumnID != nil || !expressionFilter.appliedExpression.isEmpty {
                                        Button("Clear Filter") { filter = ""; filterColumnID = nil; expressionFilter.clear() }
                                    }
                                }
                                if column.sortable != false || column.filterable != false { Divider() }
                                if topologyFeatureKind == nil && presentation?.renameableColumnIDs.contains(column.id) == true {
                                    Button("Rename Column") { openColumnTool(.renameAttribute, column: column.id) }
                                        .disabled(!session.canEdit || session.isBusy)
                                    Divider()
                                }
                                if topologyFeatureKind == nil && presentation?.canAddColumns == true {
                                    Button("Add Column") { openColumnTool(.addAttribute, column: nil) }
                                        .disabled(!session.canEdit || session.isBusy)
                                    Divider()
                                }
                            }
                            if let rowID = context.rowID,
                               let featureKind = topologyFeatureKind,
                               let topology = session.geometryTopology {
                                let editorContextIDs = Set(contextRowIDs(clickedRowID: rowID))
                                if let topologyContextIDs = topologyRowIDs(forEditorRowIDs: editorContextIDs,
                                    featureKind: featureKind) {
                                    GeometryTopologyFeatureContextMenu(topology: topology, store: store,
                                        featureKind: featureKind, rowIDs: topologyContextIDs,
                                        profileCapture: $topologyProfileActionCapture,
                                        error: $topologyFeatureActionError)
                                    Divider()
                                }
                            }
                            if let rowID = context.rowID, context.columnID == nil {
                                let contextRows = Set(contextRowIDs(clickedRowID: rowID))
                                Button("Copy Table") { if let text = selectedTableText(contextRows) { store.system.copy(text) } }
                                if presentation?.canAddRows == true {
                                    Button("Add Row") { Task { await session.perform(.addRow(table: page.id)) } }
                                        .disabled(!session.canEdit || session.loadingSelection)
                                }
                                if presentation?.canCopyRows == true {
                                    Button("Copy Row") { Task { await session.perform(.copyRows(table: page.id, ids: contextRows)) } }
                                        .disabled(!session.canEdit || session.loadingSelection)
                                }
                                if presentation?.canDeleteRows == true {
                                    Button("Delete Row", role: .destructive) {
                                        Task { await session.perform(.removeRows(table: page.id, ids: contextRows)) }
                                    }.disabled(!session.canEdit || session.loadingSelection)
                                }
                            }
                        })
                    },
                    onPaste: { edits in pasteTableCells(edits) }
                )
                if let tablePasteError { Label(tablePasteError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red).padding(.horizontal, 12) }
                if let topologyFeatureActionError {
                    Label(topologyFeatureActionError, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).padding(.horizontal, 12)
                }
            }.frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
            if showsSelectionDetail {
                TableSelectionDetail(page: page, presentation: presentation?.selection, session: session, store: store)
                    .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: page.id) { _, _ in localSelection = []; gridCellSelection = .init(); tablePasteError = nil; filter = ""; filterColumnID = nil; showsFilterBar = true; sortOrder = []; expressionFilter.clear() }
        .onChange(of: selection) { _, ids in synchronizeTopologySelection(ids) }
        .onChange(of: columns.map(\.id)) { _, ids in
            if let filterColumnID, !ids.contains(filterColumnID) { self.filterColumnID = nil }
        }
        .onChange(of: session.modelAssetID) { _, _ in localSelection = []; gridCellSelection = .init(); tablePasteError = nil }
        .sheet(item: $topologyProfileActionCapture) { capture in
            if let topology = session.geometryTopology {
                GeometryTopologyFeatureProfileSheet(store: store, topology: topology, capture: capture)
            } else {
                ContentUnavailableView("Topology unavailable", systemImage: "point.3.connected.trianglepath.dotted")
            }
        }
    }

    private func contextRowIDs(clickedRowID: String) -> [String] {
        let modifiers = NSEvent.modifierFlags
        // AttributeTableDataGrid resolves a context menu against SelectedRows.Elements,
        // including rows retained by the source selection while a filter hides them.
        return NativeDataGridContextSelection.rowIDs(clickedRowID: clickedRowID,
            selectedRowIDs: selection, sourceRowIDs: (session.rows[page.id] ?? []).map(\.id),
            addsToSelection: modifiers.contains(.control) || modifiers.contains(.command))
    }

    private func topologyRowIDs(forEditorRowIDs ids: Set<String>, featureKind: String) -> [String]? {
        guard !ids.isEmpty, let topology = session.geometryTopology else { return nil }
        let sourceRows = session.rows[page.id] ?? []
        let requestedRows = ids.compactMap { id in sourceRows.first(where: { $0.id == id }) }
        guard requestedRows.count == ids.count else { return nil }
        let fids = requestedRows.compactMap { row -> Int? in
            guard let raw = row.values["FID"] else { return nil }
            return Int(raw)
        }
        guard fids.count == ids.count, Set(fids).count == fids.count else { return nil }
        let tableRows = topology.table(for: featureKind).rows
        let mapped = fids.compactMap { fid in tableRows.first(where: { $0.fid == fid })?.id }
        guard mapped.count == ids.count, Set(mapped).count == mapped.count else { return nil }
        let mappedSet = Set(mapped)
        return tableRows.filter { mappedSet.contains($0.id) }.map(\.id)
    }

    private func synchronizeTopologySelection(_ editorRowIDs: Set<String>) {
        guard let featureKind = topologyFeatureKind,
              let mapped = topologyRowIDs(forEditorRowIDs: editorRowIDs, featureKind: featureKind),
              let assetID = session.modelAssetID else { return }
        Task { @MainActor in
            await session.ensureGeometryTopologyLoaded()
            guard session.modelAssetID == assetID,
                  selection == editorRowIDs,
                  let current = topologyRowIDs(forEditorRowIDs: editorRowIDs, featureKind: featureKind),
                  current == mapped,
                  let topology = session.geometryTopology else { return }
            topology.select(Set(mapped), featureKind: featureKind)
        }
    }
    private func openColumnTool(_ kind: ToolKind, column: String?) {
        guard let assetID = session.modelAssetID else { return }
        store.activeAttributeToolContext = .init(modelAssetID: assetID, tableID: page.id, projectSessionID: store.projectSessionID, parentEditorSessionID: session.id, columnID: column)
        store.activeTool = kind
    }
    private func copySelection() {
        if let text = selectedTableText() { store.system.copy(text) }
    }
    private func selectedTableText(_ selectedIDs: Set<String>? = nil) -> String? {
        let rows = displayedRows.filter { (selectedIDs ?? selection).contains($0.id) }
        guard !rows.isEmpty else { return nil }
        func escaped(_ value: String) -> String {
            if value.contains(where: { $0 == "\t" || $0.isNewline || $0 == "\"" }) { return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            return value
        }
        let header = columns.map { escaped(columnTitle($0)) }.joined(separator: "\t")
        let values = rows.map { row in columns.map { escaped(row.values[$0.id] ?? "") }.joined(separator: "\t") }
        return ([header] + values).joined(separator: "\n")
    }
    private func pasteTableCells(_ edits: [NativeDataGridPasteCell]) {
        guard session.canEdit, !session.isBusy, !store.isSavingAll else { return }
        var failures = 0
        for edit in edits {
            guard let column = columns.first(where: { $0.id == edit.columnID }), column.readOnly != true else { continue }
            if session.rows[page.id]?.first(where: { $0.id == edit.rowID })?.values[column.id] == edit.value { continue }
            guard pasteValueIsValid(edit.value, for: column) else { failures += 1; continue }
            session.setCell(table: page.id, rowID: edit.rowID, column: edit.columnID, value: edit.value)
        }
        tablePasteError = failures == 0 ? nil : L10n.format("Failed to paste %d cells due to invalid format or type.", failures)
    }
    private func pasteValueIsValid(_ value: String, for column: SourceTableColumn) -> Bool {
        if let choices = column.choices, !choices.isEmpty,
           !choices.filter({ store.isDebugMode || $0.debugOnly != true }).contains(where: { $0.id == value }) { return false }
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return switch column.sourceType.lowercased() {
        case "int", "int32", "integer": Int32(value) != nil
        case "long", "int64": Int64(value) != nil
        case "double", "float": Double(value) != nil
        case "bool", "boolean": ["true", "false"].contains(value.lowercased())
        case "datetime", "datetimeoffset": SourceTimestamp.parse(value) != nil
        default: true
        }
    }
}

struct TableCell: View {
    let column: SourceTableColumn
    let rowID: String
    let tableID: String
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    var units: DisplayUnitData? = nil
    private var value: String { session.rows[tableID]?.first { $0.id == rowID }?.values[column.id] ?? "" }
    private var title: String { column.localizedTitle }
    private var numericOwner: OriginalUnitNumberInputOwner {
        .tableCell(tableID: tableID, rowID: rowID, columnID: column.id)
    }
    private var editable: Bool { session.canEdit && !session.isBusy && !store.isSavingAll && column.readOnly != true }
    private var text: Binding<String> { Binding(get: { value }, set: { session.setCell(table: tableID, rowID: rowID, column: column.id, value: $0) }) }
    var body: some View {
        if column.sourceType == "bool", ["true", "false"].contains(value.lowercased()) {
            Toggle(title, isOn: Binding(get: { value.lowercased() == "true" }, set: { text.wrappedValue = String($0) }))
                .toggleStyle(.checkbox).labelsHidden().disabled(!editable)
        } else if editable, let choices = column.choices, !choices.isEmpty {
            Picker(title, selection: text) {
                ForEach(choices.filter { store.isDebugMode || $0.debugOnly != true }) { Text(L10n.text($0.title)).tag($0.id) }
                if !choices.contains(where: { $0.id == value }) { Text(value).tag(value) }
            }.labelsHidden()
        } else if editable, column.sourceType == "DateTime", let date = SourceTimestamp.parse(value) {
            DatePicker(title, selection: Binding(get: { date }, set: { if $0 != date { text.wrappedValue = ISO8601DateFormatter().string(from: $0) } }), displayedComponents: [.date, .hourAndMinute]).labelsHidden()
        } else if let units, ["double", "float"].contains(column.sourceType) {
            if editable || session.unitNumberInputDraft(for: numericOwner) != nil {
                UnitNumberField(title: title, owner: numericOwner,
                    units: units, session: session, isEnabled: editable, titleIsLocalized: true).textFieldStyle(.plain)
            } else {
                Text(session.displayUnit(units)?.string(value) ?? value).textSelection(.enabled)
            }
        } else if editable {
            TextField(title, text: text).textFieldStyle(.plain)
                .textInputSuggestions {
                    ForEach(Array((column.autoSuggestions ?? []).enumerated()), id: \.offset) { _, value in Text(value).textInputCompletion(value) }
                }
        } else { Text(value).textSelection(.enabled) }
    }
}
