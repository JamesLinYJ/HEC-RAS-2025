import Foundation
import RASWorkspaceCore

/// A live compute candidate is deliberately separate from a persisted source
/// choice: before the backend can read a stable Result revision there is no
/// SHA-backed choice to send to `map.resultSources`.
struct LiveMapResultSelectionOverride: Equatable, Sendable, Identifiable {
    enum Origin: String, Sendable {
        case latest
        case explicit
    }

    let nodeIdentity: String
    let selectionIndex: Int
    let entry: WorkspaceResultComputeEntry
    let origin: Origin

    var id: String { "\(nodeIdentity)|\(selectionIndex)" }
}

struct LiveMapResultProfile: Equatable, Sendable, Identifiable {
    let index: Int
    let name: String
    let time: String
    var id: Int { index }
}

struct LiveMapResultOutputBlock: Equatable, Sendable, Identifiable {
    let name: String
    var profileCount: Int
    var profilesByIndex: [Int: LiveMapResultProfile]
    var errorMessage: String?

    var id: String { name }
    var profiles: [LiveMapResultProfile] {
        profilesByIndex.values.sorted { $0.index < $1.index }
    }
}

/// Incrementally collects only source-reported profile metadata for one exact
/// compute run. Missing indices remain missing; the collector never fills
/// holes or invents a keyframe.
struct LiveMapResultProfileTimeline: Equatable, Sendable {
    let identity: LiveMapResultRunIdentity
    private(set) var outputBlocks: [String: LiveMapResultOutputBlock] = [:]
    private(set) var metadataError: String?

    var blocks: [LiveMapResultOutputBlock] {
        outputBlocks.values.sorted { $0.name < $1.name }
    }

    @discardableResult
    mutating func append(_ update: BackendResultProfilesUpdate) -> Bool {
        let (endIndex, overflow) = update.startIndex.addingReportingOverflow(update.profiles.count)
        guard !update.outputBlockName.isEmpty, update.startIndex >= 0,
              update.profileCount >= 0, !overflow,
              update.startIndex <= update.profileCount,
              endIndex <= update.profileCount,
              update.profiles.allSatisfy({ $0.index >= update.startIndex && $0.index < endIndex }),
              Set(update.profiles.map(\.index)).count == update.profiles.count else {
            rejectMalformedUpdate()
            return false
        }

        var block = outputBlocks[update.outputBlockName] ?? LiveMapResultOutputBlock(
            name: update.outputBlockName, profileCount: 0, profilesByIndex: [:], errorMessage: nil)
        if let errorMessage = update.errorMessage, !errorMessage.isEmpty {
            block.errorMessage = errorMessage
            block.profileCount = max(block.profileCount, update.profileCount)
            outputBlocks[update.outputBlockName] = block
            return true
        }

        // Progress packets may arrive out of order. A late earlier packet can
        // legitimately fill a missing index after a later packet raised the
        // observed total; retain the largest total and never rewrite a sample
        // identity already accepted for this exact run and output block.
        let profiles = update.profiles.map { sourceProfile in
            LiveMapResultProfile(index: sourceProfile.index,
                name: sourceProfile.name, time: sourceProfile.time)
        }
        for profile in profiles {
            if let previous = block.profilesByIndex[profile.index], previous != profile {
                metadataError = "The source output profile names and times are inconsistent."
                return false
            }
        }
        for profile in profiles {
            block.profilesByIndex[profile.index] = profile
        }
        block.profileCount = max(block.profileCount, update.profileCount)
        outputBlocks[update.outputBlockName] = block
        return true
    }

    mutating func rejectMalformedUpdate() {
        if metadataError == nil {
            metadataError = "The source output profile names and times are inconsistent."
        }
    }
}

struct LiveMapResultRunIdentity: Equatable, Hashable, Sendable {
    let projectSessionID: UUID
    let editorID: UUID
    let operationOwnerToken: String
    let operationContextID: String
    let runID: String
    let projectPath: String
    let projectRevision: String
    let projectXmlFingerprint: String
    let planPath: String
    let planRevision: String
    let resultPath: String

    init(entry: WorkspaceResultComputeEntry) {
        projectSessionID = entry.projectSessionID
        editorID = entry.editorID
        operationOwnerToken = entry.operationOwnerToken
        operationContextID = entry.operationContextID
        runID = entry.runID
        projectPath = SourceFilePaths.canonical(URL(fileURLWithPath: entry.projectPath))
        projectRevision = entry.projectRevision
        projectXmlFingerprint = entry.projectXmlFingerprint
        planPath = SourceFilePaths.canonical(URL(fileURLWithPath: entry.planPath))
        planRevision = entry.planRevision
        resultPath = SourceFilePaths.canonical(URL(fileURLWithPath: entry.resultPath))
    }

    func matches(_ capture: WorkspaceResultComputeCapture) -> Bool {
        projectSessionID == capture.projectSessionID
            && editorID == capture.editorID
            && operationOwnerToken == capture.operationOwnerToken
            && operationContextID == capture.operationContextID
            && projectPath == capture.projectPath
            && projectRevision == capture.projectRevision
            && projectXmlFingerprint == capture.projectXmlFingerprint
            && planPath == capture.planPath
            && planRevision == capture.planRevision
    }
}

enum LiveMapResultSelectionProjection {
    @MainActor
    static func nodeMatches(_ node: MapResultChartActiveNode,
                            projectSessionID: UUID,
                            capture: WorkspaceResultComputeCapture,
                            entry: WorkspaceResultComputeEntry) -> Bool {
        guard node.nodeKind == "MultiResult",
              entry.projectSessionID == projectSessionID,
              entry.projectSessionID == capture.projectSessionID,
              LiveMapResultRunIdentity(entry: entry).matches(capture),
              let owner = WorkspaceStore.exactPlanOwnerForResultGroup(node.node) else { return false }
        return SourceFilePaths.canonical(URL(fileURLWithPath: owner.assetID)) == capture.planPath
    }

    static func stableChoice(for entry: WorkspaceResultComputeEntry,
                             in node: MapResultChartActiveNode) -> MapResultChartSourceChoice? {
        guard let revision = entry.resultRevision, !revision.isEmpty else { return nil }
        return node.selections.lazy.flatMap(\.choices).first { choice in
            SourceFilePaths.canonical(URL(fileURLWithPath: choice.resultPath))
                == SourceFilePaths.canonical(URL(fileURLWithPath: entry.resultPath))
                && choice.revision.caseInsensitiveCompare(revision) == .orderedSame
        }
    }

    static func carryingProfiles(from previous: WorkspaceResultComputeEntry?,
                                 into next: WorkspaceResultComputeEntry,
                                 update: BackendResultProfilesUpdate? = nil)
        -> WorkspaceResultComputeEntry {
        var result = next
        var timeline: LiveMapResultProfileTimeline?
        if let previous, previous.runID == next.runID,
           LiveMapResultRunIdentity(entry: previous) == LiveMapResultRunIdentity(entry: next) {
            timeline = previous.profileTimeline
        }
        if let update {
            var collected = timeline ?? LiveMapResultProfileTimeline(identity: .init(entry: next))
            if !collected.append(update) { collected.rejectMalformedUpdate() }
            timeline = collected
        }
        result.profileTimeline = timeline
        return result
    }
}
