import AppKit
import Foundation
import SwiftUI

/// Modifier state for the source ListViewSelectionMode.Extended behavior.
struct SharedVisualListSelectionModifiers: OptionSet, Sendable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static let command = Self(rawValue: 1 << 0)
    static let control = Self(rawValue: 1 << 1)
    static let shift = Self(rawValue: 1 << 2)
}

enum SharedVisualBetterComboBoxSelection {
    static func firstSelectableID<ID: Hashable>(
        selectedID: ID?,
        items: [(id: ID, isSelectable: Bool)],
        selectsFirstWhenUnselected: Bool
    ) -> ID? {
        guard selectedID == nil, selectsFirstWhenUnselected else { return nil }
        return items.first(where: { $0.isSelectable })?.id
    }
}

enum SharedVisualComboBoxSelectionTransition {
    static func perform<Item>(
        _ item: Item,
        beforeSelection: ((Item) -> Void)?,
        setSelection: (Item) -> Void,
        selectionChanged: ((Item) -> Void)?
    ) {
        beforeSelection?(item)
        setSelection(item)
        selectionChanged?(item)
    }
}

/// Pure selection transition used by CollapsibleListView and its state tests.
struct SharedVisualExtendedSelectionState<ID: Hashable> {
    var selectedIDs: Set<ID>
    var anchorID: ID?

    init(selectedIDs: Set<ID> = [], anchorID: ID? = nil) {
        self.selectedIDs = selectedIDs
        self.anchorID = anchorID
    }

    mutating func select(_ id: ID, orderedIDs: [ID], modifiers: SharedVisualListSelectionModifiers) {
        let extendsSelection = modifiers.contains(.command) || modifiers.contains(.control)
        if modifiers.contains(.shift),
           let anchorID,
           let anchorIndex = orderedIDs.firstIndex(of: anchorID),
           let targetIndex = orderedIDs.firstIndex(of: id) {
            let lower = min(anchorIndex, targetIndex)
            let upper = max(anchorIndex, targetIndex)
            let range = Set(orderedIDs[lower...upper])
            selectedIDs = extendsSelection ? selectedIDs.union(range) : range
            return
        }

        if extendsSelection {
            if !selectedIDs.insert(id).inserted {
                selectedIDs.remove(id)
            }
        } else {
            selectedIDs = [id]
        }
        anchorID = id
    }

    mutating func retainAvailableItems(_ orderedIDs: [ID]) {
        let available = Set(orderedIDs)
        selectedIDs.formIntersection(available)
        if let anchorID, !available.contains(anchorID) { self.anchorID = nil }
    }
}

/// Native Menu-based equivalent of BetterComboBox. Callers provide the
/// source items, row templates, selectable predicate, and binding.
struct SharedVisualBetterComboBox<Item: Identifiable, Row: View, SelectedRow: View>: View where Item.ID: Hashable {
    let items: [Item]
    @Binding var selectedID: Item.ID?
    var placeholder: String?
    var accessibilityTitle: String?
    var selectsFirstItemWhenUnselected = false
    var isSelectable: (Item) -> Bool
    var onSelection: (Item) -> Void
    var beforeSelectionWhenPlaceholder: ((Item) -> Void)?
    let menuHeader: AnyView
    let menuFooter: AnyView
    let row: (Item) -> Row
    let selectedRow: (Item) -> SelectedRow

