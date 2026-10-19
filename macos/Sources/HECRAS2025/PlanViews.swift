import Foundation
import RASWorkspaceCore
import SwiftUI

// The shared model-editor workspace owns plan selection and left navigation.
// This page presents the source PlanCatalogSummary contents for that workspace.
struct PlanCatalogSummary: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        Form {
            Section("Plan Information") {
                SchemaFields(schema: "PlanCatalogSummary", session: session, store: store)
            }
            Section("Plan Associations") {
                PlanAssociationsPicker(session: session, store: store)
            }
            Section("Related Results") {
                PlanNodeDetails(session: session, store: store)
            }
            Section("Boundary Conditions") {
                SchemaValues(schema: "SmallBoundaryConditionsSummary", session: session)
            }
        }
        .formStyle(.grouped)
    }
}

struct PlanSettingsPage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    let resultOwner: PlanSettingsResultOwner?
    @StateObject private var resultSettings: PlanSettingsResultSession

    init(session: ModelEditorSession, store: WorkspaceStore,
         resultOwner: PlanSettingsResultOwner? = nil) {
        self.session = session
        self.store = store
        self.resultOwner = resultOwner
        let backend = session.provider as? BackendModelProvider
        _resultSettings = StateObject(wrappedValue: PlanSettingsResultSession(
            provider: BackendPlanSettingsEmbeddedResultProvider(client: backend?.client)))
    }

    private var schema: SourceEditorSchema? { SourceEditorLibrary.shared.schema("PlanSettingsPage") }
    private var isResult: Bool {
        session.fields["PlanSettingsPage/ViewModel_SelectedPlan_IsResult"]?.lowercased() == "true"
    }
    private var customTimeWindowSelected: Bool {
        session.fields["PlanSettingsPage/ViewModel_SelectedPlan_TimeWindowMode"] == "Plan"
    }
    private var resultSettingsCapture: PlanSettingsResultCapture? {
        guard isResult, session.loaded, let owner = resultOwner,
              owner.projectSessionID == store.projectSessionID,
              !owner.sourceContextID.isEmpty, !owner.resultRevision.isEmpty,
              let asset = store.assets.first(where: { $0.id == owner.resultAssetID }),
              asset.section == .results, asset.isModelFile,
              SourceFilePaths.canonical(asset.url) == SourceFilePaths.canonical(URL(fileURLWithPath: owner.resultPath)),
              let project = store.document, let projectPath = project.url,
              let projectRevision = project.sourceRevision else {
            return nil
        }
        let projectXML = project.editorXML(overridingDescription: store.descriptionDraft)
        return PlanSettingsResultCapture(owner: owner, resultName: asset.name,
            assetsRevision: store.assetsRevision,
            projectPath: projectPath.standardizedFileURL.resolvingSymlinksInPath().path,
            projectRevision: projectRevision, projectXML: projectXML)
    }
    private var resultSettingsRefreshKey: String {
        resultSettingsCapture?.identity ?? "unavailable|\(store.projectSessionID.uuidString)|\(session.id.uuidString)"
    }

    var body: some View {
        Form {
            if isResult {
                PlanSettingsEmbeddedResultDetails(session: resultSettings,
                    capture: resultSettingsCapture)
            } else {
                Section("Plan Associations") {
                    PlanAssociationsPicker(session: session, store: store)
                }
            }
            if !isResult, let schema {
                ForEach(Array(schema.groups.enumerated()), id: \.offset) { _, group in
                    Section(LocalizedStringKey(group.title)) {
                        fields(in: group, schema: schema)
                    }
                }
            } else if !isResult {
                Section { Label("Plan settings schema is unavailable", systemImage: "exclamationmark.triangle") }
            }
            if !isResult {
                PlanPrecomputeResultPanel(session: session, store: store)
            }
        }
        .formStyle(.grouped)
        .task(id: resultSettingsRefreshKey) {
            guard isResult, let capture = resultSettingsCapture else {
                resultSettings.invalidate()
                return
            }
            await resultSettings.load(capture)
        }
        .onDisappear { resultSettings.invalidate() }
    }

    @ViewBuilder
    private func fields(in group: SourceEditorGroup, schema: SourceEditorSchema) -> some View {
        let groupFields = group.fields.compactMap { id in schema.fields.first { $0.id == id } }
            .filter(isVisible)
        let modeField = groupFields.first { $0.id == "ViewModel_SelectedPlan_TimeWindowMode" }
        let timeWindowFields = groupFields.filter(\.isTimeWindowField)
        let solverIndex = groupFields.firstIndex { $0.id == "ViewModel_SelectedPlan_SolverType" }
        let specialIDs = Set([modeField?.id].compactMap { $0 } + timeWindowFields.map(\.id))

        if let modeField {
            PlanTimeWindowModePickerPropertyItem(field: modeField, session: session, store: store)
        }
        if !timeWindowFields.isEmpty {
            SourceFieldRows(fields: timeWindowFields, session: session, store: store)
                .disabled(!customTimeWindowSelected)
        }
        if let solverIndex {
            let fieldsBeforeSolver = Array(groupFields[..<solverIndex]).filter { !specialIDs.contains($0.id) }
            if !fieldsBeforeSolver.isEmpty {
                SourceFieldRows(fields: fieldsBeforeSolver, session: session, store: store)
            }
            PlanSolverTypePresentation(field: groupFields[solverIndex], session: session, store: store)
            let fieldsAfterSolver = Array(groupFields.dropFirst(solverIndex + 1)).filter { !specialIDs.contains($0.id) }
            if !fieldsAfterSolver.isEmpty {
                SourceFieldRows(fields: fieldsAfterSolver, session: session, store: store)
            }
        } else {
            let remainingFields = groupFields.filter { !specialIDs.contains($0.id) }
            if !remainingFields.isEmpty {
                SourceFieldRows(fields: remainingFields, session: session, store: store)
            }
        }
    }

    private func isVisible(_ field: SourceEditorField) -> Bool {
        !field.visibleBy.contains { route in
            let value = session.fields[field.scoped(route)]?.lowercased()
            if route.contains("IsDebugMode") {
                return !store.isDebugMode && value != "visible" && value != "true"
            }
            return value == "collapsed" || value == "hidden" || value == "false"
        }
    }
}

