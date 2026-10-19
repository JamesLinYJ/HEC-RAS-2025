import Foundation
import SwiftUI

enum OriginalDateTimeDraftCodec {
    static let dateFormat = "yyyy-MM-dd"
    static let timeFormat = "HH:mm:ss"

    /// Legacy pure-value helper kept for existing storage tests and callers.
    /// Production text input is parsed by TemporalInputService so its grammar
    /// follows .NET DateTime.TryParse for the active culture.
    static func parseDate(_ text: String, locale: Locale = .autoupdatingCurrent) -> Date? {
        let pieces = text.split(separator: "-", omittingEmptySubsequences: false)
        if pieces.count == 3,
           let year = integer(String(pieces[0]), digits: 4),
           let month = positiveInteger(String(pieces[1])),
           let day = positiveInteger(String(pieces[2])),
           (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
           let date = date(year: year, month: month, day: day) {
            return date
        }

        // DateInputBox delegates to DateTime.TryParse, which also accepts the
        // active culture's ordinary short/medium/long date strings. Keep the
        // ISO source representation as the first path, then try those native
        // localized styles without lenient rollover.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for style in [DateFormatter.Style.short, .medium, .long, .full] {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = .current
            formatter.dateStyle = style
            formatter.timeStyle = .none
            formatter.isLenient = false
            formatter.defaultDate = Date()
            guard let parsed = formatter.date(from: trimmed) else { continue }
            let calendar = gregorianCalendar
            let components = calendar.dateComponents([.year, .month, .day], from: parsed)
            if let year = components.year, let month = components.month, let day = components.day,
               (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
               let exact = date(year: year, month: month, day: day) {
                return exact
            }
        }
        return nil
    }

    /// Parses only the normalized calendar value emitted after the backend's
    /// DateTime.TryParse succeeds. User-entered culture text must be parsed by
    /// TemporalInputService, not by this storage/candidate helper.
    static func parseCanonicalDate(_ text: String) -> Date? {
        let pieces = text.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3,
              let year = integer(String(pieces[0]), digits: 4),
              let month = integer(String(pieces[1]), digits: 2),
              let day = integer(String(pieces[2]), digits: 2),
              (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        return date(year: year, month: month, day: day)
    }

    /// Legacy pure-value helper kept for existing storage tests and callers.
    /// Production text input is parsed by TemporalInputService so its grammar
    /// follows .NET TimeSpan.TryParse for the active culture.
    static func parseTime(_ text: String, locale: Locale = .autoupdatingCurrent) -> DateComponents? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count == 2 || pieces.count == 3 else { return nil }

        let numberFormatter = NumberFormatter()
        numberFormatter.locale = locale
        let decimalSeparator = numberFormatter.decimalSeparator ?? "."
        var dayCount = 0
        var hourText = pieces[0]
        if let daySeparator = hourText.firstIndex(where: { $0 == "." || String($0) == decimalSeparator }) {
            let dayText = String(hourText[..<daySeparator])
            let remainder = String(hourText[hourText.index(after: daySeparator)...])
            guard let parsedDays = positiveInteger(dayText), !remainder.isEmpty else { return nil }
            dayCount = parsedDays
            hourText = remainder
        }
        guard let hour = positiveInteger(hourText), let minute = positiveInteger(pieces[1]),
              minute <= 59 else { return nil }

        var second = 0
        if pieces.count == 3 {
            let secondText = pieces[2]
            let fractionSeparator = decimalSeparator.isEmpty ? "." : decimalSeparator
            let integerSecond: String
            var separatorRange = secondText.range(of: fractionSeparator)
            if separatorRange == nil, fractionSeparator != "." {
                separatorRange = secondText.range(of: ".")
            }
            if let range = separatorRange {
                integerSecond = String(secondText[..<range.lowerBound])
                let fraction = String(secondText[range.upperBound...])
                guard !fraction.isEmpty, fraction.utf8.count <= 7,
                      fraction.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
            } else {
                integerSecond = secondText
            }
            guard let parsedSecond = positiveInteger(integerSecond), parsedSecond <= 59 else { return nil }
            second = parsedSecond
        }
        let (hoursFromDays, dayOverflow) = dayCount.multipliedReportingOverflow(by: 24)
        guard !dayOverflow else { return nil }
        let (totalHours, hourOverflow) = hoursFromDays.addingReportingOverflow(hour)
        guard !hourOverflow else { return nil }
        // TimeInputBox passes a TimeSpan to DateTimeConverters.TimeSpanToDateTime;
        // that converter reads the TimeSpan.Hours component, so any day portion
        // is intentionally discarded and a 24-hour duration maps to 00:00:00.
        let wallClockHour = totalHours % 24
        var components = DateComponents()
        components.hour = wallClockHour
        components.minute = minute
        components.second = second
        return components
    }

    /// Parses only the normalized wall-clock component emitted by the
    /// backend's TimeSpan.TryParse compatibility route.
    static func parseCanonicalTime(_ text: String) -> DateComponents? {
        let bytes = Array(text.utf8)
        guard bytes.count == 8, bytes[2] == 58, bytes[5] == 58,
              [0, 1, 3, 4, 6, 7].allSatisfy({ (48...57).contains(bytes[$0]) }) else { return nil }
        let hour = Int(String(decoding: bytes[0..<2], as: UTF8.self)) ?? -1
        let minute = Int(String(decoding: bytes[3..<5], as: UTF8.self)) ?? -1
        let second = Int(String(decoding: bytes[6..<8], as: UTF8.self)) ?? -1
        guard (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        components.second = second
        return components
    }

    static func canonicalDateText(_ text: String, locale: Locale = .autoupdatingCurrent) -> String? {
        guard let parsed = parseDate(text, locale: locale) else { return nil }
        let parts = gregorianCalendar.dateComponents([.year, .month, .day], from: parsed)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func canonicalTimeText(_ text: String, locale: Locale = .autoupdatingCurrent) -> String? {
        guard let parts = parseTime(text, locale: locale), let hour = parts.hour,
              let minute = parts.minute, let second = parts.second else { return nil }
        return String(format: "%02d:%02d:%02d", hour, minute, second)
    }

    static func combine(dateText: String, timeText: String) -> Date? {
        guard let date = parseDate(dateText), let time = parseTime(timeText) else { return nil }
        let calendar = gregorianCalendar
        let dateParts = calendar.dateComponents([.year, .month, .day], from: date)
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = dateParts.year
        components.month = dateParts.month
        components.day = dateParts.day
        components.hour = time.hour
        components.minute = time.minute
        components.second = time.second
        guard let result = calendar.date(from: components) else { return nil }
        let check = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: result)
        guard check.year == components.year, check.month == components.month, check.day == components.day,
              check.hour == components.hour, check.minute == components.minute, check.second == components.second else {
            return nil
        }
        return result
    }

    static func combineCanonical(dateText: String, timeText: String) -> Date? {
        guard let date = parseCanonicalDate(dateText), let time = parseCanonicalTime(timeText) else { return nil }
        let calendar = gregorianCalendar
        let dateParts = calendar.dateComponents([.year, .month, .day], from: date)
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = dateParts.year
        components.month = dateParts.month
        components.day = dateParts.day
        components.hour = time.hour
        components.minute = time.minute
        components.second = time.second
        guard let result = calendar.date(from: components) else { return nil }
        let check = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: result)
        guard check.year == components.year, check.month == components.month, check.day == components.day,
              check.hour == components.hour, check.minute == components.minute, check.second == components.second else {
            return nil
        }
        return result
    }

    static func parseStoredValue(_ value: String) -> Date? {
        // These controls bind .NET DateTime wall-clock components. The source
        // suffix is a serialization detail, not an instruction to shift the
        // date and time shown in the editor into the Mac's current offset.
        guard let date = OriginalPropertyDateTimeStorage.dateText(from: value) else { return nil }
        let time = OriginalPropertyDateTimeStorage.timeText(from: value) ?? "00:00:00"
        return combineCanonical(dateText: date, timeText: time)
    }

    static func displayParts(of date: Date) -> (date: String, time: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return (
            String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0),
            String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        )
    }

