import SwiftUI

/// TimeInputBox exposes an editable HH:mm:ss value while retaining the date
/// part of its DateTime binding. The native time picker complements the exact
/// text field; the text field remains the route for second precision.
struct OriginalTimeOnlyInputView: View {
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
    private var hasTimeIssue: Bool {
        draft.timeTouched && (
            draft.issueKey == OriginalTemporalInputIssue.timeFormat ||
                draft.issueKey == OriginalTemporalInputIssue.parserUnavailable ||
                draft.issueKey == OriginalPropertyDateTimeStorage.unpreservableFormatIssue
        )
    }

    private var timeText: Binding<String> {
        Binding(get: { draft.timeText }, set: updateTime)
    }

    private var pickerSelection: Binding<Date> {
        Binding(
            get: {
                OriginalPropertyDateTimeStorage.pickerDate(
                    dateText: dateForCurrentValue,
                    timeText: OriginalPropertyDateTimeStorage.timeText(from: sourceValue) ?? "00:00:00"
                ) ?? Date()
            },
            set: { selected in
                updateTimeFromPicker(selected)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(LocalizedStringKey(field.title)) {
                HStack(spacing: 8) {
                    TextField(
                        "Time",
                        text: timeText,
                        prompt: Text(verbatim: OriginalDateTimeDraftCodec.timeFormat)
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 116, idealWidth: 136)
                    .focused($isFocused)
                    .accessibilityLabel(LocalizedStringKey(field.title))
                    .accessibilityHint(Text(verbatim: OriginalDateTimeDraftCodec.timeFormat))
                    .onSubmit { isFocused = false }
                    .disabled(!field.canEditDraft(in: session))

                    DatePicker("", selection: pickerSelection, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .accessibilityLabel(LocalizedStringKey(field.title))
                        .disabled(!field.canEditDraft(in: session))
                }
            }
            if hasTimeIssue {
                Text(LocalizedStringKey(draft.issueKey ?? "Improperly formatted time."))
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

    private func updateTime(_ text: String) {
        guard field.canEditDraft(in: session) else { return }
        let pending = OriginalDateTimeInputDraft(
            sourceValue: sourceValue, dateText: dateForCurrentValue, timeText: text,
            dateTouched: false, timeTouched: true, issueKey: OriginalTemporalInputIssue.parsing
        )
        draft = pending
        session.setDateTimeInputDraft(pending, for: field.storageID)
        temporalParseIntent = OriginalTemporalInputParseIntent(
            operation: .time,
            text: text,
            fieldID: field.storageID,
            editorIdentity: session.numericCalculatorIdentity,
            sourceValue: sourceValue,
            dateText: dateForCurrentValue,
            timeText: text,
            dateTouched: false,
            timeTouched: true
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
            guard result.isValid, result.canSetDateTime,
                  let normalized = result.canonicalTime,
                  OriginalDateTimeDraftCodec.parseCanonicalTime(normalized) != nil else {
                retainTimeDraft(intent.text, issueKey: OriginalTemporalInputIssue.timeFormat)
                return
            }
            guard let stored = OriginalPropertyDateTimeStorage.replacingTime(normalized, in: sourceValue) else {
                retainTimeDraft(intent.text, issueKey: OriginalPropertyDateTimeStorage.unpreservableFormatIssue)
                return
            }
            field.setDraftValue(stored, in: session)
            session.clearDateTimeInputDraft(for: field.storageID)
            draft = OriginalDateTimeInputDraft(
                sourceValue: stored,
                dateText: OriginalPropertyDateTimeStorage.dateText(from: stored) ?? dateForCurrentValue,
                timeText: OriginalPropertyDateTimeStorage.timeText(from: stored) ?? normalized,
                dateTouched: false, timeTouched: false, issueKey: nil
            )
        } catch is CancellationError {
            return
        } catch {
            guard temporalParseIsCurrent(intent) else { return }
            temporalParseIntent = nil
            retainTimeDraft(intent.text, issueKey: OriginalTemporalInputIssue.parserUnavailable)
        }
    }

    private func temporalParseIsCurrent(_ intent: OriginalTemporalInputParseIntent) -> Bool {
        intent.isCurrent(activeID: temporalParseIntent?.id, fieldID: field.storageID,
            editorIdentity: session.numericCalculatorIdentity, sourceValue: sourceValue,
            draft: session.dateTimeInputDraft(for: field.storageID, sourceValue: sourceValue))
            && field.canEditDraft(in: session)
    }

    private func retainTimeDraft(_ text: String, issueKey: String) {
        let pending = OriginalDateTimeInputDraft(
            sourceValue: sourceValue, dateText: dateForCurrentValue, timeText: text,
            dateTouched: false, timeTouched: true, issueKey: issueKey
        )
        draft = pending
        session.setDateTimeInputDraft(pending, for: field.storageID)
    }

    private func updateTimeFromPicker(_ selected: Date) {
        let selectedTime = OriginalDateTimeDraftCodec.displayParts(of: selected).time
        let seconds = OriginalPropertyDateTimeStorage.timeText(from: sourceValue)
            .flatMap { OriginalDateTimeDraftCodec.parseCanonicalTime($0)?.second }
            ?? 0
        updateTime("\(selectedTime.prefix(6))\(String(format: "%02d", seconds))")
    }

    private var dateForCurrentValue: String {
        if let date = OriginalPropertyDateTimeStorage.dateText(from: sourceValue) { return date }
        // TimeInputBox initializes its DateTime property to DateTime.MinValue.
        return "0001-01-01"
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
                sourceValue: sourceValue, dateText: "0001-01-01", timeText: "00:00:00",
                dateTouched: false, timeTouched: false, issueKey: nil
            )
            return
        }
        if let date = OriginalPropertyDateTimeStorage.dateText(from: sourceValue),
           let time = OriginalPropertyDateTimeStorage.timeText(from: sourceValue) {
            draft = OriginalDateTimeInputDraft(
                sourceValue: sourceValue, dateText: date, timeText: time,
                dateTouched: false, timeTouched: false, issueKey: nil
            )
            return
        }
        let invalid = OriginalDateTimeInputDraft(
            sourceValue: sourceValue, dateText: dateForCurrentValue,
            timeText: sourceValue, dateTouched: false, timeTouched: true,
            issueKey: "Improperly formatted time."
        )
        draft = invalid
        session.setDateTimeInputDraft(invalid, for: field.storageID)
    }
}
