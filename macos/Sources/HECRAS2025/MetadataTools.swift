import SwiftUI

struct AttributeToolContext: Sendable {
    let modelAssetID: String
    let tableID: String
    var columnID: String? = nil
}
enum TagValueType: String, Sendable { case string = "String", integer = "Integer", numeric = "Numeric", boolean = "Boolean" }
struct TagDefinitionPresentation: Identifiable, Sendable {
    let id: String
    let key: String
    let type: TagValueType
}
struct FilterPropertyPresentation: Identifiable, Sendable {
    enum ValueType: Sendable { case string, number, boolean, enumeration, other }
    let id: String
    let name: String
    let type: ValueType
}
struct RecentTagPresentation: Identifiable, Sendable {
    let id: String
    let definitionID: String
    let key: String
    let value: String
}
struct AssignedTagPresentation: Identifiable, Sendable {
    let id: String
    let definitionID: String
    let key: String
    let value: String
}
struct MetadataToolPresentation: Sendable {
    var definitions: [TagDefinitionPresentation] = []
    var properties: [FilterPropertyPresentation] = []
    var recentTags: [RecentTagPresentation] = []
    var assignedTags: [AssignedTagPresentation] = []
    var canRemoveAssignedTags = false
    var originalColumnName: String? = nil
    var validationMessage: String? = nil
    var canCreateTag = false
}

// TagFilterItemControl.GetOperatorsForType/GetAvailableOperators. Only the UI
// choice/visibility behavior is ported; source services evaluate the filter.
enum TagFilterPresentation {
    static let blank = ["IsNotBlank", "IsBlank"]
    static let string = blank + ["Equals", "NotEquals", "Contains", "DoesNotContain"]
    static let number = blank + ["Equals", "NotEquals", "LessThan", "AtMost", "GreaterThan", "AtLeast"]
    static func operators(fields: [String: String], metadata: MetadataToolPresentation, scope: String? = nil) -> [String] {
        let prefix = scope.map { $0 + "/" } ?? ""
        func value(_ key: String) -> String? { fields[prefix + "TagFilterItemControl/" + key] }
        if value("FilterItem_Type") == "Property" {
            guard let property = metadata.properties.first(where: { $0.id == value("FilterItem_PropertyDescriptor") }) else { return [] }
            switch property.type { case .string: return string; case .number, .boolean, .enumeration: return number; case .other: return blank }
        }
        guard let definition = metadata.definitions.first(where: { $0.id == value("FilterItem_TagDefinition") }) else { return [] }
        switch definition.type { case .string: return string; case .integer, .numeric: return number; case .boolean: return blank }
    }
    static func takesValue(_ operation: String?) -> Bool { operation.map { !blank.contains($0) } ?? false }
}