    static func serializeStoredValue(_ date: Date, dateOnly: Bool) -> String {
        // parseStoredValue/displayParts represent the source's wall clock.
        // A UTC formatter here would shift a round trip by the local offset.
        // Editing existing source text uses OriginalPropertyDateTimeStorage
        // to retain its separator and offset; new text needs neither invented.
        let parts = displayParts(of: date)
        return dateOnly ? parts.date : parts.date + "T" + parts.time
    }

    private static func integer(_ text: String, digits: Int) -> Int? {
        guard text.utf8.count == digits, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return Int(text)
    }

    private static var gregorianCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    private static func date(year: Int, month: Int, day: Int) -> Date? {
        var components = DateComponents()
        components.calendar = gregorianCalendar
        components.timeZone = TimeZone.current
        components.year = year
        components.month = month
        components.day = day
        guard let result = gregorianCalendar.date(from: components) else { return nil }
        let roundTrip = gregorianCalendar.dateComponents([.year, .month, .day], from: result)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else { return nil }
        return result
    }

    private static func positiveInteger(_ text: String) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return Int(text)
    }
}

/// Native replacement for DateInputBox + TimeInputBox inside DateTimeInputBox.
/// Partial text and validation stay in the session's presentation-only draft
/// slot; valid values continue through the existing field setter and save path.
struct OriginalDateTimeInputView: View {
    private enum Segment: Hashable { case date, time }

