import RASWorkspaceCore
import SwiftUI

enum RecipeLibrary {
    static let commands: [RecipeCommand] = {
        guard let url = Bundle.module.url(forResource: "recipe-definitions", withExtension: "json"),
              let data = try? Data(contentsOf: url), let commands = try? JSONDecoder().decode([RecipeCommand].self, from: data) else {
            preconditionFailure("Missing original recipe parameter definitions")
        }
        return commands
    }()
}

// RecipeBuilder, IngredientCard, RecipeStepCard and typed parameter controls.
// This edits the original config string; it does not run mesh operations.
struct RecipeField: View {
    let field: SourceEditorField
    let meshType: String?
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @Environment(\.openURL) private var openURL
    @State private var mode = "Steps"
    @State private var steps: [RecipeStep] = []
    @State private var text = ""
    @State private var selection: UUID?
    @State private var error: String?
    @State private var lastWritten: String?
    @State private var lastValid = ""
    @State private var showIngredients = false
    @State private var parameterDrafts: [UUID: [String: String]] = [:]

    init(field: SourceEditorField, session: ModelEditorSession, store: WorkspaceStore, meshType: String? = nil) {
        self.field = field
        self.session = session
        self.store = store
        self.meshType = meshType
    }

    private var commands: [RecipeCommand] { RecipeLibrary.commands }
    private var selectedIndex: Int? { steps.firstIndex { $0.id == selection } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(LocalizedStringKey(field.title)).font(.headline)
                Button { openURL(Self.builderHelpURL) } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.plain).help("Postprocessing Recipe Help")
                Spacer()
                Picker("Recipe View", selection: $mode) { Text("Recipe Steps").tag("Steps"); Text("Text").tag("Text") }.pickerStyle(.segmented).frame(width: 180)
            }
            if mode == "Steps" {
                HStack {
                    Button { showIngredients.toggle() } label: { Label("Add Step", systemImage: "plus") }
                        .popover(isPresented: $showIngredients) {
                            RecipeIngredientPalette(commands: commands.filter(\.palette)) { command in
                                add(command); showIngredients = false
                            }
                        }
                    Button("Use Default Recipe") { setDefault() }
                    Spacer()
                    Button { move(-1) } label: { Label("Move Up", systemImage: "arrow.up") }.disabled(selectedIndex == nil || selectedIndex == 0)
                    Button { move(1) } label: { Label("Move Down", systemImage: "arrow.down") }.disabled(selectedIndex == nil || selectedIndex == steps.count - 1)
                    Button(role: .destructive) { remove() } label: { Label("Remove Step", systemImage: "trash") }.disabled(selection == nil)
                }.labelStyle(.iconOnly)
                if steps.isEmpty {
                    Text("No postprocessing steps.").foregroundStyle(.secondary)
                } else {
                    ForEach(steps) { step in recipeStepDisclosure(for: step) }
                }
            } else {
                TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(minHeight: 140)
                    .accessibilityLabel("Postprocessing recipe text")
                HStack {
                    Button("Apply Text") { applyText() }
                    Button("Restore Last Valid Recipe") { restoreValid() }
                    Spacer(); Button("Copy") { store.system.copy(text) }
                }
            }
            if let error {
                Button { restoreValid() } label: {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Restore the last valid recipe")
            }
        }
        .onAppear(perform: load)
        .onChange(of: text) { _, value in
            if mode == "Text", value != lastWritten {
                lastWritten = value; session.set(field.storageID, value)
            }
        }
        .onChange(of: meshType) { _, _ in
            guard containsDefaultStep(text) else { return }
            load()
        }
        .onChange(of: session.fields[field.storageID]) { _, value in if value != lastWritten { load() } }
    }
    private func recipeStepDisclosure(for step: RecipeStep) -> some View {
        let isSelected: Bool = selection == step.id
        return DisclosureGroup(isExpanded: recipeStepExpansion(for: step)) {
            recipeStepDetails(for: step)
        } label: {
            recipeStepLabel(for: step, isSelected: isSelected)
        }
        .padding(7)
        .background(isSelected ? Color.accentColor.opacity(0.09) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7))
        .draggable(step.id.uuidString)
        .dropDestination(for: String.self, action: { identifiers, _ in
            return moveRecipeStep(identifiers, onto: step)
        })
    }
    private func recipeStepExpansion(for step: RecipeStep) -> Binding<Bool> {
        Binding<Bool>(
            get: { selection == step.id },
            set: { isExpanded in selection = isExpanded ? step.id : nil }
        )
    }
    @ViewBuilder private func recipeStepDetails(for step: RecipeStep) -> some View {
        if let command = commands.first(where: { $0.id == step.command }) {
            if let presentation = RecipePresentationLibrary.presentation(command.id) {
                Text(L10n.text(presentation.description))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if command.parameters.isEmpty {
                Text("No parameters.").foregroundStyle(.secondary)
            }
            recipeParameters(for: command, step: step)
        }
    }
    @ViewBuilder private func recipeParameters(for command: RecipeCommand, step: RecipeStep) -> some View {
        if let presentation = RecipePresentationLibrary.presentation(command.id) {
            ForEach(presentation.parameters) { parameter in
                parameterField(parameter, command: command, step: step)
            }
        } else {
            ForEach(command.parameters) { parameter in
                let parameterID: String = String(parameter.id.prefix(1)).uppercased() + String(parameter.id.dropFirst())
                let fallback: RecipeParameterPresentation = RecipeParameterPresentation(
                    id: parameterID, title: parameter.title, description: "")
                parameterField(fallback, command: command, step: step)
            }
        }
    }
    private func recipeStepLabel(for step: RecipeStep, isSelected: Bool) -> some View {
        let symbol: String = RecipePresentationLibrary.presentation(step.command)?.symbol ?? "list.bullet"
        let foreground: Color = isSelected ? Color.accentColor : Color.secondary
        let weight: Font.Weight = isSelected ? .semibold : .regular
        return HStack(spacing: 9) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(foreground)
            Text(L10n.text(step.command)).fontWeight(weight)
            Spacer(minLength: 6)
            Button { openURL(Self.helpURL(for: step.command)) } label: { Image(systemName: "info.circle") }
                .buttonStyle(.plain).help("Open Help")
            Button { selection = nil } label: { Image(systemName: "checkmark.circle") }
                .buttonStyle(.plain).help("Finish Editing Step")
            Button(role: .destructive) { remove(step.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).help("Remove Step")
        }
    }
    private func moveRecipeStep(_ identifiers: [String], onto step: RecipeStep) -> Bool {
        guard let identifier = identifiers.first,
              let sourceID = UUID(uuidString: identifier),
              let sourceIndex = steps.firstIndex(where: { $0.id == sourceID }),
              let destinationIndex = steps.firstIndex(where: { $0.id == step.id }) else { return false }
        let movedStep = steps.remove(at: sourceIndex)
        steps.insert(movedStep, at: min(destinationIndex, steps.count))
        commit()
        return true
    }
    @ViewBuilder private func parameterField(_ parameter: RecipeParameterPresentation, command: RecipeCommand, step: RecipeStep) -> some View {
        let definition = command.parameters.first { $0.id.caseInsensitiveCompare(parameter.wireKey) == .orderedSame }
        let value = Binding<String>(get: {
            parameterDrafts[step.id]?[parameter.id] ?? RecipeParameterEditing.display(parameter, in: steps.first { $0.id == step.id } ?? step)
        }, set: { value in
            guard let index = steps.firstIndex(where: { $0.id == step.id }) else { return }
            if parameter.id == "Threshold", command.id == "OptTopology",
               parameterDrafts[step.id]?["DeltaThreshold"] == nil,
               let delta = RecipePresentationLibrary.presentation(command.id)?.parameters.first(where: { $0.id == "DeltaThreshold" }) {
                parameterDrafts[step.id, default: [:]]["DeltaThreshold"] = RecipeParameterEditing.display(delta, in: steps[index])
            }
            parameterDrafts[step.id, default: [:]][parameter.id] = value
            RecipeParameterEditing.set(value, parameter: parameter, in: &steps[index], deltaThreshold: parameterDrafts[step.id]?["DeltaThreshold"]); commit()
        })
        VStack(alignment: .leading, spacing: 4) {
            if definition?.kind == "boolean" {
                Toggle(LocalizedStringKey(parameter.title), isOn: Binding(get: { ["true", "yes", "1", "t"].contains(value.wrappedValue.lowercased()) }, set: { value.wrappedValue = $0 ? "True" : "False" }))
            } else {
                TextField(LocalizedStringKey(parameter.id == "Threshold" ? "Threshold (%)" : parameter.title), text: value).onSubmit(commit)
                    .textFieldStyle(.roundedBorder).monospacedDigit()
            }
            if definition?.kind == "integer", Int32(value.wrappedValue) == nil {
                Text("Enter a whole number in the 32-bit integer range.").font(.caption).foregroundStyle(.red)
            } else if definition?.kind == "number", Double(value.wrappedValue)?.isFinite != true {
                Text("Enter a finite number.").font(.caption).foregroundStyle(.red)
            } else if parameter.isOutsideBounds(value.wrappedValue), let lower = parameter.minimum, let upper = parameter.maximum {
                Text(String(format: L10n.text("Allowed range: %@–%@"), lower.formatted(), upper.formatted())).font(.caption).foregroundStyle(.red)
            } else if parameter.isOutsideRecommendedBounds(value.wrappedValue), let lower = parameter.recommendedMinimum, let upper = parameter.recommendedMaximum {
                Text(String(format: L10n.text("Recommended range: %@–%@"), lower.formatted(), upper.formatted())).font(.caption).foregroundStyle(.orange)
            }
        }.help(L10n.text(parameter.description))
    }
    private func load() {
        parameterDrafts = [:]
        text = session.fields[field.storageID] ?? ""; lastWritten = text
        do { steps = try RecipeDocument.parse(text, commands: commands, meshType: meshType); lastValid = text; error = nil }
        catch { steps = []; self.error = L10n.text(error.localizedDescription); mode = "Text" }
        selection = nil
    }
    private func containsDefaultStep(_ source: String) -> Bool {
        (try? RecipeDocument.parse(source, commands: commands))?.contains(where: { $0.command == "Default" }) ?? false
    }
    private func commit() {
        do {
            let wire = try RecipeDocument.serialize(steps, commands: commands)
            text = wire; lastWritten = wire; lastValid = wire; session.set(field.storageID, wire); error = nil
        } catch {
            // Keep an invalid parameter draft in the model string so closing
            // or switching cannot silently discard it. Save validates it.
            let draft = steps.map { step in
                let parameters = commands.first { $0.id == step.command }?.parameters ?? []
                return step.command + "(" + parameters.map { $0.id + "=" + (step.values[$0.id] ?? $0.defaultValue) }.joined(separator: ", ") + ")"
            }.joined(separator: "\n")
            text = draft; lastWritten = draft; session.set(field.storageID, draft)
            self.error = L10n.text(error.localizedDescription)
        }
    }
    private func applyText() {
        do {
            let parsed = try RecipeDocument.parse(text, commands: commands, meshType: meshType)
            steps = parsed; parameterDrafts = [:]; lastWritten = text; lastValid = text; session.set(field.storageID, text); error = nil
        } catch { self.error = L10n.text(error.localizedDescription) }
    }
    private func add(_ command: RecipeCommand) {
        let step = RecipeStep(command: command, paletteDefaults: true); steps.append(step); selection = step.id; commit()
    }
    private func setDefault() {
        text = "Default()"; lastWritten = text; session.set(field.storageID, text); load()
    }
    private func restoreValid() { text = lastValid; lastWritten = text; session.set(field.storageID, text); load() }
    private func move(_ delta: Int) {
        guard let index = selectedIndex, steps.indices.contains(index + delta) else { return }
        steps.swapAt(index, index + delta); commit()
    }
    private func remove() { if let selection { remove(selection) } }
    private func remove(_ id: UUID) {
        steps.removeAll { $0.id == id }; parameterDrafts[id] = nil
        if selection == id { selection = nil }
        commit()
    }
    private static let builderHelpURL = URL(string: "https://www.hec.usace.army.mil/confluence/pages/viewpage.action?pageId=187669771&spaceKey=RAS&title=Postprocessing%2BRecipes")!
    private static func helpURL(for command: String) -> URL {
        let base = "https://www.hec.usace.army.mil/confluence/hecras/advanced-meshing"
        let fragment: String
        switch command {
        case "RemoveFaces": fragment = "#AdvancedMeshing-MergeFaces"
        case "Smooth": fragment = "#AdvancedMeshing-SmoothAngles"
        case "Split": fragment = "#AdvancedMeshing-Split"
        case "SwapEdges": fragment = "#AdvancedMeshing-SwapEdges"
        default: fragment = ""
        }
        return URL(string: base + fragment)!
    }
}

