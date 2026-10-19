import Foundation

/// Presentation-only text and validation state for the native segmented
/// DateInputBox/TimeInputBox replacement. This value never enters model fields.
struct OriginalDateTimeInputDraft: Codable, Sendable, Equatable {
    let sourceValue: String
    var dateText: String
    var timeText: String
    var dateTouched: Bool
    var timeTouched: Bool
    var issueKey: String?
    var issueArgument: String?

    init(
        sourceValue: String,
        dateText: String,
        timeText: String,
        dateTouched: Bool,
        timeTouched: Bool,
        issueKey: String?,
        issueArgument: String? = nil
    ) {
        self.sourceValue = sourceValue
        self.dateText = dateText
        self.timeText = timeText
        self.dateTouched = dateTouched
        self.timeTouched = timeTouched
        self.issueKey = issueKey
        self.issueArgument = issueArgument
    }
}

enum OriginalDateTimeInputIssue {
    static let relatedInputIncomplete = "Complete the related date or time input before validating this value."
    static let boundaryStartUnavailable = "The source boundary start time is unavailable for validation."
    static let startsAfterBoundaryTemplate = "Starts after the boundary condition time window starts (%@)"

    static func isBusinessIssue(_ key: String?) -> Bool {
        guard let key else { return false }
        return key == relatedInputIncomplete || key == boundaryStartUnavailable || key == startsAfterBoundaryTemplate
    }
}

enum OriginalDateTimeBusinessRule: Equatable, Sendable {
    case timeWindowStart(peerFieldID: String)
    case timeWindowEnd(peerFieldID: String)
    case fixedStartNotAfterBoundary(peerFieldID: String)

    var peerFieldID: String {
        switch self {
        case .timeWindowStart(let fieldID), .timeWindowEnd(let fieldID), .fixedStartNotAfterBoundary(let fieldID):
            fieldID
        }
    }
}

enum OriginalDateTimePeerValue: Equatable, Sendable {
    case missing
    case pendingInput
    case invalid
    case value(Date)
}

enum OriginalDateTimeBusinessResult: Equatable, Sendable {
    case accepted
    case warning(String)
    case rejected(key: String, argument: String?)
    case deferred(key: String)
}

/// Native counterpart of the source ValidateDateTime delegates. Rules are
/// inferred only from exact serialized setter routes and their verified peer
/// routes; a similarly named field does not acquire business behavior.
enum OriginalDateTimeBusinessValidator {
    private static let timeWindowStartSetters: Set<String> = [
        "Visual_WinUI_Controls_TimeWindow_StartTime",
        "Visual_WinUI_Controls_TimeWindowGroup_StartTime"
    ]
    private static let timeWindowEndSetters: Set<String> = [
        "Visual_WinUI_Controls_TimeWindow_EndTime",
        "Visual_WinUI_Controls_TimeWindowGroup_EndTime"
    ]
    private static let inputDateTimeSetter = "Visual_WinUI_Controls_InputDateTimePropertyItem_DateTimeValue"
    private static let timelineStartSetter = "Visual_WinUI_Controls_Timeline_StartTime"

    static func rule(for field: SourceEditorField) -> OriginalDateTimeBusinessRule? {
        guard field.kind == "date", field.sourceType == "DateTime" else { return nil }

        if timeWindowStartSetters.contains(field.sourceSetter), field.id.hasSuffix("StartTime") {
            let peerRoute = String(field.id.dropLast("StartTime".count)) + "EndTime"
            let peerID = field.scoped(peerRoute)
            guard verifiedPeer(peerID, setter: expectedWindowPeerSetter(for: field.sourceSetter, start: false)) else { return nil }
            return .timeWindowStart(peerFieldID: peerID)
        }

        if timeWindowEndSetters.contains(field.sourceSetter), field.id.hasSuffix("EndTime") {
            let peerRoute = String(field.id.dropLast("EndTime".count)) + "StartTime"
            let peerID = field.scoped(peerRoute)
            guard verifiedPeer(peerID, setter: expectedWindowPeerSetter(for: field.sourceSetter, start: true)) else { return nil }
            return .timeWindowEnd(peerFieldID: peerID)
        }

        let knownRegularHost = field.scope.hasSuffix("RegularTimeSeriesPayloadEditor")
            || field.scope.hasSuffix("RegularSpatiallyVariableTimeSeriesPayloadEditor")
        guard knownRegularHost,
              field.id == "TimeSeriesDefinition_FixedStartTime",
              field.sourceSetter == inputDateTimeSetter else { return nil }

        let peerID = field.scoped("BoundaryConditionLine_BoundaryCondition_StartTime")
        guard verifiedPeer(peerID, setter: timelineStartSetter) else { return nil }
        return .fixedStartNotAfterBoundary(peerFieldID: peerID)
    }

