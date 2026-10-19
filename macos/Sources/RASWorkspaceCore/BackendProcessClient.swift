import Darwin
import Foundation

public struct BackendServiceError: Error, Decodable, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public var errorDescription: String? { message }
    public init(code: String, message: String) { self.code = code; self.message = message }
}

/// Correlation carried by the source Plan compute operation. `resultPath` is
/// absent until the source creates the actual ObservableResult.
public struct BackendResultComputeUpdate: Decodable, Equatable, Sendable {
    public let runId: String
    public let projectPath: String
    public let projectRevision: String
    public let projectXmlFingerprint: String
    public let planPath: String
    public let planRevision: String
    public let resultPath: String?
    public let resultName: String?
    public let state: String
    public let resultRevision: String?
    public let failureReason: String?

    public init(runId: String, projectPath: String, projectRevision: String,
                projectXmlFingerprint: String, planPath: String, planRevision: String,
                resultPath: String? = nil, resultName: String? = nil,
                state: String, resultRevision: String? = nil,
                failureReason: String? = nil) {
        self.runId = runId
        self.projectPath = projectPath
        self.projectRevision = projectRevision
        self.projectXmlFingerprint = projectXmlFingerprint
        self.planPath = planPath
        self.planRevision = planRevision
        self.resultPath = resultPath
        self.resultName = resultName
        self.state = state
        self.resultRevision = resultRevision
        self.failureReason = failureReason
    }
}

/// Metadata copied from the retained writer's in-memory TimestepAdded event.
/// These are actual source profiles, not evidence of a readable raster payload.
public struct BackendResultProfile: Decodable, Equatable, Sendable {
    public let index: Int
    public let name: String
    public let time: String
    public init(index: Int, name: String, time: String) {
        self.index = index; self.name = name; self.time = time
    }
}

public struct BackendResultProfilesUpdate: Decodable, Equatable, Sendable {
    public let outputBlockName: String
    public let startIndex: Int
    public let profileCount: Int
    public let profiles: [BackendResultProfile]
    public let errorMessage: String?
    public init(outputBlockName: String, startIndex: Int, profileCount: Int,
                profiles: [BackendResultProfile], errorMessage: String? = nil) {
        self.outputBlockName = outputBlockName; self.startIndex = startIndex
        self.profileCount = profileCount; self.profiles = profiles; self.errorMessage = errorMessage
    }
}

/// Progress comes from the retained source operation; a missing fraction is indeterminate.
public struct BackendProgressUpdate: Decodable, Sendable {
    public let fraction: Double?
    public let message: String?
    public let taskName: String?
    public let values: [String: String]?
    public let resultCompute: BackendResultComputeUpdate?
    public let resultProfiles: BackendResultProfilesUpdate?
    public let planMessages: PlanComputeJobMessageUpdate?
    public let streamMapFrame: BackendStreamModeFrame?
    public init(fraction: Double? = nil, message: String? = nil, taskName: String? = nil,
                values: [String: String]? = nil, resultCompute: BackendResultComputeUpdate? = nil,
                resultProfiles: BackendResultProfilesUpdate? = nil,
                planMessages: PlanComputeJobMessageUpdate? = nil,
                streamMapFrame: BackendStreamModeFrame? = nil) {
        self.fraction = fraction; self.message = message; self.taskName = taskName
        self.values = values; self.resultCompute = resultCompute; self.resultProfiles = resultProfiles
        self.planMessages = planMessages; self.streamMapFrame = streamMapFrame
    }
}