    let field: SourceEditorField
    @ObservedObject var session: ModelEditorSession
    @State private var draft = OriginalDateTimeInputDraft(
        sourceValue: "", dateText: "", timeText: "", dateTouched: false, timeTouched: false, issueKey: nil
    )
    @State private var businessWarningKey: String?
    @State private var temporalParseIntent: OriginalTemporalInputParseIntent?
    @FocusState private var focusedSegment: Segment?

    private var sourceValue: String { session.fields[field.storageID] ?? "" }
    private var isMixed: Bool { field.hasMixedDraft(in: session) }
    private var inputIssue: String? {
        guard let issueKey = draft.issueKey else { return nil }
        return [OriginalTemporalInputIssue.dateFormat, OriginalTemporalInputIssue.timeFormat,
            OriginalTemporalInputIssue.parserUnavailable].contains(issueKey) ? issueKey : nil
    }
    private var businessIssue: String? {
        guard OriginalDateTimeInputIssue.isBusinessIssue(draft.issueKey), let key = draft.issueKey else { return nil }
        if key == OriginalDateTimeInputIssue.startsAfterBoundaryTemplate {
            return L10n.format(key, draft.issueArgument ?? "")
        }
        return L10n.text(key)
    }
    private var storageIssue: String? {
        guard draft.issueKey == OriginalPropertyDateTimeStorage.unpreservableFormatIssue else { return nil }
        return L10n.text(OriginalPropertyDateTimeStorage.unpreservableFormatIssue)
    }
    private var validationRule: OriginalDateTimeBusinessRule? {
        OriginalDateTimeBusinessValidator.rule(for: field)
    }
    private var validationDependency: OriginalDateTimeValidationDependency {
        guard let peerID = validationRule?.peerFieldID else {
            return OriginalDateTimeValidationDependency(peerFieldID: nil, sourceValue: nil, pendingInput: nil)
        }
        return OriginalDateTimeValidationDependency(
            peerFieldID: peerID,
            sourceValue: session.fields[peerID],
            pendingInput: session.dateTimeInputDrafts[peerID]
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(field.title))
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                segmentField(label: "Date", format: OriginalDateTimeDraftCodec.dateFormat, text: dateBinding, segment: .date)
                    .frame(maxWidth: .infinity, alignment: .leading)
                segmentField(label: "Time", format: OriginalDateTimeDraftCodec.timeFormat, text: timeBinding, segment: .time)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let inputIssue {
                Text(LocalizedStringKey(inputIssue)).font(.caption).foregroundStyle(.red)
            }
            if let businessIssue {
                Text(verbatim: businessIssue).font(.caption).foregroundStyle(.red)
            }
            if let storageIssue {
                Text(verbatim: storageIssue).font(.caption).foregroundStyle(.red)
            }
            if let businessWarningKey {
                Text(LocalizedStringKey(businessWarningKey)).font(.caption).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: session.numericCalculatorIdentity + "|" + field.storageID) {
            reconcileFromSession()
            revalidatePendingBusinessInput()
            refreshCommittedWarning()
        }
        .task(id: temporalParseIntent?.id) {
            await resolveTemporalParse()
        }
        .onChange(of: session.dateTimeInputDrafts[field.storageID]) { _, _ in
            reconcileFromSession()
            refreshCommittedWarning()
        }
        .onChange(of: sourceValue) { _, _ in
            temporalParseIntent = nil
            reconcileFromSession()
            refreshCommittedWarning()
        }
        .onChange(of: isMixed) { _, _ in
            reconcileFromSession()
            refreshCommittedWarning()
        }
        .onChange(of: validationDependency) { _, _ in
            revalidatePendingBusinessInput()
            refreshCommittedWarning()
        }
        .onExitCommand(perform: discardInputDraft)
    }

