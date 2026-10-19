import AppKit
import Foundation
import SwiftUI

// The renamed source binds each property item back to its editor/session value.
// Keep that route here so native controls continue to edit the session draft.
@MainActor
extension SourceEditorField {
    func hasMixedDraft(in session: ModelEditorSession) -> Bool {
        mixedBy.flatMap { session.fields[scoped($0)] }?.lowercased() == "true"
    }

    func setDraftValue(_ value: String, in session: ModelEditorSession) {
        guard !readOnly, isReadOnly != true, !session.readOnlyFieldIDs.contains(storageID) else { return }
        session.set(storageID, value)
        session.clearMixedFlag(mixedBy.map(scoped))
    }

    func draftBinding(in session: ModelEditorSession) -> Binding<String> {
        Binding(
            get: { hasMixedDraft(in: session) ? "" : (session.fields[storageID] ?? "") },
            set: { setDraftValue($0, in: session) }
        )
    }

    func hasSourceValue(in session: ModelEditorSession) -> Bool {
        session.fields[storageID] != nil || session.images[storageID] != nil ||
            session.rows[storageID] != nil || session.sourceCollections[storageID] != nil
    }

    func canEditDraft(in session: ModelEditorSession,
                      allowingPendingGeometryRegionInput: Bool = false) -> Bool {
        let queuedGeometryInputIsOnlyBusyWork = allowingPendingGeometryRegionInput
            && session.canContinueGeometryRegionInput(self)
        return !readOnly && isReadOnly != true && !session.readOnlyFieldIDs.contains(storageID) &&
            session.canEdit && hasSourceValue(in: session) && (!session.isBusy || queuedGeometryInputIsOnlyBusyWork) &&
            !session.loadingSelection &&
            !enabledBy.contains { session.fields[scoped($0)]?.lowercased() == "false" }
    }
}

/// Native NumericPropertyItem replacement: editable number text plus a stepper.
struct OriginalNumericPropertyItem: View {
    let field: SourceEditorField
    @ObservedObject var session: ModelEditorSession
    @FocusState private var isFocused: Bool
    @State private var editText = ""
    @State private var validation: String?

