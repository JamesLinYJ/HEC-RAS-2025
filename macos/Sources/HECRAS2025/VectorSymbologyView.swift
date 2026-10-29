import SwiftUI

struct VectorSymbologyView: View {
    @ObservedObject var store: WorkspaceStore
    @StateObject private var session = VectorSymbologySession()
    @State private var mapID: UUID
    @State private var assetID: String?
    @State private var selectedContext: VectorSymbologyContext?

    init(store: WorkspaceStore) {
        self.store = store
        _mapID = State(initialValue: store.lastActiveMapID)
        _assetID = State(initialValue: store.selectedAssetID)
    }

    private var contextOptions: [VectorSymbologyContext] {
        store.vectorSymbologyContexts(mapID: mapID)
    }

    private var context: VectorSymbologyContext {
        if let selectedContext,
           let latest = contextOptions.first(where: { $0.hasSameVisualTarget(as: selectedContext) }) {
            return latest
        }
        let preferred = store.vectorSymbologyContext(mapID: mapID, assetID: assetID)
        return contextOptions.first(where: { $0.hasSameVisualTarget(as: preferred) }) ?? preferred
    }

    private var layerPicker: some View {
        Group {
            if contextOptions.count > 1 {
                Picker(L10n.text("Layer"), selection: Binding(
                    get: { context },
                    set: { selectedContext = $0 }
                )) {
                    if !contextOptions.contains(context) {
                        Text(L10n.text("Choose a layer")).tag(context)
                    }
                    ForEach(contextOptions, id: \.self) { option in
                        // The node name is project data and must remain verbatim.
                        Text(option.visualNode?.nodeName ?? option.specializedNode?.nodeName ?? L10n.text("Selected Layer")).tag(option)
                    }
                }
                .frame(maxWidth: 250)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L10n.text("Symbology Settings"), systemImage: "paintpalette").font(.title2)
                Spacer()
                layerPicker
                if session.busy { ProgressView().controlSize(.small) }
            }.padding(20)
            Divider()
            if session.options.isEmpty {
                if store.vectorSymbologyProvider == nil {
                    ContentUnavailableView(
                        L10n.text("Vector Symbology Unavailable"),
                        systemImage: "exclamationmark.icloud",
                        description: Text(L10n.text("The source vector symbology provider is not connected."))
                    )
                } else {
                    ContentUnavailableView(
                        L10n.text("No Vector Layer Selected"),
                        systemImage: "point.3.connected.trianglepath.dotted",
                        description: Text(L10n.text("Choose a concrete vector layer from the layer menu."))
                    )
                }
            } else {
                Form {
                    Section(L10n.text("Symbology Settings")) {
                        ForEach(session.options) { VectorPropertyRow(option: $0, session: session) }
                    }
                    if !session.additionalOptions.isEmpty {
                        Section(L10n.text("Additional Options")) {
                            ForEach(session.additionalOptions) { option in
                                if option.isBoolean {
                                    Toggle(
                                        L10n.text(option.title),
                                        isOn: Binding(
                                            get: { option.value.lowercased() == "true" },
                                            set: { session.setAdditional(option.id, value: String($0)) }
                                        )
                                    ).disabled(!option.isEnabled)
                                        .help(L10n.text(option.description ?? ""))
                                } else {
                                    Picker(
                                        L10n.text(option.title),
                                        selection: Binding(
                                            get: { option.value },
                                            set: { session.setAdditional(option.id, value: $0) }
                                        )
                                    ) {
                                        ForEach(option.choices) { choice in
                                            Text(choice.titleIsUserData == true ? choice.title : L10n.text(choice.title)).tag(choice.id)
                                        }
                                    }.disabled(!option.isEnabled)
                                        .help(L10n.text(option.description ?? ""))
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .disabled(!session.canEdit || session.busy)
            }
            Divider()
            HStack(alignment: .center, spacing: 12) {
                if let issue = session.validationIssue {
                    Text(L10n.text(issue)).foregroundStyle(.red).font(.caption)
                } else if let error = session.error {
                    Text(VectorSymbologyErrorPresentation.text(error)).foregroundStyle(.red).font(.caption).textSelection(.enabled)
                }
                Spacer()
                Button(L10n.text("Cancel"), role: .cancel) { store.activeTool = nil }
                    .keyboardShortcut(.cancelAction)
                    .disabled(session.busy)
                Button(L10n.text("Apply")) {
                    let origin = context
                    Task {
                        if let update = await session.apply(provider: store.vectorSymbologyProvider),
                           context.hasSameVisualTarget(as: origin),
                           store.projectSessionID == origin.projectSessionID {
                            store.installMapUpdate(update, mapID: origin.mapID)
                            store.activeTool = nil
                        }
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!session.canEdit || session.busy || store.vectorSymbologyProvider == nil || session.validationIssue != nil)
            }.padding(16)
        }
        .frame(minWidth: 640, idealWidth: 740, maxWidth: 1100, minHeight: 460, idealHeight: 680, maxHeight: 1000)
        .task(id: store.mapWorkflowIdentity(mapID)) {
            await store.refreshVectorSymbologyContexts(mapID: mapID)
            reconcileContextSelection()
        }
        .task(id: context) { await session.load(context: context, provider: store.vectorSymbologyProvider) }
        .onChange(of: store.vectorSymbologyContextRevision) { _, _ in reconcileContextSelection() }
        .onChange(of: store.lastActiveMapID) { _, value in
            mapID = value
            selectedContext = nil
        }
        .onChange(of: store.selectedAssetID) { _, value in
            assetID = value
            selectedContext = nil
        }
        .onDisappear { session.invalidate() }
    }

    private func reconcileContextSelection() {
        guard let selectedContext else { return }
        guard let latest = contextOptions.first(where: { $0.hasSameVisualTarget(as: selectedContext) }) else {
            self.selectedContext = nil
            return
        }
        self.selectedContext = latest
    }
}

struct VectorPropertyRow: View {
    let option: VectorStyleOption
    @ObservedObject var session: VectorSymbologySession
    @State private var showsEditor = false
    @State private var showsConditions = false

    private func editor(conditions: Bool, previews: Bool) -> VectorOptionEditor {
        var copy = option
        copy.conditionsEnabled = conditions
        copy.showLightDarkPreview = previews
        return VectorOptionEditor(option: copy, session: session)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(option.nameIsUserData ? option.name : L10n.text(option.name))
                Spacer()
                Button { showsEditor.toggle() } label: {
                    VectorStylePreview(style: option.style, type: option.type, maxPointSize: 28, maxFontSize: 24)
                        .frame(width: 56, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.text("Edit Symbology"))
                .popover(isPresented: $showsEditor) { editor(conditions: false, previews: true).padding(16).frame(width: 360) }
                if option.conditionsEnabled {
                    Button { showsConditions.toggle() } label: {
                        Image(systemName: showsConditions ? "chevron.up" : "line.3.horizontal.decrease.circle")
                    }
                    .help(L10n.text("Conditional Rules"))
                    .disabled(!option.supportsAttributeConditions)
                }
            }
            if showsConditions && option.supportsAttributeConditions {
                editor(conditions: true, previews: false)
            }
        }
    }
}

struct VectorOptionEditor: View {
    let option: VectorStyleOption
    @ObservedObject var session: VectorSymbologySession
    @State private var rulesFor: VectorStyleProperty?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(option.properties, id: \.self) { property in
                HStack {
                    propertyEditor(property)
                    if option.supportsAttributeConditions {
                        Button { rulesFor = property } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }
                        .help(L10n.text("Conditional Rules"))
                        .popover(isPresented: Binding(
                            get: { rulesFor == property },
                            set: { if !$0 { rulesFor = nil } }
                        )) {
                            VectorConditionsTable(option: option, property: property, session: session)
                                .padding(16)
                                .frame(width: 700, height: 380)
                        }
                    }
                }
            }
            if option.type == .text {
                ColorPicker(L10n.text("Text Color"), selection: color(\.fillColor), supportsOpacity: true)
                number(L10n.text("Font Size"), field: .penWidth)
                ColorPicker(L10n.text("Halo Color"), selection: color(\.haloColor), supportsOpacity: true)
                number(L10n.text("Halo Thickness"), field: .haloThickness)
                Picker(L10n.text("Text Emphasis"), selection: Binding(
                    get: { option.style.textEmphasis },
                    set: { value in session.edit(option.id) { $0.style.textEmphasis = value } }
                )) {
                    Text(L10n.text("Normal")).tag(0)
                    Text(L10n.text("Bold")).tag(1)
                    Text(L10n.text("Italic")).tag(2)
                    if !(0...2).contains(option.style.textEmphasis) { Text(String(option.style.textEmphasis)).tag(option.style.textEmphasis) }
                }
            }
            Button(L10n.text("Reset Default")) { session.reset(option.id) }
                .frame(maxWidth: .infinity, alignment: .trailing)
            if option.showLightDarkPreview {
                HStack(spacing: 0) {
                    preview.environment(\.colorScheme, .light)
                    preview.environment(\.colorScheme, .dark)
                }
                .frame(height: 64)
                .clipShape(.rect(cornerRadius: 6))
                .accessibilityLabel(L10n.text("Light and Dark Preview"))
            }
        }
        .disabled(!session.canEdit || session.busy)
    }

    @ViewBuilder private func propertyEditor(_ property: VectorStyleProperty) -> some View {
        switch property {
        case .penColor:
            ColorPicker(L10n.text(property.title), selection: color(\.penColor), supportsOpacity: true)
        case .fillColor:
            ColorPicker(L10n.text(property.title), selection: color(\.fillColor), supportsOpacity: true)
        case .penWidth:
            number(L10n.text(property.title), field: .penWidth)
        case .pointSize:
            LabeledContent(L10n.text(property.title)) {
                TextField(L10n.text(property.title), text: numericInput(.pointSize))
                .frame(width: 100)
            }
            if session.numericInputIsInvalid(optionID: option.id, field: .pointSize) {
                numericInputIssue
            }
        }
    }

    private func color(_ path: WritableKeyPath<VectorSymbologyStyle, String>) -> Binding<Color> {
        Binding(
            get: { BoundaryARGBColor.decode(option.style[keyPath: path]) ?? .clear },
            set: { value in session.edit(option.id) { $0.style[keyPath: path] = BoundaryARGBColor.encode(value) } }
        )
    }

    @ViewBuilder private func number(_ title: String, field: VectorStyleNumberField) -> some View {
        LabeledContent(title) {
            TextField(title, text: numericInput(field))
            .frame(width: 100)
        }
        if session.numericInputIsInvalid(optionID: option.id, field: field) {
            numericInputIssue
        }
    }

    private func numericInput(_ field: VectorStyleNumberField) -> Binding<String> {
        Binding(
            get: { session.numericInputText(optionID: option.id, field: field) },
            set: { session.setNumericInputText($0, optionID: option.id, field: field) }
        )
    }

    private var numericInputIssue: some View {
        Text(L10n.text(VectorSymbologyValidation.invalidNumberDraft))
            .font(.caption)
            .foregroundStyle(.red)
            .textSelection(.enabled)
    }

    private var preview: some View {
        VectorStylePreview(style: option.style, type: option.type).frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
    }
}

private struct VectorConditionsTable: View {
    let option: VectorStyleOption
    let property: VectorStyleProperty
    @ObservedObject var session: VectorSymbologySession
    @State private var selection: Set<UUID> = []

