import CryptoKit
import Foundation
import Testing
import RASWorkspaceCore
@testable import HECRAS2025

struct BackendPlanComputeIntegrationTests {
    @Test @MainActor
    func bundledProviderRunsTheSourceCPUComputeAndReturnsItsResultIdentity() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = try #require(ProcessInfo.processInfo.environment["HECRAS_PLAN_COMPUTE_ACCEPTANCE_DIRECTORY"])
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-compute-provider-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture, isDirectory: true), to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }

        let projectURL = folder.appendingPathComponent("Plan Compute Acceptance.ras")
        let project = try ProjectDocument(contentsOf: projectURL)
        let provider = BackendModelProvider(client: .init(executableURL: URL(fileURLWithPath: executable)))
        provider.setProject(project)
        let plan = try #require(project.assets.first { $0.section == .plans && $0.name == "Plan CPU" })
        let geometry = try #require(project.assets.first { $0.section == .geometries && $0.name == "Solver Geometry" })
        let boundary = try #require(project.assets.first { $0.section == .boundaryConditions && $0.name == "Solver Boundary" })

        let projectBytes = try Data(contentsOf: projectURL)
        let planBytes = try Data(contentsOf: plan.url)
        let geometryBytes = try Data(contentsOf: geometry.url)
        let boundaryBytes = try Data(contentsOf: boundary.url)
        let snapshot = try await provider.load(plan, kind: .plan)
        let sourceRevision = try #require(snapshot.sourceRevision)
        let edits = EditorEdits(fields: [:], rows: [:], images: [:],
            sourceRevision: sourceRevision, sourceState: snapshot.sourceState)

        let inspection = try await provider.inspectCompute(plan, edits: edits)
        #expect(inspection.revision == sourceRevision)
        #expect(inspection.canExecute && !inspection.requiresCUDA)
        #expect(inspection.sourceDependencies.contains { $0.role == "Geometry" && $0.willWrite })
        #expect(inspection.sourceDependencies.contains { $0.role == "BoundaryCondition" && $0.willWrite })
        #expect(inspection.sourceDependencies.contains { $0.role == "ResultOutput" && $0.willWrite })

        let cancellation = try PlanComputeCancellationLease.create()
        defer { cancellation.cleanup() }
        let progress = PlanComputeProgressCapture()
        let result = try await provider.executeCompute(plan, edits: edits,
            inspectionID: inspection.inspectionId, cancellation: cancellation.request,
            progress: { progress.append($0) })

        #expect(result.state == "completed")
        #expect(result.inspectionId == inspection.inspectionId && result.revision == sourceRevision)
        #expect(result.summary?.success == true)
        #expect(result.summary?.startTime != nil && result.summary?.endTime != nil)
        #expect(result.resultPath.map { FileManager.default.fileExists(atPath: $0) } == true)
        let resultPath = try #require(result.resultPath)
        let expectedSHA = try sha256(at: URL(fileURLWithPath: resultPath))
        #expect(result.resultRevision == expectedSHA)
        let resultCompute = try #require(result.resultCompute)
        #expect(UUID(uuidString: resultCompute.runId) != nil)
        #expect(resultCompute.state == "completed")
        #expect(resultCompute.projectPath == SourceFilePaths.canonical(projectURL))
        #expect(resultCompute.projectRevision == inspection.projectRevision)
        #expect(resultCompute.projectXmlFingerprint == inspection.projectXmlFingerprint)
        #expect(resultCompute.planPath == SourceFilePaths.canonical(plan.url))
        #expect(resultCompute.planRevision == inspection.revision)
        #expect(resultCompute.resultPath.map { SourceFilePaths.canonical(URL(fileURLWithPath: $0)) }
            == SourceFilePaths.canonical(URL(fileURLWithPath: resultPath)))
        #expect(resultCompute.resultRevision == expectedSHA)
        #expect(progress.values.contains { update in
            guard let correlated = update.resultCompute else { return false }
            return correlated.runId == resultCompute.runId
                && correlated.state == "running"
                && correlated.resultPath.map { SourceFilePaths.canonical(URL(fileURLWithPath: $0)) }
                    == SourceFilePaths.canonical(URL(fileURLWithPath: resultPath))
        })
        #expect(result.finalDependencies.contains { $0.role == "Result" && $0.revision == "sha256:" + expectedSHA })
        #expect(result.sourceValues?["Steps"] != nil)
        #expect(result.sourceValues?["LastIterations"] != nil)
        #expect(result.sourceValues?["TotalCellCount"] == "1")
        #expect(result.sourceValues?["RetryElevationCount"] != nil)
        #expect(progress.values.contains { $0.values?["Steps"] != nil })

        let geometryAfter = try Data(contentsOf: geometry.url)
        let boundaryAfter = try Data(contentsOf: boundary.url)
        #expect(try Data(contentsOf: projectURL) == projectBytes)
        #expect(try Data(contentsOf: plan.url) == planBytes)
        #expect(geometryAfter != geometryBytes || boundaryAfter != boundaryBytes)
    }

    private func sha256(at url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02X", $0) }.joined()
    }
}

private final class PlanComputeProgressCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [BackendProgressUpdate] = []

    var values: [BackendProgressUpdate] {
        lock.withLock { updates }
    }

    func append(_ update: BackendProgressUpdate) {
        lock.withLock { updates.append(update) }
    }
}
