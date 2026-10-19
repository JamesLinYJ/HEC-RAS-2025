import SwiftUI

/// DateInputBox keeps an editable yyyy-MM-dd draft until the entered date is
/// complete. The source DateInputBox exposes a date-only text segment, while
/// this native view also offers the macOS calendar picker for direct selection.
struct OriginalDateOnlyInputView: View {
    let field: SourceEditorField
    @ObservedObject var session: ModelEditorSession

    @State private var draft = OriginalDateTimeInputDraft(
        sourceValue: "", dateText: "", timeText: "", dateTouched: false,
        timeTouched: false, issueKey: nil
    )
    @State private var temporalParseIntent: OriginalTemporalInputParseIntent?
    @FocusState private var isFocused: Bool

    private var sourceValue: String { session.fields[field.storageID] ?? "" }
    private var isMixed: Bool { field.hasMixedDraft(in: session) }
    private var hasDateIssue: Bool {
        draft.dateTouched && (
            draft.issueKey == OriginalTemporalInputIssue.dateFormat ||
                draft.issueKey == OriginalTemporalInputIssue.parserUnavailable ||
                draft.issueKey == OriginalPropertyDateTimeStorage.unpreservableFormatIssue
        )
    }

    private var dateText: Binding<String> {
        Binding(get: { draft.dateText }, set: updateDate)
    }