    init(
        items: [Item],
        selectedID: Binding<Item.ID?>,
        placeholder: String? = nil,
        accessibilityTitle: String? = nil,
        selectsFirstItemWhenUnselected: Bool = false,
        isSelectable: @escaping (Item) -> Bool = { _ in true },
        onSelection: @escaping (Item) -> Void = { _ in },
        beforeSelectionWhenPlaceholder: ((Item) -> Void)? = nil,
        menuHeader: AnyView = AnyView(EmptyView()),
        menuFooter: AnyView = AnyView(EmptyView()),
        @ViewBuilder row: @escaping (Item) -> Row,
        @ViewBuilder selectedRow: @escaping (Item) -> SelectedRow
    ) {
        self.items = items
        _selectedID = selectedID
        self.placeholder = placeholder
        self.accessibilityTitle = accessibilityTitle
        self.selectsFirstItemWhenUnselected = selectsFirstItemWhenUnselected
        self.isSelectable = isSelectable
        self.onSelection = onSelection
        self.beforeSelectionWhenPlaceholder = beforeSelectionWhenPlaceholder
        self.menuHeader = menuHeader
        self.menuFooter = menuFooter
        self.row = row
        self.selectedRow = selectedRow
    }

    private var selectedItem: Item? {
        if let selectedID { return items.first { $0.id == selectedID } }
        return selectsFirstItemWhenUnselected ? items.first(where: isSelectable) : nil
    }

    private var selectableIDs: [Item.ID] { items.filter(isSelectable).map(\.id) }

    var body: some View {
        Menu {
            menuHeader
            ForEach(items) { item in
                Button {
                    SharedVisualComboBoxSelectionTransition.perform(
                        item,
                        beforeSelection: beforeSelectionWhenPlaceholder,
                        setSelection: { selectedID = $0.id },
                        selectionChanged: onSelection
                    )
                } label: {
                    HStack(spacing: 8) {
                        row(item)
                        Spacer(minLength: 8)
                        if item.id == selectedID { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                    .contentShape(Rectangle())
                }
                .disabled(!isSelectable(item))
            }
            menuFooter
        } label: {
            HStack(spacing: 8) {
                Group {
                    if let selectedItem {
                        selectedRow(selectedItem)
                    } else if let placeholder {
                        Text(L10n.text(placeholder)).foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: "")
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down").font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.bordered)
        .accessibilityElement(children: .combine)
        .modifier(SharedVisualOptionalAccessibilityLabel(label: accessibilityTitle))
        .onAppear(perform: normalizeSelection)
        .onChange(of: items.map(\.id)) { _, _ in normalizeSelection() }
        .onChange(of: selectableIDs) { _, _ in normalizeSelection() }
        .onChange(of: selectsFirstItemWhenUnselected) { _, _ in normalizeSelection() }
        .onChange(of: selectedID) { _, _ in normalizeSelection() }
    }

    private func normalizeSelection() {
        guard let id = SharedVisualBetterComboBoxSelection.firstSelectableID(
            selectedID: selectedID,
            items: items.map { (id: $0.id, isSelectable: isSelectable($0)) },
            selectsFirstWhenUnselected: selectsFirstItemWhenUnselected
        ), let item = items.first(where: { $0.id == id }) else { return }
        selectedID = id
        onSelection(item)
    }
}

private struct SharedVisualOptionalAccessibilityLabel: ViewModifier {
    let label: String?

    @ViewBuilder func body(content: Content) -> some View {
        if let label {
            content.accessibilityLabel(L10n.text(label))
        } else {
            content
        }
    }
}

/// BetterComboBoxPropertyItem presentation wrapper. Selection state and source
/// value conversion remain with the caller, as on the original PropertyItem.
struct SharedVisualBetterComboBoxPropertyItem<Control: View>: View {
    let label: String
    let control: Control

    init(label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        LabeledContent { control } label: { Text(L10n.text(label)) }
    }
}

/// ComboBoxPropertyItem equivalent with the source placeholder force-set
/// ordering and selected-value callback exposed as real caller actions.
struct SharedVisualComboBoxPropertyItem<Item: Identifiable, Row: View>: View where Item.ID: Hashable {
    let label: String
    let items: [Item]
    @Binding var selectedID: Item.ID?
    var showPlaceholder: Bool
    var placeholderText: String?
    var forceSetCommand: ((Item) -> Void)?
    var selectedValueChanged: ((Item) -> Void)?
    var isSelectable: (Item) -> Bool
    let row: (Item) -> Row

    init(
        label: String,
        items: [Item],
        selectedID: Binding<Item.ID?>,
        showPlaceholder: Bool = false,
        placeholderText: String? = nil,
        forceSetCommand: ((Item) -> Void)? = nil,
        selectedValueChanged: ((Item) -> Void)? = nil,
        isSelectable: @escaping (Item) -> Bool = { _ in true },
        @ViewBuilder row: @escaping (Item) -> Row
    ) {
        self.label = label
        self.items = items
        _selectedID = selectedID
        self.showPlaceholder = showPlaceholder
        self.placeholderText = placeholderText
        self.forceSetCommand = forceSetCommand
        self.selectedValueChanged = selectedValueChanged
        self.isSelectable = isSelectable
        self.row = row
    }

    var body: some View {
        LabeledContent {
            SharedVisualBetterComboBox(
                items: items,
                selectedID: $selectedID,
                placeholder: showPlaceholder ? placeholderText : nil,
                isSelectable: isSelectable,
                onSelection: { selectedValueChanged?($0) },
                beforeSelectionWhenPlaceholder: showPlaceholder ? forceSetCommand : nil,
                row: row,
                selectedRow: row
            )
        } label: {
            Text(L10n.text(label))
        }
    }
}

/// SimpleListPropertyItem equivalent. Item strings are source values and are
/// intentionally rendered verbatim; only the fixed property label is localized.
struct SharedVisualSimpleListPropertyItem: View {
    let title: String
    let items: [String]
    var showItemsCount: Bool
    @State private var isExpanded: Bool

    init(title: String, items: [String], showItemsCount: Bool = false, isExpanded: Bool = false) {
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
                            Button(L10n.text("Copy")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(item, forType: .string)
                            }
                        }
                }
            }
        } label: {
            HStack {
                Text(L10n.text(title))
                Spacer(minLength: 6)
                if showItemsCount { Text(verbatim: String(items.count)).foregroundStyle(.secondary) }
            }
        }
    }
}

/// PropertyItemListPropertyItem equivalent. The original owner supplies the
/// exact ordered child items and receives expansion state through a binding.
struct SharedVisualPropertyItemListPropertyItem<Item: Identifiable, Row: View>: View where Item.ID: Hashable {
    let title: String
    let items: [Item]
    var showItemsCount: Bool
    @Binding var isExpanded: Bool
    let row: (Item) -> Row