    private var value: String { session.fields[field.storageID] ?? "" }
    private var isMixed: Bool { field.hasMixedDraft(in: session) }
    private var formattedValue: String {
        guard !isMixed else { return "" }
        guard let number = OriginalNumberBoxFormat.number(from: value) else { return value }
        return OriginalNumberBoxFormat.g8(number)
    }
    private var titleLabel: Text {
        field.titleIsPrelocalized == true ? Text(verbatim: field.title) : Text(LocalizedStringKey(field.title))
    }
    private var textBinding: Binding<String> {
        Binding(
            get: { isFocused || hasPendingText ? editText : formattedValue },
            set: receiveInput
        )
    }
    // NumericPropertyItem.Increment defaults to 1.0 in the original control.
    private let step = 1.0
    private var numericValue: Binding<Double> {
        Binding(
            get: { OriginalNumberBoxFormat.number(from: value) ?? 0 },
            set: { next in
                let status = OriginalNumberInputValidator.evaluate(String(next), minimum: field.minimum, maximum: field.maximum)
                guard case .valid(let number) = status else {
                    validation = originalNumberInputMessage(status)
                    return
                }
                field.setDraftValue(String(next), in: session)
                editText = OriginalNumberBoxFormat.g8(number)
                hasPendingText = false
                validation = nil
            }
        )
    }
    @State private var hasPendingText = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent {
                HStack(spacing: 8) {
                    TextField("", text: textBinding, prompt: Text(LocalizedStringKey(isMixed ? "Mixed values" : (field.placeholder.isEmpty ? "—" : field.placeholder))))
                        .frame(minWidth: 82, idealWidth: 110, maxWidth: 150)
                        .focused($isFocused)
                        .onSubmit {
                            commitInput()
                            isFocused = false
                        }
                        .accessibilityLabel(titleLabel)
                        .disabled(!field.canEditDraft(in: session))
                    Stepper("", value: numericValue, step: step)
                        .labelsHidden()
                        .disabled(isMixed || OriginalNumberBoxFormat.number(from: value) == nil || !field.canEditDraft(in: session))
                        .accessibilityLabel(titleLabel)
                }
            } label: { titleLabel }
            if let validation { Text(validation).font(.caption).foregroundStyle(.red) }
        }
        .onChange(of: isFocused) { _, focused in
            if focused {
                if !hasPendingText { editText = isMixed ? "" : formattedValue }
            } else {
                commitInput()
            }
        }
        .onChange(of: value) { _, newValue in
            if !isFocused && !hasPendingText { editText = formatted(newValue) }
        }
        .onChange(of: field.storageID) { _, _ in resetInput() }
        .onChange(of: session.modelAssetID) { _, _ in resetInput() }
    }

    private func receiveInput(_ rawValue: String) {
        editText = rawValue
        hasPendingText = true
        let status = OriginalNumberInputValidator.evaluate(rawValue, minimum: field.minimum, maximum: field.maximum)
        if case .valid = status {
            field.setDraftValue(rawValue, in: session)
            validation = nil
        } else {
            validation = originalNumberInputMessage(status)
        }
    }

    private func commitInput() {
        guard hasPendingText else { return }
        let status = OriginalNumberInputValidator.evaluate(editText, minimum: field.minimum, maximum: field.maximum)
        guard case .valid(let number) = status else {
            validation = originalNumberInputMessage(status)
            return
        }
        field.setDraftValue(editText, in: session)
        editText = OriginalNumberBoxFormat.g8(number)
        hasPendingText = false
        validation = nil
    }

    private func formatted(_ rawValue: String) -> String {
        guard let number = OriginalNumberBoxFormat.number(from: rawValue) else { return rawValue }
        return OriginalNumberBoxFormat.g8(number)
    }

    private func resetInput() {
        isFocused = false
        editText = ""
        hasPendingText = false
        validation = nil
    }
}

private enum OriginalNumberBoxFormat {
    static func g8(_ value: Double) -> String {
        // Text drafts are submitted to the source backend's invariant parser.
        // Keep their decimal separator stable across macOS locale settings.
        String(format: "%.8G", locale: Locale(identifier: "en_US_POSIX"), arguments: [value])
    }

    static func number(from string: String) -> Double? {
        guard let value = Double(string), value.isFinite else { return nil }
        return value
    }
}

/// Native NumberBox route. The editor keeps the user's raw string in its
/// session draft while editing and validates on submit/blur. G8 is a display
/// format only, so intermediate text such as "-", "1.", or a high-precision
/// value is never replaced while the field is focused.
struct OriginalNumberBoxPropertyItem: View {
    let field: SourceEditorField
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @FocusState private var isFocused: Bool
    @State private var editText = ""
    @State private var validation: String?
    @State private var hasPendingText = false