    private var pickerSelection: Binding<Date> {
        Binding(
            get: {
                let dateText = OriginalDateTimeDraftCodec.parseCanonicalDate(draft.dateText) != nil
                    ? draft.dateText
                    : (OriginalPropertyDateTimeStorage.dateText(from: sourceValue) ?? "0001-01-01")
                let timeText = OriginalPropertyDateTimeStorage.timeText(from: sourceValue) ?? "00:00:00"
                return OriginalPropertyDateTimeStorage.pickerDate(dateText: dateText, timeText: timeText)
                    ?? Date()
            },
            set: { selected in
                updateDate(OriginalDateTimeDraftCodec.displayParts(of: selected).date)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(LocalizedStringKey(field.title)) {
                HStack(spacing: 8) {
                    TextField(
                        "Date",
                        text: dateText,
                        prompt: Text(verbatim: OriginalDateTimeDraftCodec.dateFormat)
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 126, idealWidth: 150)
                    .focused($isFocused)
                    .accessibilityLabel(LocalizedStringKey(field.title))
                    .accessibilityHint(Text(verbatim: OriginalDateTimeDraftCodec.dateFormat))
                    .onSubmit { isFocused = false }
                    .disabled(!field.canEditDraft(in: session))

                    DatePicker("", selection: pickerSelection, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .accessibilityLabel(LocalizedStringKey(field.title))
                        .disabled(!field.canEditDraft(in: session))
                }
            }
            if hasDateIssue {
                Text(LocalizedStringKey(draft.issueKey ?? "Improperly formatted date."))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .task(id: session.numericCalculatorIdentity + "|" + field.storageID) {
            reconcileFromSession()
        }
        .task(id: temporalParseIntent?.id) {
            await resolveTemporalParse()
        }
        .onChange(of: sourceValue) { _, _ in
            temporalParseIntent = nil
            reconcileFromSession()
        }
        .onChange(of: isMixed) { _, _ in reconcileFromSession() }
        .onChange(of: session.dateTimeInputDrafts[field.storageID]) { _, _ in reconcileFromSession() }
        .onExitCommand(perform: discardInputDraft)
    }

    private func updateDate(_ text: String) {
        guard field.canEditDraft(in: session) else { return }
        let pending = OriginalDateTimeInputDraft(
            sourceValue: sourceValue, dateText: text, timeText: "",
            dateTouched: true, timeTouched: false, issueKey: OriginalTemporalInputIssue.parsing
        )
        draft = pending
        session.setDateTimeInputDraft(pending, for: field.storageID)
        temporalParseIntent = OriginalTemporalInputParseIntent(
            operation: .date,
            text: text,
            fieldID: field.storageID,
            editorIdentity: session.numericCalculatorIdentity,
            sourceValue: sourceValue,
            dateText: text,
            timeText: "",
            dateTouched: true,
            timeTouched: false
        )
    }

    @MainActor
    private func resolveTemporalParse() async {
        guard let intent = temporalParseIntent else { return }
        do {
            let client = (session.provider as? BackendModelProvider)?.client
            let result = try await BackendTemporalInputProvider(client: client).parse(intent)
            guard !Task.isCancelled, temporalParseIsCurrent(intent) else { return }
            temporalParseIntent = nil
            guard result.isValid,
                  let normalized = result.canonicalDate,
                  OriginalDateTimeDraftCodec.parseCanonicalDate(normalized) != nil else {
                retainDateDraft(intent.text, issueKey: OriginalTemporalInputIssue.dateFormat)
                return
            }
            guard let stored = OriginalPropertyDateTimeStorage.replacingDate(normalized, in: sourceValue) else {
                retainDateDraft(intent.text, issueKey: OriginalPropertyDateTimeStorage.unpreservableFormatIssue)
                return
            }
            field.setDraftValue(stored, in: session)
            session.clearDateTimeInputDraft(for: field.storageID)
            draft = OriginalDateTimeInputDraft(
                sourceValue: stored,
                dateText: OriginalPropertyDateTimeStorage.dateText(from: stored) ?? normalized,
                timeText: "", dateTouched: false, timeTouched: false, issueKey: nil
            )
        } catch is CancellationError {
            return
        } catch {
            guard temporalParseIsCurrent(intent) else { return }
            temporalParseIntent = nil
            retainDateDraft(intent.text, issueKey: OriginalTemporalInputIssue.parserUnavailable)
        }
    }

    private func temporalParseIsCurrent(_ intent: OriginalTemporalInputParseIntent) -> Bool {
        intent.isCurrent(activeID: temporalParseIntent?.id, fieldID: field.storageID,
            editorIdentity: session.numericCalculatorIdentity, sourceValue: sourceValue,
            draft: session.dateTimeInputDraft(for: field.storageID, sourceValue: sourceValue))
            && field.canEditDraft(in: session)
    }

    private func retainDateDraft(_ text: String, issueKey: String) {
        let pending = OriginalDateTimeInputDraft(
            sourceValue: sourceValue, dateText: text, timeText: "",
            dateTouched: true, timeTouched: false, issueKey: issueKey
        )
        draft = pending
        session.setDateTimeInputDraft(pending, for: field.storageID)
    }

    private func discardInputDraft() {
        temporalParseIntent = nil
        guard session.dateTimeInputDrafts[field.storageID] != nil else { return }
        session.clearDateTimeInputDraft(for: field.storageID)
        isFocused = false
        reconcileFromSession()
    }

    private func reconcileFromSession() {
        if let retained = session.dateTimeInputDraft(for: field.storageID, sourceValue: sourceValue) {
            draft = retained
            return
        }
        guard !isMixed else {
            draft = OriginalDateTimeInputDraft(
                sourceValue: sourceValue, dateText: "", timeText: "",
                dateTouched: false, timeTouched: false, issueKey: nil
            )
            return
        }
        if sourceValue.isEmpty {
            draft = OriginalDateTimeInputDraft(
                sourceValue: sourceValue, dateText: "0001-01-01", timeText: "",
                dateTouched: false, timeTouched: false, issueKey: nil
            )
            return
        }
        if let date = OriginalPropertyDateTimeStorage.dateText(from: sourceValue) {
            draft = OriginalDateTimeInputDraft(
                sourceValue: sourceValue,
                dateText: date,
                timeText: "", dateTouched: false, timeTouched: false, issueKey: nil
            )
            return
        }
        let invalid = OriginalDateTimeInputDraft(
            sourceValue: sourceValue, dateText: sourceValue, timeText: "",
            dateTouched: true, timeTouched: false,
            issueKey: "Improperly formatted date."
        )
        draft = invalid
        session.setDateTimeInputDraft(invalid, for: field.storageID)
    }
}