/// Invokes the bundled source backend without a shell or a machine-wide .NET installation.
public struct BackendProcessClient: Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public init(executableURL: URL, arguments: [String] = []) {
        self.executableURL = executableURL; self.arguments = arguments
    }
    public func request<Parameters: Encodable & Sendable, Result: Decodable & Sendable>(
        _ method: String, parameters: Parameters, as: Result.Type = Result.self,
        reportsJob: Bool? = nil,
        progress: (@Sendable (BackendProgressUpdate) -> Void)? = nil
    ) async throws -> Result {
        // A request that reports incremental progress is an actual bounded
        // operation/batch, but remains non-cancellable because this one-shot
        // protocol has no source cancellation control.
        let reportsAsJob = reportsJob ?? (progress != nil)
        let id = UUID().uuidString
        let input = try JSONEncoder().encode(Request(id: id, method: method, parameters: parameters, streamProgress: progress != nil))
        let invocation = BackendInvocation(executableURL: executableURL, arguments: arguments)
        let eventCenter = BackendOperationEventCenter.shared
        eventCenter.publish(BackendOperationEvent(invocationID: id, method: method, phase: .started,
            isJob: reportsAsJob))
        do {
            let observedProgress: (@Sendable (BackendProgressUpdate) -> Void)?
            if let progress {
                observedProgress = { update in
                    eventCenter.publish(BackendOperationEvent(invocationID: id, method: method,
                        phase: .progress, isJob: reportsAsJob, progress: update.fraction,
                        message: update.message, taskName: update.taskName))
                    progress(update)
                }
            } else {
                observedProgress = nil
            }
            let output = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try invocation.run(input, requestID: id, progress: observedProgress)
                }.value
            } onCancel: { invocation.cancel() }
            try Task.checkCancellation()
            let response: Response<Result>
            do { response = try JSONDecoder().decode(Response<Result>.self, from: output.data) }
            catch {
                throw BackendServiceError(code: "protocolFailure", message: output.diagnostics.isEmpty
                    ? "The backend returned an invalid response." : output.diagnostics)
            }
            guard response.id == id else {
                throw BackendServiceError(code: "protocolFailure", message: "The backend response has a different request identity.")
            }
            if let error = response.error { throw error }
            guard output.status == 0, let result = response.result else {
                throw BackendServiceError(code: "processFailure", message: output.diagnostics.isEmpty
                    ? "The backend could not finish the operation." : output.diagnostics)
            }
            let terminal = BackendOperationTerminal.decode(from: output.data)
            eventCenter.publish(BackendOperationEvent(invocationID: id, method: method,
                phase: terminal.phase, isJob: reportsAsJob, message: terminal.message,
                sourceState: terminal.state,
                sourceSucceeded: terminal.succeeded, sourceCancelled: terminal.cancelled))
            return result
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            eventCenter.publish(BackendOperationEvent(invocationID: id, method: method,
                phase: cancelled ? .cancelled : .failed, isJob: reportsAsJob,
                errorMessage: cancelled ? nil : error.localizedDescription))
            throw error
        }
    }

    /// Starts one long-lived child using newline-delimited request/control and
    /// progress/terminal frames. The child remains owned by the returned
    /// operation until its terminal response or cancellation.
    public func startDuplex<Parameters: Encodable & Sendable,
                            Control: Encodable & Sendable,
                            Event: Decodable & Sendable,
                            Result: Decodable & Sendable>(
        _ method: String, parameters: Parameters, control: Control.Type = Control.self,
        event: Event.Type = Event.self, as: Result.Type = Result.self,
        reportsJob: Bool = true,
        progressMetadata: @escaping @Sendable (Event) -> BackendOperationProgress? = {
            ($0 as? any BackendOperationProgressProviding)?.backendOperationProgress
        }
    ) throws -> BackendDuplexOperation<Control, Event, Result> {
        let id = UUID().uuidString
        let request = DuplexRequest(id: id, method: method, parameters: parameters,
                                    streamProgress: true, duplex: true)
        var input = try JSONEncoder().encode(request)
        input.append(10)
        return try BackendDuplexInvocation<Control, Event, Result>.start(
            executableURL: executableURL, arguments: arguments + ["--duplex"], requestID: id,
            method: method, reportsJob: reportsJob, initialFrame: input,
            progressMetadata: progressMetadata)
    }

    private struct Request<Parameters: Encodable>: Encodable {
        let id: String; let method: String; let parameters: Parameters; let streamProgress: Bool
    }
    private struct DuplexRequest<Parameters: Encodable>: Encodable {
        let id: String; let method: String; let parameters: Parameters
        let streamProgress: Bool; let duplex: Bool
    }
    private struct Response<Result: Decodable>: Decodable {
        let id: String?
        let result: Result?
        let error: BackendServiceError?
    }
}