struct PlanPrecomputeResultPanel: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @StateObject private var state = PlanPrecomputeState()

    private var isResult: Bool {
        session.fields["PlanSettingsPage/ViewModel_SelectedPlan_IsResult"]?.lowercased() == "true"
    }
    private var contextID: String? { session.currentPlanPrecomputeContext()?.id }
    private var associatedDraftsID: String {
        store.planPrecomputeAssociatedDraftsIdentity(for: session)
    }
    private var refreshKey: String {
        [store.projectSessionID.uuidString, session.id.uuidString,
         contextID ?? "unavailable", String(store.assetsRevision), associatedDraftsID].joined(separator: "|")
    }
    private var hasProvider: Bool { session.provider is any PlanPrecomputeProvider }
    private var currentResult: PlanPrecomputeResult? {
        guard let contextID, state.resultContextID == contextID,
              state.resultProjectSessionID == store.projectSessionID,
              state.resultAssociatedDraftsID == associatedDraftsID else { return nil }
        return state.result
    }

    var body: some View {
        Section("Precompute Result") {
            Button {
                state.refresh(session: session, store: store, force: true)
            } label: {
                Label("Refresh Precompute Result", systemImage: "arrow.clockwise")
            }
            .disabled(!hasProvider || contextID == nil || isResult || state.isRefreshing || store.isSavingAll || store.isClosingTab)
            .help("Checks the current plan draft and project association without saving.")

            if !hasProvider {
                Label("Plan precompute is unavailable from the active model service.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            } else if isResult {
                Label("Precompute checks are only available for source plans.", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            } else if state.isRefreshing {
                ProgressView("Checking plan…")
            } else if let error = state.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if let result = currentResult {
                PlanDiagnosticOperationResultView(result: result, store: store,
                    onNavigate: navigateToTarget, isTargetCurrent: diagnosticTargetIsCurrent,
                    onCompute: computeFromDiagnostic)
            } else {
                Label("Run the source plan check to see diagnostics.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: refreshKey) {
            guard !isResult else { return }
            state.refresh(session: session, store: store, force: true)
        }
        .onHover { isInside in
            guard isInside, !isResult else { return }
            state.refresh(session: session, store: store, force: true)
        }
        .onChange(of: contextID) { _, value in
            state.clearIfStale(currentContextID: value, currentAssociatedDraftsID: associatedDraftsID)
        }
        .onChange(of: associatedDraftsID) { _, value in
            state.clearIfStale(currentContextID: contextID, currentAssociatedDraftsID: value)
        }
        .onDisappear { state.clearIfStale(currentContextID: nil) }
    }

    private func navigateToTarget(_ target: PlanDiagnosticTarget) -> Bool {
        guard diagnosticTargetIsCurrent(target),
              let projectSessionID = state.resultProjectSessionID,
              let context = session.currentPlanPrecomputeContext() else { return false }
        return store.navigateToPlanDiagnosticTarget(target,
            projectSessionID: projectSessionID,
            planEditorID: session.id,
            planContextID: context.id)
    }

    private func diagnosticTargetIsCurrent(_ target: PlanDiagnosticTarget) -> Bool {
        guard let projectSessionID = state.resultProjectSessionID,
              projectSessionID == store.projectSessionID,
              let context = session.currentPlanPrecomputeContext(),
              context.id == contextID,
              state.resultContextID == context.id,
              session.isCurrentPlanPrecomputeContext(context.id),
              !store.isClosingTab else { return false }
        return store.isCurrentPlanDiagnosticTarget(target,
            projectSessionID: projectSessionID, planEditorID: session.id, planContextID: context.id)
    }

    private func computeFromDiagnostic(_ target: PlanDiagnosticTarget) async -> Bool {
        if target.kind == "geometry" {
            guard diagnosticTargetIsCurrent(target), let projectID = state.resultProjectSessionID,
                  let context = session.currentPlanPrecomputeContext() else { return false }
            return await store.requestGeometryPropertyTables(from: target, projectSessionID: projectID,
                planEditorID: session.id, planContextID: context.id)
        }
        guard target.kind == "plan", diagnosticTargetIsCurrent(target),
              session.availableOperations.contains(.compute), !session.isBusy,
              !store.isRunningProjectTool, !store.isSavingAll, !store.isClosingTab,
              await PlanDiagnosticFileFingerprint.matches(target),
              diagnosticTargetIsCurrent(target) else { return false }
        return await session.perform(.compute)
    }
}

struct PlanComputeSettingsPage: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore

    private var schema: SourceEditorSchema? { SourceEditorLibrary.shared.schema("PlanComputeSettingsPage") }
    private var isResult: Bool {
        session.fields["PlanComputeSettingsPage/ViewModel_SelectedPlan_IsResult"]?.lowercased() == "true"
    }
    var body: some View {
        Form {
            if let schema {
                ForEach(Array(schema.groups.enumerated()), id: \.offset) { _, group in
                    Section(LocalizedStringKey(group.title)) {
                        fields(in: group, schema: schema)
                    }
                    .disabled(isResult)
                }
            } else {
                Section { Label("Plan compute settings schema is unavailable", systemImage: "exclamationmark.triangle") }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func fields(in group: SourceEditorGroup, schema: SourceEditorSchema) -> some View {
        let fields = group.fields.compactMap { id in schema.fields.first { $0.id == id } }
            .filter(isVisible)
            .map(unitField)
        SourceFieldRows(fields: fields, session: session, store: store)
    }

    private func unitField(_ field: SourceEditorField) -> SourceEditorField {
        let labels: [String: String] = [
            "ViewModel_SelectedPlan_PartialGridElevationTolerance": "Partial Grid Elevation Tolerance",
            "ViewModel_SelectedPlan_VolumeTolerance": "Volume Tolerance",
            "ViewModel_SelectedPlan_VolumeMaxTolerance": "Volume Maximum Tolerance",
            "ViewModel_SelectedPlan_VolumeRMSTolerance": "Volume RMS Tolerance",
            "ViewModel_SelectedPlan_WaterSurfaceTolerance": "Water Surface Tolerance",
            "ViewModel_SelectedPlan_WaterSurfaceMaxTolerance": "Water Surface Maximum Tolerance",
            "ViewModel_SelectedPlan_WaterSurfaceRMSTolerance": "Water Surface RMS Tolerance"
        ]
        guard let label = labels[field.id] else { return field }
        guard let sourceTitle = session.fieldTitles[field.storageID],
              sourceTitle.hasPrefix(label + " ("), sourceTitle.hasSuffix(")") else {
            return field.titled(verbatim: L10n.text(label))
        }
        let unitStart = sourceTitle.index(sourceTitle.startIndex, offsetBy: (label + " (").count)
        let unitEnd = sourceTitle.index(before: sourceTitle.endIndex)
        let lengthUnit = String(sourceTitle[unitStart..<unitEnd])
        guard lengthUnit == "ft" || lengthUnit == "m" else { return field.titled(verbatim: L10n.text(label)) }
        return field.titled(verbatim: "\(L10n.text(label)) (\(lengthUnit))")
    }

    private func isVisible(_ field: SourceEditorField) -> Bool {
        !field.visibleBy.contains { route in
            let value = session.fields[field.scoped(route)]?.lowercased()
            if route.contains("IsDebugMode") {
                return !store.isDebugMode && value != "visible" && value != "true"
            }
            return value == "collapsed" || value == "hidden" || value == "false"
        }
    }
}

struct PlanSolverTypePresentation: View {
    let field: SourceEditorField
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore

    private var selectedSolver: String { session.fields[field.storageID] ?? "" }
    private var choices: [EditorChoice] {
        session.choiceOptions[field.storageID] ?? field.choices
    }
    private var selectedChoice: EditorChoice? {
        choices.first { $0.id == selectedSolver }
    }
    private var description: String? {
        guard let sourceDescription = selectedChoice?.description else {
            return selectedSolver == "CPU" ? L10n.text("Use the explicit CPU solver") : nil
        }
        let gpuDevicePrefix = "Use the explicit GPU solver with device: "
        if selectedSolver == "GPU", sourceDescription.hasPrefix(gpuDevicePrefix) {
            let device = String(sourceDescription.dropFirst(gpuDevicePrefix.count))
            return L10n.format("Use the explicit GPU solver with device: %@", device)
        }
        return L10n.text(sourceDescription)
    }
    private var iconSystemName: String? {
        switch selectedChoice?.sourceIcon {
        case "CPUColored1": "cpu"
        case "GPUColored": "memorychip"
        default:
            switch selectedSolver {
            case "CPU": "cpu"
            case "GPU": "memorychip"
            default: nil
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            OriginalChoicePropertyItem(field: field, choices: choices, session: session, store: store)
            if let description {
                Label {
                    Text(verbatim: description)
                } icon: {
                    Image(systemName: iconSystemName ?? "info.circle")
                }
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PlanAssociationsPicker: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    var isReadOnly = false

    private var plan: ProjectAsset? { store.assets.first { $0.id == session.modelAssetID } }
    private var associationExists: Bool {
        guard let plan else { return false }
        return store.document?.associationRows(group: "PlanAssociations").contains { $0.name == plan.name } == true
    }
    private func associationValue(_ field: String) -> String? {
        guard let plan else { return nil }
        return store.document?.associationRows(group: "PlanAssociations")
            .first { $0.name == plan.name }?.fields[field]
    }

    var body: some View {
        if plan != nil, associationExists, isReadOnly {
            LabeledContent("Geometry", value: associationValue("Geometry") ?? "—")
                .textSelection(.enabled)
            LabeledContent("Boundary Condition", value: associationValue("BoundaryCondition") ?? "—")
                .textSelection(.enabled)
        } else if let plan, associationExists {
            PlanAssociationHeader(store: store, plan: plan)
                .disabled(store.isSavingAll || store.isClosingTab)
        } else if plan != nil {
            Label("Plan associations are unavailable in the current project document.", systemImage: "link.badge.plus")
                .foregroundStyle(.secondary)
        } else {
            Label("Select a plan to edit its associations.", systemImage: "link")
                .foregroundStyle(.secondary)
        }
    }
}

struct PlanNodeDetails: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        if let results = session.planResults {
            PlanResultPicker(results: results, session: session, store: store)
        } else {
            Text("No matching results are available.").foregroundStyle(.secondary)
        }
    }
}

struct PlanTimeWindowModePicker: View {
    let field: SourceEditorField
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore

    private var choices: [EditorChoice] {
        (session.choiceOptions[field.storageID] ?? field.choices)
            .filter { store.isDebugMode || $0.debugOnly != true }
    }
    private var isDisabled: Bool {
        !session.canEdit || field.readOnly || session.readOnlyFieldIDs.contains(field.storageID) ||
        session.fields[field.storageID] == nil || choices.isEmpty || session.isBusy ||
        session.loadingSelection || store.isSavingAll
    }

    var body: some View {
        Picker(LocalizedStringKey(field.title), selection: Binding(
            get: { session.fields[field.storageID] ?? "" },
            set: { session.set(field.storageID, $0) }
        )) {
            ForEach(choices) { option in
                Text(option.titleIsUserData == true ? option.title : L10n.text(option.title)).tag(option.id)
            }
            if let current = session.fields[field.storageID], !current.isEmpty,
               !choices.contains(where: { $0.id == current }) {
                Text(current).tag(current)
            }
        }
        .pickerStyle(.menu)
        .accessibilityLabel(LocalizedStringKey(field.title))
        .help(L10n.text(field.help))
        .disabled(isDisabled)
    }
}

struct PlanTimeWindowModePickerPropertyItem: View {
    let field: SourceEditorField
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        PlanTimeWindowModePicker(field: field, session: session, store: store)
    }
}

// ComputeButton opens the active job/result view. Starting a calculation stays
// on the explicit Compute action in the shared model-editor workspace.
struct ComputeButton: View {
    @ObservedObject var session: ModelEditorSession
    let openComputeLog: (() -> Void)?

    private var hasComputeRecord: Bool {
        let jobID = session.fields["Job_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let summaryKeys = ["ComputeSummary_Success", "ComputeSummary_StartTime", "ComputeSummary_Solver"]
        return session.planCompute?.isRunning == true || session.planCompute?.result != nil
            || !jobID.isEmpty || summaryKeys.contains { session.fields[$0] != nil }
    }
    private var isRunning: Bool { session.planCompute?.isRunning == true || session.fields["IsComputeRunning"]?.lowercased() == "true" }

    var body: some View {
        Button(action: { openComputeLog?() }) {
            Label(LocalizedStringKey(isRunning ? "Open Running Compute" : "Open Compute Log"), systemImage: "text.alignleft")
        }
        .disabled(!hasComputeRecord || openComputeLog == nil)
        .help("Open the selected plan’s active compute log and result.")
    }
}
