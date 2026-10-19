import Foundation
import RASWorkspaceCore
import SwiftUI

struct StableChannelDebugSource: Codable, Equatable, Sendable {
    var sourceID: String
    var projectPath: String?
    var projectRevision: String?
    var designPath: String?
    var designRevision: String?
    var inMemory: Bool
}

struct StableChannelDebugPartState: Codable, Equatable, Sendable {
    var d: Double?
    var angleOfRepose: Double?
    var roughness: Double?
    var specificGravity: Double?
    var shieldsParameter: Double?
    var equation: String
}

struct StableChannelDebugState: Codable, Equatable, Sendable {
    var depth: Double?
    var discharge: Double?
    var slope: Double?
    var leftBankSideSlope: Double?
    var rightBankSideSlope: Double?
    var temperature: Double?
    var width: Double?
    var solutionMethod: String
    var leftBank: StableChannelDebugPartState?
    var bed: StableChannelDebugPartState?
    var rightBank: StableChannelDebugPartState?
}

struct StableChannelDebugOpenRequest: Codable, Sendable {
    var requestID: String
    var projectPath: String?
    var inMemorySourceID: String?
    var inMemoryState: StableChannelDebugState?
    var coreLayerContext: CoreLayerRequestContext? = nil
}

struct StableChannelDebugOpenResponse: Codable, Sendable {
    var requestID: String
    var source: StableChannelDebugSource
    var state: StableChannelDebugState
}

struct StableChannelDebugComputeRequest: Codable, Sendable {
    var requestID: String
    var source: StableChannelDebugSource
    var state: StableChannelDebugState
    var solveFor: [String]
    var coreLayerContext: CoreLayerRequestContext? = nil
}

struct StableChannelDebugComputeResponse: Codable, Sendable {
    var requestID: String
    var sourceID: String
    var state: StableChannelDebugState
    var solveFor: [String]
    var computed: Bool
    var errorCode: String?
}

struct StableChannelDebugSaveRequest: Codable, Sendable {
    var requestID: String
    var source: StableChannelDebugSource
    var state: StableChannelDebugState
    var coreLayerContext: CoreLayerRequestContext? = nil
}

struct StableChannelDebugSaveResponse: Codable, Sendable {
    var requestID: String
    var sourceID: String
    var designPath: String
    var designRevision: String
    var state: StableChannelDebugState
}

@MainActor
protocol StableChannelDebugProviding {
    func open(_ request: StableChannelDebugOpenRequest) async throws -> StableChannelDebugOpenResponse
    func compute(_ request: StableChannelDebugComputeRequest) async throws -> StableChannelDebugComputeResponse
    func save(_ request: StableChannelDebugSaveRequest) async throws -> StableChannelDebugSaveResponse
}

@MainActor
final class BackendStableChannelDebugProvider: StableChannelDebugProviding {
    private let client: BackendProcessClient

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func open(_ request: StableChannelDebugOpenRequest) async throws -> StableChannelDebugOpenResponse {
        try await client.request("stableChannel.open", parameters: request,
                                 as: StableChannelDebugOpenResponse.self)
    }

    func compute(_ request: StableChannelDebugComputeRequest) async throws -> StableChannelDebugComputeResponse {
        try await client.request("stableChannel.compute", parameters: request,
                                 as: StableChannelDebugComputeResponse.self)
    }

    func save(_ request: StableChannelDebugSaveRequest) async throws -> StableChannelDebugSaveResponse {
        try await client.request("stableChannel.save", parameters: request,
                                 as: StableChannelDebugSaveResponse.self)
    }
}

enum StableChannelDebugPart: String, CaseIterable, Sendable {
    case leftBank
    case bed
    case rightBank

    var titleKey: String {
        switch self {
        case .leftBank: "Left Bank"
        case .bed: "Bed"
        case .rightBank: "Right Bank"
        }
    }
}

enum StableChannelDebugField: String, CaseIterable, Sendable {
    case depth
    case discharge
    case slope
    case leftBankSideSlope
    case rightBankSideSlope
    case temperature
    case width
    case leftBankD
    case leftBankAngleOfRepose
    case leftBankRoughness
    case leftBankSpecificGravity
    case leftBankShieldsParameter
    case bedD
    case bedAngleOfRepose
    case bedRoughness
    case bedSpecificGravity
    case bedShieldsParameter
    case rightBankD
    case rightBankAngleOfRepose
    case rightBankRoughness
    case rightBankSpecificGravity
    case rightBankShieldsParameter

