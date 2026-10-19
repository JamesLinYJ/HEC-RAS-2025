import Combine
import Foundation
import RASWorkspaceCore

@MainActor
final class BoundaryInitialConditionsSession: ObservableObject {
    @Published private(set) var capture: BoundaryInitialConditionsCapture?
    @Published private(set) var inspection: BoundaryInitialConditionsInspection?
    @Published private(set) var receipt: BoundaryInitialConditionsReceipt?
    @Published private(set) var operationStatus: BoundaryInitialConditionsOperationStatus?
    @Published private(set) var selectedResultURL: URL?
    @Published var timestampText = ""
    @Published var numberCulture = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
    @Published private(set) var isInspecting = false
    @Published private(set) var isAttaching = false
    @Published private(set) var isCheckingStatus = false
    @Published private(set) var errorMessage: String?

    private let provider: any BoundaryInitialConditionsProvider
    private var inspectionOwnerID: String?
    private var inspectionGeneration = 0
    private var inspectionFlight: Task<BoundaryInitialConditionsInspection, Error>?
    private var inspectedTimestamp: String?
    private var inspectedNumberCulture: String?
    private var frozenRequest: BoundaryInitialConditionsAttachRequest?
    private var frozenCapture: BoundaryInitialConditionsCapture?
    private var leaseHeld = false
    private var isCurrentCapture: (@MainActor (BoundaryInitialConditionsCapture) -> Bool)?
    private var beginCommit: (@MainActor (BoundaryInitialConditionsCapture, BoundaryInitialConditionsAttachRequest) -> Bool)?
    private var endCommit: (@MainActor (String) -> Void)?
    private var commit: (@MainActor (BoundaryInitialConditionsCapture, BoundaryInitialConditionsReceipt) async throws -> Bool)?

    init(provider: any BoundaryInitialConditionsProvider) {
        self.provider = provider
    }

    var pendingOperationID: String? { frozenRequest?.operationID }
    var needsStatusRecovery: Bool {
        guard frozenRequest != nil else { return false }
        return operationStatus == nil || operationStatus?.state == .prepared
    }
    var canInspect: Bool {
        guard let capture else { return false }
        return frozenRequest == nil && !isInspecting && !isAttaching && !isCheckingStatus
            && isCurrentCapture?(capture) == true
    }
    var canAttach: Bool {
        guard let capture, let inspection, frozenRequest == nil,
              inspectionOwnerID == capture.id, inspection.canAttach,
              inspection.resultRevision != nil, !isInspecting, !isAttaching, !isCheckingStatus,
              timestampText == (inspectedTimestamp ?? "") else { return false }
        if let inspectedNumberCulture,
           numberCulture.replacingOccurrences(of: "_", with: "-") != inspectedNumberCulture { return false }
        return isCurrentCapture?(capture) == true
    }
    var canRetry: Bool {
        frozenRequest != nil && !isAttaching && !isCheckingStatus
    }
    var canCancelUnstartedOperation: Bool {
        frozenRequest != nil && operationStatus?.state == .notFound && !isAttaching && !isCheckingStatus
    }

    func configure(capture newCapture: BoundaryInitialConditionsCapture,
                   isCurrent: @escaping @MainActor (BoundaryInitialConditionsCapture) -> Bool,
                   beginCommit: @escaping @MainActor (BoundaryInitialConditionsCapture, BoundaryInitialConditionsAttachRequest) -> Bool,
                   endCommit: @escaping @MainActor (String) -> Void,
                   commit: @escaping @MainActor (BoundaryInitialConditionsCapture, BoundaryInitialConditionsReceipt) async throws -> Bool) {
        let changedOwner = capture?.id != newCapture.id
        isCurrentCapture = isCurrent
        self.beginCommit = beginCommit
        self.endCommit = endCommit
        self.commit = commit
        if changedOwner {
            cancelInspection(clearResult: true)
            capture = newCapture
            if frozenRequest == nil {
                receipt = nil
                operationStatus = nil
                errorMessage = nil
            }
        } else {
            capture = newCapture
        }
    }