struct MetadataToolContent: View {
    @ObservedObject var store: WorkspaceStore
    let kind: ToolKind
    @ObservedObject var state: DataToolSession
    @ObservedObject var editor: ModelEditorSession
    let context: DataToolContext
    let currentRequest: @MainActor () -> ToolRequest
    let perform: @MainActor (DataToolOperation, String?) -> Void
    @State private var creatingTag = false
    @State private var filterRows: [TagFilterRow] = [.primary]
    @FocusState private var focusName: Bool
    private var metadata: MetadataToolPresentation { state.presentation.metadata ?? .init() }
    private var selectedTag: TagDefinitionPresentation? { metadata.definitions.first { $0.id == editor.fields["SetTagValueControl/ViewModel_SelectedTagDefinition"] } }
    private var filterTargets: String {
        filterRows.map { row in
            ["FilterItem_Type", "FilterItem_TagDefinition", "FilterItem_PropertyDescriptor"]
                .map { editor.fields[row.field($0)] ?? "" }.joined(separator: ":")
        }.joined(separator: "|")
    }
    var body: some View {
        Form {
            switch kind {
            case .tagCreate:
                Section("Create Tag") {
                    nameField("Tag Name", key: "CreateTagControl/ViewModel_NewTagName")
                    typePicker("Tag Type", key: "CreateTagControl/ViewModel_NewTagType")
                }
            case .addAttribute:
                Section("Add Column") {
                    nameField("Column Name", key: "AddAttributeTableColumnControl/ViewModel_NewColumnName")
                    typePicker("Column Type", key: "AddAttributeTableColumnControl/ViewModel_NewColumnType")
                }
            case .renameAttribute:
                Section("Rename Column") {
                    LabeledContent("Original Column Name", value: metadata.originalColumnName ?? "—").textSelection(.enabled)
                    nameField("Column Name", key: "RenameAttributeTableColumnControl/ViewModel_NewColumnName")
                }
            case .tagEdit: tagAssignment
            case .tagFilter: filter
            default: EmptyView()
            }
            if let message = metadata.validationMessage, !message.isEmpty { Section { Text(message).foregroundStyle(.red).textSelection(.enabled) } }
            if [.addAttribute, .renameAttribute].contains(kind), context.attributeTable == nil {
                Section { Label("Open this command from an attribute table.", systemImage: "tablecells").foregroundStyle(.secondary) }
            }
        }.formStyle(.grouped).disabled(!editor.canEdit)
        .onAppear { focusName = true; ensureInitialFilter() }
        .onChange(of: filterTargets) { _, _ in if kind == .tagFilter { normalizeFilterOperators() } }
        .onChange(of: selectedTag?.id) { _, _ in synchronizeBoolean() }
    }
    @ViewBuilder private var tagAssignment: some View {
        Section("Tags") {
            HStack {
                Spacer()
                Button("Create New Tag") { creatingTag = true }.disabled(!metadata.canCreateTag || state.busy)
                    .popover(isPresented: $creatingTag) {
                        CreateTagPopover(store: store, context: context) { value in
                            guard context.projectSessionID == store.projectSessionID else { return }
                            state.acceptSourceUpdate(value, editor: editor,
                                sourceWins: ["SetTagValueControl/ViewModel_SelectedTagDefinition"], currentRequest: currentRequest)
                            creatingTag = false
                        }
                    }
            }
            Picker("Select a Tag", selection: text("SetTagValueControl/ViewModel_SelectedTagDefinition")) {
                Text("None").tag("")
                ForEach(metadata.definitions) { definition in Text(definition.key).tag(definition.id) }
            }
            if selectedTag?.type == .boolean {
                Toggle("Value", isOn: Binding(get: { editor.fields["SetTagValueControl/ViewModel_BoolValue"] == "true" }, set: { value in
                    editor.set("SetTagValueControl/ViewModel_BoolValue", String(value))
                    editor.set("SetTagValueControl/ViewModel_Value", value ? "True" : "False")
                }))
            } else {
                DataToolField(schema: "SetTagValueControl", id: "ViewModel_Value", editor: editor, store: store)
                    .disabled(selectedTag == nil)
            }
        }
        Section("Tags on Selection") {
            TagChipList(tags: metadata.assignedTags, canRemove: metadata.canRemoveAssignedTags && !state.busy) { tag in
                perform(.removeTag, tag.definitionID)
            }
        }
        if !metadata.recentTags.isEmpty {
            Section("Recent Tags") {
                ForEach(metadata.recentTags) { tag in
                    Button { perform(.assignRecentTag, tag.id) } label: {
                        LabeledContent(tag.key, value: tag.value).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(state.busy)
                }
            }
        }
    }
    private var filter: some View {
        Section {
            ForEach(filterRows) { row in
                TagFilterRowView(row: row, index: filterRows.firstIndex(where: { $0.id == row.id }) ?? 0,
                    metadata: metadata, editor: editor, store: store) {
                    removeFilter(row)
                }
            }
            Button("Add Filter", systemImage: "plus", action: addFilter)
        } header: { Text("Tag Filter") }
    }
    private func ensureInitialFilter() {
        guard kind == .tagFilter, let row = filterRows.first else { return }
        if editor.fields[row.field("FilterItem_Type")] == nil { editor.set(row.field("FilterItem_Type"), "Tag") }
        if editor.fields[row.field("FilterItem_Operator")] == nil { editor.set(row.field("FilterItem_Operator"), "IsNotBlank") }
    }
    private func addFilter() {
        let row = TagFilterRow(id: UUID().uuidString)
        filterRows.append(row)
        editor.set(row.field("FilterItem_Type"), "Tag")
        editor.set(row.field("FilterItem_Operator"), "IsNotBlank")
    }
    private func removeFilter(_ row: TagFilterRow) {
        filterRows.removeAll { $0.id == row.id }
        for field in SourceEditorLibrary.shared.schema("TagFilterItemControl")?.fields ?? [] {
            editor.fields.removeValue(forKey: row.field(field.id))
        }
    }
    private func normalizeFilterOperators() {
        for row in filterRows {
            let available = TagFilterPresentation.operators(fields: editor.fields, metadata: metadata, scope: row.scope)
            let field = row.field("FilterItem_Operator")
            if !available.isEmpty, !available.contains(editor.fields[field] ?? "") {
                editor.set(field, "IsNotBlank")
            }
        }
    }
    private func operatorTitle(_ id: String) -> String {
        SourceEditorLibrary.shared.schema("TagFilterItemControl")?.fields.first { $0.id == "FilterItem_Operator" }?.choices.first { $0.id == id }?.title ?? id
    }
    private func nameField(_ title: String, key: String) -> some View {
        TextField(LocalizedStringKey(title), text: text(key), prompt: Text("RiverName")).focused($focusName)
    }
    private func typePicker(_ title: String, key: String) -> some View {
        Picker(LocalizedStringKey(title), selection: text(key, fallback: "String")) {
            ForEach(["String", "Integer", "Numeric", "Boolean"], id: \.self) { value in Text(LocalizedStringKey(value)).tag(value) }
        }
    }
    private func text(_ key: String, fallback: String = "") -> Binding<String> { Binding(get: { editor.fields[key] ?? fallback }, set: { editor.set(key, $0) }) }
    private func synchronizeBoolean() {
        guard selectedTag?.type == .boolean else { return }
        let raw = editor.fields["SetTagValueControl/ViewModel_Value"]?.lowercased()
        let value = raw == "true" || raw != "false" && editor.fields["SetTagValueControl/ViewModel_BoolValue"] == "true"
        editor.set("SetTagValueControl/ViewModel_BoolValue", String(value))
        editor.set("SetTagValueControl/ViewModel_Value", value ? "True" : "False")
    }
}

private struct TagFilterRow: Identifiable, Hashable {
    let id: String
    static let primary = TagFilterRow(id: "primary")
    var scope: String? { id == "primary" ? nil : "TagFilterControl/Filters/\(id)" }
    func field(_ name: String) -> String { (scope.map { $0 + "/" } ?? "") + "TagFilterItemControl/" + name }
}

private struct TagFilterRowView: View {
    let row: TagFilterRow
    let index: Int
    let metadata: MetadataToolPresentation
    @ObservedObject var editor: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    let remove: () -> Void