    init(
        title: String,
        items: [Item],
        showItemsCount: Bool = false,
        isExpanded: Binding<Bool>,
        @ViewBuilder row: @escaping (Item) -> Row
    ) {
        self.title = title
        self.items = items
        self.showItemsCount = showItemsCount
        _isExpanded = isExpanded
        self.row = row
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items) { item in row(item) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text(L10n.text(title))
                Spacer(minLength: 6)
                if showItemsCount { Text(verbatim: String(items.count)).foregroundStyle(.secondary) }
            }
        }
    }
}

/// SliderNumberBox equivalent using native text entry, a bounded-step Stepper,
/// and the original horizontal drag increment. Invalid text remains visible.
struct SharedVisualSliderNumberBox: View {
    let label: String
    @Binding var value: String
    var increment: Double = 1
    var validation: (String) -> SharedVisualValidationMessage? = { _ in nil }
    @State private var validationMessage: SharedVisualValidationMessage?
    @State private var lastDragTranslation: CGFloat = 0
    @State private var dragValue: Double?
    @FocusState private var isTextFieldFocused: Bool

    init(
        label: String = "Value",
        value: Binding<String>,
        increment: Double = 1,
        validation: @escaping (String) -> SharedVisualValidationMessage? = { _ in nil }
    ) {
        self.label = label
        _value = value
        self.increment = increment
        self.validation = validation
    }

    private var parsedValue: Double? {
        SharedVisualSliderNumberBoxState.parse(value, locale: .current)
    }

    private var step: Double { abs(increment) }

