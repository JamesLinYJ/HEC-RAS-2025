import RASWorkspaceCore
import SwiftUI

/// The analysis-menu entry owns its read-only inspector instead of borrowing an
/// editor's changing selection. It uses the same source plan groups and keyed
/// profiles as the Result page, with an explicit saved-Result anchor.
@MainActor
struct ResultPlanComparisonTool: View {
    @ObservedObject var store: WorkspaceStore
    let client: BackendProcessClient
    @StateObject private var inspector: ResultInspectorSession
    @StateObject private var plans: ResultPlanContextSession
    @State private var anchorID: String?
    @State private var refreshGeneration = 0
    @State private var selection: LinkedResultSelection?
    @State private var selectionError: String?

    init(store: WorkspaceStore, client: BackendProcessClient) {
        self.store = store
        self.client = client
        _inspector = StateObject(wrappedValue: ResultInspectorSession(
            provider: BackendResultInspectorProvider(client: client)))
        _plans = StateObject(wrappedValue: ResultPlanContextSession(
            provider: BackendResultPlanContextProvider(client: client)))
        _anchorID = State(initialValue: store.selectedAsset.flatMap {
            $0.section == .results && $0.isModelFile ? $0.id : nil
        })
    }

    private var results: [ProjectAsset] {
        store.assets.filter { $0.section == .results && $0.isModelFile }
    }
    private var anchor: ProjectAsset? { results.first { $0.id == anchorID } }
    private var projectXML: String? {
        store.document?.editorXML(overridingDescription: store.descriptionDraft)
    }
    private var sourceContextRevision: String { "\(store.projectSessionID):\(store.assetsRevision)" }
    private var requestIdentity: String {
        makeRequestIdentity(coreLayerContext: store.captureCoreLayerRequestContext())
    }
    private func makeRequestIdentity(coreLayerContext: CoreLayerRequestContext?) -> String {
        [sourceContextRevision, store.document?.url?.path ?? "", projectXML ?? "",
         coreLayerContext?.identityToken ?? "",
         anchor?.id ?? "", String(refreshGeneration)].joined(separator: "\n")
    }
    private var isBusy: Bool { inspector.isLoading || plans.isLoading }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(L10n.text("Compare Result Plans"), systemImage: "square.stack.3d.up")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(L10n.text("Close")) { store.activeTool = nil }
                    .keyboardShortcut(.cancelAction)
            }
            if store.document == nil {
                ContentUnavailableView(L10n.text("Open a project to compare saved Results."),
                    systemImage: "folder")
            } else if results.isEmpty {
                ContentUnavailableView(L10n.text("No saved Results are available in this project."),
                    systemImage: "doc.chart.line.uptrend.xyaxis")
            } else {
                HStack {
                    Picker(L10n.text("Anchor Result"), selection: $anchorID) {
                        Text(L10n.text("Choose a saved Result…")).tag(String?.none)
                        ForEach(results) { result in
                            Text(verbatim: result.name).tag(Optional(result.id))
                        }
                    }
                    .pickerStyle(.menu)
                    Button {
                        refreshGeneration += 1
                    } label: { Label(L10n.text("Refresh"), systemImage: "arrow.clockwise") }
                    .disabled(anchor == nil || isBusy)
                }
                if let anchor {
                    Text(verbatim: anchor.url.path).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if inspector.isLoading {
                        ProgressView(L10n.text("Reading result source…"))
                    } else if let error = inspector.error {
                        Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).textSelection(.enabled)
                    } else {
                        ScrollView {
                            ResultPlanAssociationPanel(session: plans, onLinkedResultSelection: accept)
                        }
                    }
                } else {
                    ContentUnavailableView(L10n.text("Choose a saved Result to load plan choices."),
                        systemImage: "cursorarrow.click")
                }
            }
            if let selectionError {
                Label(selectionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 540, idealWidth: 650, minHeight: 400, idealHeight: 540)
        .task(id: requestIdentity) {
            let coreLayerContext = store.captureCoreLayerRequestContext()
            inspector.invalidate()
            plans.invalidate()
            let capture = makeRequestIdentity(coreLayerContext: coreLayerContext)
            guard capture == requestIdentity else { return }
            await inspector.ensureLoaded(asset: anchor, projectPath: store.document?.url,
                projectXML: projectXML, sourceContextRevision: sourceContextRevision)
            guard !Task.isCancelled, capture == requestIdentity else { return }
            await plans.ensureLoaded(asset: anchor, projectPath: store.document?.url,
                projectXml: projectXML, inspectorSnapshot: inspector.snapshot,
                sourceContextRevision: sourceContextRevision,
                coreLayerContext: coreLayerContext)
        }
        .onChange(of: requestIdentity) { _, _ in
            selection = nil
            selectionError = nil
        }
        .onChange(of: store.projectSessionID) { _, _ in anchorID = nil }
        .onDisappear {
            inspector.invalidate()
            plans.invalidate()
        }
        .sheet(isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } })) {
            if let selection, let projectXML {
                LinkedResultProfilesWorkspace(selection: selection, projectXML: projectXML,
                    projectContextID: sourceContextRevision, client: client)
            }
        }
    }

    private func accept(_ value: LinkedResultSelection) {
        guard plans.accepts(value, asset: anchor, projectPath: store.document?.url,
            projectXml: projectXML, inspectorSnapshot: inspector.snapshot,
            sourceContextRevision: sourceContextRevision) else {
            selectionError = L10n.text("The linked Result context changed. Reopen Link Plans.")
            return
        }
        selectionError = nil
        selection = value.withCoreLayerContext(plans.coreLayerContext)
    }
}
