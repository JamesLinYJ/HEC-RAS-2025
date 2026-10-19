import Foundation

/// Stable, selection-driven presentation helpers for the terrain profiles
/// returned by the geometry culvert provider.
struct GeometryCulvertProfilePresentation {
    static func selectedProfiles(
        _ profiles: [GeometryCulvertProfile],
        barrelIDs: Set<String>
    ) -> [GeometryCulvertProfile] {
        guard !barrelIDs.isEmpty else { return [] }
        var profilesByID: [String: GeometryCulvertProfile] = [:]
        for profile in profiles where profilesByID[profile.barrelID] == nil {
            profilesByID[profile.barrelID] = profile
        }
        return barrelIDs.sorted().compactMap { profilesByID[$0] }
    }

    static func plotProfiles(_ profiles: [GeometryCulvertProfile]) -> [GeometryCulvertProfile] {
        profiles.filter { !$0.samples.isEmpty }
    }

    static func legendLabels(for profiles: [GeometryCulvertProfile]) -> [String: String] {
        labels(barrelIDs: Set(profiles.map(\.barrelID)), profiles: profiles, fallbackNames: [:])
    }

    static func labels(barrelIDs: Set<String>, profiles: [GeometryCulvertProfile],
                       fallbackNames: [String: String]) -> [String: String] {
        var namesByID = fallbackNames
        for profile in profiles where namesByID[profile.barrelID] == nil {
            namesByID[profile.barrelID] = profile.barrelName
        }
        let selectedIDs = barrelIDs.sorted()
        var nameCounts: [String: Int] = [:]
        for id in selectedIDs { nameCounts[namesByID[id] ?? id, default: 0] += 1 }
        return Dictionary(uniqueKeysWithValues: selectedIDs.map { id in
            let name = namesByID[id] ?? id
            let label = nameCounts[name, default: 0] > 1 ? "\(name) · \(id)" : name
            return (id, label)
        })
    }
}

struct GeometryMeshPatchDimensionEditorIdentity: Hashable, Sendable {
    let assetID: String?
    let featureIDs: [Int]
    let axis: String
    let sourceIdentity: String?

    init(assetID: String?, featureIDs: [Int], axis: String, sourceIdentity: String? = nil) {
        self.assetID = assetID
        self.sourceIdentity = sourceIdentity
        self.featureIDs = Array(Set(featureIDs)).sorted()
        self.axis = axis
    }
}

struct GeometryMeshPatchDimensionDraftSource: Equatable, Sendable {
    let mode: String?
    let modeHasMismatch: Bool
    let liveValue: Double?
    let liveValueHasMismatch: Bool

    init(mode: String?, modeHasMismatch: Bool, liveValue: Double?, liveValueHasMismatch: Bool) {
        self.mode = mode
        self.modeHasMismatch = modeHasMismatch
        self.liveValue = liveValue
        self.liveValueHasMismatch = liveValueHasMismatch
    }

    init(_ dimension: GeometryMeshPatchDimension) {
        self.init(mode: dimension.sizeFunction, modeHasMismatch: dimension.sizeFunctionHasMismatch,
            liveValue: dimension.liveValue, liveValueHasMismatch: dimension.liveValueHasMismatch)
    }

    var modeText: String { modeHasMismatch ? "" : (mode ?? "") }
    var valueText: String {
        guard !liveValueHasMismatch else { return "" }
        return liveValue.map { String($0) } ?? ""
    }
}

struct GeometryMeshPatchDimensionDraftRequest: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case mode(String)
        case value(mode: String, value: String)
    }

    let id: UUID
    let identity: GeometryMeshPatchDimensionEditorIdentity
    let kind: Kind
}

/// Holds only editor-local drafts. Provider snapshots update clean fields,
/// while edits the user has not submitted remain intact across refreshes.
struct GeometryMeshPatchDimensionDraftState: Equatable, Sendable {
    let identity: GeometryMeshPatchDimensionEditorIdentity
    private(set) var source: GeometryMeshPatchDimensionDraftSource
    private(set) var mode: String
    private(set) var value: String
    private(set) var pendingRequest: GeometryMeshPatchDimensionDraftRequest?

    init(identity: GeometryMeshPatchDimensionEditorIdentity,
         source: GeometryMeshPatchDimensionDraftSource) {
        self.identity = identity
        self.source = source
        mode = source.modeText
        value = source.valueText
        pendingRequest = nil
    }

    mutating func setMode(_ value: String) { mode = value }
    mutating func setValue(_ value: String) { self.value = value }

    mutating func beginModeRequest(_ value: String, id: UUID) -> GeometryMeshPatchDimensionDraftRequest {
        let request = GeometryMeshPatchDimensionDraftRequest(id: id, identity: identity, kind: .mode(value))
        pendingRequest = request
        return request
    }

