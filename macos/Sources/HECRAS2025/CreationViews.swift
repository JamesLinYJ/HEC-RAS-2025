import SwiftUI

struct CreationTimeWindow: Sendable {
    let start: Date
    let end: Date
}
struct CreationPresentation: Sendable {
    var boundaryTimeWindows: [String: CreationTimeWindow] = [:]
    var directory: URL? = nil
    var validationMessage: String? = nil
    var warning: String? = nil
}

enum CreationDefaults {
    static func fields(kind: ToolKind, timeZone: TimeZone = .current) -> [String: String] {
        guard kind == .newBoundary || kind == .newPlan else { return [:] }
        let year = kind == .newBoundary ? 1900 : 2000
        let schema = kind == .newBoundary ? "NewBoundaryConditionControl" : "NewPlanControl"
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = calendar.date(from: DateComponents(year: year, month: 1, day: 2)) else { return [:] }
        var fields = [schema + "/StartTime": ISO8601DateFormatter().string(from: start), schema + "/EndTime": ISO8601DateFormatter().string(from: end)]
        if kind == .newPlan { fields[schema + "/TimeWindowMode"] = "BoundaryCondition" }
        return fields
    }
}

// The dialog wrappers contain these controls; their duplicated dependency
// properties are not another set of independently editable dates.
struct CreationToolContent: View {
    @ObservedObject var store: WorkspaceStore
    let kind: ToolKind
    @ObservedObject var state: DataToolSession
    @ObservedObject var editor: ModelEditorSession
    @FocusState private var nameFocused: Bool
    private var source: CreationPresentation { state.presentation.creation ?? .init() }
    private let boundaryConditionKey = "NewPlanControl/SelectedBoundaryCondition"
    private var boundaryID: String { editor.fields[boundaryConditionKey] ?? "" }
    private var inherited: Bool { editor.fields["NewPlanControl/TimeWindowMode"] != "Plan" }
    var body: some View {
        Form {
            switch kind {
            case .newGeometry:
                Section("Geometry Information") {
                    name("Geometry Name", key: "NewGeometryControl/GeometryName")
                    association("Selected Terrain", key: "NewGeometryControl/SelectedTerrain", optional: true)
                    association("Selected N Value", key: "NewGeometryControl/SelectedNValue", optional: true)
                }
            case .newPlan:
                Section("Plan Information") {
                    name("Plan Name", key: "NewPlanControl/PlanName")
                    association("Geometry", key: "NewPlanControl/SelectedGeometry", optional: false)
                    boundaryConditionPicker
                }
                Section("Time Window") {
                    Picker("Mode", selection: text("NewPlanControl/TimeWindowMode", fallback: "BoundaryCondition")) {
                        Text("Boundary Condition").tag("BoundaryCondition"); Text("Custom").tag("Plan")
                    }
                    Text(inherited ? L10n.text("Inherit the time window from the boundary condition.") : L10n.text("Enter a custom time window. Cannot exceed boundary condition time window."))
                        .font(.caption).foregroundStyle(.secondary)
                    date("Start Time", key: "NewPlanControl/StartTime").disabled(inherited)
                    date("End Time", key: "NewPlanControl/EndTime").disabled(inherited)
                }
            case .newBoundary:
                Section("New Boundary Condition") { name("Boundary Condition Name", key: "NewBoundaryConditionControl/BoundaryConditionName") }
                Section("Time Window") {
                    date("Start Time", key: "NewBoundaryConditionControl/StartTime")
                    date("End Time", key: "NewBoundaryConditionControl/EndTime")
                }
            case .newShapefile:
                Section("New Shapefile") {
                    Picker("Type", selection: text("NewShapefileDialog/ViewModel_SelectedType", fallback: "Point")) {
                        Text("Point").tag("Point"); Text("Line").tag("Line"); Text("Polygon").tag("Polygon")
                    }
                    TextField("File Name", text: text("NewShapefileDialog/ViewModel_FileName")).focused($nameFocused)
                    LabeledContent("Folder") {
                        Text(state.destination?.path ?? source.directory?.path ?? "—").textSelection(.enabled).lineLimit(3)
                        Button("Choose Folder…") { if let folder = store.system.chooseFolder(title: "New Shapefile") { state.destination = folder } }
                    }
                }
            default: EmptyView()
            }
            if let message = source.validationMessage, !message.isEmpty { Section { Text(message).textSelection(.enabled).foregroundStyle(.orange) } }
            if let warning = source.warning, !warning.isEmpty { Section { Label(warning, systemImage: "exclamationmark.triangle").textSelection(.enabled).foregroundStyle(.orange) } }
        }.formStyle(.grouped).disabled(!editor.canEdit)
        .onAppear { nameFocused = true }
        .onChange(of: boundaryID) { _, _ in inheritWindow() }
        .onChange(of: inherited) { _, _ in inheritWindow() }
        .onChange(of: source.boundaryTimeWindows[boundaryID]?.start) { _, _ in inheritWindow() }
        .onChange(of: source.boundaryTimeWindows[boundaryID]?.end) { _, _ in inheritWindow() }
    }
    private func name(_ title: String, key: String) -> some View {
        TextField(LocalizedStringKey(title), text: text(key)).focused($nameFocused)
    }
    private func association(_ title: String, key: String, optional: Bool) -> some View {
        Picker(LocalizedStringKey(title), selection: text(key)) {
            Text(optional ? "(No Association)" : "None").tag("")
            ForEach(editor.choiceOptions[key] ?? []) { choice in Text(choice.title).tag(choice.id) }
        }
    }
    private var boundaryConditionPicker: some View {
        let selectedAsset = store.assets.first(where: { $0.id == boundaryID && $0.section == .boundaryConditions })
        return BoundaryConditionPickerControl(
            choices: editor.choiceOptions[boundaryConditionKey] ?? [],
            selection: text(boundaryConditionKey),
            selectionIsUninitialized: editor.fields[boundaryConditionKey] == nil,
            isEnabled: editor.canEdit,
            openEditor: selectedAsset.map { asset in
                { store.openEditor(.boundaryCondition, assetID: asset.id) }
            }
        )
    }
    @ViewBuilder private func date(_ title: String, key: String) -> some View {
        if let value = editor.fields[key], let parsed = Self.parseDate(value) {
            DatePicker(LocalizedStringKey(title), selection: Binding(get: { Self.parseDate(editor.fields[key] ?? "") ?? parsed }, set: { editor.set(key, ISO8601DateFormatter().string(from: $0)) }), displayedComponents: [.date, .hourAndMinute])
        } else { LabeledContent(LocalizedStringKey(title), value: "—") }
    }
    private func text(_ key: String, fallback: String = "") -> Binding<String> { Binding(get: { editor.fields[key] ?? fallback }, set: { editor.set(key, $0) }) }
    private func inheritWindow() {
        guard kind == .newPlan, inherited, let window = source.boundaryTimeWindows[boundaryID] else { return }
        editor.set("NewPlanControl/StartTime", ISO8601DateFormatter().string(from: window.start))
        editor.set("NewPlanControl/EndTime", ISO8601DateFormatter().string(from: window.end))
    }
    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
}

