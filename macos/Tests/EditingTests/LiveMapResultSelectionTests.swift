import Foundation
import Testing
import RASWorkspaceCore
@testable import HECRAS2025

@Suite(.serialized)
struct LiveMapResultSelectionTests {
    @Test
    func liveProfilePacketsAcceptReorderingAndIdenticalDuplicatesButRejectConflicts() throws {
        var timeline = LiveMapResultProfileTimeline(identity: .init(entry: entry()))
        let lateStart = BackendResultProfilesUpdate(outputBlockName: "BaseOutput",
            startIndex: 1, profileCount: 2,
            profiles: [.init(index: 1, name: "02Jan2025 01:00", time: "2025-01-02T01:00:00.0000000")])
        let earlyStart = BackendResultProfilesUpdate(outputBlockName: "BaseOutput",
            startIndex: 0, profileCount: 1,
            profiles: [.init(index: 0, name: "02Jan2025 00:00", time: "2025-01-02T00:00:00.0000000")])

        let acceptedLate = timeline.append(lateStart)
        #expect(acceptedLate)
        let acceptedEarly = timeline.append(earlyStart)
        #expect(acceptedEarly, "An older packet may fill a missing index after a newer count arrived.")
        let acceptedDuplicate = timeline.append(earlyStart)
        #expect(acceptedDuplicate, "An identical repeated profile is idempotent.")
        #expect(timeline.blocks.first?.profileCount == 2)
        #expect(timeline.blocks.first?.profiles.map(\.index) == [0, 1])
        #expect(timeline.metadataError == nil)

        let conflict = BackendResultProfilesUpdate(outputBlockName: "BaseOutput",
            startIndex: 0, profileCount: 1,
            profiles: [.init(index: 0, name: "changed source name", time: "2025-01-02T00:00:00.0000000")])
        let acceptedConflict = timeline.append(conflict)
        #expect(!acceptedConflict)
        #expect(timeline.blocks.first?.profiles.first?.name == "02Jan2025 00:00")
        #expect(timeline.metadataError != nil)
    }

    @Test
    func liveProfilePacketRangeRejectsIntegerOverflowAndDoesNotCreateBlock() throws {
        var timeline = LiveMapResultProfileTimeline(identity: .init(entry: entry()))
        let overflow = BackendResultProfilesUpdate(outputBlockName: "BaseOutput",
            startIndex: Int.max, profileCount: Int.max,
            profiles: [.init(index: Int.max, name: "impossible", time: "source-time")])

        let acceptedOverflow = timeline.append(overflow)
        #expect(!acceptedOverflow)
        #expect(timeline.blocks.isEmpty)
        #expect(timeline.metadataError != nil)
    }

    private func entry() -> WorkspaceResultComputeEntry {
        WorkspaceResultComputeEntry(runID: "run-r32-1",
            projectSessionID: UUID(uuidString: "A40009D3-D1B7-4FC8-AB88-7A8EF9B25E14")!,
            editorID: UUID(uuidString: "B50009D3-D1B7-4FC8-AB88-7A8EF9B25E14")!,
            operationOwnerToken: "owner-1", operationContextID: "context-1",
            projectPath: "/tmp/r32/model.ras", projectRevision: "project-revision",
            projectXmlFingerprint: "xml-fingerprint", planPath: "/tmp/r32/Plan.p02",
            planRevision: "plan-revision", resultPath: "/tmp/r32/Plan.p02.hdf",
            resultName: "Plan 02", resultRevision: nil, status: .running,
            fraction: 0.25, message: nil, taskName: "computing", failureReason: nil)
    }
}