    mutating func beginValueRequest(mode: String, value: String,
                                    id: UUID) -> GeometryMeshPatchDimensionDraftRequest {
        let request = GeometryMeshPatchDimensionDraftRequest(id: id, identity: identity,
            kind: .value(mode: mode, value: value))
        pendingRequest = request
        return request
    }

    mutating func synchronize(with nextSource: GeometryMeshPatchDimensionDraftSource) {
        let oldModeIsDirty = mode != source.modeText
        let oldValueIsDirty = value != source.valueText
        let request = pendingRequest
        let modeWasConfirmed: Bool
        let valueWasConfirmed: Bool

        switch request?.kind {
        case let .some(.mode(requestedMode)):
            modeWasConfirmed = !nextSource.modeHasMismatch && nextSource.modeText == requestedMode
            valueWasConfirmed = false
        case let .some(.value(requestedMode, requestedValue)):
            modeWasConfirmed = false
            valueWasConfirmed = Self.source(nextSource, confirms: requestedValue, mode: requestedMode)
        case .none:
            modeWasConfirmed = false
            valueWasConfirmed = false
        }

        if !oldModeIsDirty || (modeWasConfirmed && mode == (request?.requestedMode ?? "")) {
            mode = nextSource.modeText
        }
        if !oldValueIsDirty || (valueWasConfirmed && request?.draftValueMatches(value) == true) {
            value = nextSource.valueText
        }

        source = nextSource
        if modeWasConfirmed || valueWasConfirmed { pendingRequest = nil }
    }

    mutating func finish(_ request: GeometryMeshPatchDimensionDraftRequest,
                         returnedSource: GeometryMeshPatchDimensionDraftSource?) {
        guard identity == request.identity, pendingRequest?.id == request.id else { return }
        if let returnedSource { synchronize(with: returnedSource) }
        guard pendingRequest?.id == request.id else { return }
        if case .mode = request.kind { mode = source.modeText }
        pendingRequest = nil
    }

    func submissionValue(canEdit: Bool, sourceCanApply: Bool, arcCount: Int,
                         modeHasMismatch: Bool) -> String? {
        guard canEdit, sourceCanApply, arcCount > 0, !modeHasMismatch,
              !source.modeHasMismatch, !mode.isEmpty, mode == source.modeText,
              let normalized = GeometryMeshPatchDimensionValue.normalized(value, mode: mode) else {
            return nil
        }
        if source.liveValueHasMismatch { return normalized }
        if GeometryMeshPatchDimensionValue.matches(normalized, sourceValue: source.liveValue, mode: mode) {
            return nil
        }
        return normalized
    }

    private static func source(_ source: GeometryMeshPatchDimensionDraftSource,
                               confirms requestedValue: String, mode: String) -> Bool {
        guard !source.liveValueHasMismatch,
              let requested = GeometryMeshPatchDimensionValue.normalized(requestedValue, mode: mode),
              let sourceValue = source.liveValue else { return false }
        return GeometryMeshPatchDimensionValue.matches(requested, sourceValue: sourceValue, mode: mode)
    }
}

private extension GeometryMeshPatchDimensionDraftRequest {
    var requestedMode: String? {
        if case let .mode(mode) = kind { return mode }
        if case let .value(mode, _) = kind { return mode }
        return nil
    }

    func draftValueMatches(_ draftValue: String) -> Bool {
        guard case let .value(mode, requestedValue) = kind,
              let normalizedDraft = GeometryMeshPatchDimensionValue.normalized(draftValue, mode: mode),
              let normalizedRequested = GeometryMeshPatchDimensionValue.normalized(requestedValue, mode: mode) else {
            return false
        }
        return normalizedDraft == normalizedRequested
    }
}

enum GeometryMeshPatchDimensionValue {
    /// The source stores ConstantSize as a float and PointCount as an integer.
    /// Reject non-finite values and float overflow before sending a mutation.
    static func normalized(_ rawValue: String, mode: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case "Constant":
            guard let value = Double(trimmed), value.isFinite else { return nil }
            let sourceFloat = Float(value)
            guard sourceFloat.isFinite else { return nil }
            return String(sourceFloat)
        case "CountWithBias":
            guard let value = Int32(trimmed) else { return nil }
            return String(value)
        default:
            return nil
        }
    }

    static func matches(_ normalized: String, sourceValue: Double?, mode: String) -> Bool {
        guard let sourceValue else { return false }
        switch mode {
        case "Constant":
            guard let requested = Float(normalized), requested.isFinite else { return false }
            let current = Float(sourceValue)
            return current.isFinite && requested == current
        case "CountWithBias":
            guard let requested = Int32(normalized), let current = Int32(exactly: sourceValue) else { return false }
            return requested == current
        default:
            return false
        }
    }
}