    private var rows: [VectorCondition] {
        session.options.first { $0.id == option.id }?.conditions[property] ?? []
    }
    private var selectedRowIndex: Int? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return rows.firstIndex { $0.id == id }
    }
    private var selectableColumns: [VectorAttributeColumn] {
        option.columns.filter { $0.kind.supportsConditions }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text(property.title)).font(.headline)
            if !option.supportsAttributeConditions {
                Label(L10n.text(option.conditionCapabilityReason ?? "Conditional rules are not available for this source."), systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            } else if selectableColumns.isEmpty {
                Label(L10n.text("No supported attribute columns are available for conditional rules."), systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            Table(rows, selection: $selection) {
                TableColumn(L10n.text("Column")) { row in
                    columnPicker(row)
                }.width(min: 130, ideal: 180)
                TableColumn(L10n.text("Operator")) { row in
                    operatorPicker(row)
                }.width(120)
                TableColumn(L10n.text("Threshold")) { row in
                    TextField(L10n.text("Threshold"), text: text(row.id, \.threshold))
                }.width(min: 100, ideal: 140)
                TableColumn(L10n.text("Value")) { row in
                    TextField(L10n.text("Value"), text: text(row.id, \.resultValue))
                }.width(min: 100, ideal: 140)
            }
            HStack {
                Button { session.edit(option.id) { $0.conditions[property, default: []].append(.init()) } } label: {
                    Label(L10n.text("Add"), systemImage: "plus")
                }.disabled(selectableColumns.isEmpty)
                Button { moveSelection(by: -1) } label: {
                    Label(L10n.text("Move Up"), systemImage: "arrow.up")
                }.disabled(selectedRowIndex.map { $0 == 0 } ?? true)
                Button { moveSelection(by: 1) } label: {
                    Label(L10n.text("Move Down"), systemImage: "arrow.down")
                }.disabled(selectedRowIndex.map { $0 == rows.count - 1 } ?? true)
                Button(role: .destructive) {
                    session.edit(option.id) { $0.conditions[property]?.removeAll { selection.contains($0.id) } }
                    selection = []
                } label: {
                    Label(L10n.text("Remove"), systemImage: "minus")
                }.disabled(selection.isEmpty)
                Spacer()
            }
            if let issue = session.validationIssue {
                Text(L10n.text(issue)).font(.caption).foregroundStyle(.red)
            }
        }
        .disabled(!session.canEdit || session.busy || !option.supportsAttributeConditions)
    }

    @ViewBuilder private func columnPicker(_ row: VectorCondition) -> some View {
        Picker(L10n.text("Column"), selection: column(row.id)) {
            Text(L10n.text("Choose a column")).tag("")
            ForEach(selectableColumns) { column in Text(column.name).tag(column.name) }
            if !row.column.isEmpty, !option.columns.contains(where: { $0.name == row.column }) {
                Text(row.column).tag(row.column)
            } else if !row.column.isEmpty,
                      option.columns.first(where: { $0.name == row.column })?.kind == .unsupported {
                Text(row.column).tag(row.column)
            }
        }
        .labelsHidden()
    }

    @ViewBuilder private func operatorPicker(_ row: VectorCondition) -> some View {
        let allowed = option.operators(for: row.column)
        Picker(L10n.text("Operator"), selection: text(row.id, \.comparison)) {
            ForEach(allowed, id: \.self) { value in Text(L10n.text(value)).tag(value) }
            if !allowed.contains(row.comparison) { Text(L10n.text(row.comparison)).tag(row.comparison) }
        }
        .labelsHidden()
        .disabled(allowed.isEmpty)
    }

    private func column(_ id: UUID) -> Binding<String> {
        Binding(
            get: { rows.first { $0.id == id }?.column ?? "" },
            set: { value in
                session.edit(option.id) { current in
                    guard var rules = current.conditions[property],
                          let index = rules.firstIndex(where: { $0.id == id }) else { return }
                    rules[index].column = value
                    let allowed = current.operators(for: value)
                    if !allowed.contains(rules[index].comparison), let first = allowed.first {
                        rules[index].comparison = first
                    }
                    current.conditions[property] = rules
                }
            }
        )
    }

    private func text(_ id: UUID, _ path: WritableKeyPath<VectorCondition, String>) -> Binding<String> {
        Binding(
            get: { rows.first { $0.id == id }?[keyPath: path] ?? "" },
            set: { value in
                session.edit(option.id) { current in
                    guard var rules = current.conditions[property],
                          let index = rules.firstIndex(where: { $0.id == id }) else { return }
                    rules[index][keyPath: path] = value
                    current.conditions[property] = rules
                }
            }
        )
    }

    private func moveSelection(by offset: Int) {
        guard let selectedRowIndex, rows.indices.contains(selectedRowIndex) else { return }
        let id = rows[selectedRowIndex].id
        session.moveCondition(optionID: option.id, property: property, conditionID: id, offset: offset)
    }
}

struct VectorStylePreview: View {
    let style: VectorSymbologyStyle
    let type: VectorType
    var maxPointSize: Double = 0
    var maxFontSize: Double = 0