/// A running duplex request. Controls are serialized and sequenced by the
/// caller; event delivery applies bounded backpressure so progress metadata and
/// raster frames are not silently dropped when the consumer falls behind.
public struct BackendDuplexOperation<Control: Encodable & Sendable,
                                     Event: Decodable & Sendable,
                                     Result: Decodable & Sendable>: Sendable {
    public let id: String
    public let events: BackendDuplexEventStream<Event>
    private let invocation: BackendDuplexInvocation<Control, Event, Result>
    private let completion: Task<Result, any Error>

    fileprivate init(id: String, events: BackendDuplexEventStream<Event>,
                     invocation: BackendDuplexInvocation<Control, Event, Result>,
                     completion: Task<Result, any Error>) {
        self.id = id; self.events = events; self.invocation = invocation
        self.completion = completion
    }

    public func sendControl(_ control: Control, sequence: UInt64) throws {
        try invocation.sendControl(control, sequence: sequence)
    }

    public func value() async throws -> Result {
        try await withTaskCancellationHandler {
            try await completion.value
        } onCancel: {
            invocation.cancel()
        }
    }

    public func cancel() { invocation.cancel() }

    /// Requests the source's orderly `{ type: "cancel" }` control. Returns
    /// false when the source stream has already closed or the control could
    /// not be written; callers may then explain that termination is a fallback.
    @discardableResult
    public func requestSourceCancellation() -> Bool { invocation.requestSourceCancellation() }
}

/// A single-consumer async sequence backed by a bounded blocking queue. The
/// backend reader waits for capacity instead of accumulating large raster
/// frames or dropping intervening compute/profile events.
public struct BackendDuplexEventStream<Element: Sendable>: AsyncSequence, Sendable {
    public typealias AsyncIterator = Iterator
    private let buffer: BackendDuplexEventBuffer<Element>

    fileprivate init(buffer: BackendDuplexEventBuffer<Element>) { self.buffer = buffer }

    public func makeAsyncIterator() -> Iterator { Iterator(buffer: buffer) }

    public struct Iterator: AsyncIteratorProtocol {
        private let buffer: BackendDuplexEventBuffer<Element>

        fileprivate init(buffer: BackendDuplexEventBuffer<Element>) { self.buffer = buffer }

        public mutating func next() async throws -> Element? {
            let buffer = self.buffer
            return try await Task.detached(priority: .userInitiated) {
                try buffer.next()
            }.value
        }
    }
}

private final class BackendDuplexEventBuffer<Element: Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private let capacity: Int
    private var values: [Element] = []
    private var finished = false
    private var failure: (any Error)?

    init(capacity: Int) { self.capacity = capacity }

    func append(_ value: Element) throws {
        condition.lock()
        while values.count >= capacity && !finished { condition.wait() }
        guard !finished else {
            let error = failure ?? CancellationError()
            condition.unlock()
            throw error
        }
        values.append(value)
        condition.broadcast()
        condition.unlock()
    }

    func next() throws -> Element? {
        condition.lock()
        while values.isEmpty && !finished { condition.wait() }
        if !values.isEmpty {
            let value = values.removeFirst()
            condition.broadcast()
            condition.unlock()
            return value
        }
        let error = failure
        condition.unlock()
        if let error { throw error }
        return nil
    }

    func finish(throwing error: (any Error)? = nil) {
        condition.lock()
        if !finished {
            finished = true
            failure = error
        }
        condition.broadcast()
        condition.unlock()
    }
}

private struct BackendSourceCancelControl: Encodable, Sendable {
    let type: String
}

private struct BackendSourceCancelFrame: Encodable, Sendable {
    let id: String
    let controlSequence: UInt64
    let control: BackendSourceCancelControl
}

