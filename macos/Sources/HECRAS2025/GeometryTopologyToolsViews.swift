import RASWorkspaceCore
import SwiftUI

enum GeometryTopologyToolPanel: String, CaseIterable, Identifiable {
    case factor
    case recipe
    case arcPoints
    case tagFilter
    case vectorImport

    var id: String { rawValue }

    @MainActor var title: String {
        switch self {
        case .factor: L10n.text("Global Factor")
        case .recipe: L10n.text("Recipe Builder")
        case .arcPoints: L10n.text("Arc Points")
        case .tagFilter: L10n.text("Tag Filter")
        case .vectorImport: L10n.text("Import Vector Lines")
        }
    }

    var symbol: String {
        switch self {
        case .factor: "arrow.up.left.and.arrow.down.right"
        case .recipe: "list.bullet.rectangle.portrait"
        case .arcPoints: "point.topleft.down.to.point.bottomright.curvepath"
        case .tagFilter: "line.3.horizontal.decrease"
        case .vectorImport: "square.and.arrow.down"
        }
    }
}

struct GeometryTopologyToolsMenu: View {
    @Binding var selection: GeometryTopologyToolPanel?
    let availableTools: [GeometryTopologyToolPanel]

    var body: some View {
        Menu {
            ForEach(availableTools) { tool in
                Button {
                    selection = tool
                } label: {
                    Label(tool.title, systemImage: tool.symbol)
                }
            }
            if selection != nil {
                Divider()
                Button(L10n.text("Close Tool"), systemImage: "xmark") {
                    selection = nil
                }
            }
        } label: {
            Label(L10n.text("Topology Tools"), systemImage: "wrench.and.screwdriver")
        }
        .menuStyle(.borderlessButton)
    }
}

struct GeometryTopologyFactorToolView: View {
    @ObservedObject var session: GeometryTopologySession
    @State private var selectedOnly = false
    @State private var factorText = "2"

    private var selectedArcCount: Int { session.selectedRows(for: "arc").count }
    private var selectedControlPointCount: Int { session.selectedRows(for: "region").count }
    private var selectedCount: Int { selectedArcCount + selectedControlPointCount }

    private let presets = ["0.25", "0.5", "2", "4"]