    private var value: String { session.fields[field.storageID] ?? "" }
    private var isMixed: Bool { field.hasMixedDraft(in: session) }
    private var isEditable: Bool { field.canEditDraft(in: session) && !store.isSavingAll }
    private var prompt: Text {
        Text(LocalizedStringKey(isMixed ? "Mixed values" : (field.placeholder.isEmpty ? "—" : field.placeholder)))
    }
    private var formattedValue: String {
        guard !isMixed else { return "" }
        guard let number = OriginalNumberBoxFormat.number(from: value) else { return value }
        return OriginalNumberBoxFormat.g8(number)
    }
    private var textBinding: Binding<String> {
        Binding(
            get: { isFocused || hasPendingText ? editText : formattedValue },
            set: receiveInput
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent(LocalizedStringKey(field.title)) {
                TextField("", text: textBinding, prompt: prompt)
                    .frame(minWidth: 82, idealWidth: 110, maxWidth: 180)
                    .focused($isFocused)
                    .onSubmit(commit)
                    .accessibilityLabel(LocalizedStringKey(field.title))
                    .disabled(!isEditable)
            }
            if let validation {
                Text(verbatim: validation)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onChange(of: isFocused) { _, focused in
            if focused {
                if !hasPendingText { editText = isMixed ? "" : formattedValue }
            } else {
                commit()
            }
        }
        .onChange(of: value) { _, newValue in
            if !isFocused && !hasPendingText { editText = formatted(newValue) }
        }
        .onChange(of: field.storageID) { _, _ in resetInput() }
        .onChange(of: session.modelAssetID) { _, _ in resetInput() }
    }

    private func receiveInput(_ rawValue: String) {
        editText = rawValue
        hasPendingText = true
        let status = OriginalNumberInputValidator.evaluate(rawValue, minimum: field.minimum, maximum: field.maximum)
        if case .valid = status {
            field.setDraftValue(rawValue, in: session)
            validation = nil
        } else {
            validation = originalNumberInputMessage(status)
        }
    }

    private func commit() {
        guard hasPendingText else { return }
        let status = OriginalNumberInputValidator.evaluate(editText, minimum: field.minimum, maximum: field.maximum)
        guard case .valid(let number) = status else {
            validation = originalNumberInputMessage(status)
            return
        }
        field.setDraftValue(editText, in: session)
        validation = nil
        editText = OriginalNumberBoxFormat.g8(number)
        hasPendingText = false
    }

    private func formatted(_ rawValue: String) -> String {
        guard let number = OriginalNumberBoxFormat.number(from: rawValue) else { return rawValue }
        return OriginalNumberBoxFormat.g8(number)
    }

    private func resetInput() {
        isFocused = false
        editText = ""
        hasPendingText = false
        validation = nil
    }
}

@MainActor
private func originalNumberInputMessage(_ status: OriginalNumberInputStatus) -> String? {
    switch status {
    case .empty, .valid:
        return nil
    case .invalid:
        return L10n.text("Enter a finite number.")
    case .belowMinimum(let minimum):
        return L10n.format("Enter a value greater than or equal to %@.", minimum.formatted())
    case .aboveMaximum(let maximum):
        return L10n.format("Enter a value less than or equal to %@.", maximum.formatted())
    }
}

/// A macOS checkbox can display the same native indeterminate state as the
/// source's nullable IsChecked / IsIndeterminate binding.
private struct MixedStateCheckbox: NSViewRepresentable {
    let title: String
    let isChecked: Bool
    let isMixed: Bool
    let isEnabled: Bool
    let onChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.valueChanged(_:)))
        button.allowsMixedState = true
        button.setAccessibilityLabel(title)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        button.allowsMixedState = true
        button.isEnabled = isEnabled
        button.state = isMixed ? .mixed : (isChecked ? .on : .off)
        button.setAccessibilityLabel(title)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: MixedStateCheckbox

        init(parent: MixedStateCheckbox) { self.parent = parent }

        @objc func valueChanged(_ sender: NSButton) {
            // The source cycles mixed -> true -> false -> true.
            parent.onChange(parent.isMixed ? true : sender.state == .on)
        }
    }
}

/// TriStateToggleSlider / ToggleablePropertyItem replacement, preserving a
/// native mixed mark when the source exposes a nullable or indeterminate value.
struct OriginalMixedTogglePropertyItem: View {
    let field: SourceEditorField
    @ObservedObject var session: ModelEditorSession

    private var isMixed: Bool {
        if field.hasMixedDraft(in: session) { return true }
        guard field.sourceType.hasSuffix("?") else { return false }
        let raw = session.fields[field.storageID]?.lowercased()
        return raw == nil || raw == "null"
    }
    private var isOn: Binding<Bool> {
        Binding(
            get: { !isMixed && session.fields[field.storageID]?.lowercased() == "true" },
            set: { field.setDraftValue(String($0), in: session) }
        )
    }
    private var usesIndeterminateStyle: Bool {
        (field.sourceControl + " " + field.sourceSetter).localizedCaseInsensitiveContains("tristate") ||
            field.sourceType.hasSuffix("?")
    }