    @discardableResult
    func inspect(resultURL: URL, timestamp: String?, numberCulture: String?) async -> Bool {
        guard canInspect, let capture, resultURL.isFileURL else { return false }
        let resultPath = resultURL.standardizedFileURL.path
        guard !resultPath.isEmpty, isCurrentCapture?(capture) == true else { return false }
        cancelInspection(clearResult: true)
        inspectionGeneration += 1
        let generation = inspectionGeneration
        let culture = numberCulture?.replacingOccurrences(of: "_", with: "-")
        let request = BoundaryInitialConditionsInspectionRequest(model: capture.model,
            projectRevision: capture.projectRevision, resultPath: resultPath,
            timestamp: timestamp, numberCulture: culture)
        inspectedTimestamp = timestamp
        inspectedNumberCulture = culture
        timestampText = timestamp ?? ""
        if let culture { self.numberCulture = culture }
        isInspecting = true
        selectedResultURL = resultURL
        errorMessage = nil
        let provider = self.provider
        let flight = Task { @MainActor in try await provider.inspect(request) }
        inspectionFlight = flight
        defer {
            if generation == inspectionGeneration {
                isInspecting = false
                inspectionFlight = nil
            }
        }
        do {
            let response = try await flight.value
            guard generation == inspectionGeneration, self.capture?.id == capture.id,
                  isCurrentCapture?(capture) == true,
                  Self.matches(response, request: request, capture: capture) else { return false }
            inspection = response
            inspectionOwnerID = capture.id
            if !response.canAttach { errorMessage = response.errorMessage }
            return response.canAttach
        } catch {
            guard generation == inspectionGeneration else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func attach() async -> Bool {
        guard canAttach, let capture, let inspection, let resultRevision = inspection.resultRevision,
              let beginCommit, isCurrentCapture?(capture) == true else { return false }
        let request = BoundaryInitialConditionsAttachRequest(model: capture.model,
            projectRevision: capture.projectRevision, projectXmlFingerprint: capture.projectXmlFingerprint,
            resultPath: inspection.resultPath, resultRevision: resultRevision,
            operationID: UUID().uuidString.lowercased(),
            timestamp: inspectedTimestamp,
            numberCulture: inspectedNumberCulture)
        guard beginCommit(capture, request) else {
            errorMessage = L10n.text("The project or boundary condition changed before the attach could start.")
            return false
        }
        frozenCapture = capture
        frozenRequest = request
        leaseHeld = true
        receipt = nil
        operationStatus = nil
        errorMessage = nil
        return await sendFrozenAttach()
    }

    @discardableResult
    func refreshStatus() async -> Bool {
        guard let request = frozenRequest, let owner = frozenCapture, !isCheckingStatus,
              !isAttaching else { return false }
        guard await acquireLeaseIfNeeded(owner: owner, request: request) else { return false }
        isCheckingStatus = true
        defer { isCheckingStatus = false }
        do {
            let status = try await provider.status(request)
            guard frozenRequest?.operationID == request.operationID,
                  frozenCapture?.id == owner.id else { return false }
            operationStatus = status
            errorMessage = status.errorMessage
            if status.state == .committed, let receipt = status.receipt {
                return await acceptCommitted(receipt, request: request, capture: owner)
            }
            if status.state == .rolledBack || status.state == .conflict {
                finishTerminalOperation(request.operationID)
                frozenRequest = nil
                frozenCapture = nil
                inspection = nil
                inspectionOwnerID = nil
                return false
            }
            return status.state == .prepared || status.state == .notFound
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Retry always consults the operation journal first. A committed receipt
    /// is adopted without resending the mutation; prepared/notFound reuses the
    /// exact frozen request and operation ID.
    @discardableResult
    func retry() async -> Bool {
        guard let request = frozenRequest, let owner = frozenCapture,
              !isAttaching, !isCheckingStatus else { return false }
        guard await acquireLeaseIfNeeded(owner: owner, request: request) else { return false }
        isCheckingStatus = true
        errorMessage = nil
        do {
            let status = try await provider.status(request)
            guard frozenRequest?.operationID == request.operationID,
                  frozenCapture?.id == owner.id else { isCheckingStatus = false; return false }
            operationStatus = status
            if status.state == .committed, let receipt = status.receipt {
                isCheckingStatus = false
                return await acceptCommitted(receipt, request: request, capture: owner)
            }
            if status.state == .rolledBack || status.state == .conflict {
                errorMessage = status.errorMessage
                isCheckingStatus = false
                finishTerminalOperation(request.operationID)
                frozenRequest = nil
                frozenCapture = nil
                inspection = nil
                inspectionOwnerID = nil
                return false
            }
            isCheckingStatus = false
            return await sendFrozenAttach()
        } catch {
            isCheckingStatus = false
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Closing the sheet cancels only stale, read-only inspection. An attach
    /// request and operation journal identity survive view teardown so the
    /// Store can recover a lost response rather than issuing a second commit.
    func close() {
        cancelInspection(clearResult: true)
    }

    func invalidate() {
        close()
        if frozenRequest == nil {
            capture = nil
            selectedResultURL = nil
            errorMessage = nil
        }
    }

    /// A status-confirmed missing journal means publication never started. It
    /// is safe to unlock the owning editor without silently retrying a write.
    @discardableResult
    func cancelUnstartedOperation() -> Bool {
        guard canCancelUnstartedOperation, let request = frozenRequest else { return false }
        finishTerminalOperation(request.operationID)
        frozenRequest = nil
        frozenCapture = nil
        receipt = nil
        inspection = nil
        inspectionOwnerID = nil
        selectedResultURL = nil
        operationStatus = .init(state: .notFound, receipt: nil, errorMessage: nil)
        errorMessage = L10n.text("No attachment was saved.")
        return true
    }

    private func sendFrozenAttach() async -> Bool {
        guard let request = frozenRequest, let owner = frozenCapture, !isAttaching else { return false }
        isAttaching = true
        defer { isAttaching = false }
        let provider = self.provider
        let flight = Task { @MainActor in try await provider.attach(request) }
        do {
            let response = try await flight.value
            guard frozenRequest?.operationID == request.operationID,
                  frozenCapture?.id == owner.id,
                  Self.matches(response, request: request, capture: owner) else {
                errorMessage = L10n.text("The attach response did not match its frozen source request.")
                return false
            }
            operationStatus = .init(state: .committed, receipt: response, errorMessage: nil)
            return await acceptCommitted(response, request: request, capture: owner)
        } catch {
            // Do not release the Store lease here. The source may have committed
            // and the pipe may have lost only the receipt; status recovery is
            // required before any competing project/model mutation may proceed.
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func acceptCommitted(_ response: BoundaryInitialConditionsReceipt,
                                 request: BoundaryInitialConditionsAttachRequest,
                                 capture: BoundaryInitialConditionsCapture) async -> Bool {
        receipt = response
        operationStatus = .init(state: .committed, receipt: response, errorMessage: nil)
        guard let commit else {
            errorMessage = L10n.text("The committed initial-conditions receipt could not be adopted by the project.")
            finishTerminalOperation(request.operationID)
            return false
        }
        do {
            let accepted = try await commit(capture, response)
            guard frozenRequest?.operationID == request.operationID else { return false }
            if accepted {
                frozenRequest = nil
                frozenCapture = nil
                inspection = nil
                inspectionOwnerID = nil
                selectedResultURL = nil
                inspectedTimestamp = nil
                inspectedNumberCulture = nil
                errorMessage = nil
                finishTerminalOperation(request.operationID)
                return true
            }
            errorMessage = L10n.text("The source committed the attachment, but the project session could not adopt the receipt.")
            finishTerminalOperation(request.operationID)
            return false
        } catch {
            errorMessage = error.localizedDescription
            finishTerminalOperation(request.operationID)
            return false
        }
    }

    private func acquireLeaseIfNeeded(owner: BoundaryInitialConditionsCapture,
                                      request: BoundaryInitialConditionsAttachRequest) async -> Bool {
        if leaseHeld { return true }
        guard let beginCommit, beginCommit(owner, request) else {
            errorMessage = L10n.text("The original project context is not ready to recover this attach operation.")
            return false
        }
        leaseHeld = true
        return true
    }

    private func finishTerminalOperation(_ operationID: String) {
        guard leaseHeld else { return }
        leaseHeld = false
        endCommit?(operationID)
    }

    private func cancelInspection(clearResult: Bool) {
        inspectionGeneration += 1
        inspectionFlight?.cancel()
        inspectionFlight = nil
        isInspecting = false
        if clearResult {
            inspection = nil
            inspectionOwnerID = nil
            selectedResultURL = nil
            inspectedTimestamp = nil
            inspectedNumberCulture = nil
        }
    }

    private static func matches(_ response: BoundaryInitialConditionsInspection,
                                request: BoundaryInitialConditionsInspectionRequest,
                                capture: BoundaryInitialConditionsCapture) -> Bool {
        samePath(response.assetPath, capture.model.assetPath) && response.assetRevision == capture.model.revision &&
            samePath(response.projectPath, capture.projectPath) && response.projectRevision == capture.projectRevision &&
            response.projectXmlFingerprint == capture.projectXmlFingerprint &&
            samePath(response.resultPath, request.resultPath) &&
            response.timestamp == (request.timestamp ?? "") && response.numberCulture == request.numberCulture
    }

    private static func matches(_ response: BoundaryInitialConditionsReceipt,
                                request: BoundaryInitialConditionsAttachRequest,
                                capture: BoundaryInitialConditionsCapture) -> Bool {
        response.operationID == request.operationID &&
            request.projectXmlFingerprint == capture.projectXmlFingerprint &&
            samePath(response.assetPath, capture.model.assetPath) && samePath(response.projectPath, capture.projectPath) &&
            samePath(response.resultPath, request.resultPath) && response.resultRevision == request.resultRevision &&
            (response.timestamp ?? "") == (request.timestamp ?? "") && response.model.revision != capture.model.revision
    }

    private static func samePath(_ left: String, _ right: String) -> Bool {
        SourceFilePaths.canonical(URL(fileURLWithPath: left)) == SourceFilePaths.canonical(URL(fileURLWithPath: right))
    }
}