    var titleKey: String {
        switch self {
        case .depth: "Depth"
        case .discharge: "Discharge"
        case .slope: "Slope"
        case .leftBankSideSlope: "Left Bank Side Slope"
        case .rightBankSideSlope: "Right Bank Side Slope"
        case .temperature: "Temperature"
        case .width: "Width"
        case .leftBankD, .bedD, .rightBankD: "Particle Size"
        case .leftBankAngleOfRepose, .bedAngleOfRepose, .rightBankAngleOfRepose: "Angle of Repose"
        case .leftBankRoughness, .bedRoughness, .rightBankRoughness: "Roughness"
        case .leftBankSpecificGravity, .bedSpecificGravity, .rightBankSpecificGravity: "Specific Gravity"
        case .leftBankShieldsParameter, .bedShieldsParameter, .rightBankShieldsParameter: "Shield's Parameter"
        }
    }

    var part: StableChannelDebugPart? {
        switch self {
        case .leftBankD, .leftBankAngleOfRepose, .leftBankRoughness,
             .leftBankSpecificGravity, .leftBankShieldsParameter: .leftBank
        case .bedD, .bedAngleOfRepose, .bedRoughness, .bedSpecificGravity, .bedShieldsParameter: .bed
        case .rightBankD, .rightBankAngleOfRepose, .rightBankRoughness,
             .rightBankSpecificGravity, .rightBankShieldsParameter: .rightBank
        default: nil
        }
    }

    static let mainInputs: [Self] = [.depth, .discharge, .slope, .leftBankSideSlope,
        .rightBankSideSlope, .temperature, .width]

    static func numericInputs(for part: StableChannelDebugPart) -> [Self] {
        switch part {
        case .leftBank: [.leftBankD, .leftBankAngleOfRepose, .leftBankRoughness,
                         .leftBankSpecificGravity, .leftBankShieldsParameter]
        case .bed: [.bedD, .bedAngleOfRepose, .bedRoughness, .bedSpecificGravity, .bedShieldsParameter]
        case .rightBank: [.rightBankD, .rightBankAngleOfRepose, .rightBankRoughness,
                          .rightBankSpecificGravity, .rightBankShieldsParameter]
        }
    }
}

extension StableChannelDebugState {
    func value(for field: StableChannelDebugField) -> Double? {
        switch field {
        case .depth: return depth
        case .discharge: return discharge
        case .slope: return slope
        case .leftBankSideSlope: return leftBankSideSlope
        case .rightBankSideSlope: return rightBankSideSlope
        case .temperature: return temperature
        case .width: return width
        default:
            guard let part = field.part.flatMap({ partState(for: $0) }) else { return nil }
            switch field {
            case .leftBankD, .bedD, .rightBankD: return part.d
            case .leftBankAngleOfRepose, .bedAngleOfRepose, .rightBankAngleOfRepose: return part.angleOfRepose
            case .leftBankRoughness, .bedRoughness, .rightBankRoughness: return part.roughness
            case .leftBankSpecificGravity, .bedSpecificGravity, .rightBankSpecificGravity: return part.specificGravity
            case .leftBankShieldsParameter, .bedShieldsParameter, .rightBankShieldsParameter: return part.shieldsParameter
            default: return nil
            }
        }
    }

    func partState(for part: StableChannelDebugPart) -> StableChannelDebugPartState? {
        switch part {
        case .leftBank: leftBank
        case .bed: bed
        case .rightBank: rightBank
        }
    }

    mutating func setValue(_ value: Double?, for field: StableChannelDebugField) {
        switch field {
        case .depth: depth = value
        case .discharge: discharge = value
        case .slope: slope = value
        case .leftBankSideSlope: leftBankSideSlope = value
        case .rightBankSideSlope: rightBankSideSlope = value
        case .temperature: temperature = value
        case .width: width = value
        default:
            guard let partID = field.part else { return }
            var part = partState(for: partID) ?? StableChannelDebugPartState(
                d: nil, angleOfRepose: nil, roughness: nil, specificGravity: nil,
                shieldsParameter: nil, equation: "Strickler")
            switch field {
            case .leftBankD, .bedD, .rightBankD: part.d = value
            case .leftBankAngleOfRepose, .bedAngleOfRepose, .rightBankAngleOfRepose: part.angleOfRepose = value
            case .leftBankRoughness, .bedRoughness, .rightBankRoughness: part.roughness = value
            case .leftBankSpecificGravity, .bedSpecificGravity, .rightBankSpecificGravity: part.specificGravity = value
            case .leftBankShieldsParameter, .bedShieldsParameter, .rightBankShieldsParameter: part.shieldsParameter = value
            default: break
            }
            setPartState(part, for: partID)
        }
    }

