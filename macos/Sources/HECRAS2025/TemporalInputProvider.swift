import Foundation
import RASWorkspaceCore

enum OriginalTemporalInputOperation: String, Codable, Sendable {
    case date
    case time
}

enum OriginalTemporalInputContinuation: String, Codable, Sendable {
    case none
    case focusTime
    case dismiss
}

struct OriginalTemporalInputParseIntent: Identifiable, Equatable, Sendable {
    let id: UUID
    let operation: OriginalTemporalInputOperation
    let text: String
    let cultureName: String
    let fieldID: String
    let editorIdentity: String
    let sourceValue: String
    let dateText: String
    let timeText: String
    let dateTouched: Bool
    let timeTouched: Bool
    let continuation: OriginalTemporalInputContinuation

    init(
        id: UUID = UUID(),
        operation: OriginalTemporalInputOperation,
        text: String,
        locale: Locale = .autoupdatingCurrent,
        fieldID: String,
        editorIdentity: String,
        sourceValue: String,
        dateText: String,
        timeText: String,
        dateTouched: Bool,
        timeTouched: Bool,
        continuation: OriginalTemporalInputContinuation = .none
    ) {
        self.id = id
        self.operation = operation
        self.text = text
        cultureName = OriginalTemporalCulture.name(for: locale)
        self.fieldID = fieldID
        self.editorIdentity = editorIdentity
        self.sourceValue = sourceValue
        self.dateText = dateText
        self.timeText = timeText
        self.dateTouched = dateTouched
        self.timeTouched = timeTouched
        self.continuation = continuation
    }

    func isCurrent(
        activeID: UUID?,
        fieldID: String,
        editorIdentity: String,
        sourceValue: String,
        draft: OriginalDateTimeInputDraft?
    ) -> Bool {
        guard id == activeID, self.fieldID == fieldID, self.editorIdentity == editorIdentity,
              self.sourceValue == sourceValue, let draft else { return false }
        return draft.sourceValue == sourceValue && draft.issueKey == OriginalTemporalInputIssue.parsing &&
            draft.dateText == dateText && draft.timeText == timeText &&
            draft.dateTouched == dateTouched && draft.timeTouched == timeTouched
    }
}

struct TemporalInputParseRequest: Encodable, Sendable {
    let operation: String
    let text: String
    let cultureName: String
}

struct TemporalInputParseResult: Decodable, Equatable, Sendable {
    let operation: String
    let isValid: Bool
    let canonicalDate: String?
    let canonicalTime: String?
    let timeSpanTicks: Int64?
    let timeSpanDays: Int?
    let timeSpanHours: Int?
    let timeSpanMinutes: Int?
    let timeSpanSeconds: Int?
    let canSetDateTime: Bool
}

enum OriginalTemporalInputIssue {
    static let dateFormat = "Improperly formatted date."
    static let timeFormat = "Improperly formatted time."
    static let parserUnavailable = "The source date/time parser is unavailable."
    static let parsing = "Validating date/time input…"
}

enum OriginalTemporalCulture {
    /// Convert the active Foundation locale to a .NET culture name while
    /// removing Foundation-only encoding, calendar, numbering, and private
    /// extension suffixes. Language, script, and region remain intact.
    static func name(for locale: Locale) -> String {
        // Locale.Language infers likely scripts (de -> Latn, th -> Thai).
        // Those are not explicit culture subtags. Parse the canonical locale
        // components so .NET receives de-DE rather than a synthesized name.
        // Foundation may already remove a redundant default script, e.g.
        // zh-Hans_CN -> zh_CN; non-default scripts such as sr-Latn remain.
        let language = Locale.Components(identifier: locale.identifier).languageComponents
        return [language.languageCode?.identifier, language.script?.identifier,
                language.region?.identifier].compactMap { $0 }.joined(separator: "-")
    }
}

struct BackendTemporalInputProvider: Sendable {
    private let client: BackendProcessClient

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func parse(_ intent: OriginalTemporalInputParseIntent) async throws -> TemporalInputParseResult {
        let request = TemporalInputParseRequest(
            operation: intent.operation.rawValue,
            text: intent.text,
            cultureName: intent.cultureName
        )
        let response = try await client.request("temporal.input.parse", parameters: request,
            as: TemporalInputParseResult.self)
        guard response.operation == intent.operation.rawValue else {
            throw BackendServiceError(code: "protocolFailure", message: "The temporal parser returned a different operation.")
        }
        return response
    }
}