/// Native name-only dialogs for the retained Add Terrain, Add Classification
/// Layer, and Add N-Value Layer actions. The backend creates and validates the
/// actual source HDF file; this view never treats a local draft as success.
struct SurfaceCreationDialog: View {
    let kind: SurfaceCreationKind
    let projectSessionID: UUID
    let projectPath: String
    let coreLayerContext: CoreLayerRequestContext?
    let projectXML: @MainActor () -> String
    let currentProjectSessionID: @MainActor () -> UUID
    let currentCoreLayerContext: @MainActor () -> CoreLayerRequestContext?
    let provider: any SurfaceCreationProvider
    let onRunningChanged: @MainActor (Bool) -> Void
    let onCreated: @MainActor (SurfaceCreationResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var inspection: SurfaceCreationInspection?
    @State private var inspectedRequest: SurfaceCreationRequestIdentity?
    @State private var requestSequence = 0
    @State private var isInspecting = false
    @State private var isCreating = false
    @State private var errorMessage: String?

    private var documentIdentity: SurfaceCreationDocumentIdentity {
        SurfaceCreationDocumentIdentity(projectSessionID: projectSessionID, projectPath: projectPath,
            projectXML: projectXML(), coreLayerContext: coreLayerContext)
    }
    private var currentRequestIdentity: SurfaceCreationRequestIdentity {
        SurfaceCreationRequestIdentity(document: documentIdentity, kind: kind, name: name)
    }
    private var canCreate: Bool {
        currentProjectSessionID() == projectSessionID && !isInspecting && !isCreating
            && inspection?.canExecute == true && inspectedRequest == currentRequestIdentity
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L10n.text(kind.title), systemImage: kind.section.symbol)
                .font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: nameBinding)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isCreating)
                LabeledContent("Folder") {
                    Text(inspection?.targetDirectory ?? "—")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                if isInspecting { ProgressView("Checking name…").controlSize(.small) }
                if let message = inspection?.validationMessage, !name.isEmpty {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "xmark.octagon.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCreating)
                Spacer()
                Button {
                    Task { await create() }
                } label: {
                    if isCreating { ProgressView().controlSize(.small) }
                    else { Text("Create") }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(minWidth: 430, idealWidth: 500)
        .interactiveDismissDisabled(isCreating)
        .task(id: SurfaceCreationPresentationIdentity(document: documentIdentity,
            activeProjectSessionID: currentProjectSessionID())) {
            await loadSuggestedName(for: documentIdentity)
        }
    }

    private var nameBinding: Binding<String> {
        Binding(get: { name }, set: { value in
            name = value
            inspection = nil
            inspectedRequest = nil
            errorMessage = nil
            let identity = documentIdentity
            Task { @MainActor in await inspect(name: value, for: identity) }
        })
    }

    @MainActor private func loadSuggestedName(for identity: SurfaceCreationDocumentIdentity) async {
        requestSequence += 1
        let sequence = requestSequence
        inspection = nil
        inspectedRequest = nil
        errorMessage = nil
        isInspecting = true
        defer { if requestSequence == sequence { isInspecting = false } }
        do {
            let initial = try await provider.inspect(makeRequest(name: "", identity: identity))
            guard isCurrent(identity, sequence: sequence) else { return }
            let candidate = name.isEmpty ? initial.suggestedName : name
            name = candidate
            await inspect(name: candidate, for: identity)
        } catch is CancellationError {
            return
        } catch {
            if isCurrent(identity, sequence: sequence) { errorMessage = error.localizedDescription }
        }
    }

    @MainActor private func inspect(name candidate: String, for identity: SurfaceCreationDocumentIdentity) async {
        guard identity == documentIdentity, candidate == name else { return }
        requestSequence += 1
        let sequence = requestSequence
        let requestIdentity = SurfaceCreationRequestIdentity(document: identity, kind: kind, name: candidate)
        isInspecting = true
        inspection = nil
        inspectedRequest = nil
        defer { if requestSequence == sequence { isInspecting = false } }
        do {
            let result = try await provider.inspect(makeRequest(name: candidate, identity: identity))
            guard isCurrent(identity, sequence: sequence), candidate == name else { return }
            inspection = result
            inspectedRequest = requestIdentity
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            if isCurrent(identity, sequence: sequence), candidate == name { errorMessage = error.localizedDescription }
        }
    }

    @MainActor private func create() async {
        guard canCreate, let inspection else { return }
        let identity = currentRequestIdentity
        guard identityIsCurrent(identity.document) else { return }
        isCreating = true
        onRunningChanged(true)
        errorMessage = nil
        defer { isCreating = false; onRunningChanged(false) }
        do {
            let request = makeRequest(name: identity.name, identity: identity.document, revision: inspection.revision)
            let result = try await provider.create(request)
            // The backend published from the validated draft captured above.
            // An unrelated edit in the same open project does not make that
            // newly created file disappear or require creating it a second time.
            guard currentProjectSessionID() == identity.document.projectSessionID else {
                errorMessage = L10n.text("The active project changed. Reopen its creation dialog to add the created file.")
                return
            }
            onCreated(result)
            dismiss()
        } catch is CancellationError {
            return
        } catch {
            let failureMessage = error.localizedDescription
            await inspect(name: name, for: documentIdentity)
            if identityIsCurrent(documentIdentity) { errorMessage = failureMessage }
        }
    }

    @MainActor private func makeRequest(name: String, identity: SurfaceCreationDocumentIdentity,
                                        revision: String? = nil) -> SurfaceCreationRequest {
        SurfaceCreationRequest(kind: kind, projectPath: identity.projectPath,
            projectXml: identity.projectXML, name: name, revision: revision,
            coreLayerContext: identity.coreLayerContext)
    }

    @MainActor private func isCurrent(_ identity: SurfaceCreationDocumentIdentity, sequence: Int) -> Bool {
        !Task.isCancelled && identityIsCurrent(identity) && sequence == requestSequence
    }

    @MainActor private func identityIsCurrent(_ identity: SurfaceCreationDocumentIdentity) -> Bool {
        identity == documentIdentity && currentProjectSessionID() == identity.projectSessionID
            && currentCoreLayerContext() == identity.coreLayerContext
    }
}

private struct SurfaceCreationDocumentIdentity: Hashable {
    let projectSessionID: UUID
    let projectPath: String
    let projectXML: String
    let coreLayerContext: CoreLayerRequestContext?
}

private struct SurfaceCreationRequestIdentity: Equatable {
    let document: SurfaceCreationDocumentIdentity
    let kind: SurfaceCreationKind
    let name: String
}

private struct SurfaceCreationPresentationIdentity: Hashable {
    let document: SurfaceCreationDocumentIdentity
    let activeProjectSessionID: UUID
}