private final class BackendDuplexInvocation<Control: Encodable & Sendable,
                                            Event: Decodable & Sendable,
                                            Result: Decodable & Sendable>: @unchecked Sendable {
    private struct ControlFrame<Value: Encodable>: Encodable {
        let id: String
        let controlSequence: UInt64
        let control: Value
    }
    // The terminal envelope has a different generic payload from progress;
    // decode its result/error separately after inspecting the top-level keys.
    private struct Terminal: Decodable {
        let id: String?
        let result: Result?
        let error: BackendServiceError?
    }
    private struct Progress: Decodable {
        let id: String?
        let progress: Event?
    }

    private let requestID: String
    private let method: String
    private let reportsJob: Bool
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()
    private let eventBuffer: BackendDuplexEventBuffer<Event>
    private let progressMetadata: @Sendable (Event) -> BackendOperationProgress?
    private let eventCenter: BackendOperationEventCenter
    private var cancelled = false
    private var terminalAccepted = false
    private var finished = false
    private var lastControlSequence: UInt64 = 0

    private init(requestID: String, method: String, reportsJob: Bool,
                 eventBuffer: BackendDuplexEventBuffer<Event>,
                 progressMetadata: @escaping @Sendable (Event) -> BackendOperationProgress?,
                 eventCenter: BackendOperationEventCenter) {
        self.requestID = requestID
        self.method = method
        self.reportsJob = reportsJob
        self.eventBuffer = eventBuffer
        self.progressMetadata = progressMetadata
        self.eventCenter = eventCenter
    }

    static func start(executableURL: URL, arguments: [String], requestID: String,
                      method: String, reportsJob: Bool, initialFrame: Data,
                      progressMetadata: @escaping @Sendable (Event) -> BackendOperationProgress?)
        throws -> BackendDuplexOperation<Control, Event, Result> {
        let eventBuffer = BackendDuplexEventBuffer<Event>(capacity: 8)
        let eventCenter = BackendOperationEventCenter.shared
        let invocation = BackendDuplexInvocation(requestID: requestID, method: method,
            reportsJob: reportsJob,
            eventBuffer: eventBuffer, progressMetadata: progressMetadata, eventCenter: eventCenter)
        invocation.process.executableURL = executableURL
        invocation.process.arguments = arguments
        invocation.process.standardInput = invocation.stdin
        invocation.process.standardOutput = invocation.stdout
        invocation.process.standardError = invocation.stderr
        try invocation.lock.withLock {
            guard !invocation.cancelled else { throw CancellationError() }
            try invocation.process.run()
        }
        do {
            try invocation.stdin.fileHandleForWriting.write(contentsOf: initialFrame)
        } catch {
            invocation.cancel()
            throw error
        }
        let sourceCancellation: (@Sendable () -> Bool)?
        if reportsJob {
            sourceCancellation = { invocation.requestSourceCancellation() }
        } else {
            sourceCancellation = nil
        }
        let cancellationCapability: BackendOperationCancellationCapability =
            reportsJob ? .sourceControl : .none
        let startedEvent = BackendOperationEvent(invocationID: requestID, method: method,
            phase: .started, isJob: reportsJob, cancellationCapability: cancellationCapability,
            taskName: nil, requestSourceCancellation: sourceCancellation)
        eventCenter.publish(startedEvent)
        let completion = Task.detached(priority: .userInitiated) {
            try await invocation.consume()
        }
        return BackendDuplexOperation(id: requestID, events: BackendDuplexEventStream(buffer: eventBuffer),
                                       invocation: invocation, completion: completion)
    }

    func sendControl(_ control: Control, sequence: UInt64) throws {
        let encoder = JSONEncoder()
        var frame = try encoder.encode(ControlFrame(id: requestID, controlSequence: sequence, control: control))
        frame.append(10)
        try lock.withLock {
            guard !cancelled, !terminalAccepted, !finished, process.isRunning else {
                throw BackendServiceError(code: "duplexClosed", message: "The backend duplex operation is already closed.")
            }
            try stdin.fileHandleForWriting.write(contentsOf: frame)
            lastControlSequence = max(lastControlSequence, sequence)
        }
    }

    /// Uses the retained duplex protocol's actual `{ type: "cancel" }` control
    /// frame. Process termination is only a fallback if the source control
    /// channel is already unavailable.
    func requestSourceCancellation() -> Bool {
        let sent = lock.withLock { () -> Bool in
            guard !cancelled, !terminalAccepted, !finished, process.isRunning else { return false }
            let sequence = lastControlSequence == UInt64.max ? UInt64.max : lastControlSequence + 1
            do {
                var frame = try JSONEncoder().encode(BackendSourceCancelFrame(id: requestID,
                    controlSequence: sequence, control: BackendSourceCancelControl(type: "cancel")))
                frame.append(10)
                try stdin.fileHandleForWriting.write(contentsOf: frame)
                lastControlSequence = sequence
                return true
            } catch {
                cancelled = true
                eventBuffer.finish(throwing: CancellationError())
                if process.isRunning { process.terminate() }
                try? stdin.fileHandleForWriting.close()
                try? stdout.fileHandleForReading.close()
                try? stderr.fileHandleForReading.close()
                return false
            }
        }
        return sent
    }

    func cancel() {
        lock.withLock {
            // Once a terminal envelope has been accepted, the source work is
            // already complete. Keep draining that response instead of
            // turning a late view/task cancellation into a false compute
            // failure while the child performs protocol cleanup.
            guard !finished, !terminalAccepted else { return }
            cancelled = true
            eventBuffer.finish(throwing: CancellationError())
            if process.isRunning { process.terminate() }
            try? stdin.fileHandleForWriting.close()
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
        }
    }

    private func consume() async throws -> Result {
        let stderrCapture = BackendOutputCapture()
        let stderrReader = Task.detached(priority: .utility) {
            stderrCapture.setDiagnostics(self.stderr.fileHandleForReading.readDataToEndOfFile())
        }
        do {
            let descriptor = stdout.fileHandleForReading.fileDescriptor
            var bytes = [UInt8](repeating: 0, count: 65_536)
            var pending = Data()
            var terminal: Data?
            while true {
                let count = try Self.readAvailableBytes(from: descriptor, into: &bytes)
                if count == 0 { break }
                pending.append(contentsOf: bytes.prefix(count))
                while let newline = pending.firstIndex(of: 10) {
                    let frame = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    if terminal != nil, !frame.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 13 }) {
                        throw invalid("The backend returned data after its terminal response.")
                    }
                    if let value = try accept(frame) {
                        guard terminal == nil else { throw invalid("The backend returned data after its terminal response.") }
                        terminal = value
                    }
                }
            }
            if terminal != nil, !pending.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 13 }) {
                throw invalid("The backend returned data after its terminal response.")
            }
            if !pending.isEmpty, let value = try accept(pending) {
                guard terminal == nil else { throw invalid("The backend returned data after its terminal response.") }
                terminal = value
            }
            if terminal == nil { throw invalid("The backend closed the duplex stream without a terminal response.") }
            process.waitUntilExit()
            await stderrReader.value
            let diagnostics = stderrCapture.diagnostics
            try? stdin.fileHandleForWriting.close()
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
            let terminalFrame = try JSONDecoder().decode(Terminal.self, from: terminal!)
            guard terminalFrame.id == requestID else { throw invalid("The backend response has a different request identity.") }
            if let error = terminalFrame.error { throw error }
            guard process.terminationStatus == 0, let result = terminalFrame.result else {
                let text = String(decoding: diagnostics, as: UTF8.self)
                throw BackendServiceError(code: "processFailure", message: text.isEmpty
                    ? "The backend could not finish the duplex operation." : text)
            }
            lock.withLock { finished = true }
            eventBuffer.finish()
            let sourceTerminal = BackendOperationTerminal.decode(from: terminal!)
            eventCenter.publish(BackendOperationEvent(invocationID: requestID, method: method,
                phase: sourceTerminal.phase, isJob: reportsJob, message: sourceTerminal.message,
                sourceState: sourceTerminal.state,
                sourceSucceeded: sourceTerminal.succeeded, sourceCancelled: sourceTerminal.cancelled))
            return result
        } catch {
            lock.withLock { if process.isRunning { process.terminate() } }
            process.waitUntilExit()
            await stderrReader.value
            try? stdin.fileHandleForWriting.close()
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
            lock.withLock { finished = true }
            let wasCancelled = lock.withLock({ cancelled })
            if wasCancelled { eventBuffer.finish(throwing: CancellationError()) }
            else { eventBuffer.finish(throwing: error) }
            let cancellationError = error is CancellationError || wasCancelled
            let errorMessage = cancellationError ? nil : error.localizedDescription
            eventCenter.publish(BackendOperationEvent(invocationID: requestID, method: method,
                phase: cancellationError ? .cancelled : .failed, isJob: reportsJob,
                errorMessage: errorMessage))
            throw wasCancelled ? CancellationError() : error
        }
    }

    private func accept(_ frame: Data) throws -> Data? {
        guard !frame.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 13 }) else { return nil }
        guard let object = try JSONSerialization.jsonObject(with: frame) as? [String: Any],
              object["id"] as? String == requestID else {
            throw invalid("The backend returned an invalid duplex frame.")
        }
        if object.keys.contains("progress") {
            guard !object.keys.contains("result"), !object.keys.contains("error") else {
                throw invalid("The backend returned an ambiguous duplex frame.")
            }
            let decoded = try JSONDecoder().decode(Progress.self, from: frame)
            guard let event = decoded.progress else { throw invalid("The backend returned an empty progress frame.") }
            try eventBuffer.append(event)
            if let metadata = progressMetadata(event) {
                eventCenter.publish(BackendOperationEvent(invocationID: requestID, method: method,
                    phase: .progress, isJob: reportsJob, cancellationCapability: .sourceControl,
                    progress: metadata.fraction, message: metadata.message,
                    taskName: metadata.taskName))
            }
            return nil
        }
        guard object.keys.contains("result") || object.keys.contains("error") else {
            throw invalid("The backend returned an unknown duplex frame.")
        }
        lock.withLock {
            terminalAccepted = true
            try? stdin.fileHandleForWriting.close()
        }
        return frame
    }

    private func invalid(_ message: String) -> BackendServiceError {
        BackendServiceError(code: "protocolFailure", message: message)
    }

    private static func readAvailableBytes(from descriptor: Int32, into buffer: inout [UInt8]) throws -> Int {
        while true {
            let count = buffer.withUnsafeMutableBufferPointer { bytes in
                Darwin.read(descriptor, bytes.baseAddress!, bytes.count)
            }
            if count >= 0 { return count }
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}


private final class BackendInvocation: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    init(executableURL: URL, arguments: [String]) {
        process.executableURL = executableURL; process.arguments = arguments
    }
    func cancel() {
        lock.withLock {
            cancelled = true
            if process.isRunning { process.terminate() }
        }
    }
    struct Output: Sendable { let data: Data; let diagnostics: String; let status: Int32 }
    func run(_ input: Data, requestID: String,
             progress: (@Sendable (BackendProgressUpdate) -> Void)?) throws -> Output {
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        try lock.withLock {
            if cancelled { throw CancellationError() }
            try process.run()
        }
        let capture = BackendOutputCapture(), readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { readers.leave() }
            guard let progress else {
                capture.setData(stdout.fileHandleForReading.readDataToEndOfFile())
                return
            }
            do {
                let frames = BackendProgressFrames(requestID: requestID) { update in
                    if !self.lock.withLock({ self.cancelled }) { progress(update) }
                }
                let descriptor = stdout.fileHandleForReading.fileDescriptor
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while true {
                    let count = try Self.readAvailableBytes(from: descriptor, into: &buffer)
                    guard count > 0 else { break }
                    try frames.append(Data(buffer.prefix(count)))
                }
                capture.setData(try frames.finish())
            } catch {
                capture.setFailure(error)
                self.lock.withLock { if self.process.isRunning { self.process.terminate() } }
            }
        }
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            capture.setDiagnostics(stderr.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        var writeError: (any Error)?
        do { try stdin.fileHandleForWriting.write(contentsOf: input) }
        catch { writeError = error; lock.withLock { if process.isRunning { process.terminate() } } }
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit(); readers.wait()
        try? stdout.fileHandleForReading.close(); try? stderr.fileHandleForReading.close()
        if lock.withLock({ cancelled }) { throw CancellationError() }
        if let writeError { throw writeError }
        if let error = capture.failure { throw error }
        return Output(data: capture.data, diagnostics: String(decoding: capture.diagnostics, as: UTF8.self), status: process.terminationStatus)
    }

    /// A blocking pipe read returns as soon as bytes are available. Using a
    /// fixed-size FileHandle read here can defer short progress frames until
    /// the child exits, defeating streaming when the child waits for feedback.
    private static func readAvailableBytes(from descriptor: Int32, into buffer: inout [UInt8]) throws -> Int {
        while true {
            let count = buffer.withUnsafeMutableBufferPointer { bytes in
                Darwin.read(descriptor, bytes.baseAddress!, bytes.count)
            }
            if count >= 0 { return count }
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

private final class BackendOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data(), errors = Data()
    private var readFailure: (any Error)?
    var data: Data { lock.withLock { output } }
    var diagnostics: Data { lock.withLock { errors } }
    var failure: (any Error)? { lock.withLock { readFailure } }
    func setData(_ data: Data) { lock.withLock { output = data } }
    func setDiagnostics(_ data: Data) { lock.withLock { errors = data } }
    func setFailure(_ error: any Error) { lock.withLock { readFailure = error } }
}

/// Runs only on the stdout reader. Buffer bytes until a whole UTF-8 JSON frame
/// is available, rather than decoding each arbitrary pipe chunk as text.
private final class BackendProgressFrames {
    private let requestID: String
    private let report: @Sendable (BackendProgressUpdate) -> Void
    private var pending = Data()
    private var terminal: Data?

    init(requestID: String, report: @escaping @Sendable (BackendProgressUpdate) -> Void) {
        self.requestID = requestID; self.report = report
    }

    func append(_ data: Data) throws {
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            let frame = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            try accept(frame)
        }
    }

    func finish() throws -> Data {
        if !pending.isEmpty { try accept(pending); pending.removeAll() }
        guard let terminal else { throw invalid("The backend did not return a terminal response.") }
        return terminal
    }

    private func accept(_ data: Data) throws {
        if data.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 13 }) { return }
        guard terminal == nil else { throw invalid("The backend returned data after its terminal response.") }
        let frame: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw invalid("The backend returned an invalid progress response.")
            }
            frame = object
        } catch { throw invalid("The backend returned an invalid progress response.") }
        guard frame["id"] as? String == requestID else {
            throw invalid("The backend response has a different request identity.")
        }
        let isProgress = frame.keys.contains("progress")
        let hasResult = frame.keys.contains("result")
        let hasError = frame.keys.contains("error")
        guard [isProgress, hasResult, hasError].filter({ $0 }).count == 1 else {
            throw invalid("The backend returned an ambiguous response.")
        }
        if isProgress {
            struct Frame: Decodable { let progress: BackendProgressUpdate }
            let update: BackendProgressUpdate
            do { update = try JSONDecoder().decode(Frame.self, from: data).progress }
            catch { throw invalid("The backend returned invalid progress values.") }
            if let fraction = update.fraction, !fraction.isFinite || !(0...1).contains(fraction) {
                throw invalid("The backend returned a progress fraction outside zero to one.")
            }
            report(update)
        } else {
            terminal = data
        }
    }

    private func invalid(_ message: String) -> BackendServiceError {
        BackendServiceError(code: "protocolFailure", message: message)
    }
}