    var body: some View {
        GroupBox {
            Form {
                Picker(L10n.text("Apply To"), selection: $selectedOnly) {
                    Text(L10n.text("All Features")).tag(false)
                    Text(L10n.text("Selected Only")).tag(true)
                }
                .pickerStyle(.segmented)

                LabeledContent(L10n.text("Selected Arcs"), value: selectedArcCount.formatted())
                LabeledContent(L10n.text("Selected Control Points"), value: selectedControlPointCount.formatted())

                Section(L10n.text("Preset Factors")) {
                    HStack {
                        ForEach(presets, id: \.self) { value in
                            Button("\(value)×") {
                                factorText = value
                                apply(value)
                            }
                            .buttonStyle(.bordered)
                            .disabled(!canApply)
                        }
                    }
                }

                Section(L10n.text("Custom Factor")) {
                    HStack {
                        TextField(L10n.text("Factor"), text: $factorText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 180)
                            .onSubmit { apply(factorText) }
                        Button(L10n.text("Apply Factor"), systemImage: "checkmark") {
                            apply(factorText)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canApply || factorText.isEmpty)
                    }
                }

                if selectedOnly && selectedCount == 0 {
                    Label(L10n.text("Select arcs or control points to apply a factor."), systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(!session.canMutateTopology || session.isLoading || session.parentSaveInProgress)
        } label: {
            Label(L10n.text("Global Factor"), systemImage: "arrow.up.left.and.arrow.down.right")
                .font(.headline)
        }
    }

    private var canApply: Bool {
        session.canMutateTopology && !session.isLoading && !session.parentSaveInProgress
            && (!selectedOnly || selectedCount > 0)
    }

    private func apply(_ value: String) {
        guard canApply, !value.isEmpty else { return }
        Task { await session.applyFactor(factorText: value, selectedOnly: selectedOnly) }
    }
}

private enum GeometryTopologyRecipeEditingMode: String, CaseIterable, Identifiable {
    case raw
    case structured
    var id: String { rawValue }
    @MainActor var title: String { L10n.text(rawValue == "raw" ? "Raw Recipe" : "Structured Recipe") }
}

private struct GeometryTopologyRecipeStepDraft: Identifiable {
    let id: UUID
    var name: String
    var parameters: [String: String]

    init(id: UUID = UUID(), name: String, parameters: [String: String]) {
        self.id = id
        self.name = name
        self.parameters = parameters
    }
}

/// Uses only the retained parser's step schema. Invalid raw input remains in
/// the session buffer; structured controls are enabled only for the exact
/// successfully inspected text.
struct GeometryTopologyRecipeToolView: View {
    @ObservedObject var session: GeometryTopologySession
    let selectedControlPointFIDs: [Int]
    @State private var mode: GeometryTopologyRecipeEditingMode = .raw
    @State private var stepDrafts: [GeometryTopologyRecipeStepDraft] = []
    @State private var newStepName = ""
    @State private var hydratedRecipeIdentity: String?
    @State private var structuredDraftText: String?
    @State private var structuredDraftOwnerIdentity: String?
    @State private var lastParsedRecipe: GeometryTopologyRecipeSnapshot?

    private var editorState: GeometryTopologyRecipeEditorState? { session.recipeEditorState }
    private var inspection: GeometryTopologyRecipeSnapshot? { editorState?.inspection }
    private var currentText: String { editorState?.rawText ?? "" }
    private var selectionIsCurrent: Bool { editorState?.controlPointFIDs == selectedControlPointFIDs }
    private var recipeEditorOwnerIdentity: String {
        "\(session.mapAssetIdentity ?? "")|\(editorState?.sourceRevision ?? "")|\(editorState?.draftIdentity ?? "")|\(editorState?.controlPointFIDs.map(String.init).joined(separator: ",") ?? "")"
    }
    private var recipeInspectionIdentity: String? {
        guard let inspection else { return nil }
        return "\(session.mapAssetIdentity ?? "")|\(inspection.revision)|\(inspection.draftIdentity)|\(inspection.controlPointFIDs.map(String.init).joined(separator: ","))|\(inspection.rawText)"
    }
    private var parsedTextIsCurrent: Bool {
        guard let inspection, selectionIsCurrent else { return false }
        return inspection.rawText == currentText && inspection.controlPointFIDs == selectedControlPointFIDs
    }
    private var inspectionIsCurrent: Bool {
        guard let inspection, let snapshot = session.snapshot else { return false }
        return inspection.revision == snapshot.revision
            && inspection.draftIdentity == GeometryTopologyCompletionResult.draftIdentity(for: snapshot.draftState)
    }
    private var containsDefaultRecipeStep: Bool {
        if let parsed = try? RecipeDocument.parse(currentText, commands: RecipeLibrary.commands) {
            return parsed.contains { $0.command == "Default" }
        }
        return currentText.range(of: #"\bDefault\s*\("#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    private var selectedMeshType: String? {
        let supported: Set<String> = ["Quad", "TrianglePaver", "Cartesian", "OneD", "Empty"]
        guard inspectionIsCurrent, let inspection,
              inspection.controlPointFIDs == selectedControlPointFIDs,
              let patchTypes = inspection.selectedPatchTypes,
              patchTypes.count == selectedControlPointFIDs.count,
              !patchTypes.isEmpty, patchTypes.allSatisfy(supported.contains),
              Set(patchTypes).count == 1 else { return nil }
        return patchTypes[0]
    }
    private var unresolvedDefaultRecipe: Bool { containsDefaultRecipeStep && selectedMeshType == nil }
    private var resolvedStepsForDisplay: [GeometryTopologyRecipeStep]? {
        guard let inspection else { return nil }
        guard containsDefaultRecipeStep else { return inspection.steps }
        guard let meshType = selectedMeshType,
              let parsed = try? RecipeDocument.parse(inspection.rawText,
                commands: RecipeLibrary.commands, meshType: meshType) else { return nil }
        return parsed.map { GeometryTopologyRecipeStep(name: $0.command, parameters: $0.values) }
    }
    private var structuredDraftIsCurrent: Bool {
        selectionIsCurrent && structuredDraftOwnerIdentity == recipeEditorOwnerIdentity
            && structuredDraftText == currentText
    }
    private var canUseStructuredEditor: Bool {
        !unresolvedDefaultRecipe && ((parsedTextIsCurrent && inspection?.isValid == true && inspectionIsCurrent)
            || (structuredDraftIsCurrent && inspectionIsCurrent))
    }
    private var structuredSchemaSnapshot: GeometryTopologyRecipeSnapshot? {
        if parsedTextIsCurrent, inspection?.isValid == true, inspectionIsCurrent { return inspection }
        return structuredDraftIsCurrent && lastParsedRecipe?.revision == session.snapshot?.revision ? lastParsedRecipe : nil
    }
    private var hasPendingArcInput: Bool { session.pendingArcPointInput != nil }
    private var canEdit: Bool {
        session.canEdit && !session.isEditing && !session.isLoading && !session.parentSaveInProgress
            && !hasPendingArcInput && selectionIsCurrent
            && (editorState?.isInspecting != true || editorState?.isPending == true || structuredDraftIsCurrent)
    }
    private var canApply: Bool {
        canEdit && !selectedControlPointFIDs.isEmpty && parsedTextIsCurrent
            && (editorState?.isPending == true || inspection?.hasMismatch == true)
            && editorState?.isInspecting != true
    }
    private var inspectionIdentity: String {
        "\(session.mapAssetIdentity ?? "")|\(inspection?.revision ?? "")|\(inspection?.draftIdentity ?? "")|\(inspection?.rawText ?? "")|\(selectedControlPointFIDs.map(String.init).joined(separator: ","))"
    }
    private var inputIdentity: String {
        "\(editorState?.sourceRevision ?? "")|\(editorState?.draftIdentity ?? "")|\(currentText)|\(selectedControlPointFIDs.map(String.init).joined(separator: ","))"
    }
    private var recipeLoadIdentity: String {
        let snapshotIdentity = session.snapshot.map {
            "\($0.revision)|\(GeometryTopologyCompletionResult.draftIdentity(for: $0.draftState))"
        } ?? ""
        return "\(session.mapAssetIdentity ?? "")|\(snapshotIdentity)|\(selectedControlPointFIDs.map(String.init).joined(separator: ","))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent(L10n.text("Selected Control Points"), value: selectedControlPointFIDs.count.formatted())
                        if selectedControlPointFIDs.isEmpty {
                            Label(L10n.text("Select control points in the table or map to edit a recipe."), systemImage: "info.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if inspection?.hasMismatch == true {
                            Label(L10n.text("Selected control points have different recipes."), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        } else if inspection?.hasSelection != true {
                            Label(L10n.text("Recipe selection is unavailable."), systemImage: "questionmark.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                } label: {
                    Label(L10n.text("Recipe Selection"), systemImage: "point.3.connected.trianglepath.dotted")
                }

                Picker(L10n.text("Editor Mode"), selection: $mode) {
                    Text(GeometryTopologyRecipeEditingMode.raw.title).tag(GeometryTopologyRecipeEditingMode.raw)
                    Text(GeometryTopologyRecipeEditingMode.structured.title)
                        .tag(GeometryTopologyRecipeEditingMode.structured)
                        .disabled(!canUseStructuredEditor)
                }
                .pickerStyle(.segmented)

                if mode == .raw {
                    rawEditor
                } else {
                    structuredEditor
                }

                if let parseIssue = inspection?.parseIssue, !parseIssue.isEmpty {
                    Label(parseIssue, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                if parsedTextIsCurrent, inspection?.isValid == false {
                    Label(L10n.text("This recipe is invalid. Applying it will store the text as entered."),
                          systemImage: "text.alignleft")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if editorState?.isPending == true {
                    Label(L10n.text("Recipe input has not been applied to the topology draft."),
                          systemImage: "pencil.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if hasPendingArcInput {
                    Label(L10n.text("Apply or discard the pending arc coordinate before editing a recipe."),
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let error = editorState?.error, !error.isEmpty {
                    Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }

                HStack {
                    Button(L10n.text("Restore Last Valid Recipe"), systemImage: "arrow.uturn.backward") {
                        _ = session.restoreLastValidRecipe(controlPointFIDs: selectedControlPointFIDs)
                    }
                    .disabled(!canEdit || selectedControlPointFIDs.isEmpty || editorState?.lastValidText == nil)
                    if editorState?.isPending == true {
                        Button(L10n.text("Discard Recipe Input"), systemImage: "xmark.circle") {
                            session.discardPendingInputs()
                            if !selectedControlPointFIDs.isEmpty {
                                Task { await session.loadRecipe(controlPointFIDs: selectedControlPointFIDs) }
                            }
                        }
                        .disabled(session.isEditing || session.isLoading || session.parentSaveInProgress)
                    }
                    Spacer()
                    Button(recipeApplyTitle, systemImage: "checkmark") {
                        Task { await session.applyRecipe(controlPointFIDs: selectedControlPointFIDs,
                            forceSet: inspection?.hasMismatch == true) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canApply)
                }
            }
            .padding(14)
        }
        .background(.background)
        .task(id: recipeLoadIdentity) {
            guard !selectedControlPointFIDs.isEmpty,
                  editorState?.controlPointFIDs != selectedControlPointFIDs
                    || editorState?.sourceRevision != session.snapshot?.revision
                    || editorState?.draftIdentity != session.snapshot.map({ GeometryTopologyCompletionResult.draftIdentity(for: $0.draftState) }) else { return }
            await session.loadRecipe(controlPointFIDs: selectedControlPointFIDs)
        }
        .task(id: inputIdentity) {
            guard selectionIsCurrent, !selectedControlPointFIDs.isEmpty,
                  editorState?.isInspecting != true,
                  editorState?.inspection?.rawText != currentText,
                  editorState?.rawText == currentText else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await session.inspectRecipe(controlPointFIDs: selectedControlPointFIDs, rawText: currentText)
        }
        .onChange(of: inspectionIdentity) { _, _ in hydrateStructuredStepsIfCurrent() }
    }

    private var rawEditor: some View {
        GroupBox(L10n.text("Raw Recipe")) {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: Binding(get: { currentText }, set: {
                    _ = session.updateRecipeInput($0, controlPointFIDs: selectedControlPointFIDs)
                }))
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 145)
                .disabled(!canEdit || selectedControlPointFIDs.isEmpty)
                HStack {
                    if editorState?.isInspecting == true {
                        ProgressView().controlSize(.small)
                    } else if parsedTextIsCurrent {
                        Label(inspection?.isValid == true ? L10n.text("Recipe is valid") : L10n.text("Recipe is invalid"),
                              systemImage: inspection?.isValid == true ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(inspection?.isValid == true ? .green : .red)
                    } else {
                        Label(L10n.text("Checking recipe…"), systemImage: "clock")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L10n.text("Inspect Recipe"), systemImage: "checkmark.magnifyingglass") {
                        Task { await session.inspectRecipe(controlPointFIDs: selectedControlPointFIDs, rawText: currentText) }
                    }
                    .disabled(!canEdit || selectedControlPointFIDs.isEmpty || editorState?.isInspecting == true)
                }
            }
        }
    }

    private var recipeApplyTitle: String {
        if inspection?.hasMismatch == true {
            return L10n.text(inspection?.isValid == false ? "Force Set Raw Recipe" : "Force Set Recipe")
        }
        return L10n.text(inspection?.isValid == false ? "Save Raw Recipe" : "Apply Recipe")
    }

    private var structuredEditor: some View {
        GroupBox(L10n.text("Structured Recipe")) {
            VStack(alignment: .leading, spacing: 10) {
                if canUseStructuredEditor, let schemaSnapshot = structuredSchemaSnapshot {
                    if parsedTextIsCurrent, inspection?.isValid == false {
                        Label(L10n.text("The current structured text has a parse issue. Keep editing or switch to Raw Recipe."),
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if stepDrafts.isEmpty {
                        ContentUnavailableView(L10n.text("No Recipe Steps"), systemImage: "list.bullet.rectangle",
                            description: Text(L10n.text("Add a recipe step to begin.")))
                            .frame(minHeight: 120)
                    } else {
                        ForEach(Array(stepDrafts.indices), id: \.self) { index in
                            recipeStepCard(at: index)
                        }
                    }
                    HStack {
                        Picker(L10n.text("Recipe Step"), selection: $newStepName) {
                            ForEach(schemaSnapshot.stepSchema, id: \.name) { schema in
                                Text(schema.name).tag(schema.name)
                            }
                        }
                        .frame(maxWidth: 230)
                        Button(L10n.text("Add Step"), systemImage: "plus") { addStep() }
                            .disabled(!canEditStructured || newStepName.isEmpty)
                        Spacer()
                    }
                    .disabled(!canEditStructured)
                } else {
                    Label(L10n.text(unresolvedDefaultRecipe
                        ? "Select control points with one cell type to resolve Default()."
                        : "Inspect a valid recipe before editing its steps."), systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear(perform: hydrateStructuredStepsIfCurrent)
    }

    private func recipeStepCard(at index: Int) -> some View {
        let step = stepDrafts[index]
        let schema = structuredSchemaSnapshot?.stepSchema.first { $0.name == step.name || $0.aliases.contains(step.name) }
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(step.name).font(.headline)
                    Spacer()
                    Button(L10n.text("Move Up"), systemImage: "arrow.up") { moveStep(index, by: -1) }
                        .labelStyle(.iconOnly).disabled(index == 0 || !canEditStructured)
                    Button(L10n.text("Move Down"), systemImage: "arrow.down") { moveStep(index, by: 1) }
                        .labelStyle(.iconOnly).disabled(index + 1 >= stepDrafts.count || !canEditStructured)
                    Button(L10n.text("Remove Step"), systemImage: "trash") { removeStep(index) }
                        .labelStyle(.iconOnly).disabled(!canEditStructured)
                }
                if let schema {
                    ForEach(schema.parameters, id: \.name) { parameter in
                        parameterEditor(stepIndex: index, parameter: parameter)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func parameterEditor(stepIndex: Int, parameter: GeometryTopologyRecipeParameter) -> some View {
        let value = stepDrafts[stepIndex].parameters[parameter.name] ?? parameter.defaultValue
        if isBoolean(parameter.sourceType) {
            Toggle(parameter.name, isOn: Binding(get: { isTruthy(value) }, set: { newValue in
                updateParameter(stepIndex: stepIndex, name: parameter.name, value: newValue ? "true" : "false")
            }))
            .disabled(!canEditStructured)
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text(parameter.name)
                Spacer(minLength: 8)
                TextField(parameter.defaultValue, text: Binding(get: { value }, set: { newValue in
                    updateParameter(stepIndex: stepIndex, name: parameter.name, value: newValue)
                }))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)
                .disabled(!canEditStructured)
            }
        }
    }

    private func addStep() {
        guard canEditStructured,
              let schema = structuredSchemaSnapshot?.stepSchema.first(where: { $0.name == newStepName }) else { return }
        let parameters = Dictionary(uniqueKeysWithValues: schema.parameters.map { ($0.name, $0.defaultValue) })
        stepDrafts.append(.init(name: schema.name, parameters: parameters))
        publishStructuredRecipe()
    }

    private func removeStep(_ index: Int) {
        guard canEditStructured, stepDrafts.indices.contains(index) else { return }
        stepDrafts.remove(at: index)
        publishStructuredRecipe()
    }

    private func moveStep(_ index: Int, by offset: Int) {
        let target = index + offset
        guard canEditStructured, stepDrafts.indices.contains(index), stepDrafts.indices.contains(target) else { return }
        let item = stepDrafts.remove(at: index)
        stepDrafts.insert(item, at: target)
        publishStructuredRecipe()
    }

    private func updateParameter(stepIndex: Int, name: String, value: String) {
        guard canEditStructured, stepDrafts.indices.contains(stepIndex) else { return }
        stepDrafts[stepIndex].parameters[name] = value
        publishStructuredRecipe()
    }

    private func publishStructuredRecipe() {
        let schemaByName = Dictionary(uniqueKeysWithValues: (structuredSchemaSnapshot?.stepSchema ?? []).map { ($0.name, $0) })
        let text = stepDrafts.map { step -> String in
            let orderedNames = schemaByName[step.name]?.parameters.map(\.name) ?? step.parameters.keys.sorted()
            let orderedValues = orderedNames.compactMap { name -> String? in
                guard let value = step.parameters[name] else { return nil }
                return "\(name)=\(value)"
            }
            return "\(step.name)(\(orderedValues.joined(separator: ",")))"
        }.joined(separator: ", ")
        if session.updateRecipeInput(text, controlPointFIDs: selectedControlPointFIDs) {
            structuredDraftText = text
            structuredDraftOwnerIdentity = recipeEditorOwnerIdentity
        } else {
            structuredDraftText = nil
            structuredDraftOwnerIdentity = nil
        }
    }

    private func hydrateStructuredStepsIfCurrent() {
        guard parsedTextIsCurrent, inspection?.isValid == true, inspectionIsCurrent,
              let inspection, let identity = recipeInspectionIdentity,
              hydratedRecipeIdentity != identity else { return }
        if structuredDraftIsCurrent {
            // This parser reply validates text already represented by the
            // structured controls. Preserve row IDs so the active field keeps
            // focus while debounced inspection returns.
            lastParsedRecipe = inspection
            hydratedRecipeIdentity = identity
            return
        }
        guard let resolvedStepsForDisplay else { return }
        stepDrafts = resolvedStepsForDisplay.map { step in
            let schema = inspection.stepSchema.first { $0.name == step.name || $0.aliases.contains(step.name) }
            var values = Dictionary(uniqueKeysWithValues: (schema?.parameters ?? []).map { ($0.name, $0.defaultValue) })
            values.merge(step.parameters) { _, explicit in explicit }
            return .init(name: step.name, parameters: values)
        }
        lastParsedRecipe = inspection
        structuredDraftText = inspection.rawText
        structuredDraftOwnerIdentity = recipeEditorOwnerIdentity
        if let firstSchema = inspection.stepSchema.first, !inspection.stepSchema.contains(where: { $0.name == newStepName }) {
            newStepName = firstSchema.name
        }
        hydratedRecipeIdentity = identity
    }

    private func isBoolean(_ sourceType: String) -> Bool {
        let type = sourceType.split(separator: ".").last.map(String.init)?.lowercased() ?? sourceType.lowercased()
        return type == "bool" || type == "boolean"
    }

    private var canEditStructured: Bool {
        canEdit && canUseStructuredEditor
    }

    private func isTruthy(_ value: String) -> Bool {
        ["true", "t", "1", "yes"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

struct GeometryTopologyArcPointsToolView: View {
    @ObservedObject var session: GeometryTopologySession
    let selectedArcRows: [GeometryTopologyFeatureRow]

    private var selectedArcFID: Int? { selectedArcRows.count == 1 ? selectedArcRows[0].fid : nil }
    private var pointSnapshot: GeometryTopologyArcPointsSnapshot? {
        guard let selectedArcFID, let current = session.snapshot,
              let points = session.arcPoints,
              points.arcFID == selectedArcFID,
              points.revision == current.revision,
              points.draftIdentity == GeometryTopologyCompletionResult.draftIdentity(for: current.draftState) else { return nil }
        return session.arcPoints
    }
    private var pending: GeometryTopologyArcPointInputDraft? { session.pendingArcPointInput }
    private var loadIdentity: String {
        let source = session.snapshot.map {
            "\($0.revision)|\(GeometryTopologyCompletionResult.draftIdentity(for: $0.draftState))"
        } ?? ""
        return "\(selectedArcFID.map(String.init) ?? "")|\(source)|\(pending?.id ?? "")"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if selectedArcRows.isEmpty {
                    ContentUnavailableView(L10n.text("Select one arc to edit its points."),
                        systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                        description: Text(L10n.text("Choose an arc in the table or map. The endpoint coordinates belong to shared topology nodes.")))
                        .frame(minHeight: 220)
                } else if selectedArcRows.count > 1 {
                    ContentUnavailableView(L10n.text("Select exactly one arc."), systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                        description: Text(L10n.text("Arc Points edits one source arc at a time.")))
                        .frame(minHeight: 220)
                } else if let pointSnapshot {
                    pointsEditor(pointSnapshot)
                } else {
                    ProgressView(L10n.text("Loading arc points…"))
                        .frame(maxWidth: .infinity, minHeight: 180)
                }

                if let error = session.arcPointsError, !error.isEmpty {
                    Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).textSelection(.enabled)
                }
                if session.recipeEditorState?.isPending == true {
                    Label(L10n.text("Apply or discard the pending recipe input before editing arc points."),
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .padding(14)
        }
        .background(.background)
        .task(id: loadIdentity) {
            guard let selectedArcFID, pending == nil else { return }
            await session.loadArcPoints(arcFID: selectedArcFID)
        }
    }

    private func pointsEditor(_ snapshot: GeometryTopologyArcPointsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent(L10n.text("Arc FID"), value: snapshot.arcFID.formatted())
                    Text(L10n.text("Start and end points are shared nodes; interior vertices belong to this arc."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } label: {
                Label(L10n.text("Arc Point Coordinates"), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text(L10n.text("Type")).font(.caption.weight(.semibold))
                    Text("X").font(.caption.weight(.semibold))
                    Text("Y").font(.caption.weight(.semibold))
                }
                ForEach(snapshot.rows, id: \.rowIndex) { row in
                    GridRow {
                        Text(pointLabel(row)).frame(maxWidth: .infinity, alignment: .leading)
                        coordinateField(row, axisRawValue: "X", sourceValue: row.x)
                        coordinateField(row, axisRawValue: "Y", sourceValue: row.y)
                    }
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                if pending != nil {
                    Button(L10n.text("Discard Coordinate"), systemImage: "xmark.circle") {
                        session.discardPendingInputs()
                    }
                    .disabled(session.isEditing)
                }
                Spacer()
                Button(L10n.text("Apply Coordinate"), systemImage: "checkmark") {
                    Task { await session.applyArcPointInput() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(pending == nil || !canEditArcPoints || session.isEditing)
            }

            if let pending {
                Text(L10n.format("Editing %@ coordinate at row %@ for arc %@", pending.axis.rawValue,
                    (pending.rowIndex + 1).formatted(), pending.arcFID.formatted()))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func coordinateField(_ row: GeometryTopologyArcPoint, axisRawValue: String, sourceValue: Double) -> some View {
        let axis = GeometryTopologyCoordinateAxis(rawValue: axisRawValue)!
        let isPendingCell = pending?.arcFID == rowArcFID(row)
            && pending?.rowIndex == row.rowIndex && pending?.axis == axis
        let cellIsAvailable = pending == nil || isPendingCell
        let binding = Binding<String>(get: {
            if isPendingCell, let pending { return pending.rawText }
            return String(sourceValue)
        }, set: { rawValue in
            guard let arcFID = selectedArcFID else { return }
            _ = session.updateArcPointInput(arcFID: arcFID, rowIndex: row.rowIndex,
                axis: axis, rawText: rawValue)
        })
        return TextField(axisRawValue, text: binding)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .frame(minWidth: 88, idealWidth: 105)
            .disabled(!cellIsAvailable || !canEditArcPoints || session.isEditing)
            .onSubmit { if isPendingCell { Task { await session.applyArcPointInput() } } }
            .help(pointHelp(row))
    }

    private func pointLabel(_ row: GeometryTopologyArcPoint) -> String {
        switch row.pointKind {
        case "start": return L10n.format("Start Node %@", row.endpointNodeIndex?.formatted() ?? "—")
        case "end": return L10n.format("End Node %@", row.endpointNodeIndex?.formatted() ?? "—")
        case "internal": return L10n.format("Vertex %@", ((row.internalPointIndex ?? row.rowIndex - 1) + 1).formatted())
        default: return row.pointKind
        }
    }

    private var canEditArcPoints: Bool {
        session.canEdit && !session.isEditing && !session.isLoading
            && session.recipeEditorState?.isPending != true
    }

    private func pointHelp(_ row: GeometryTopologyArcPoint) -> String {
        switch row.pointKind {
        case "start", "end": L10n.text("This coordinate edits the shared topology node.")
        case "internal": L10n.text("This coordinate edits the selected arc's internal vertex.")
        default: L10n.text("Source point identity")
        }
    }

    private func rowArcFID(_ row: GeometryTopologyArcPoint) -> Int? {
        pointSnapshot?.arcFID
    }
}

private struct GeometryTopologyFilterClauseDraft: Identifiable, Equatable {
    let id: UUID
    var type: GeometryTopologyTagFilterClauseType
    var tagDefinitionID: String?
    var propertyColumnID: String?
    var filterOperator: GeometryTopologyTagFilterOperator
    var value: String

    init(id: UUID = UUID(), type: GeometryTopologyTagFilterClauseType = .tag,
         tagDefinitionID: String? = nil, propertyColumnID: String? = nil,
         filterOperator: GeometryTopologyTagFilterOperator = .isNotBlank, value: String = "") {
        self.id = id
        self.type = type
        self.tagDefinitionID = tagDefinitionID
        self.propertyColumnID = propertyColumnID
        self.filterOperator = filterOperator
        self.value = value
    }

    init(_ clause: GeometryTopologyTagFilterClause) {
        self.init(type: clause.type, tagDefinitionID: clause.tagDefinitionID,
            propertyColumnID: clause.propertyColumnID, filterOperator: clause.filterOperator,
            value: clause.value ?? "")
    }

    var clause: GeometryTopologyTagFilterClause? {
        switch type {
        case .tag:
            guard let tagDefinitionID, !tagDefinitionID.isEmpty else { return nil }
            return .tag(definitionID: tagDefinitionID, operator: filterOperator,
                        value: filterOperator.takesValue ? value : nil)
        case .property:
            guard let propertyColumnID, !propertyColumnID.isEmpty else { return nil }
            return .property(columnID: propertyColumnID, operator: filterOperator,
                             value: filterOperator.takesValue ? value : nil)
        }
    }
}

struct GeometryTopologyTagFilterToolView: View {
    @ObservedObject var session: GeometryTopologySession
    let featureKind: String
    @State private var rows: [GeometryTopologyFilterClauseDraft] = []
    @State private var loadedDraftKind: String?

    private var hostFeatureKind: String { featureKind == "region" ? "region" : "arc" }
    private var query: GeometryTopologyTagFilterQuery { session.tagFilterQuery(for: hostFeatureKind) }
    private var definitions: [GeometryTopologyTagDefinition] { session.tagDefinitions(for: featureKind) }
    private var currentResult: GeometryTopologyFilterSnapshot? { session.tagFilterResult(for: hostFeatureKind) }
    private var descriptors: [GeometryTopologyPropertyDescriptor] { currentResult?.propertyDescriptors ?? [] }
    private var resultIsCurrent: Bool {
        session.tagFilterResultIsCurrent(for: hostFeatureKind) && currentResult?.featureKind == hostFeatureKind
    }
    private var hasIncompleteRows: Bool { rows.contains { $0.clause == nil } }
    private var canApply: Bool {
        session.snapshot != nil && !session.isEditing
            && !session.tagFilterIsLoading(for: hostFeatureKind) && !hasIncompleteRows
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.text("Filter rules act only on this source feature list."))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(L10n.text("Property clauses combine with AND; clauses for one tag combine with OR; separate tags combine with AND."))
                            .font(.caption).foregroundStyle(.secondary)
                        if let error = session.tagFilterError(for: hostFeatureKind), !error.isEmpty {
                            Label(L10n.text(error), systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red).textSelection(.enabled)
                        }
                    }
                } label: {
                    Label(L10n.text("Tag Filter"), systemImage: "line.3.horizontal.decrease")
                }

                if rows.isEmpty {
                    ContentUnavailableView(L10n.text("No Filter Conditions"), systemImage: "line.3.horizontal.decrease",
                        description: Text(L10n.text("Add a property or tag condition to filter the active list.")))
                        .frame(minHeight: 90)
                } else {
                    ForEach($rows) { $row in
                        filterClauseEditor(row: $row)
                    }
                }

                HStack {
                    Button(L10n.text("Add Condition"), systemImage: "plus") { addRow() }
                    Button(L10n.text("Clear Conditions"), systemImage: "trash") {
                        rows.removeAll()
                        publishQuery()
                    }
                    .disabled(rows.isEmpty)
                    Spacer()
                    if session.tagFilterIsLoading(for: hostFeatureKind) { ProgressView().controlSize(.small) }
                    Button(L10n.text("Apply Filter"), systemImage: "line.3.horizontal.decrease.circle") {
                        Task { await session.applyTagFilterQuery(featureKind: hostFeatureKind) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canApply)
                }

                filterResultStatus
            }
            .padding(14)
        }
        .background(.background)
        .task(id: hostFeatureKind) {
            if loadedDraftKind != hostFeatureKind {
                rows = query.clauses.map { GeometryTopologyFilterClauseDraft($0) }
                loadedDraftKind = hostFeatureKind
            }
            if currentResult == nil || !resultIsCurrent {
                await session.applyTagFilterQuery(featureKind: hostFeatureKind)
            }
        }
        .onChange(of: rows) { _, _ in publishQuery() }
    }

    private func filterClauseEditor(row: Binding<GeometryTopologyFilterClauseDraft>) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker(L10n.text("Filter Type"), selection: row.type) {
                        Text(L10n.text("Tag")).tag(GeometryTopologyTagFilterClauseType.tag)
                        Text(L10n.text("Property")).tag(GeometryTopologyTagFilterClauseType.property)
                    }
                    .frame(maxWidth: 150)
                    Button(L10n.text("Remove Condition"), systemImage: "minus.circle") {
                        rows.removeAll { $0.id == row.wrappedValue.id }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                }

                if row.wrappedValue.type == .tag {
                    Picker(L10n.text("Tag Definition"), selection: row.tagDefinitionID) {
                        Text(L10n.text("Choose a Tag")).tag(String?.none)
                        ForEach(definitions) { definition in
                            Text("\(definition.id) · \(definition.type)").tag(Optional(definition.id))
                        }
                    }
                    .onChange(of: row.wrappedValue.tagDefinitionID) { _, _ in resetUnsupportedOperator(row.wrappedValue.id) }
                } else {
                    Picker(L10n.text("Property"), selection: row.propertyColumnID) {
                        Text(L10n.text("Choose a Property")).tag(String?.none)
                        ForEach(descriptors) { descriptor in
                            Text("\(descriptor.name) · \(descriptor.columnName)").tag(Optional(descriptor.columnName))
                        }
                    }
                    .onChange(of: row.wrappedValue.propertyColumnID) { _, _ in resetUnsupportedOperator(row.wrappedValue.id) }
                }

                HStack {
                    Picker(L10n.text("Operator"), selection: row.filterOperator) {
                        ForEach(operators(for: row.wrappedValue), id: \.self) { op in
                            Text(op.title).tag(op)
                        }
                    }
                    .frame(maxWidth: 190)
                    if row.wrappedValue.filterOperator.takesValue {
                        TextField(L10n.text("Value"), text: row.value)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
    }

    @ViewBuilder private var filterResultStatus: some View {
        if resultIsCurrent, let result = currentResult {
            GroupBox {
                HStack {
                    Label(L10n.format("%@ matching features", result.matchedFeatureIDs.count.formatted()),
                          systemImage: "checkmark.circle")
                    Spacer()
                    if query.clauses.isEmpty { Text(L10n.text("No filter applied")) }
                }
                .foregroundStyle(.secondary)
            } label: {
                Text(L10n.text("Current Filter Result"))
            }
        } else if let result = currentResult {
            Label(L10n.format("Previous result: %@ matching features", result.matchedFeatureIDs.count.formatted()),
                  systemImage: "clock.arrow.circlepath")
                .font(.caption).foregroundStyle(.secondary)
        } else if session.tagFilterIsLoading(for: hostFeatureKind) {
            ProgressView(L10n.text("Loading filter fields…"))
        } else {
            Label(L10n.text("Apply the filter to update the active list."), systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func addRow() {
        if let definition = definitions.first {
            rows.append(.init(type: .tag, tagDefinitionID: definition.id))
        } else if let descriptor = descriptors.first {
            rows.append(.init(type: .property, propertyColumnID: descriptor.columnName))
        } else {
            rows.append(.init())
        }
        publishQuery()
    }

    private func publishQuery() {
        guard loadedDraftKind == hostFeatureKind else { return }
        let clauses = rows.compactMap(\.clause)
        session.updateTagFilterQuery(.init(featureKind: hostFeatureKind, clauses: clauses))
    }

    private func resetUnsupportedOperator(_ id: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let available = operators(for: rows[index])
        if !available.contains(rows[index].filterOperator) {
            rows[index].filterOperator = available.first ?? .isNotBlank
        }
    }

    private func operators(for row: GeometryTopologyFilterClauseDraft) -> [GeometryTopologyTagFilterOperator] {
        if row.type == .tag {
            guard let definition = definitions.first(where: { $0.id == row.tagDefinitionID }) else { return [.isNotBlank, .isBlank] }
            switch definition.type.lowercased() {
            case "string": return GeometryTopologyTagFilterOperator.blank + GeometryTopologyTagFilterOperator.string
            case "integer", "numeric": return GeometryTopologyTagFilterOperator.blank + GeometryTopologyTagFilterOperator.numeric
            default: return GeometryTopologyTagFilterOperator.blank
            }
        }
        guard let descriptor = descriptors.first(where: { $0.columnName == row.propertyColumnID }) else { return [.isNotBlank, .isBlank] }
        let type = descriptor.sourceType.split(separator: ".").last.map(String.init)?.lowercased() ?? descriptor.sourceType.lowercased()
        switch type {
        case "string": return GeometryTopologyTagFilterOperator.blank + GeometryTopologyTagFilterOperator.string
        case "int", "float", "double", "bool":
            return GeometryTopologyTagFilterOperator.blank + GeometryTopologyTagFilterOperator.numeric
        default:
            return descriptor.isEnum == true
                ? GeometryTopologyTagFilterOperator.blank + GeometryTopologyTagFilterOperator.numeric
                : GeometryTopologyTagFilterOperator.blank
        }
    }
}

private extension GeometryTopologyTagFilterOperator {
    var takesValue: Bool { self != .isBlank && self != .isNotBlank }
    @MainActor var title: String {
        let key = switch self {
        case .isNotBlank: "Is Not Blank"
        case .isBlank: "Is Blank"
        case .equals: "Equals"
        case .notEquals: "Does Not Equal"
        case .contains: "Contains"
        case .doesNotContain: "Does Not Contain"
        case .lessThan: "Less Than"
        case .atMost: "At Most"
        case .greaterThan: "Greater Than"
        case .atLeast: "At Least"
        }
        return L10n.text(key)
    }

    static let blank: [Self] = [.isNotBlank, .isBlank]
    static let string: [Self] = [.equals, .notEquals, .contains, .doesNotContain]
    static let numeric: [Self] = [.equals, .notEquals, .lessThan, .atMost, .greaterThan, .atLeast]
}