    private var operators: [String] {
        editor.choiceOptions[row.field("FilterItem_Operator")]?.map(\.id)
            ?? TagFilterPresentation.operators(fields: editor.fields, metadata: metadata, scope: row.scope)
    }
    private var targetSignature: String {
        ["FilterItem_Type", "FilterItem_TagDefinition", "FilterItem_PropertyDescriptor"]
            .map { editor.fields[row.field($0)] ?? "" }.joined(separator: "|")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 4) {
                    Text("Filter")
                    Text(verbatim: String(index + 1)).monospacedDigit()
                }.font(.subheadline.weight(.semibold))
                Spacer()
                Button(role: .destructive, action: remove) {
                    Label("Remove Filter", systemImage: "minus.circle")
                }.buttonStyle(.borderless)
            }
            Picker("Type", selection: text("FilterItem_Type", fallback: "Tag")) {
                Text("Tag").tag("Tag")
                Text("Property").tag("Property")
            }
            if editor.fields[row.field("FilterItem_Type")] == "Property" {
                Picker("Property", selection: text("FilterItem_PropertyDescriptor")) {
                    Text("None").tag("")
                    ForEach(metadata.properties) { property in Text(property.name).tag(property.id) }
                }
            } else {
                Picker("Tag", selection: text("FilterItem_TagDefinition")) {
                    Text("None").tag("")
                    ForEach(metadata.definitions) { definition in Text(definition.key).tag(definition.id) }
                }
            }
            Picker("Operator", selection: text("FilterItem_Operator")) {
                if operators.isEmpty { Text("None").tag(editor.fields[row.field("FilterItem_Operator")] ?? "") }
                ForEach(operators, id: \.self) { operation in Text(L10n.text(operatorTitle(operation))).tag(operation) }
            }.disabled(operators.isEmpty)
            if TagFilterPresentation.takesValue(editor.fields[row.field("FilterItem_Operator")]) {
                DataToolField(schema: "TagFilterItemControl", id: "FilterItem_Value", scope: row.scope, editor: editor, store: store)
            }
        }
        .padding(.vertical, 6)
        .onChange(of: targetSignature) { _, _ in normalizeOperator() }
        .onChange(of: operators) { _, _ in normalizeOperator() }
    }

    private func text(_ field: String, fallback: String = "") -> Binding<String> {
        let key = row.field(field)
        return Binding(get: { editor.fields[key] ?? fallback }, set: { editor.set(key, $0) })
    }

    private func normalizeOperator() {
        guard !operators.isEmpty else { return }
        let field = row.field("FilterItem_Operator")
        if !operators.contains(editor.fields[field] ?? "") { editor.set(field, "IsNotBlank") }
    }

    private func operatorTitle(_ id: String) -> String {
        SourceEditorLibrary.shared.schema("TagFilterItemControl")?.fields.first { $0.id == "FilterItem_Operator" }?.choices.first { $0.id == id }?.title ?? id
    }
}

