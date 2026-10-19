import Foundation
import Testing
import RASWorkspaceCore
@testable import HECRAS2025

struct PlanComputeJobMessageStreamTests {
    @Test
    func appendsEveryMessageInContiguousSourceOrderAndKeepsDuplicates() {
        var stream = PlanComputeJobMessageStream()
        stream.begin(contextID: "plan-context-a")
        let first = message(index: 0, code: "BC_LineWarning")
        let second = message(index: 1, code: "BC_LineWarning")

        stream.append(.init(runId: "run-a", messages: [first]), envelopeRunID: "run-a")
        stream.append(.init(runId: "run-a", messages: [second]), envelopeRunID: "run-a")

        #expect(stream.runID == "run-a")
        #expect(stream.contextID == "plan-context-a")
        #expect(stream.messages == [first, second])
        #expect(stream.issue == nil)
    }

    @Test
    func beginningAnotherPlanContextClearsThePreviousRunMessages() {
        var stream = PlanComputeJobMessageStream()
        stream.begin(contextID: "plan-context-a")
        stream.append(.init(runId: "run-a", messages: [message(index: 0, code: "Warning")]),
                      envelopeRunID: "run-a")

        stream.begin(contextID: "plan-context-b")

        #expect(stream.contextID == "plan-context-b")
        #expect(stream.runID == nil && stream.messages.isEmpty && stream.issue == nil)
    }

    @Test
    func rejectsGapsAndMessagesCorrelatedToAnotherRun() {
        var stream = PlanComputeJobMessageStream()
        stream.observe(runID: "run-current")

        stream.append(.init(runId: "run-current", messages: [message(index: 1, code: "Warning")]),
                      envelopeRunID: "run-current")
        #expect(stream.messages.isEmpty)
        #expect(stream.issue == "The live solver message sequence is incomplete.")

        stream.reset()
        stream.observe(runID: "run-current")
        stream.append(.init(runId: "run-old", messages: [message(index: 0, code: "Warning")]),
                      envelopeRunID: "run-current")
        #expect(stream.messages.isEmpty)
        #expect(stream.issue == "The live solver message sequence is incomplete.")
    }

    @Test
    func rejectsUncorrelatedUpdatesAndMissingTerminalRunIdentity() {
        var stream = PlanComputeJobMessageStream()
        stream.append(.init(runId: "run-a", messages: [message(index: 0, code: "Warning")]),
                      envelopeRunID: nil)
        #expect(stream.messages.isEmpty)
        #expect(stream.issue == "The live solver message sequence is incomplete.")

        stream.reset()
        stream.observe(runID: "run-a")
        stream.verifyTerminal(runID: nil)
        #expect(stream.issue == "The live solver message sequence is incomplete.")
    }

    @Test
    func diagnosticTargetDecodesExactOwnerAndFeatureRevisionFields() throws {
        let data = Data(#"{"kind":"flowArea","projectPath":"/project/Model.ras","projectRevision":"project-sha","planPath":"/project/Plans/Plan A.h5","planRevision":"plan-sha","assetPath":"/project/Geometries/Geometry A.h5","assetRevision":"geometry-sha","featureID":"flow-area-row:2","featureName":"Area A"}"#.utf8)
        let target = try JSONDecoder().decode(PlanDiagnosticTarget.self, from: data)

        #expect(target.kind == "flowArea")
        #expect(target.projectRevision == "project-sha")
        #expect(target.planRevision == "plan-sha")
        #expect(target.featureID == "flow-area-row:2")
        #expect(target.featureName == "Area A")
    }

    private func message(index: Int, code: String) -> PlanComputeJobMessage {
        .init(index: index, code: code, defaultSeverity: "Warning",
              evaluatedMessage: "Source message", logData: [
                .init(key: "PlanName", value: "Plan A")
              ])
    }
}
