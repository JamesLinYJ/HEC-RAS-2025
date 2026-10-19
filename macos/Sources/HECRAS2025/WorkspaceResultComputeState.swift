import Foundation
import RASWorkspaceCore

struct WorkspaceResultComputeCapture: Equatable, Sendable {
    let projectSessionID: UUID
    let editorID: UUID
    let operationOwnerToken: String
    let operationContextID: String
    let projectPath: String
    let projectRevision: String
    let projectXmlFingerprint: String
    let planPath: String
    let planRevision: String

    init(projectSessionID: UUID, editorID: UUID, operationOwnerToken: String,
         operationContextID: String, projectPath: String, projectRevision: String,
         projectXmlFingerprint: String, planPath: String, planRevision: String) {
        self.projectSessionID = projectSessionID
        self.editorID = editorID
        self.operationOwnerToken = operationOwnerToken
        self.operationContextID = operationContextID
        self.projectPath = Self.canonical(projectPath)
        self.projectRevision = projectRevision
        self.projectXmlFingerprint = projectXmlFingerprint
        self.planPath = Self.canonical(planPath)
        self.planRevision = planRevision
    }

    fileprivate static func canonical(_ path: String) -> String {
        SourceFilePaths.canonical(URL(fileURLWithPath: path))
    }
}

enum WorkspaceResultComputeStatus: String, Equatable, Sendable {
    case running
    case completed
    case failed
    case cancelled
    case unknown

    var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }

    var localizedTitle: String {
        switch self {
        case .running: "Running"
        case .completed: "Completed Successfully"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .unknown: "Unknown"
        }
    }
}

struct WorkspaceResultComputeEntry: Equatable, Sendable, Identifiable {
    let runID: String
    let projectSessionID: UUID
    let editorID: UUID
    let operationOwnerToken: String
    let operationContextID: String
    let projectPath: String
    let projectRevision: String
    let projectXmlFingerprint: String
    let planPath: String
    let planRevision: String
    let resultPath: String
    let resultName: String
    let resultRevision: String?
    let status: WorkspaceResultComputeStatus
    let fraction: Double?
    let message: String?
    let taskName: String?
    let failureReason: String?
    var profileTimeline: LiveMapResultProfileTimeline? = nil

    var id: String { resultPath + "\n" + runID }
}

/// Accepted source catalog snapshots can confirm a terminal output even when
/// no saved map currently owns a MultiResult view for its Plan.
enum WorkspaceResultComputeCatalogReconciliation {
    private static let sourceResultClasses: Set<String> = [
        "ObservableResult", "ResultNode", "ResultNodeVM", "MultiResultNode", "MultiResultNodeVM"
    ]

    static func confirmedTerminalEntries(in snapshot: LayerTreeSnapshot,
                                         projectSessionID: UUID,
                                         liveEntries: [String: WorkspaceResultComputeEntry])
        -> [WorkspaceResultComputeEntry] {
        var confirmed: [String: WorkspaceResultComputeEntry] = [:]
        func visit(_ node: LayerTreeNode) {
            if sourceResultClasses.contains(node.sourceClass),
               let rawPath = node.resultComputeSourcePath, !rawPath.isEmpty,
               let sourceRevision = node.resultComputeSourceRevision, !sourceRevision.isEmpty {
                let path = SourceFilePaths.canonical(URL(fileURLWithPath: rawPath))
                if let entry = liveEntries[path],
                   entry.projectSessionID == projectSessionID,
                   entry.status.isTerminal,
                   SourceFilePaths.canonical(URL(fileURLWithPath: entry.resultPath)) == path,
                   entry.resultRevision?.caseInsensitiveCompare(sourceRevision) == .orderedSame {
                    confirmed[entry.id] = entry
                }
            }
            for child in node.children ?? [] { visit(child) }
        }
        for root in snapshot.roots { visit(root) }
        return confirmed.values.sorted { $0.resultPath < $1.resultPath }
    }
}

struct WorkspaceResultComputePresentation: Equatable, Sendable {
    let status: WorkspaceResultComputeStatus
    let fraction: Double?
    let message: String?
    let taskName: String?
    let failureReason: String?
    let isLive: Bool

    static func resolve(path: String?, projectSessionID: UUID,
                        sourceRevision: String? = nil,
                        liveEntries: [String: WorkspaceResultComputeEntry],
                        persistedState: String?, persistedFailureReason: String?) -> Self {
        if let path, !path.isEmpty {
            let canonicalPath = WorkspaceResultComputeCapture.canonical(path)
            if let entry = liveEntries[canonicalPath], entry.projectSessionID == projectSessionID {
                let revisionsMatch: Bool
                if entry.status.isTerminal {
                    if let sourceRevision {
                        revisionsMatch = entry.resultRevision.map {
                            sourceRevision.caseInsensitiveCompare($0) == .orderedSame
                        } ?? false
                    } else {
                        revisionsMatch = entry.resultRevision != nil
                    }
                } else {
                    revisionsMatch = true
                }
                if revisionsMatch {
                    return .init(status: entry.status, fraction: entry.fraction, message: entry.message,
                                  taskName: entry.taskName, failureReason: entry.failureReason,
                                  isLive: entry.status == .running)
                }
            }
        }

        // Catalog nodes report persisted ComputeSummary only. A missing
        // summary, a failure-reason fallback, or a file on disk is never proof
        // of a running or failed compute.
        let status: WorkspaceResultComputeStatus
        switch persistedState?.lowercased() {
        case "completed": status = .completed
        case "failed": status = .failed
        default: status = .unknown
        }
        return .init(status: status, fraction: nil, message: nil, taskName: nil,
                     failureReason: status == .failed ? persistedFailureReason : nil,
                     isLive: false)
    }
}

