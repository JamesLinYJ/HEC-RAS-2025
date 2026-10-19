import Foundation

/// The five message levels exposed by Utility.Logging.MessageSeverity.
enum WorkspaceMessageSeverity: String, CaseIterable, Codable, Hashable, Sendable {
    case information = "Information"
    case trace = "Trace"
    case debug = "Debug"
    case warning = "Warning"
    case error = "Error"

    var visualSeverity: SharedVisualMessageSeverity {
        switch self {
        case .information: .information
        case .trace: .trace
        case .debug: .debug
        case .warning: .warning
        case .error: .error
        }
    }

    var localizationKey: String { rawValue }

    var isError: Bool { self == .error }
}

/// A stable description of a ToastMessage.DefaultAction. It carries the
/// destination identity instead of retaining an action closure past the
/// project or map that created the message.
enum WorkspaceMessageDefaultAction: Hashable, Sendable {
    case showMessages
    case openEditor(projectSessionID: UUID, editorKind: String, assetID: String)
    case openMap(projectSessionID: UUID, mapID: UUID)

    var titleKey: String {
        switch self {
        case .showMessages: "Messages"
        case .openEditor: "Open Editor"
        case .openMap: "Open Map"
        }
    }

    var systemImage: String {
        switch self {
        case .showMessages: "text.bubble"
        case .openEditor: "pencil"
        case .openMap: "map"
        }
    }
}

/// A retained workspace message and its optional, identity-bound action.
/// `id` and `time` are injectable so queue and expiry behavior can be tested
/// deterministically.
struct WorkspaceMessage: Identifiable, Hashable, Sendable {
    let id: UUID
    let time: Date
    let operation: String
    let text: String
    let severity: WorkspaceMessageSeverity
    let defaultAction: WorkspaceMessageDefaultAction?

    init(
        id: UUID = UUID(),
        time: Date = Date(),
        operation: String,
        text: String,
        severity: WorkspaceMessageSeverity = .information,
        defaultAction: WorkspaceMessageDefaultAction? = nil
    ) {
        self.id = id
        self.time = time
        self.operation = operation
        self.text = text
        self.severity = severity
        self.defaultAction = defaultAction
    }

    /// Compatibility for existing callers while producers migrate to the
    /// source's full severity enum.
    init(
        operation: String,
        text: String,
        isError: Bool,
        id: UUID = UUID(),
        time: Date = Date(),
        defaultAction: WorkspaceMessageDefaultAction? = nil
    ) {
        self.init(
            id: id,
            time: time,
            operation: operation,
            text: text,
            severity: isError ? .error : .information,
            defaultAction: defaultAction
        )
    }

    /// Kept for existing history filters and toolbar badges.
    var isError: Bool { severity.isError }
}
