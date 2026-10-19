import AppKit
import SwiftUI

/// Native menu presentation for BetterComboBox, ComboBoxPropertyItem, and
/// LinkableComboBox selection routes. Options and their display order must
/// come from the source session; this view only writes the selected key.
struct OriginalChoicePropertyItem: View {
    let field: SourceEditorField
    let choices: [EditorChoice]
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    var onSelect: ((EditorChoice) -> Void)? = nil
    @State private var isSearchFlyoutPresented = false
    @State private var searchText = ""

    private var currentValue: String { session.fields[field.storageID] ?? "" }
    private var currentChoice: EditorChoice? { choices.first { $0.id == currentValue } }
    private var enabled: Bool { field.isReadOnly != true && field.canEditDraft(in: session) && !store.isSavingAll }
    private var usesSearchFlyout: Bool {
        field.sourceControl.localizedCaseInsensitiveContains("bettercombobox")
    }
    private var visibleChoices: [EditorChoice] {
        guard !searchText.isEmpty else { return choices }
        return choices.filter { choice in
            choice.id.localizedCaseInsensitiveContains(searchText) ||
                displayedChoiceTitle(choice).localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        LabeledContent(LocalizedStringKey(field.title)) {
            Group {
                if usesSearchFlyout {
                    Button { isSearchFlyoutPresented = true } label: { pickerLabel }
                        .buttonStyle(.plain)
                        .popover(isPresented: $isSearchFlyoutPresented, arrowEdge: .trailing) {
                            searchFlyout
                        }
                } else {
                    Menu {
                        ForEach(choices) { choice in
                            choiceButton(choice)
                        }
                    } label: {
                        pickerLabel
                    }
                }
            }
            .disabled(!enabled || choices.isEmpty)
            .accessibilityLabel(LocalizedStringKey(field.title))
        }
        .onChange(of: isSearchFlyoutPresented) { _, presented in
            if !presented { searchText = "" }
        }
    }

    private var pickerLabel: some View {
        HStack(spacing: 6) {
            if field.hasMixedDraft(in: session) {
                Text("Mixed values")
            } else if let currentChoice {
                choiceContent(currentChoice)
            } else if !currentValue.isEmpty {
                Text(verbatim: currentValue)
            } else {
                Text(LocalizedStringKey(field.placeholder.isEmpty ? "—" : field.placeholder))
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contentShape(Rectangle())
    }

    private func choiceButton(_ choice: EditorChoice) -> some View {
        Button {
            select(choice)
            isSearchFlyoutPresented = false
        } label: {
            HStack(spacing: 8) {
                choiceContent(choice)
                if choice.id == currentValue {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
    }

    private var searchFlyout: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search options", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(Text("Search options"))
            if visibleChoices.isEmpty {
                Text("No options match the search.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(visibleChoices) { choice in
                            Button {
                                select(choice)
                                isSearchFlyoutPresented = false
                            } label: {
                                HStack(spacing: 8) {
                                    choiceContent(choice)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if choice.id == currentValue {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(choice.id == currentValue ? .isSelected : [])
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 320)
            }
        }
        .padding(12)
        .frame(minWidth: 260, idealWidth: 320)
        .disabled(!enabled)
    }

    @ViewBuilder
    private func choiceContent(_ choice: EditorChoice) -> some View {
        HStack(spacing: 7) {
            if let symbol = sourceIconSymbol(choice.sourceIcon) {
                Image(systemName: symbol).foregroundStyle(.secondary)
            }
            if choice.titleIsUserData == true {
                Text(verbatim: choice.title)
            } else {
                Text(LocalizedStringKey(choice.title))
            }
        }
    }

    private func select(_ choice: EditorChoice) {
        if let onSelect { onSelect(choice) }
        else { field.setDraftValue(choice.id, in: session) }
    }

    private func sourceIconSymbol(_ sourceIcon: String?) -> String? {
        switch sourceIcon {
        case "CPUColored1": "cpu"
        case "GPUColored": "memorychip"
        default: nil
        }
    }

    private func displayedChoiceTitle(_ choice: EditorChoice) -> String {
        choice.titleIsUserData == true ? choice.title : L10n.text(choice.title)
    }
}

/// Source ColorPickerPropertyItem using the project's RRGGBBAA draft format.
struct OriginalColorPickerPropertyItem: View {
    let field: SourceEditorField
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    var supportsOpacity = true

    private var selection: Binding<Color> {
        Binding(
            get: { EditorColor.decode(session.fields[field.storageID] ?? "") },
            set: { field.setDraftValue(EditorColor.encode($0), in: session) }
        )
    }

    var body: some View {
        LabeledContent(LocalizedStringKey(field.title)) {
            HStack(spacing: 8) {
                ColorPicker("", selection: selection, supportsOpacity: supportsOpacity)
                    .labelsHidden()
                    .disabled(!field.canEditDraft(in: session) || store.isSavingAll)
                    .accessibilityLabel(LocalizedStringKey(field.title))
                if field.hasMixedDraft(in: session) {
                    Text("Mixed values").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Native text entry for InputTextPropertyItem and ValidateableTextBox routes.
/// A source clear command is optional because the original command can have
/// behavior beyond assigning an empty string; callers pass it only when the
/// source instance exposes ShowClearButton and ClearCommand.
struct OriginalInputTextPropertyItem: View {
    let field: SourceEditorField
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    var acceptsReturn = false
    var showsClearButton = false
    var clearAction: (() -> Void)? = nil
    var validationMessage: String? = nil
    var onSubmit: (() -> Void)? = nil
    var textBinding: Binding<String>? = nil
    var mixedValue: Bool? = nil
    var onCommit: (() -> Void)? = nil
    var onEscape: ((String) -> Void)? = nil
    var allowsPendingGeometryRegionInput = false

    @FocusState private var isFocused: Bool
    @State private var valueAtFocus = ""

    private var value: String { textBinding?.wrappedValue ?? session.fields[field.storageID] ?? "" }
    private var isMixed: Bool { mixedValue ?? field.hasMixedDraft(in: session) }
    private var prompt: Text {
        Text(isMixed ? LocalizedStringKey("Mixed values") : LocalizedStringKey(field.placeholder.isEmpty ? "—" : field.placeholder))
    }
    private var canEdit: Bool {
        field.isReadOnly != true &&
            field.canEditDraft(in: session, allowingPendingGeometryRegionInput: allowsPendingGeometryRegionInput) &&
            !store.isSavingAll
    }
    private var geometryRegionInputWriteIsPending: Bool {
        allowsPendingGeometryRegionInput && session.geometryTopology?.isWritingRegionInputs == true
    }
    private var binding: Binding<String> { textBinding ?? field.draftBinding(in: session) }

    var body: some View {
        Group {
            if field.readOnly || field.isReadOnly == true || session.readOnlyFieldIDs.contains(field.storageID) {
                OriginalTextPropertyItem(title: field.title, value: value.isEmpty ? "—" : value)
            } else if acceptsReturn {
                LabeledContent(LocalizedStringKey(field.title)) {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: binding)
                            .frame(minHeight: 84)
                            .focused($isFocused)
                            .onExitCommand(perform: restoreValueAtFocus)
                            .accessibilityLabel(LocalizedStringKey(field.title))
                        if value.isEmpty {
                            prompt.foregroundStyle(.secondary)
                                .padding(.leading, 5)
                                .padding(.top, 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .disabled(!canEdit)
                    .overlay(alignment: .trailing) { clearButton }
                }
            } else {
                LabeledContent(LocalizedStringKey(field.title)) {
                    HStack(spacing: 6) {
                        TextField("", text: binding, prompt: prompt)
                            .focused($isFocused)
                            .textInputSuggestions {
                                ForEach(Array((session.textSuggestions[field.storageID] ?? []).enumerated()), id: \.offset) { _, suggestion in
                                    Text(verbatim: suggestion).textInputCompletion(suggestion)
                                }
                            }
                            .onSubmit {
                                onSubmit?()
                                isFocused = false
                            }
                            .onExitCommand(perform: restoreValueAtFocus)
                            .accessibilityLabel(LocalizedStringKey(field.title))
                            .disabled(!canEdit)
                        clearButton
                    }
                }
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let validationMessage, !validationMessage.isEmpty {
                Text(verbatim: validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onChange(of: isFocused) { wasFocused, focused in
            if focused {
                valueAtFocus = value
            } else if wasFocused {
                onCommit?()
            }
        }
    }

    /// ValidateableTextBox defaults EscapeReturnsOriginalValue to true. Restore
    /// the focus-start text through the ordinary source draft setter; applying
    /// one value to a mixed selection is what clears the source mismatch flag.
    private func restoreValueAtFocus() {
        guard isFocused else { return }
        if let onEscape {
            onEscape(valueAtFocus)
        } else {
            field.setDraftValue(valueAtFocus, in: session)
        }
        isFocused = false
    }

    @ViewBuilder private var clearButton: some View {
        if showsClearButton, let clearAction {
            Button {
                // Source ClearCommand may reset a multi-selection or restore
                // a model-specific default. Its result is authoritative; a
                // second empty-string write here would overwrite that result.
                clearAction()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Clear"))
            .disabled(!canEdit || geometryRegionInputWriteIsPending)
        }
    }
}

/// Read-only TextPropertyItem equivalent, including the source copy command.
struct OriginalTextPropertyItem: View {
    let title: String
    let value: String
    var allowsCopy = true

    var body: some View {
        LabeledContent(LocalizedStringKey(title)) {
            Text(verbatim: value.isEmpty ? "—" : value)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .contextMenu {
                    if allowsCopy {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(value, forType: .string)
                        }
                    }
                }
        }
    }
}

/// ParagraphPropertyItem equivalent for multi-line read-only values.
struct OriginalParagraphPropertyItem: View {
    let title: String
    let value: String

    var body: some View {
        OriginalTextPropertyItem(title: title, value: value, allowsCopy: false)
    }
}

/// DynamicIconHeaderPropertyItem equivalent for routes that provide its text.
/// The source KnownResource and brush are optional because those values are
/// not part of SourceEditorField; callers must supply a mapped native symbol.
struct OriginalDynamicIconHeaderPropertyItem: View {
    let title: String
    let text: String
    var iconSystemName: String? = nil

    var body: some View {
        LabeledContent(LocalizedStringKey(title)) {
            HStack(alignment: .top, spacing: 8) {
                if let iconSystemName {
                    Image(systemName: iconSystemName)
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: text.isEmpty ? "—" : text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .contextMenu {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                    }
            }
        }
    }
}

/// ContentPropertyItem host for a caller-supplied native child view.
struct OriginalContentPropertyItem<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        LabeledContent(LocalizedStringKey(title)) { content }
    }
}

/// ControlHeader shell with caller-provided icon and subcontent so source
/// KnownResource/FrameworkElement values can be mapped without guessing them.
struct OriginalControlHeader<Icon: View, SubContent: View>: View {
    let text: String
    let backgroundColor: Color
    let dontRecolorIcon: Bool
    let icon: Icon
    let subContent: SubContent

    init(
        text: String,
        backgroundColor: Color,
        dontRecolorIcon: Bool,
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder subContent: () -> SubContent
    ) {
        self.text = text
        self.backgroundColor = backgroundColor
        self.dontRecolorIcon = dontRecolorIcon
        self.icon = icon()
        self.subContent = subContent()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.foregroundColor(dontRecolorIcon ? .primary : .accentColor)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: text)
                    .font(.headline)
                subContent
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(backgroundColor)
    }
}

/// IsLinkedControl toggles the explicit dynamic-link state. Configuration
/// existence or a connected external path must not be used as this binding.
struct OriginalIsLinkedControl: View {
    @Binding var isDynamicallyLinked: Bool

    var body: some View {
        Button {
            isDynamicallyLinked.toggle()
        } label: {
            Image(systemName: isDynamicallyLinked ? "link" : "link.slash")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey(isDynamicallyLinked ? "Linked" : "Unlinked")))
    }
}

/// SimpleListPropertyItem equivalent. The caller supplies the exact source
/// item sequence and ShowItemsCount setting from that property-item instance.
struct OriginalSimpleListPropertyItem: View {
    let title: String
    let items: [String]
    let showItemsCount: Bool
    @State private var isExpanded: Bool

    init(title: String, items: [String], showItemsCount: Bool, isExpanded: Bool = false) {
        self.title = title
        self.items = items
        self.showItemsCount = showItemsCount
        _isExpanded = State(initialValue: isExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text(verbatim: item)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .contextMenu {
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(item, forType: .string)
                            }
                        }
                }
            }
        } label: {
            HStack {
                Text(LocalizedStringKey(title))
                Spacer(minLength: 6)
                if showItemsCount { Text(verbatim: String(items.count)).foregroundStyle(.secondary) }
            }
        }
    }
}

/// One read-only child PropertyItem in a source PropertyItemListPropertyItem.
/// Labels are fixed UI copy; values are model/runtime data and stay verbatim.
struct OriginalPropertyListEntry: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let value: String

    init(id: String? = nil, label: String, value: String) {
        self.id = id ?? label
        self.label = label
        self.value = value
    }
}

/// Native expandable ordered list for source PropertyItemListPropertyItem
/// instances. The caller must pass the exact child items from its source host;
/// SourceEditorSchema.children is an editor-page route and is not this list.
struct OriginalPropertyItemListPropertyItem: View {
    let title: String
    let items: [OriginalPropertyListEntry]
    let showItemsCount: Bool
    @State private var isExpanded: Bool

    init(title: String, items: [OriginalPropertyListEntry], showItemsCount: Bool = false, isExpanded: Bool = true) {
        self.title = title
        self.items = items
        self.showItemsCount = showItemsCount
        _isExpanded = State(initialValue: isExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items) { item in
                    OriginalTextPropertyItem(title: item.label, value: item.value)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text(LocalizedStringKey(title))
                Spacer(minLength: 6)
                if showItemsCount {
                    Text(verbatim: String(items.count))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
