import Foundation

/// The progress metadata used by the task hub. Values come from a retained
/// source operation; missing fractions remain indeterminate.
public struct BackendOperationProgress: Sendable {
    public let fraction: Double?
    public let message: String?
    public let taskName: String?

    public init(fraction: Double? = nil, message: String? = nil, taskName: String? = nil) {
        self.fraction = fraction
        self.message = message
        self.taskName = taskName
    }
}

public protocol BackendOperationProgressProviding: Sendable {
    var backendOperationProgress: BackendOperationProgress { get }
}

public enum BackendOperationPhase: String, Sendable {
    case started
    case progress
    case completed
    case failed
    case cancelled
}

public enum BackendOperationCancellationCapability: String, Sendable {
    case none
    case sourceControl
}

/// One real invocation of the retained backend. `isJob` is true for duplex
/// source operations; one-shot discovery and validation RPCs are observable
/// but are not inserted into the BatchJob/task list.
public struct BackendOperationEvent: Sendable {
    public let invocationID: String
    public let method: String
    public let phase: BackendOperationPhase
    public let isJob: Bool
    public let cancellationCapability: BackendOperationCancellationCapability
    public let progress: Double?
    public let message: String?
    public let taskName: String?
    public let sourceState: String?
    public let sourceSucceeded: Bool?
    public let sourceCancelled: Bool?
    public let errorMessage: String?
    public let requestSourceCancellation: (@Sendable () -> Bool)?

    public init(invocationID: String, method: String, phase: BackendOperationPhase,
                isJob: Bool, cancellationCapability: BackendOperationCancellationCapability = .none,
                progress: Double? = nil, message: String? = nil, taskName: String? = nil,
                sourceState: String? = nil, sourceSucceeded: Bool? = nil,
                sourceCancelled: Bool? = nil, errorMessage: String? = nil,
                requestSourceCancellation: (@Sendable () -> Bool)? = nil) {
        self.invocationID = invocationID
        self.method = method
        self.phase = phase
        self.isJob = isJob
        self.cancellationCapability = cancellationCapability
        self.progress = progress
        self.message = message
        self.taskName = taskName
        self.sourceState = sourceState
        self.sourceSucceeded = sourceSucceeded
        self.sourceCancelled = sourceCancelled
        self.errorMessage = errorMessage
        self.requestSourceCancellation = requestSourceCancellation
    }
}

/// Thread-safe observer hub. The Core module does not depend on SwiftUI or the
/// app's job registry; the host application owns observer registration.
public final class BackendOperationEventCenter: @unchecked Sendable {
    public static let shared = BackendOperationEventCenter()

    private let lock = NSLock()
    private var observers: [UUID: @Sendable (BackendOperationEvent) -> Void] = [:]

    public init() {}

    @discardableResult
    public func addObserver(_ observer: @escaping @Sendable (BackendOperationEvent) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { observers[id] = observer }
        return id
    }

    public func removeObserver(_ id: UUID) {
        lock.withLock { _ = observers.removeValue(forKey: id) }
    }

    public func publish(_ event: BackendOperationEvent) {
        let callbacks = lock.withLock { Array(observers.values) }
        for callback in callbacks { callback(event) }
    }
}

/// Common source terminal fields are inspected without assuming every source
/// result has the same schema. The full result still remains owned by its
/// method-specific provider.
public struct BackendOperationTerminal: Sendable {
    public let state: String?
    public let succeeded: Bool?
    public let cancelled: Bool?
    public let message: String?

    public init(state: String? = nil, succeeded: Bool? = nil,
                cancelled: Bool? = nil, message: String? = nil) {
        self.state = state
        self.succeeded = succeeded
        self.cancelled = cancelled
        self.message = message
    }

    public var phase: BackendOperationPhase {
        let normalized = state?.lowercased()
        if cancelled == true || normalized == "cancelled" || normalized == "canceled" {
            return .cancelled
        }
        if succeeded == false || normalized == "failed" || normalized == "failure" || normalized == "error" {
            return .failed
        }
        return .completed
    }

    public static func decode(from frame: Data) -> Self {
        guard let root = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any] else {
            return Self()
        }
        let result = root["result"] as? [String: Any] ?? root
        let state = result["state"] as? String ?? result["status"] as? String
        let succeeded = result["succeeded"] as? Bool ?? result["success"] as? Bool
        let cancelled = result["cancelled"] as? Bool ?? result["canceled"] as? Bool
        let message = result["message"] as? String ?? result["errorMessage"] as? String
            ?? result["failureReason"] as? String
        return Self(state: state, succeeded: succeeded, cancelled: cancelled, message: message)
    }
}

extension BackendProgressUpdate: BackendOperationProgressProviding {
    public var backendOperationProgress: BackendOperationProgress {
        BackendOperationProgress(fraction: fraction, message: message, taskName: taskName)
    }
}