    mutating func setEquation(_ equation: String, for partID: StableChannelDebugPart) {
        var part = partState(for: partID) ?? StableChannelDebugPartState(
            d: nil, angleOfRepose: nil, roughness: nil, specificGravity: nil,
            shieldsParameter: nil, equation: "Strickler")
        part.equation = equation
        setPartState(part, for: partID)
    }

    private mutating func setPartState(_ part: StableChannelDebugPartState, for partID: StableChannelDebugPart) {
        switch partID {
        case .leftBank: leftBank = part
        case .bed: bed = part
        case .rightBank: rightBank = part
        }
    }
}

@MainActor
final class StableChannelDebugSession: ObservableObject {
    @Published private(set) var source: StableChannelDebugSource?
    @Published private(set) var state: StableChannelDebugState?
    @Published private(set) var inputText: [StableChannelDebugField: String] = [:]
    @Published private(set) var invalidFields: Set<StableChannelDebugField> = []
    @Published private(set) var selectedSolveFor: Set<String> = []
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    @Published private(set) var messageIsError = false

    private let provider: StableChannelDebugProviding
    private var baselineState: StableChannelDebugState?
    private var projectSessionID: UUID?
    private var coreLayerContext: CoreLayerRequestContext?
    private var generation = 0
    private var busyTaskID: UUID?
    private var lastNotifiedDirty = false

    var onParentDraftChange: (@MainActor (Bool) -> Void)?

    init(provider: StableChannelDebugProviding = BackendStableChannelDebugProvider()) {
        self.provider = provider
    }

    var hasOpened: Bool { state != nil && source != nil }
    var hasUnsavedChanges: Bool { source?.inMemory == false && isDirty }
    var isDirty: Bool { state != baselineState || !invalidFields.isEmpty }
    var canSave: Bool { hasOpened && source?.inMemory == false && isDirty && invalidFields.isEmpty && !isBusy }
    var canCompute: Bool { hasOpened && !isBusy && selectedSolveFor.count == 2 && invalidFields.isEmpty }
    var projectOwner: UUID? { projectSessionID }

    /// Accepts only the exact project-save receipt from the owning workspace.
    /// Stable Channel drafts remain bound to the backend's source revision; a
    /// parent project save may legitimately advance that revision while leaving
    /// the captured design file and this local draft untouched.
    @discardableResult
    func acceptProjectSave(projectPath: String, projectSessionID: UUID, projectRevision: String,
                           coreLayerContext: CoreLayerRequestContext? = nil) -> Bool {
        guard !isBusy, self.projectSessionID == projectSessionID,
              let currentSource = source, let currentProjectPath = currentSource.projectPath,
              Self.samePath(currentProjectPath, projectPath), Self.isSHA256(projectRevision) else { return false }
        if let coreLayerContext,
           (coreLayerContext.projectSessionID != projectSessionID.uuidString ||
            CoreLayerRequestContext.canonical(URL(fileURLWithPath: coreLayerContext.projectPath)) !=
                CoreLayerRequestContext.canonical(URL(fileURLWithPath: projectPath)) ||
            coreLayerContext.projectRevision?.caseInsensitiveCompare(projectRevision) != .orderedSame) {
            return false
        }
        var updatedSource = currentSource
        updatedSource.projectRevision = projectRevision
        source = updatedSource
        self.coreLayerContext = coreLayerContext
        return true
    }

    func textBinding(for field: StableChannelDebugField) -> Binding<String> {
        Binding(get: { self.inputText[field] ?? "" }, set: { self.updateInput($0, for: field) })
    }