    private var width: Double { style.penWidth.isFinite ? max(0, style.penWidth) : 0 }
    private var pointSize: Double {
        let value = Double(max(0, style.pointSize))
        return maxPointSize > 0 ? min(value, maxPointSize) : value
    }
    private var outlineSize: Double {
        let value = Double(max(0, style.pointSize)) + width * 2
        return maxPointSize > 0 ? min(value, maxPointSize) : value
    }
    private func sourceColor(_ value: String) -> Color { BoundaryARGBColor.decode(value) ?? .clear }

    var body: some View {
        Group {
            switch type {
            case .point:
                ZStack {
                    Circle().fill(sourceColor(style.penColor)).frame(width: outlineSize, height: outlineSize)
                    Circle().fill(sourceColor(style.fillColor)).frame(width: pointSize, height: pointSize)
                }
            case .segment, .line:
                Rectangle().fill(sourceColor(style.penColor)).frame(height: width).padding(.horizontal, 8)
            case .polygon, .complexPolygon:
                Rectangle().fill(sourceColor(style.fillColor))
                    .overlay(Rectangle().strokeBorder(sourceColor(style.penColor), lineWidth: width))
                    .padding(8)
            case .text:
                Text("Aa")
                    .font(.system(size: max(1, maxFontSize > 0 ? min(width, maxFontSize) : width), weight: style.textEmphasis == 1 ? .bold : .regular))
                    .italic(style.textEmphasis == 2)
                    .foregroundStyle(sourceColor(style.fillColor))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}