    var body: some View {
        HStack(spacing: 8) {
            if usesIndeterminateStyle {
                MixedStateCheckbox(
                    title: L10n.text(field.title),
                    isChecked: isOn.wrappedValue,
                    isMixed: isMixed,
                    isEnabled: field.canEditDraft(in: session),
                    onChange: { isOn.wrappedValue = $0 }
                )
                .frame(width: 18, height: 18)
                .accessibilityValue(Text(LocalizedStringKey(isMixed ? "Mixed values" : (isOn.wrappedValue ? "On" : "Off"))))
            } else {
                Toggle("", isOn: isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(LocalizedStringKey(field.title))
                    .disabled(!field.canEditDraft(in: session))
            }
            Text(LocalizedStringKey(field.title))
            if isMixed {
                Label("Mixed values", systemImage: "minus.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// InputDateTimePropertyItem replacement. Date-only DatePicker sources remain
/// date-only. DateTimeInputBox sources keep the original segmented text format
/// so seconds and incomplete input remain visible.
struct OriginalDateTimePropertyItem: View {
    let field: SourceEditorField
    @ObservedObject var session: ModelEditorSession

    private var currentDate: Date? {
        guard !field.hasMixedDraft(in: session) else { return nil }
        return Self.parse(session.fields[field.storageID] ?? "")
    }
    private var usesDateInputBox: Bool {
        let control = field.sourceControl.lowercased()
        return (control.contains("dateinputbox") && !control.contains("datetimeinputbox")) ||
            field.sourceSetter.localizedCaseInsensitiveContains("DateInputBox_Date")
    }
    private var usesTimeInputBox: Bool {
        let control = field.sourceControl.lowercased()
        return (control.contains("timeinputbox") && !control.contains("datetimeinputbox")) ||
            field.sourceSetter.localizedCaseInsensitiveContains("TimeInputBox_Date")
    }
    private var isDateOnly: Bool {
        !usesTimeInputBox && (usesDateInputBox || field.sourceControl.lowercased().contains("datepicker") || field.sourceSetter.hasSuffix("_Date"))
    }
    private var components: DatePickerComponents {
        isDateOnly ? .date : [.date, .hourAndMinute]
    }
    private var selection: Binding<Date> {
        Binding(
            get: { currentDate ?? Date() },
            set: { field.setDraftValue(Self.serialize(preservingSubminuteParts(of: $0), dateOnly: isDateOnly), in: session) }
        )
    }

    private func preservingSubminuteParts(of selected: Date) -> Date {
        guard !isDateOnly, let currentDate else { return selected }
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: selected)
        components.second = calendar.component(.second, from: currentDate)
        components.nanosecond = calendar.component(.nanosecond, from: currentDate)
        return calendar.date(from: components) ?? selected
    }

    var body: some View {
        if field.readOnly || session.readOnlyFieldIDs.contains(field.storageID) {
            LabeledContent(LocalizedStringKey(field.title)) {
                Text(field.hasMixedDraft(in: session) ? "Mixed values" : (session.fields[field.storageID].flatMap { $0.isEmpty ? nil : $0 } ?? "—"))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } else if usesDateInputBox {
            OriginalDateOnlyInputView(field: field, session: session)
        } else if usesTimeInputBox {
            OriginalTimeOnlyInputView(field: field, session: session)
        } else if isDateOnly, currentDate == nil {
            LabeledContent(LocalizedStringKey(field.title)) {
                HStack(spacing: 8) {
                    Text(field.hasMixedDraft(in: session) ? "Mixed values" : "—").foregroundStyle(.secondary)
                    DatePicker("", selection: selection, displayedComponents: components)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .accessibilityLabel(LocalizedStringKey(field.title))
                        .disabled(!field.canEditDraft(in: session))
                }
            }
        } else if isDateOnly {
            DatePicker(LocalizedStringKey(field.title), selection: selection, displayedComponents: components)
                .datePickerStyle(.compact)
                .disabled(!field.canEditDraft(in: session))
        } else {
            OriginalDateTimeInputView(field: field, session: session)
        }
    }

    fileprivate static func parse(_ value: String) -> Date? {
        OriginalDateTimeDraftCodec.parseStoredValue(value)
    }

    private static func serialize(_ date: Date, dateOnly: Bool) -> String {
        OriginalDateTimeDraftCodec.serializeStoredValue(date, dateOnly: dateOnly)
    }
}

/// TimeWindow and TimeWindowGroup replacement for sibling StartTime/EndTime
/// fields. The caller passes the exact pair sharing the source control.
struct OriginalTimeWindowGroup: View {
    let fields: [SourceEditorField]
    @ObservedObject var session: ModelEditorSession
    @State private var isExpanded = true

    private var orderedFields: [SourceEditorField] {
        fields.sorted { lhs, rhs in
            let lhsStart = lhs.id.localizedCaseInsensitiveContains("StartTime") || lhs.title == "Start Time"
            let rhsStart = rhs.id.localizedCaseInsensitiveContains("StartTime") || rhs.title == "Start Time"
            return lhsStart && !rhsStart
        }
    }

    private var validationMessages: [String] {
        guard let startField = orderedFields.first(where: { $0.id.localizedCaseInsensitiveContains("starttime") }),
              let endField = orderedFields.first(where: { $0.id.localizedCaseInsensitiveContains("endtime") }) else { return [] }
        // A partial or rejected candidate is not the committed endpoint. Do
        // not validate it against the previous value and show a stale warning.
        guard !hasPendingInput(for: startField), !hasPendingInput(for: endField),
              let start = OriginalDateTimePropertyItem.parse(session.fields[startField.storageID] ?? ""),
              let end = OriginalDateTimePropertyItem.parse(session.fields[endField.storageID] ?? "") else { return [] }
        if start == end {
            return ["Time window cannot start when it ends.", "Time window cannot end when it starts."]
        }
        if start > end {
            return ["Time window cannot begin after it ends.", "Time window cannot end before it begins."]
        }
        return []
    }

    private var timeDifferenceText: String? {
        guard orderedFields.contains(where: { $0.sourceSetter.localizedCaseInsensitiveContains("TimeWindowGroup_") }),
              validationMessages.isEmpty,
              let startField = orderedFields.first(where: { $0.id.localizedCaseInsensitiveContains("starttime") }),
              let endField = orderedFields.first(where: { $0.id.localizedCaseInsensitiveContains("endtime") }),
              !hasPendingInput(for: startField), !hasPendingInput(for: endField),
              let start = OriginalDateTimePropertyItem.parse(session.fields[startField.storageID] ?? ""),
              let end = OriginalDateTimePropertyItem.parse(session.fields[endField.storageID] ?? "") else { return nil }
        let interval = end.timeIntervalSince(start)
        guard interval > 0 else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 3
        return formatter.string(from: interval)
    }

    private var usesSourceTimeWindowGroup: Bool {
        orderedFields.contains { $0.sourceSetter.localizedCaseInsensitiveContains("TimeWindowGroup_") }
    }

    private var collapsedSummary: String? {
        guard usesSourceTimeWindowGroup,
              let startField = orderedFields.first(where: { $0.id.localizedCaseInsensitiveContains("starttime") }),
              let endField = orderedFields.first(where: { $0.id.localizedCaseInsensitiveContains("endtime") }),
              let start = OriginalDateTimePropertyItem.parse(session.fields[startField.storageID] ?? ""),
              let end = OriginalDateTimePropertyItem.parse(session.fields[endField.storageID] ?? "") else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: start) + " to " + formatter.string(from: end)
    }

    private func hasPendingInput(for field: SourceEditorField) -> Bool {
        guard let sourceValue = session.fields[field.storageID],
              let pending = session.dateTimeInputDrafts[field.storageID] else { return false }
        return pending.sourceValue == sourceValue
    }

    var body: some View {
        GroupBox {
            if usesSourceTimeWindowGroup {
                DisclosureGroup(isExpanded: $isExpanded) {
                    editorContents
                } label: {
                    HStack(spacing: 8) {
                        Text("Time Window").font(.headline)
                        if !isExpanded, let collapsedSummary {
                            Text(verbatim: collapsedSummary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                editorContents
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var editorContents: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(orderedFields) { field in
                OriginalDateTimePropertyItem(field: field, session: session)
            }
            ForEach(validationMessages, id: \.self) { message in
                Text(L10n.text(message)).font(.caption).foregroundStyle(.orange)
            }
            if let timeDifferenceText {
                LabeledContent("Time Difference", value: timeDifferenceText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// InputDoubleStringPropertyItem and DoubleTextPropertyItem replacement.
struct OriginalDoubleStringPropertyItem: View {
    let fields: [SourceEditorField]
    @ObservedObject var session: ModelEditorSession

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            ForEach(fields) { field in
                if field.readOnly || session.readOnlyFieldIDs.contains(field.storageID) {
                    LabeledContent(LocalizedStringKey(field.title)) {
                        Text(field.hasMixedDraft(in: session) ? "Mixed values" : (session.fields[field.storageID].flatMap { $0.isEmpty ? nil : $0 } ?? "—"))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } else {
                    LabeledContent(LocalizedStringKey(field.title)) {
                        TextField(LocalizedStringKey(field.title), text: field.draftBinding(in: session), prompt: Text(LocalizedStringKey(field.hasMixedDraft(in: session) ? "Mixed values" : (field.placeholder.isEmpty ? "—" : field.placeholder))))
                            .frame(minWidth: 72)
                            .disabled(!field.canEditDraft(in: session))
                    }
                }
            }
        }
    }
}

/// SliderPropertyItem and SliderTextPropertyItem replacement. The source
/// SliderText variant includes a numeric field bound to the same session value.
struct OriginalSliderPropertyItem: View {
    let field: SourceEditorField
    @ObservedObject var session: ModelEditorSession
    @State private var validation: String?
    @FocusState private var numericTextFocused: Bool
    @State private var numericEditText = ""
    @State private var hasPendingNumericText = false

    private var lowerBound: Double { field.minimum ?? 0 }
    // SliderTextPropertyItem defaults MaxValue to 100; its plain SliderPropertyItem
    // counterpart defaults MaxValue to 0 and normally receives a range from
    // its containing source instance. Never invent a useful-looking range if
    // that instance configuration is absent from the field contract.
    private var upperBound: Double { max(lowerBound, field.maximum ?? (showsNumericValue ? 100 : 0)) }
    private var range: ClosedRange<Double> { lowerBound...upperBound }
    private var numericText: Binding<String> {
        Binding(
            get: {
                if numericTextFocused || hasPendingNumericText { return numericEditText }
                return isMixed ? "" : (session.fields[field.storageID] ?? "")
            },
            set: receiveNumericText
        )
    }
    private var value: Binding<Double> {
        Binding(
            get: {
                guard !isMixed else { return lowerBound }
                guard let number = Double(session.fields[field.storageID] ?? ""), number.isFinite else { return lowerBound }
                return min(max(number, lowerBound), upperBound)
            },
            set: { field.setDraftValue(String($0), in: session); validation = nil }
        )
    }
    private var showsNumericValue: Bool {
        field.sourceControl.localizedCaseInsensitiveContains("sliderText") ||
            field.sourceSetter.localizedCaseInsensitiveContains("SliderTextPropertyItem")
    }
    private var isMixed: Bool { field.hasMixedDraft(in: session) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent(LocalizedStringKey(field.title)) {
                HStack(spacing: 10) {
                    Group {
                        if showsNumericValue {
                            Slider(value: value, in: range, step: 1.0)
                        } else {
                            Slider(value: value, in: range)
                        }
                    }
                    .accessibilityLabel(LocalizedStringKey(field.title))
                    .disabled(isMixed || !field.canEditDraft(in: session))
                    if showsNumericValue {
                        TextField("", text: numericText, prompt: Text(LocalizedStringKey(isMixed ? "Mixed values" : "—")))
                            .frame(width: 88)
                            .focused($numericTextFocused)
                            .onSubmit(commitNumericText)
                            .accessibilityLabel(LocalizedStringKey(field.title))
                            .disabled(!field.canEditDraft(in: session))
                    }
                }
            }
            if let validation { Text(validation).font(.caption).foregroundStyle(.red) }
        }
        .onChange(of: numericTextFocused) { _, focused in
            if focused {
                if !hasPendingNumericText { numericEditText = isMixed ? "" : (session.fields[field.storageID] ?? "") }
            } else {
                commitNumericText()
            }
        }
        .onChange(of: session.fields[field.storageID]) { _, newValue in
            if !numericTextFocused && !hasPendingNumericText { numericEditText = newValue ?? "" }
        }
        .onChange(of: field.storageID) { _, _ in resetNumericText() }
        .onChange(of: session.modelAssetID) { _, _ in resetNumericText() }
    }

    private func receiveNumericText(_ rawValue: String) {
        numericEditText = rawValue
        hasPendingNumericText = true
        let status = OriginalNumberInputValidator.evaluate(rawValue, minimum: lowerBound, maximum: upperBound)
        if case .valid = status {
            field.setDraftValue(rawValue, in: session)
            validation = nil
        } else {
            validation = sliderTextValidationMessage(status, minimum: lowerBound, maximum: upperBound)
        }
    }

    private func commitNumericText() {
        guard hasPendingNumericText else { return }
        let status = OriginalNumberInputValidator.evaluate(numericEditText, minimum: lowerBound, maximum: upperBound)
        guard case .valid = status else {
            validation = sliderTextValidationMessage(status, minimum: lowerBound, maximum: upperBound)
            return
        }
        field.setDraftValue(numericEditText, in: session)
        hasPendingNumericText = false
        validation = nil
    }

    private func resetNumericText() {
        numericTextFocused = false
        numericEditText = ""
        hasPendingNumericText = false
        validation = nil
    }
}

@MainActor
private func sliderTextValidationMessage(_ status: OriginalNumberInputStatus, minimum: Double, maximum: Double) -> String? {
    switch status {
    case .empty, .valid:
        return nil
    case .invalid:
        return L10n.text("Enter a finite number.")
    case .belowMinimum, .aboveMaximum:
        return L10n.format("Must be between %@ and %@", minimum.formatted(), maximum.formatted())
    }
}

/// Status companion for ExternalConnectionLinker/WellKnownExternalPathEditor.
struct OriginalExternalConnectionIndicator: View {
    let field: SourceEditorField
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore

    private var selectedName: String? {
        if field.kind == "connection" || field.id.localizedCaseInsensitiveContains("selectedconnection") {
            return session.fields[field.storageID]
        }
        guard let route = field.connectionBy else { return nil }
        return session.fields[field.scoped(route)]
    }
    private var connectionExists: Bool {
        guard let selectedName, !selectedName.isEmpty else { return false }
        return store.document?.connections.contains { $0.name == selectedName } == true
    }

    var body: some View {
        Group {
            if let selectedName, !selectedName.isEmpty {
                if connectionExists {
                    Label("Configured", systemImage: "link.circle")
                        .foregroundStyle(.secondary)
                        .help(selectedName)
                } else {
                    Label("Connection unavailable", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(selectedName)
                }
            } else {
                Label("No connection selected", systemImage: "link")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}

/// Native DisclosureGroup wrapper for source property groups that can collapse.
struct OriginalCollapsiblePropertyItem<Content: View>: View {
    let title: String
    @State private var isExpanded: Bool
    private let content: Content

    init(title: String, isExpanded: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        _isExpanded = State(initialValue: isExpanded)
        self.content = content()
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content
        } label: {
            Text(LocalizedStringKey(title)).font(.headline)
        }
    }
}