    func load(projectPath: String?, projectSessionID: UUID,
              coreLayerContext: CoreLayerRequestContext? = nil) async {
        if self.projectSessionID == projectSessionID, hasOpened { return }
        guard !isBusy else {
            showError("Wait for the Stable Channel operation to finish before changing the project.")
            return
        }
        guard !isDirty else {
            showError("Save or discard the Stable Channel changes before changing the project.")
            return
        }
        self.projectSessionID = projectSessionID
        self.coreLayerContext = coreLayerContext
        generation &+= 1
        let loadGeneration = generation
        source = nil
        state = nil
        baselineState = nil
        inputText = [:]
        invalidFields = []
        selectedSolveFor = []
        let requestID = UUID().uuidString
        let taskID = beginBusy()
        message = nil
        messageIsError = false
        do {
            let response = try await provider.open(StableChannelDebugOpenRequest(
                requestID: requestID, projectPath: projectPath,
                inMemorySourceID: nil, inMemoryState: nil,
                coreLayerContext: coreLayerContext))
            guard generation == loadGeneration, self.projectSessionID == projectSessionID,
                  response.requestID == requestID,
                  Self.isValidOpenedSource(response.source, requestedProjectPath: projectPath) else {
                throw Self.protocolFailure
            }
            source = response.source
            state = response.state
            baselineState = response.state
            synchronizeText(from: response.state)
            selectedSolveFor = []
            invalidFields = []
            message = nil
            messageIsError = false
            endBusy(taskID)
            notifyParentIfNeeded()
        } catch {
            guard generation == loadGeneration, self.projectSessionID == projectSessionID else { return }
            endBusy(taskID)
            showError(error.localizedDescription)
        }
    }