    private var horizontalIncrementGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                guard !isTextFieldFocused, step.isFinite, step > 0 else { return }
                if dragValue == nil {
                    guard let parsedValue else { return }
                    dragValue = parsedValue
                    lastDragTranslation = 0
                }
                let delta = gesture.translation.width - lastDragTranslation
                lastDragTranslation = gesture.translation.width
                guard let next = SharedVisualSliderNumberBoxState.value(
                    current: dragValue ?? 0,
                    horizontalDelta: Double(delta),
                    increment: increment
                ) else { return }
                dragValue = next
                value = formatted(next)
            }
            .onEnded { _ in
                dragValue = nil
                lastDragTranslation = 0
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel(L10n.text(label))
                    .focused($isTextFieldFocused)
                    .onSubmit { validateCurrentValue() }
                HStack(spacing: 2) {
                    Button { adjust(by: -1) } label: {
                        Image(systemName: "minus")
                            .frame(width: 22, height: 24)
                    }
                    Button { adjust(by: 1) } label: {
                        Image(systemName: "plus")
                            .frame(width: 22, height: 24)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(parsedValue?.isFinite != true || !step.isFinite || step == 0)
                .accessibilityLabel(L10n.text("Adjust value"))
                Image(systemName: "arrow.left.and.right")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(parsedValue == nil || !step.isFinite || step == 0 ? .tertiary : .secondary)
                    .frame(width: 26, height: 28)
                    .contentShape(Rectangle())
                    .gesture(horizontalIncrementGesture)
                    .accessibilityElement()
                    .accessibilityLabel(L10n.text("Drag to adjust"))
                    .accessibilityValue(Text(verbatim: value))
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: adjust(by: 1)
                        case .decrement: adjust(by: -1)
                        @unknown default: break
                        }
                    }
                    .help(L10n.text("Drag horizontally to adjust the value"))
            }
            if let validationMessage {
                SharedVisualValidationErrorList(errors: [validationMessage])
            }
        }
        .onAppear(perform: validateCurrentValue)
        .onChange(of: value) { _, _ in validateCurrentValue() }
    }

    private func formatted(_ number: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        formatter.usesSignificantDigits = true
        formatter.maximumSignificantDigits = 17
        return formatter.string(from: NSNumber(value: number)) ?? String(number)
    }

    private func adjust(by stepCount: Double) {
        guard let current = parsedValue,
              step.isFinite, step > 0,
              let next = SharedVisualSliderNumberBoxState.value(current: current, horizontalDelta: stepCount, increment: increment) else { return }
        value = formatted(next)
    }

    private func validateCurrentValue() {
        if let callerValidation = validation(value) {
            validationMessage = callerValidation
        } else if let fallbackMessage = SharedVisualSliderNumberBoxState.invalidInputMessage(value, locale: .current) {
            validationMessage = SharedVisualValidationMessage(
                id: "slider-number-box-value",
                text: fallbackMessage,
                level: .typeError
            )
        } else {
            validationMessage = nil
        }
    }
}

enum SharedVisualSliderNumberBoxState {
    static func invalidInputMessage(_ text: String, locale: Locale) -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              parse(text, locale: locale) == nil else { return nil }
        return "The current input is not a valid number."
    }

    static func parse(_ text: String, locale: Locale) -> Double? {
        let decimalSeparator = locale.decimalSeparator ?? "."
        let groupingSeparator = locale.groupingSeparator
        var normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let groupingSeparator, !groupingSeparator.isEmpty {
            normalized = normalized.replacingOccurrences(of: groupingSeparator, with: "")
        }
        if decimalSeparator != "." {
            normalized = normalized.replacingOccurrences(of: decimalSeparator, with: ".")
        }
        guard let parsed = Double(normalized) else { return nil }
        return parsed
    }

    static func value(current: Double, horizontalDelta: Double, increment: Double) -> Double? {
        guard current.isFinite, horizontalDelta.isFinite, increment.isFinite else { return nil }
        let result = current + horizontalDelta * increment
        return result.isFinite ? result : nil
    }
}