/// TagList: native flow layout with the source hover-to-remove interaction.
struct TagChipList: View {
    let tags: [AssignedTagPresentation]
    let canRemove: Bool
    let remove: (AssignedTagPresentation) -> Void
    var body: some View {
        if tags.isEmpty {
            ContentUnavailableView("No Tags", systemImage: "tag", description: Text("No tags are shared by the current feature selection."))
        } else {
            TagChipFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(tags) { tag in
                    TagChipView(tag: tag, canRemove: canRemove) { remove(tag) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}

/// TagControl: remove affordance appears while the chip is hovered.
struct TagChipView: View {
    let tag: AssignedTagPresentation
    let canRemove: Bool
    let remove: () -> Void
    @State private var pointerOver = false

    var body: some View {
        HStack(spacing: 6) {
            Text(tag.key).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
            if !tag.value.isEmpty { Text(tag.value).font(.caption).lineLimit(1).truncationMode(.middle) }
            if pointerOver {
                Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .disabled(!canRemove)
                    .help(canRemove ? L10n.text("Remove Tag") : L10n.text("Tag removal is unavailable."))
                    .accessibilityLabel("Remove Tag")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
        .onHover { pointerOver = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "\(tag.key): \(tag.value)"))
    }
}

private struct TagChipFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > limit {
                widest = max(widest, x - horizontalSpacing)
                x = 0; y += rowHeight + verticalSpacing; rowHeight = 0
            }
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
        if !subviews.isEmpty { widest = max(widest, x - horizontalSpacing); y += rowHeight }
        return CGSize(width: min(proposal.width ?? widest, widest), height: y)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + verticalSpacing; rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height))
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct CreateTagPopover: View {
    @ObservedObject var store: WorkspaceStore
    let context: DataToolContext
    let created: @MainActor (DataToolPresentation) -> Void
    @StateObject private var editor = ModelEditorSession()
    @StateObject private var state = DataToolSession()
    @State private var initialized = false
    private var request: ToolRequest { state.request(kind: .tagCreate, editor: editor, context: context) }
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Create Tag") {
                    TextField("Tag Name", text: Binding(get: { editor.fields["CreateTagControl/ViewModel_NewTagName"] ?? "" }, set: { editor.set("CreateTagControl/ViewModel_NewTagName", $0) }), prompt: Text("RiverName"))
                    Picker("Tag Type", selection: Binding(get: { editor.fields["CreateTagControl/ViewModel_NewTagType"] ?? "String" }, set: { editor.set("CreateTagControl/ViewModel_NewTagType", $0) })) {
                        ForEach(["String", "Integer", "Numeric", "Boolean"], id: \.self) { value in Text(LocalizedStringKey(value)).tag(value) }
                    }
                }
                if let message = state.presentation.metadata?.validationMessage { Text(message).foregroundStyle(.red) }
            }.formStyle(.grouped)
            if let error = state.error { Text(error).font(.caption).foregroundStyle(.red).padding(12) }
            HStack {
                Spacer()
                Button("Create") {
                    guard context.projectSessionID == store.projectSessionID else { return }
                    var value = request; value.operation = .createTag
                    state.perform(value, editor: editor, provider: store.toolProvider, currentRequest: { request }, completion: created)
                }.buttonStyle(.glassProminent).disabled(context.projectSessionID != store.projectSessionID || !state.canExecute(request) || (editor.fields["CreateTagControl/ViewModel_NewTagName"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(12)
        }.frame(width: 390, height: 285).disabled(state.running)
        .onAppear { editor.startDraft(); editor.set("CreateTagControl/ViewModel_NewTagType", "String"); initialized = true }
        .task(id: state.signature(request)) {
            guard initialized, context.projectSessionID == store.projectSessionID, !state.isCurrent(request), !state.running else { return }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            state.prepare(request, editor: editor, provider: store.toolProvider, currentRequest: { request })
        }
        .onDisappear { state.stopPreparation() }
        .onChange(of: store.projectSessionID) { _, _ in state.stopPreparation() }
    }
}
