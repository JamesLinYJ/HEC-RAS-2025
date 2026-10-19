import Foundation

/// A contiguous append from the retained source BatchJob.Messages collection.
public struct PlanComputeJobMessageUpdate: Decodable, Equatable, Sendable {
    public let runId: String
    public let messages: [PlanComputeJobMessage]

    public init(runId: String, messages: [PlanComputeJobMessage]) {
        self.runId = runId
        self.messages = messages
    }
}

/// One original message, kept distinct even when another message has the same
/// code and evaluated text.
public struct PlanComputeJobMessage: Decodable, Equatable, Sendable, Identifiable {
    public let index: Int
    public let code: String
    public let defaultSeverity: String
    public let evaluatedMessage: String
    public let logData: [PlanComputeJobLogDatum]

    public var id: Int { index }

    public init(index: Int, code: String, defaultSeverity: String,
                evaluatedMessage: String, logData: [PlanComputeJobLogDatum]) {
        self.index = index
        self.code = code
        self.defaultSeverity = defaultSeverity
        self.evaluatedMessage = evaluatedMessage
        self.logData = logData
    }
}

public struct PlanComputeJobLogDatum: Decodable, Equatable, Sendable {
    public let key: String
    public let value: String?
    public let target: PlanDiagnosticTarget?

    public init(key: String, value: String?, target: PlanDiagnosticTarget? = nil) {
        self.key = key
        self.value = value
        self.target = target
    }
}

/// Exact source object identity captured when a diagnostic is produced.
/// Feature rows additionally carry a stable source token, name and HDF SHA so
/// navigation can reject a row that shifted after the diagnostic was emitted.
public struct PlanDiagnosticTarget: Codable, Equatable, Sendable, Identifiable {
    public let kind: String
    public let projectPath: String
    public let projectRevision: String
    public let planPath: String
    public let planRevision: String
    public let assetPath: String
    public let assetRevision: String
    public let featureID: String?
    public let featureName: String?

    public var id: String {
        [kind, projectPath, projectRevision, planPath, planRevision,
         assetPath, assetRevision, featureID ?? "", featureName ?? ""].joined(separator: "|")
    }

    public init(kind: String, projectPath: String, projectRevision: String,
                planPath: String, planRevision: String, assetPath: String,
                assetRevision: String, featureID: String? = nil, featureName: String? = nil) {
        self.kind = kind
        self.projectPath = projectPath
        self.projectRevision = projectRevision
        self.planPath = planPath
        self.planRevision = planRevision
        self.assetPath = assetPath
        self.assetRevision = assetRevision
        self.featureID = featureID
        self.featureName = featureName
    }
}