private struct RecipeIngredientPalette: View {
    let commands: [RecipeCommand]
    let add: (RecipeCommand) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add Ingredient").font(.headline).padding(16)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(commands) { command in
                        Button { add(command) } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: RecipePresentationLibrary.presentation(command.id)?.symbol ?? "list.bullet")
                                    .font(.title3).foregroundStyle(.tint).frame(width: 26)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(L10n.text(command.title)).fontWeight(.medium)
                                    if let presentation = RecipePresentationLibrary.presentation(command.id) {
                                        Text(L10n.text(presentation.paletteDescription)).font(.caption).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "plus").foregroundStyle(.secondary)
                            }.padding(.vertical, 6).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityLabel(Text(L10n.text(command.title)))
                            .accessibilityHint(Text(L10n.text(RecipePresentationLibrary.presentation(command.id)?.paletteDescription ?? "Add Step")))
                        Divider()
                    }
                }.padding(.horizontal, 16)
            }
        }.frame(width: 430, height: 490)
    }
}

struct TopologyRecipeBuilderView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var editor: ModelEditorSession
    let canForceSet: Bool
    let forceSet: () -> Void
    private var recipeField: SourceEditorField? {
        SourceEditorLibrary.shared.field(storageID: "TopologyRecipeBuilder/Recipe")
    }
    private var hasMismatch: Bool {
        editor.fields["TopologyRecipeBuilder/RecipeHasMismatch"]?.lowercased() == "true"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Section("Selected Control Points") {
                    LabeledContent("Selection", value: editor.fields["TopologyRecipeBuilder/SelectedControlPointCount"] ?? "—")
                    if !canForceSet {
                        Label("Topology selection details are unavailable without the model adapter.", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if hasMismatch {
                    Section("Mixed Recipes") {
                        Label("Selected control points have different recipes.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Button("Force Set Recipe for Selection", action: forceSet)
                            .disabled(!canForceSet)
                    }
                } else {
                    Section("Recipe Status") {
                        Text("Recipe editing is tied to the current topology selection. Selection and mixed-recipe status require the topology adapter.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.formStyle(.grouped).fixedSize(horizontal: false, vertical: true)
            if let recipeField {
                ScrollView { RecipeField(field: recipeField, session: editor, store: store).padding(14) }
                    .frame(minHeight: 280)
            } else {
                ContentUnavailableView("Recipe Editor Unavailable", systemImage: "list.bullet.rectangle",
                    description: Text("The source recipe definition could not be loaded."))
            }
        }
    }
}
