import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import Testing
import RASWorkspaceCore
@testable import HECRAS2025

@Suite(.serialized)
struct PlanDiagnosticNavigationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_PLAN_CONTEXT_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func bundledBackendPlanContextRoutesExactTargetAndRejectsStaleSource() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixturePath = try #require(environment["HECRAS_PLAN_CONTEXT_ACCEPTANCE_DIRECTORY"])
        let executablePath = try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = URL(fileURLWithPath: fixturePath, isDirectory: true)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-diagnostic-navigation-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }

        let projectURL = folder.appendingPathComponent("Plan Context Refresh.ras")
        let provider = BackendModelProvider(client: BackendProcessClient(
            executableURL: URL(fileURLWithPath: executablePath)))
        let store = WorkspaceStore(
            system: SourceWorkflowFixtureServices(recoveryFolder: folder.appendingPathComponent("Recovery")),
            modelProvider: provider)
        store.requestOpen(projectURL)
        try await Self.waitUntil { !store.isOpeningProject }

        let document = try #require(store.document)
        let plan = try #require(store.assets.first { $0.section == .plans && $0.name == "Plan A" })
        let planSession = store.primaryEditorSession(.plan)
        store.openEditor(.plan, assetID: plan.id)
        await planSession.load(plan, kind: .plan)
        #expect(planSession.loaded && planSession.error == nil)
        let planContext = try #require(planSession.currentPlanComputeContext())
        let contextID = planContext.id
        let projectRevision = try #require(document.sourceRevision)
        let planRevision = try #require(planSession.sourceFileRevision)

        let backendInspection = try await provider.inspect(plan, edits: planContext.edits)
        let target = try #require(backendInspection.messages.lazy.flatMap(\.logData)
            .first { $0.key == "PlanName" }?.target)
        #expect(target.kind == "plan")
        #expect(target.projectPath == SourceFilePaths.canonical(projectURL))
        #expect(target.projectRevision.caseInsensitiveCompare(projectRevision) == .orderedSame)
        #expect(target.planPath == SourceFilePaths.canonical(plan.url))
        #expect(target.planRevision.caseInsensitiveCompare(planRevision) == .orderedSame)

        let association = try #require(document.associationRows(group: "PlanAssociations")
            .first { $0.name == plan.name })
        let boundaryName = try #require(association.fields["BoundaryCondition"])
        let boundary = try #require(store.assets.first {
            $0.section == .boundaryConditions && $0.isModelFile && $0.name == boundaryName
        })
        let boundaryTarget = PlanDiagnosticTarget(kind: "boundaryCondition",
            projectPath: target.projectPath, projectRevision: target.projectRevision,
            planPath: target.planPath, planRevision: target.planRevision,
            assetPath: SourceFilePaths.canonical(boundary.url),
            assetRevision: try Self.sha256(at: boundary.url))

        #expect(!store.navigateToPlanDiagnosticTarget(target,
            projectSessionID: UUID(), planEditorID: planSession.id, planContextID: contextID),
            "A target from another open project session must be rejected.")
        #expect(!store.navigateToPlanDiagnosticTarget(target,
            projectSessionID: store.projectSessionID, planEditorID: planSession.id,
            planContextID: contextID + "-stale"),
            "A target from another Plan editor context must be rejected.")
        let staleProjectTarget = Self.replacing(target, projectRevision: String(repeating: "0", count: 64))
        #expect(!store.navigateToPlanDiagnosticTarget(staleProjectTarget,
            projectSessionID: store.projectSessionID, planEditorID: planSession.id, planContextID: contextID),
            "A target with an old project SHA must be rejected before routing.")
        let wrongProjectTarget = Self.replacing(target, projectPath: folder.appendingPathComponent("Other.ras").path)
        #expect(!store.navigateToPlanDiagnosticTarget(wrongProjectTarget,
            projectSessionID: store.projectSessionID, planEditorID: planSession.id, planContextID: contextID),
            "A target naming another project path must be rejected even in the current editor context.")
        #expect(store.pendingPlanDiagnosticNavigation == nil)

        let staleAssetTarget = Self.replacing(boundaryTarget, assetRevision: String(repeating: "0", count: 64))
        #expect(store.navigateToPlanDiagnosticTarget(staleAssetTarget,
            projectSessionID: store.projectSessionID, planEditorID: planSession.id, planContextID: contextID))
        try await Self.waitUntil { store.pendingPlanDiagnosticNavigation == nil }
        #expect(planSession.error != nil, "A target with a wrong asset SHA must not open as current.")
        planSession.error = nil

        // A separately registered Plan window owns an equally valid source
        // context. Diagnostics must route from that window without depending
        // on which editor is designated the workspace's primary instance.
        let detachedSession = ModelEditorSession(provider: provider)
        store.registerEditor(detachedSession)
        await detachedSession.load(plan, kind: .plan)
        let detachedContext = try #require(detachedSession.currentPlanComputeContext())
        #expect(store.navigateToPlanDiagnosticTarget(target,
            projectSessionID: store.projectSessionID, planEditorID: detachedSession.id,
            planContextID: detachedContext.id))
        try await Self.waitUntil { store.pendingPlanDiagnosticNavigation?.phase == .ready }
        let detachedRequest = try #require(store.pendingPlanDiagnosticNavigation)
        #expect(detachedRequest.planEditorID == detachedSession.id)
        #expect(await store.verifyPlanDiagnosticNavigation(detachedRequest))
        store.finishPlanDiagnosticNavigation(detachedRequest)
        store.unregisterEditor(detachedSession)
        #expect(!store.navigateToPlanDiagnosticTarget(target,
            projectSessionID: store.projectSessionID, planEditorID: detachedSession.id,
            planContextID: detachedContext.id),
            "A closed Plan window cannot originate a diagnostic navigation.")

        #expect(store.navigateToPlanDiagnosticTarget(target,
            projectSessionID: store.projectSessionID, planEditorID: planSession.id, planContextID: contextID))
        try await Self.waitUntil {
            store.pendingPlanDiagnosticNavigation?.phase == .ready
                && store.activeTab == .editor(.plan)
        }
        let request = try #require(store.pendingPlanDiagnosticNavigation)
        #expect(request.target == target)
        #expect(request.destinationKind == .plan)
        #expect(request.destinationAssetID == plan.id)
        #expect(request.destinationPageID == "Summary")
        #expect(store.editorAssetRequests[.plan] == plan.id)
        #expect(await store.verifyPlanDiagnosticNavigation(request),
            "The exact backend target must remain current after the Store routes to its primary editor.")
        store.finishPlanDiagnosticNavigation(request)

        #expect(store.navigateToPlanDiagnosticTarget(boundaryTarget,
            projectSessionID: store.projectSessionID, planEditorID: planSession.id, planContextID: contextID))
        try await Self.waitUntil {
            store.pendingPlanDiagnosticNavigation?.phase == .ready
                && store.activeTab == .editor(.boundaryCondition)
        }
        let boundaryRequest = try #require(store.pendingPlanDiagnosticNavigation)
        #expect(boundaryRequest.destinationAssetID == boundary.id)
        #expect(boundaryRequest.destinationPageID == "General Options")
        #expect(store.editorAssetRequests[.boundaryCondition] == boundary.id)
        #expect(await store.verifyPlanDiagnosticNavigation(boundaryRequest))

        let handle = try FileHandle(forWritingTo: boundary.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        #expect(!(await store.verifyPlanDiagnosticNavigation(boundaryRequest)),
            "A target whose source changes after routing must be rejected before row selection.")
        store.finishPlanDiagnosticNavigation(boundaryRequest)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_PLAN_CONTEXT_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func bundledBackendStoreRejectsAmbiguousPlanAssociation() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixture = try #require(environment["HECRAS_PLAN_CONTEXT_ACCEPTANCE_DIRECTORY"])
        let executable = try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-diagnostic-ambiguous-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }

        let projectURL = folder.appendingPathComponent("Plan Context Refresh.ras")
        let xml = try XMLDocument(contentsOf: projectURL, options: [])
        let root = try #require(xml.rootElement())
        let associationGroup = try #require(root.elements(forName: "PlanAssociations").first)
        let planAssociation = try #require(associationGroup.elements(forName: "PlanAssociation")
            .first { $0.attribute(forName: "Plan")?.stringValue == "Plan A" })
        associationGroup.addChild(try #require(planAssociation.copy() as? XMLElement))
        try xml.xmlData(options: [.nodePrettyPrint]).write(to: projectURL, options: .atomic)

        let provider = BackendModelProvider(client: BackendProcessClient(
            executableURL: URL(fileURLWithPath: executable)))
        let store = WorkspaceStore(
            system: SourceWorkflowFixtureServices(recoveryFolder: folder.appendingPathComponent("Recovery")),
            modelProvider: provider)
        store.requestOpen(projectURL)
        try await Self.waitUntil { !store.isOpeningProject }

        let document = try #require(store.document)
        let plan = try #require(store.assets.first { $0.section == .plans && $0.name == "Plan A" })
        let boundaryName = try #require(document.associationRows(group: "PlanAssociations")
            .first { $0.name == plan.name }?.fields["BoundaryCondition"])
        let boundary = try #require(store.assets.first {
            $0.section == .boundaryConditions && $0.isModelFile && $0.name == boundaryName
        })
        let planSession = store.primaryEditorSession(.plan)
        store.openEditor(.plan, assetID: plan.id)
        await planSession.load(plan, kind: .plan)
        #expect(planSession.loaded && planSession.error == nil)
        let context = try #require(planSession.currentPlanComputeContext())
        let target = PlanDiagnosticTarget(kind: "boundaryCondition",
            projectPath: SourceFilePaths.canonical(projectURL),
            projectRevision: try #require(document.sourceRevision),
            planPath: SourceFilePaths.canonical(plan.url),
            planRevision: try #require(planSession.sourceFileRevision),
            assetPath: SourceFilePaths.canonical(boundary.url),
            assetRevision: try Self.sha256(at: boundary.url))

        #expect(!store.navigateToPlanDiagnosticTarget(target,
            projectSessionID: store.projectSessionID, planEditorID: planSession.id,
            planContextID: context.id),
            "A source-valid target must still be rejected when its Plan association is ambiguous.")
        #expect(store.pendingPlanDiagnosticNavigation == nil)
        #expect(store.activeTab == .editor(.plan))
    }

    @Test
    func ambiguousAssociationsAssetsAndFeatureNamesCannotResolve() throws {
        let association = ProjectAssociation(group: "PlanAssociations", element: "PlanAssociation",
            primaryKey: "Plan", name: "Plan A", fields: ["Plan": "Plan A"])
        #expect(PlanDiagnosticNavigationIdentity.uniqueAssociation(named: "Plan A",
            group: "PlanAssociations", in: [association, association]) == nil)

        let boundary = ProjectAsset(url: URL(fileURLWithPath: "/fixture/Boundaries/Boundary A.h5"),
            section: .boundaryConditions)
        #expect(PlanDiagnosticNavigationIdentity.uniqueAssociatedAsset(named: "Boundary A",
            section: .boundaryConditions, in: [boundary, boundary]) == nil)

        #expect(!PlanDiagnosticNavigationIdentity.uniqueFeatureRow(index: 0,
            name: "Duplicate line", names: ["Duplicate line", "Duplicate line"]))
        #expect(PlanDiagnosticNavigationIdentity.uniqueFeatureRow(index: 1,
            name: "Boundary line B", names: ["Boundary line A", "Boundary line B"]))
    }

    private static func replacing(_ target: PlanDiagnosticTarget,
                                  projectPath: String? = nil,
                                  projectRevision: String? = nil,
                                  assetRevision: String? = nil) -> PlanDiagnosticTarget {
        PlanDiagnosticTarget(kind: target.kind,
            projectPath: projectPath ?? target.projectPath,
            projectRevision: projectRevision ?? target.projectRevision,
            planPath: target.planPath, planRevision: target.planRevision,
            assetPath: target.assetPath, assetRevision: assetRevision ?? target.assetRevision,
            featureID: target.featureID, featureName: target.featureName)
    }

    private static func sha256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    private static func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        while !predicate(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(predicate(), "Timed out waiting for Plan diagnostic navigation state.")
    }
}