    func updateInput(_ text: String, for field: StableChannelDebugField) {
        guard !isBusy, var state else { return }
        inputText[field] = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            invalidFields.remove(field)
            state.setValue(nil, for: field)
        } else if let value = UnitCalculatorNumberFormat.number(from: trimmed) {
            invalidFields.remove(field)
            state.setValue(value, for: field)
        } else {
            invalidFields.insert(field)
            state.setValue(nil, for: field)
        }
        self.state = state
        generation &+= 1
        message = nil
        notifyParentIfNeeded()
    }

    func setEquation(_ equation: String, for part: StableChannelDebugPart) {
        guard !isBusy, var state else { return }
        state.setEquation(equation, for: part)
        self.state = state
        generation &+= 1
        message = nil
        notifyParentIfNeeded()
    }

    func setSolutionMethod(_ method: String) {
        guard !isBusy, var state else { return }
        state.solutionMethod = method
        self.state = state
        generation &+= 1
        message = nil
        notifyParentIfNeeded()
    }

    func toggleSolveFor(_ target: String) {
        guard !isBusy else { return }
        if selectedSolveFor.contains(target) {
            selectedSolveFor.remove(target)
        } else {
            selectedSolveFor.insert(target)
        }
        message = nil
    }

    func compute() async {
        guard canCompute, let source, let state else {
            if selectedSolveFor.count != 2 { showError("Select exactly two variables to solve for.") }
            return
        }
        let capturedGeneration = generation
        let capturedOwner = projectSessionID
        let requestID = UUID().uuidString
        let targets = ["Depth", "Width", "Slope", "ParticleSize"].filter(selectedSolveFor.contains)
        let taskID = beginBusy()
        message = nil
        do {
            let response = try await provider.compute(StableChannelDebugComputeRequest(
                requestID: requestID, source: source, state: state, solveFor: targets,
                coreLayerContext: coreLayerContext))
            guard generation == capturedGeneration, projectSessionID == capturedOwner,
                  self.source == source,
                  response.requestID == requestID, response.sourceID == source.sourceID,
                  response.solveFor == targets else {
                throw Self.protocolFailure
            }
            endBusy(taskID)
            if response.computed {
                self.state = response.state
                synchronizeText(from: response.state)
                message = L10n.text("Stable Channel calculation completed.")
                messageIsError = false
                notifyParentIfNeeded()
            } else {
                showError(Self.localizedComputeError(response.errorCode))
            }
        } catch {
            guard generation == capturedGeneration, projectSessionID == capturedOwner else { return }
            endBusy(taskID)
            showError(error.localizedDescription)
        }
    }

    @discardableResult
    func save() async -> Bool {
        guard canSave, let source, let state else { return false }
        let capturedGeneration = generation
        let capturedOwner = projectSessionID
        let requestID = UUID().uuidString
        let taskID = beginBusy()
        message = nil
        do {
            let response = try await provider.save(StableChannelDebugSaveRequest(
                requestID: requestID, source: source, state: state,
                coreLayerContext: coreLayerContext))
            guard generation == capturedGeneration, projectSessionID == capturedOwner,
                  self.source == source,
                  response.requestID == requestID, response.sourceID == source.sourceID,
                  Self.samePath(response.designPath, source.designPath),
                  Self.isSHA256(response.designRevision) else {
                throw Self.protocolFailure
            }
            var updatedSource = source
            updatedSource.designRevision = response.designRevision
            self.source = updatedSource
            self.state = response.state
            baselineState = response.state
            synchronizeText(from: response.state)
            endBusy(taskID)
            message = L10n.text("Stable Channel changes saved.")
            messageIsError = false
            notifyParentIfNeeded()
            return true
        } catch {
            guard generation == capturedGeneration, projectSessionID == capturedOwner else { return false }
            endBusy(taskID)
            showError(error.localizedDescription)
            return false
        }
    }

    func discard() {
        guard !isBusy, let baselineState else { return }
        generation &+= 1
        state = baselineState
        synchronizeText(from: baselineState)
        invalidFields = []
        message = nil
        messageIsError = false
        notifyParentIfNeeded()
    }

    @discardableResult
    func invalidateOwner() -> Bool {
        guard !isBusy else {
            showError("Wait for the Stable Channel operation to finish before closing the project.")
            return false
        }
        guard !hasUnsavedChanges else {
            showError("Save or discard the Stable Channel changes before closing the project.")
            return false
        }
        generation &+= 1
        source = nil
        state = nil
        baselineState = nil
        inputText = [:]
        invalidFields = []
        selectedSolveFor = []
        projectSessionID = nil
        coreLayerContext = nil
        message = nil
        messageIsError = false
        notifyParentIfNeeded()
        return true
    }

    private func synchronizeText(from state: StableChannelDebugState) {
        inputText = Dictionary(uniqueKeysWithValues: StableChannelDebugField.allCases.map { field in
            let value = state.value(for: field)
            return (field, value.map(UnitCalculatorNumberFormat.g8) ?? "")
        })
        invalidFields = []
    }

    private func beginBusy() -> UUID {
        let id = UUID()
        busyTaskID = id
        isBusy = true
        return id
    }

    private func endBusy(_ id: UUID) {
        guard busyTaskID == id else { return }
        busyTaskID = nil
        isBusy = false
    }

    private func notifyParentIfNeeded() {
        let dirty = hasUnsavedChanges
        guard dirty != lastNotifiedDirty else { return }
        lastNotifiedDirty = dirty
        onParentDraftChange?(dirty)
    }

    private func showError(_ value: String) {
        message = L10n.text(value)
        messageIsError = true
    }

    private static func localizedComputeError(_ code: String?) -> String {
        let key: String
        switch code {
        case "selectExactlyTwoTargets": key = "Select exactly two variables to solve for."
        case "unsupportedSolveFor": key = "The selected solve-for combination is not supported."
        case "missingInput": key = "Enter finite values for the required inputs."
        case "invalidSolutionMethod": key = "Choose a valid solution method."
        case "invalidEquation": key = "Choose Manning or Strickler for each section."
        case "temperatureOutsideSourceRange": key = "Temperature must be between 40 and 120 °F."
        case "sourceChanged": key = "The Stable Channel source changed. Reopen it before calculating."
        case "nonFiniteResult": key = "The source calculation did not produce finite values."
        case "solverFailed": key = "The source Stable Channel calculation failed."
        default: key = "The Stable Channel calculation could not complete."
        }
        return L10n.text(key)
    }

    private static let protocolFailure = BackendServiceError(code: "protocolFailure",
        message: "The Stable Channel response does not match the current project and draft.")

    private static func isValidOpenedSource(_ source: StableChannelDebugSource,
                                            requestedProjectPath: String?) -> Bool {
        guard !source.sourceID.isEmpty else { return false }
        guard let requestedProjectPath else {
            return source.inMemory && UUID(uuidString: source.sourceID) != nil &&
                source.projectPath == nil && source.projectRevision == nil &&
                source.designPath == nil && source.designRevision == nil
        }
        guard let projectPath = source.projectPath, let projectRevision = source.projectRevision,
              samePath(projectPath, requestedProjectPath), isSHA256(projectRevision) else { return false }
        if source.inMemory {
            return UUID(uuidString: source.sourceID) != nil && source.designPath == nil && source.designRevision == nil
        }
        guard let designPath = source.designPath, !designPath.isEmpty,
              let designRevision = source.designRevision else { return false }
        return isSHA256(source.sourceID) && isSHA256(designRevision)
    }

    private static func samePath(_ left: String?, _ right: String?) -> Bool {
        guard let left, let right else { return left == nil && right == nil }
        return SourceFilePaths.canonical(URL(fileURLWithPath: left))
            == SourceFilePaths.canonical(URL(fileURLWithPath: right))
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 70) || (byte >= 97 && byte <= 102)
        }
    }
}