    private var dateBinding: Binding<String> {
        Binding(get: { draft.dateText }, set: { update(dateText: $0, timeText: draft.timeText, touched: .date) })
    }

    private var timeBinding: Binding<String> {
        Binding(get: { draft.timeText }, set: { update(dateText: draft.dateText, timeText: $0, touched: .time) })
    }

    private func segmentField(label: String, format: String, text: Binding<String>, segment: Segment) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(label)).font(.caption).foregroundStyle(.secondary)
            TextField(LocalizedStringKey(label), text: text, prompt: Text(verbatim: format))
                .focused($focusedSegment, equals: segment)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 112)
                .accessibilityHint(Text(verbatim: format))
                .onSubmit { submit(segment) }
                .disabled(!field.canEditDraft(in: session))
        }
    }

    private func update(
        dateText: String,
        timeText: String,
        touched segment: Segment,
        continuation: OriginalTemporalInputContinuation = .none
    ) {
        guard field.canEditDraft(in: session) else { return }
        businessWarningKey = nil
        let touchedDate = draft.dateTouched || segment == .date
        let touchedTime = draft.timeTouched || segment == .time
        let pending = OriginalDateTimeInputDraft(
            sourceValue: sourceValue,
            dateText: dateText,
            timeText: timeText,
            dateTouched: touchedDate,
            timeTouched: touchedTime,
            issueKey: OriginalTemporalInputIssue.parsing
        )
        draft = pending
        session.setDateTimeInputDraft(pending, for: field.storageID)
        let operation: OriginalTemporalInputOperation = segment == .date ? .date : .time
        temporalParseIntent = OriginalTemporalInputParseIntent(
            operation: operation,
            text: segment == .date ? dateText : timeText,
            fieldID: field.storageID,
            editorIdentity: session.numericCalculatorIdentity,
            sourceValue: sourceValue,
            dateText: dateText,
            timeText: timeText,
            dateTouched: touchedDate,
            timeTouched: touchedTime,
            continuation: continuation
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
            let normalized: String
            if intent.operation == .date {
                guard result.isValid, let parsedDate = result.canonicalDate,
                      OriginalDateTimeDraftCodec.parseCanonicalDate(parsedDate) != nil else {
                    retainTemporalIssue(intent, key: OriginalTemporalInputIssue.dateFormat)
                    return
                }
                normalized = parsedDate
            } else {
                guard result.isValid, result.canSetDateTime, let parsedTime = result.canonicalTime,
                      OriginalDateTimeDraftCodec.parseCanonicalTime(parsedTime) != nil else {
                    retainTemporalIssue(intent, key: OriginalTemporalInputIssue.timeFormat)
                    return
                }
                normalized = parsedTime
            }
            let dateText = intent.operation == .date ? normalized : intent.dateText
            let timeText = intent.operation == .time ? normalized : intent.timeText
            processNormalizedCandidate(
                dateText: dateText,
                timeText: timeText,
                dateTouched: intent.dateTouched,
                timeTouched: intent.timeTouched
            )
            if intent.continuation == .focusTime {
                focusedSegment = .time
            } else if intent.continuation == .dismiss {
                focusedSegment = nil
            }
        } catch is CancellationError {
            return
        } catch {
            guard temporalParseIsCurrent(intent) else { return }
            temporalParseIntent = nil
            retainTemporalIssue(intent, key: OriginalTemporalInputIssue.parserUnavailable)
        }
    }

    private func temporalParseIsCurrent(_ intent: OriginalTemporalInputParseIntent) -> Bool {
        intent.isCurrent(activeID: temporalParseIntent?.id, fieldID: field.storageID,
            editorIdentity: session.numericCalculatorIdentity, sourceValue: sourceValue,
            draft: session.dateTimeInputDraft(for: field.storageID, sourceValue: sourceValue))
            && field.canEditDraft(in: session)
    }

    private func retainTemporalIssue(_ intent: OriginalTemporalInputParseIntent, key: String) {
        let pending = OriginalDateTimeInputDraft(
            sourceValue: intent.sourceValue,
            dateText: intent.dateText,
            timeText: intent.timeText,
            dateTouched: intent.dateTouched,
            timeTouched: intent.timeTouched,
            issueKey: key
        )
        draft = pending
        session.setDateTimeInputDraft(pending, for: field.storageID)
    }

    private func processNormalizedCandidate(
        dateText: String,
        timeText: String,
        dateTouched: Bool,
        timeTouched: Bool
    ) {
        guard let value = OriginalDateTimeDraftCodec.combineCanonical(dateText: dateText, timeText: timeText) else {
            let issue = OriginalDateTimeDraftCodec.parseCanonicalDate(dateText) == nil
                ? OriginalTemporalInputIssue.dateFormat : OriginalTemporalInputIssue.timeFormat
            retainBusinessIssue(key: issue, argument: nil, dateText: dateText, timeText: timeText,
                dateTouched: dateTouched, timeTouched: timeTouched)
            return
        }
        switch validateBusinessRules(candidate: value) {
        case .accepted:
            commit(dateText: dateText, timeText: timeText, dateTouched: dateTouched, timeTouched: timeTouched)
        case .warning(let key):
            businessWarningKey = key
            commit(dateText: dateText, timeText: timeText, dateTouched: dateTouched, timeTouched: timeTouched)
        case .rejected(let key, let argument):
            retainBusinessIssue(key: key, argument: argument, dateText: dateText, timeText: timeText,
                dateTouched: dateTouched, timeTouched: timeTouched)
        case .deferred(let key):
            retainBusinessIssue(key: key, argument: nil, dateText: dateText, timeText: timeText,
                dateTouched: dateTouched, timeTouched: timeTouched)
        }
    }

    private func commit(dateText: String, timeText: String, dateTouched: Bool, timeTouched: Bool) {
        // DateTimeInputBox strips subsecond ticks when its DateTimeValue setter
        // runs. Patch only edited segments while retaining the source offset,
        // separator, and timestamp precision pattern.
        guard let storageDate = dateTouched ? (OriginalDateTimeDraftCodec.parseCanonicalDate(dateText) == nil ? nil : dateText) : dateText,
              let storageTime = timeTouched ? (OriginalDateTimeDraftCodec.parseCanonicalTime(timeText) == nil ? nil : timeText) : timeText else {
            let pending = OriginalDateTimeInputDraft(
                sourceValue: sourceValue, dateText: dateText, timeText: timeText,
                dateTouched: dateTouched, timeTouched: timeTouched,
                issueKey: dateTouched && OriginalDateTimeDraftCodec.parseCanonicalDate(dateText) == nil
                    ? OriginalTemporalInputIssue.dateFormat : OriginalTemporalInputIssue.timeFormat
            )
            draft = pending
            session.setDateTimeInputDraft(pending, for: field.storageID)
            return
        }
        guard let serialized = OriginalPropertyDateTimeStorage.replacing(
            dateText: storageDate,
            timeText: storageTime,
            dateTouched: dateTouched,
            timeTouched: timeTouched,
            in: sourceValue,
            resetSubsecondPrecision: true
        ) else {
            businessWarningKey = nil
            let pending = OriginalDateTimeInputDraft(
                sourceValue: sourceValue, dateText: dateText, timeText: timeText,
                dateTouched: dateTouched, timeTouched: timeTouched,
                issueKey: OriginalPropertyDateTimeStorage.unpreservableFormatIssue
            )
            draft = pending
            session.setDateTimeInputDraft(pending, for: field.storageID)
            return
        }
        field.setDraftValue(serialized, in: session)
        session.clearDateTimeInputDraft(for: field.storageID)
        draft = OriginalDateTimeInputDraft(
            sourceValue: serialized,
            dateText: OriginalPropertyDateTimeStorage.dateText(from: serialized) ?? dateText,
            timeText: OriginalPropertyDateTimeStorage.timeText(from: serialized) ?? timeText,
            dateTouched: false, timeTouched: false, issueKey: nil
        )
    }

    private func submit(_ segment: Segment) {
        if segment == .date {
            update(dateText: draft.dateText, timeText: draft.timeText, touched: .date, continuation: .focusTime)
            return
        }
        update(dateText: draft.dateText, timeText: draft.timeText, touched: .time, continuation: .dismiss)
    }

    private func discardInputDraft() {
        temporalParseIntent = nil
        session.clearDateTimeInputDraft(for: field.storageID)
        focusedSegment = nil
        reconcileFromSession()
    }

    private func validateBusinessRules(candidate: Date) -> OriginalDateTimeBusinessResult {
        guard let rule = validationRule else { return .accepted }
        let peerSourceValue = session.fields[rule.peerFieldID]
        let pending = session.dateTimeInputDraft(for: rule.peerFieldID, sourceValue: peerSourceValue ?? "")
        let peer = OriginalDateTimeBusinessValidator.peerValue(
            for: rule,
            sourceValue: peerSourceValue,
            pendingInput: pending
        )
        return OriginalDateTimeBusinessValidator.evaluate(rule, candidate: candidate, peer: peer)
    }

    private func retainBusinessIssue(
        key: String,
        argument: String?,
        dateText: String,
        timeText: String,
        dateTouched: Bool,
        timeTouched: Bool
    ) {
        let pending = OriginalDateTimeInputDraft(
            sourceValue: sourceValue, dateText: dateText, timeText: timeText,
            dateTouched: dateTouched, timeTouched: timeTouched,
            issueKey: key, issueArgument: argument
        )
        draft = pending
        session.setDateTimeInputDraft(pending, for: field.storageID)
    }

    private func revalidatePendingBusinessInput() {
        guard let pending = session.dateTimeInputDraft(for: field.storageID, sourceValue: sourceValue),
              OriginalDateTimeInputIssue.isBusinessIssue(pending.issueKey),
              let candidate = OriginalDateTimeDraftCodec.combineCanonical(
                dateText: pending.dateText,
                timeText: pending.timeText
              ) else { return }
        switch validateBusinessRules(candidate: candidate) {
        case .accepted:
            commit(dateText: pending.dateText, timeText: pending.timeText,
                dateTouched: pending.dateTouched, timeTouched: pending.timeTouched)
        case .warning(let key):
            businessWarningKey = key
            commit(dateText: pending.dateText, timeText: pending.timeText,
                dateTouched: pending.dateTouched, timeTouched: pending.timeTouched)
        case .rejected(let key, let argument):
            retainBusinessIssue(key: key, argument: argument, dateText: pending.dateText,
                timeText: pending.timeText, dateTouched: pending.dateTouched,
                timeTouched: pending.timeTouched)
        case .deferred(let key):
            retainBusinessIssue(key: key, argument: nil, dateText: pending.dateText,
                timeText: pending.timeText, dateTouched: pending.dateTouched,
                timeTouched: pending.timeTouched)
        }
    }

    private func refreshCommittedWarning() {
        guard !isMixed,
              session.dateTimeInputDraft(for: field.storageID, sourceValue: sourceValue) == nil,
              let value = OriginalDateTimeDraftCodec.parseStoredValue(sourceValue) else {
            businessWarningKey = nil
            return
        }
        guard case .warning(let key) = validateBusinessRules(candidate: value) else {
            businessWarningKey = nil
            return
        }
        businessWarningKey = key
    }

    private func reconcileFromSession() {
        let raw = sourceValue
        if let retained = session.dateTimeInputDraft(for: field.storageID, sourceValue: raw) {
            draft = retained
            return
        }
        guard !isMixed else {
            draft = OriginalDateTimeInputDraft(
                sourceValue: raw, dateText: "", timeText: "", dateTouched: false, timeTouched: false, issueKey: nil
            )
            return
        }
        if raw.isEmpty {
            // InputDateTimePropertyItem is a non-nullable DateTime dependency
            // property whose source default is DateTime.MinValue.
            draft = OriginalDateTimeInputDraft(
                sourceValue: raw, dateText: "0001-01-01", timeText: "00:00:00",
                dateTouched: false, timeTouched: false, issueKey: nil
            )
            return
        }
        if let date = OriginalPropertyDateTimeStorage.dateText(from: raw) {
            draft = OriginalDateTimeInputDraft(
                sourceValue: raw,
                dateText: date,
                timeText: OriginalPropertyDateTimeStorage.timeText(from: raw) ?? "00:00:00",
                dateTouched: false, timeTouched: false, issueKey: nil
            )
            return
        }
        let invalid = OriginalDateTimeInputDraft(
            sourceValue: raw, dateText: raw, timeText: "", dateTouched: true, timeTouched: false,
            issueKey: "Improperly formatted date."
        )
        draft = invalid
        session.setDateTimeInputDraft(invalid, for: field.storageID)
    }
}