enum WorkspaceResultComputeReducer {
    static func acceptProgress(_ envelope: BackendResultComputeUpdate,
                               progress: BackendProgressUpdate,
                               capture: WorkspaceResultComputeCapture,
                               activeCapture: WorkspaceResultComputeCapture?,
                               projectSessionID: UUID,
                               editorID: UUID,
                               operationOwnerToken: String?,
                               operationContextID: String?) -> WorkspaceResultComputeEntry? {
        guard progress.resultCompute == envelope,
              isCurrent(capture: capture, activeCapture: activeCapture,
                        projectSessionID: projectSessionID, editorID: editorID,
                        operationOwnerToken: operationOwnerToken,
                        operationContextID: operationContextID),
              let entry = entry(from: envelope, capture: capture,
                                fraction: progress.fraction, message: progress.message,
                                taskName: progress.taskName),
              entry.status == .running else { return nil }
        return entry
    }

    static func acceptTerminal(_ envelope: BackendResultComputeUpdate,
                               result: PlanComputeExecutionResult,
                               capture: WorkspaceResultComputeCapture,
                               activeCapture: WorkspaceResultComputeCapture?,
                               projectSessionID: UUID,
                               editorID: UUID,
                               operationOwnerToken: String?,
                               operationContextID: String?) -> WorkspaceResultComputeEntry? {
        guard isCurrent(capture: capture, activeCapture: activeCapture,
                        projectSessionID: projectSessionID, editorID: editorID,
                        operationOwnerToken: operationOwnerToken,
                        operationContextID: operationContextID),
              result.resultCompute == envelope,
              result.state.lowercased() == envelope.state.lowercased(),
              let resultPath = envelope.resultPath,
              let responsePath = result.resultPath,
              let resultRevision = envelope.resultRevision,
              !resultRevision.isEmpty,
              WorkspaceResultComputeCapture.canonical(resultPath)
                == WorkspaceResultComputeCapture.canonical(responsePath),
              resultRevision == result.resultRevision,
              let entry = entry(from: envelope, capture: capture,
                                fraction: result.state == "completed" ? 1 : nil,
                                message: nil, taskName: nil),
              entry.status.isTerminal else { return nil }
        return entry
    }

    static func shouldReplace(_ current: WorkspaceResultComputeEntry?, with next: WorkspaceResultComputeEntry) -> Bool {
        guard let current else { return true }
        guard current.projectSessionID == next.projectSessionID else { return true }
        if current.runID != next.runID { return true }
        guard current.operationOwnerToken == next.operationOwnerToken,
              current.operationContextID == next.operationContextID else { return false }
        return !current.status.isTerminal
    }

    private static func isCurrent(capture: WorkspaceResultComputeCapture,
                                  activeCapture: WorkspaceResultComputeCapture?,
                                  projectSessionID: UUID, editorID: UUID,
                                  operationOwnerToken: String?, operationContextID: String?) -> Bool {
        capture == activeCapture
            && capture.projectSessionID == projectSessionID
            && capture.editorID == editorID
            && capture.operationOwnerToken == operationOwnerToken
            && capture.operationContextID == operationContextID
    }

    private static func entry(from envelope: BackendResultComputeUpdate,
                              capture: WorkspaceResultComputeCapture,
                              fraction: Double?, message: String?, taskName: String?) -> WorkspaceResultComputeEntry? {
        guard let runID = UUID(uuidString: envelope.runId),
              runID.uuidString.lowercased() == envelope.runId.lowercased(),
              WorkspaceResultComputeCapture.canonical(envelope.projectPath) == capture.projectPath,
              envelope.projectRevision == capture.projectRevision,
              envelope.projectXmlFingerprint == capture.projectXmlFingerprint,
              WorkspaceResultComputeCapture.canonical(envelope.planPath) == capture.planPath,
              envelope.planRevision == capture.planRevision,
              let resultPath = envelope.resultPath, !resultPath.isEmpty else { return nil }

        let status = WorkspaceResultComputeStatus(rawValue: envelope.state.lowercased()) ?? .unknown
        guard status != .unknown,
              !(status == .running && envelope.resultRevision != nil) else { return nil }
        let validFraction = fraction.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
        let suppliedName = envelope.resultName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resultName = suppliedName.flatMap { $0.isEmpty ? nil : $0 }
            ?? URL(fileURLWithPath: resultPath).lastPathComponent
        return WorkspaceResultComputeEntry(
            runID: runID.uuidString,
            projectSessionID: capture.projectSessionID,
            editorID: capture.editorID,
            operationOwnerToken: capture.operationOwnerToken,
            operationContextID: capture.operationContextID,
            projectPath: capture.projectPath,
            projectRevision: capture.projectRevision,
            projectXmlFingerprint: capture.projectXmlFingerprint,
            planPath: capture.planPath,
            planRevision: capture.planRevision,
            resultPath: WorkspaceResultComputeCapture.canonical(resultPath),
            resultName: resultName,
            resultRevision: envelope.resultRevision,
            status: status,
            fraction: validFraction,
            message: message,
            taskName: taskName,
            failureReason: status == .failed || status == .cancelled ? envelope.failureReason : nil)
    }
}