    /// Resolves the peer without falling back to its committed value when a
    /// matching presentation draft exists. Time-window endpoints can compare
    /// a complete peer candidate so two drafts cannot deadlock each other;
    /// fixed-start validation still waits for the committed boundary value.
    static func peerValue(
        for rule: OriginalDateTimeBusinessRule,
        sourceValue: String?,
        pendingInput: OriginalDateTimeInputDraft?
    ) -> OriginalDateTimePeerValue {
        if let pendingInput, pendingInput.sourceValue == (sourceValue ?? "") {
            guard pendingInput.issueKey == nil || OriginalDateTimeInputIssue.isBusinessIssue(pendingInput.issueKey) else {
                return .pendingInput
            }
            switch rule {
            case .timeWindowStart(_), .timeWindowEnd(_):
                // Only normalized service-validated peer text is comparable.
                // A raw culture-sensitive draft waits for its own .NET parse
                // rather than being interpreted with the Mac's different
                // date grammar or falling back to a stale committed value.
                guard let candidate = OriginalDateTimeDraftCodec.combineCanonical(
                    dateText: pendingInput.dateText,
                    timeText: pendingInput.timeText
                ) else {
                    return .pendingInput
                }
                return .value(candidate)
            case .fixedStartNotAfterBoundary(_):
                return .pendingInput
            }
        }

        guard let sourceValue else { return .missing }
        guard let value = OriginalDateTimeDraftCodec.parseStoredValue(sourceValue) else { return .invalid }
        return .value(value)
    }

    static func evaluate(
        _ rule: OriginalDateTimeBusinessRule,
        candidate: Date,
        peer: OriginalDateTimePeerValue
    ) -> OriginalDateTimeBusinessResult {
        switch peer {
        case .pendingInput:
            return .deferred(key: OriginalDateTimeInputIssue.relatedInputIncomplete)
        case .invalid:
            if case .fixedStartNotAfterBoundary = rule {
                return .deferred(key: OriginalDateTimeInputIssue.boundaryStartUnavailable)
            }
            return .deferred(key: OriginalDateTimeInputIssue.relatedInputIncomplete)
        case .missing:
            // The original Regular*PayloadEditor delegate returns Success
            // when BoundaryConditionLine is null. A missing window endpoint
            // cannot be compared and remains blocked instead of using stale data.
            if case .fixedStartNotAfterBoundary = rule { return .accepted }
            return .deferred(key: OriginalDateTimeInputIssue.relatedInputIncomplete)
        case .value(let peerDate):
            switch rule {
            case .timeWindowStart:
                if candidate == peerDate { return .warning("Time window cannot start when it ends.") }
                if candidate > peerDate { return .warning("Time window cannot begin after it ends.") }
                return .accepted
            case .timeWindowEnd:
                if candidate == peerDate { return .warning("Time window cannot end when it starts.") }
                if candidate < peerDate { return .warning("Time window cannot end before it begins.") }
                return .accepted
            case .fixedStartNotAfterBoundary:
                guard candidate > peerDate else { return .accepted }
                return .rejected(
                    key: OriginalDateTimeInputIssue.startsAfterBoundaryTemplate,
                    argument: localizedBoundaryDate(peerDate)
                )
            }
        }
    }

    private static func expectedWindowPeerSetter(for setter: String, start: Bool) -> String? {
        if setter.hasPrefix("Visual_WinUI_Controls_TimeWindowGroup_") {
            return "Visual_WinUI_Controls_TimeWindowGroup_" + (start ? "StartTime" : "EndTime")
        }
        if setter.hasPrefix("Visual_WinUI_Controls_TimeWindow_") {
            return "Visual_WinUI_Controls_TimeWindow_" + (start ? "StartTime" : "EndTime")
        }
        return nil
    }

    private static func verifiedPeer(_ storageID: String, setter: String?) -> Bool {
        guard let setter,
              let peer = SourceEditorLibrary.shared.field(storageID: storageID) else { return false }
        return peer.kind == "date" && peer.sourceType == "DateTime" && peer.sourceSetter == setter
    }

    private static func localizedBoundaryDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

struct OriginalDateTimeValidationDependency: Equatable {
    let peerFieldID: String?
    let sourceValue: String?
    let pendingInput: OriginalDateTimeInputDraft?
}
