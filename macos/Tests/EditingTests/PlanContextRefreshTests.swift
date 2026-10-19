import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class ControlledPlanContextProvider: ModelEditorProvider {
    var refreshEnabled = true
    var supportsProjectContextRefresh: Bool { refreshEnabled }
    var loadSnapshots: [EditorSnapshot] = [PlanContextRefreshFixture.snapshot()]
    private(set) var loadCount = 0
    private(set) var refreshRequests: [EditorEdits] = []
    private(set) var saveRequests: [EditorEdits] = []

    private var refreshContinuations: [Int: CheckedContinuation<EditorContextRefresh, any Error>] = [:]
    private var saveContinuations: [Int: CheckedContinuation<EditorSaveResult, any Error>] = [:]

    func load(_ asset: ProjectAsset, kind: ModelEditorKind) async throws -> EditorSnapshot {
        let index = min(loadCount, loadSnapshots.count - 1)
        loadCount += 1
        return loadSnapshots[index]
    }

    func refreshProjectContext(_ asset: ProjectAsset, edits: EditorEdits) async throws -> EditorContextRefresh {
        let request = refreshRequests.count + 1
        refreshRequests.append(edits)
        return try await withCheckedThrowingContinuation { continuation in
            refreshContinuations[request] = continuation
        }
    }

    func save(_ asset: ProjectAsset, changes: EditorEdits) async throws {}

    func saveModel(_ asset: ProjectAsset, changes: EditorEdits) async throws -> EditorSaveResult {
        let request = saveRequests.count + 1
        saveRequests.append(changes)
        return try await withCheckedThrowingContinuation { continuation in
            saveContinuations[request] = continuation
        }
    }

    func perform(_ asset: ProjectAsset, action: EditorAction) async throws -> EditorSnapshot {
        loadSnapshots[min(max(loadCount - 1, 0), loadSnapshots.count - 1)]
    }

    func finishRefresh(_ request: Int, with result: EditorContextRefresh) {
        refreshContinuations.removeValue(forKey: request)?.resume(returning: result)
    }

    func finishSave(_ request: Int = 1) {
        saveContinuations.removeValue(forKey: request)?.resume(returning: EditorSaveResult())
    }

    func finishSave(_ request: Int, with snapshot: EditorSnapshot) {
        saveContinuations.removeValue(forKey: request)?.resume(returning: EditorSaveResult(
            sourceRevision: snapshot.sourceRevision, snapshot: snapshot))
    }
}

private enum PlanContextRefreshFixture {
    static let asset = ProjectAsset(url: URL(fileURLWithPath: "/task-fixture/plan-context/Plan A.h5"), section: .plans)
    static let timestep = "PlanSettingsPage/ViewModel_SelectedPlan_ComputeTimestep"
    static let description = "PlanSettingsPage/ViewModel_SelectedPlan_Description"
    static let descriptionAlias = "PlanCatalogSummary/Context_Description"
    static let embeddedImages = "PlanSettingsPage/ViewModel_SelectedPlan_EmbeddedImages"
    static let windowFields = PlanTimeWindowFieldIDs(
        mode: "PlanSettingsPage/ViewModel_SelectedPlan_TimeWindowMode",
        start: "PlanSettingsPage/ViewModel_SelectedPlan_ComputeStartTime",
        end: "PlanSettingsPage/ViewModel_SelectedPlan_ComputeEndTime")
    static let sourceRevision = "plan-context-source-revision"

    static func image(_ id: String) -> ImageAttachment {
        .init(id: id, name: id + ".png", data: Data([1, 2, 3]))
    }

    static func snapshot(
        timestepValue: String = "12.5",
        descriptionValue: String = "Saved plan description",
        images: [ImageAttachment] = [],
        windowModeValue: String = "BoundaryCondition",
        windowStartValue: String = "2026-10-01T00:00:00Z",
        windowEndValue: String = "2026-10-02T00:00:00Z",
        sourceStateValue: String? = "canonical-plan-window-state"
    ) -> EditorSnapshot {
        EditorSnapshot(
            fields: [timestep: timestepValue, description: descriptionValue, descriptionAlias: descriptionValue,
                windowFields.mode: windowModeValue, windowFields.start: windowStartValue, windowFields.end: windowEndValue],
            rows: [:], samples: [:], canEdit: true,
            images: [embeddedImages: images],
            sourceRevision: sourceRevision,
            fieldGroups: ["PlanDescriptionAliases": [description, descriptionAlias]],
            sourceState: sourceStateValue, planTimeWindowFieldIDs: windowFields)
    }

    static func context(
        baselineTimestep: String,
        draftTimestep: String? = nil,
        baselineDescription: String,
        draftDescription: String? = nil,
        baselineImages: [ImageAttachment] = [],
        draftImages: [ImageAttachment] = [],
        baselineWindowMode: String = "BoundaryCondition",
        baselineWindowStart: String = "2026-10-01T00:00:00Z",
        baselineWindowEnd: String = "2026-10-02T00:00:00Z",
        draftWindowMode: String? = nil,
        draftWindowStart: String? = nil,
        draftWindowEnd: String? = nil,
        sourceStateValue: String? = "canonical-plan-window-state"
    ) -> EditorContextRefresh {
        EditorContextRefresh(
            baseline: snapshot(timestepValue: baselineTimestep, descriptionValue: baselineDescription, images: baselineImages,
                windowModeValue: baselineWindowMode, windowStartValue: baselineWindowStart, windowEndValue: baselineWindowEnd),
            draft: snapshot(timestepValue: draftTimestep ?? baselineTimestep,
                descriptionValue: draftDescription ?? baselineDescription, images: draftImages,
                windowModeValue: draftWindowMode ?? baselineWindowMode,
                windowStartValue: draftWindowStart ?? baselineWindowStart,
                windowEndValue: draftWindowEnd ?? baselineWindowEnd,
                sourceStateValue: sourceStateValue))
    }
}

@Suite(.serialized)
struct PlanContextRefreshTests {
    @Test @MainActor
    func refreshAdoptsInheritedValuesAndPreservesAliasRawDraftAndImageDraft() async throws {
        let originalImage = PlanContextRefreshFixture.image("source-image")
        let localImage = PlanContextRefreshFixture.image("local-image")
        let provider = ControlledPlanContextProvider()
        provider.loadSnapshots = [PlanContextRefreshFixture.snapshot(images: [originalImage])]
        let session = ModelEditorSession(provider: provider)
        await session.load(PlanContextRefreshFixture.asset, kind: .plan)

        let exactDraft = "  Plan notes 🌊  "
        session.set(PlanContextRefreshFixture.timestep, "0004")
        session.set(PlanContextRefreshFixture.description, exactDraft)
        session.addImage(PlanContextRefreshFixture.embeddedImages, image: localImage)
        let refresh = Task { await session.refreshProjectContext() }

        #expect(await waitUntil { provider.refreshRequests.count == 1 })
        let request = try #require(provider.refreshRequests.first)
        #expect(request.fields[PlanContextRefreshFixture.timestep] == "0004")
        #expect(request.fields[PlanContextRefreshFixture.description] == exactDraft)
        #expect(request.images[PlanContextRefreshFixture.embeddedImages]?.map(\.id) == [originalImage.id, localImage.id])

        let returnedImage = PlanContextRefreshFixture.image("backend-image")
        provider.finishRefresh(1, with: PlanContextRefreshFixture.context(
            baselineTimestep: "13.25", draftTimestep: "14.75",
            baselineDescription: "Inherited source description", draftDescription: "provider draft echo",
            baselineImages: [returnedImage], draftImages: [returnedImage]))

        #expect(await refresh.value)
        #expect(session.fields[PlanContextRefreshFixture.timestep] == "0004")
        #expect(session.fields[PlanContextRefreshFixture.description] == exactDraft)
        #expect(session.fields[PlanContextRefreshFixture.descriptionAlias] == exactDraft)
        #expect(session.images[PlanContextRefreshFixture.embeddedImages]?.map(\.id) == [originalImage.id, localImage.id])
        #expect(session.modified)
    }

    @Test @MainActor
    func discardRestoresTheRefreshedBaselineRatherThanTheRefreshedDraft() async throws {
        let originalImage = PlanContextRefreshFixture.image("old-source-image")
        let localImage = PlanContextRefreshFixture.image("local-image")
        let refreshedImage = PlanContextRefreshFixture.image("refreshed-source-image")
        let provider = ControlledPlanContextProvider()
        provider.loadSnapshots = [PlanContextRefreshFixture.snapshot(images: [originalImage])]
        let session = ModelEditorSession(provider: provider)
        await session.load(PlanContextRefreshFixture.asset, kind: .plan)
        session.set(PlanContextRefreshFixture.description, "local draft before association refresh")
        session.addImage(PlanContextRefreshFixture.embeddedImages, image: localImage)
        session.set(PlanContextRefreshFixture.windowFields.mode, "Plan")
        session.set(PlanContextRefreshFixture.windowFields.start, "custom start before refresh")
        session.set(PlanContextRefreshFixture.windowFields.end, "custom end before refresh")

        let refresh = Task { await session.refreshProjectContext() }
        #expect(await waitUntil { provider.refreshRequests.count == 1 })
        provider.finishRefresh(1, with: PlanContextRefreshFixture.context(
            baselineTimestep: "14.0", draftTimestep: "14.0",
            baselineDescription: "New source baseline", draftDescription: "local draft before association refresh",
            baselineImages: [refreshedImage], draftImages: [originalImage, localImage],
            baselineWindowMode: "BoundaryCondition", baselineWindowStart: "new inherited start", baselineWindowEnd: "new inherited end",
            draftWindowMode: "Plan", draftWindowStart: "custom start before refresh", draftWindowEnd: "custom end before refresh"))
        #expect(await refresh.value)
        #expect(session.fields[PlanContextRefreshFixture.description] == "local draft before association refresh")
        #expect(session.fields[PlanContextRefreshFixture.windowFields.mode] == "Plan")
        #expect(session.fields[PlanContextRefreshFixture.windowFields.start] == "custom start before refresh")
        #expect(session.images[PlanContextRefreshFixture.embeddedImages]?.map(\.id) == [originalImage.id, localImage.id])

        session.discardEdits()

        #expect(session.fields[PlanContextRefreshFixture.timestep] == "14.0")
        #expect(session.fields[PlanContextRefreshFixture.description] == "New source baseline")
        #expect(session.fields[PlanContextRefreshFixture.descriptionAlias] == "New source baseline")
        #expect(session.fields[PlanContextRefreshFixture.windowFields.mode] == "BoundaryCondition")
        #expect(session.fields[PlanContextRefreshFixture.windowFields.start] == "new inherited start")
        #expect(session.fields[PlanContextRefreshFixture.windowFields.end] == "new inherited end")
        #expect(session.images[PlanContextRefreshFixture.embeddedImages]?.map(\.id) == [refreshedImage.id])
        #expect(!session.modified)
    }

    @Test @MainActor
    func associationRefreshCoalescesAndDoesNotMarkACleanPlanModified() async throws {
        let provider = ControlledPlanContextProvider()
        let fixture = try makeWorkspace(provider: provider, name: "Clean Plan Refresh")
        defer { cleanup(fixture) }
        let session = ModelEditorSession(provider: provider)
        fixture.store.registerEditor(session)
        await session.load(fixture.asset, kind: .plan)

        fixture.store.setAssociation(fixture.association, field: "Geometry", value: "Geometry A")
        fixture.store.setAssociation(fixture.association, field: "BoundaryCondition", value: "Boundary A")
        #expect(fixture.store.isModified)
        #expect(!session.modified)

        #expect(await waitUntil { provider.refreshRequests.count == 1 })
        try await Task.sleep(for: .milliseconds(150))
        #expect(provider.refreshRequests.count == 1)
        #expect(provider.refreshRequests[0].fields.isEmpty)

        provider.finishRefresh(1, with: PlanContextRefreshFixture.context(
            baselineTimestep: "15.0", baselineDescription: "Association-only baseline"))
        #expect(await waitUntil { session.fields[PlanContextRefreshFixture.timestep] == "15.0" && !session.isRefreshingContext })
        #expect(!session.modified)
    }

    @Test @MainActor
    func orderedWindowEventsCoalesceOnlyAdjacentSameFieldEditsAndRetryUnacknowledgedPrefix() async throws {
        let provider = ControlledPlanContextProvider()
        provider.loadSnapshots = [PlanContextRefreshFixture.snapshot()]
        let session = ModelEditorSession(provider: provider)
        await session.load(PlanContextRefreshFixture.asset, kind: .plan)

        session.set(PlanContextRefreshFixture.windowFields.mode, "Plan")
        session.set(PlanContextRefreshFixture.windowFields.start, "first start")
        session.set(PlanContextRefreshFixture.windowFields.start, "coalesced start")
        session.set(PlanContextRefreshFixture.windowFields.end, "custom end")
        session.set(PlanContextRefreshFixture.windowFields.start, "later start")

        let refresh = Task { await session.refreshProjectContext() }
        #expect(await waitUntil { provider.refreshRequests.count == 1 })
        let firstRequest = try #require(provider.refreshRequests.first)
        #expect(firstRequest.fields[PlanContextRefreshFixture.windowFields.mode] == nil)
        #expect(firstRequest.fields[PlanContextRefreshFixture.windowFields.start] == nil)
        #expect(firstRequest.fields[PlanContextRefreshFixture.windowFields.end] == nil)
        #expect(firstRequest.planTimeWindowEdits.map(\.fieldID) == [
            PlanContextRefreshFixture.windowFields.mode,
            PlanContextRefreshFixture.windowFields.start,
            PlanContextRefreshFixture.windowFields.end,
            PlanContextRefreshFixture.windowFields.start
        ])
        #expect(firstRequest.planTimeWindowEdits.map(\.value) == ["Plan", "coalesced start", "custom end", "later start"])

        session.set(PlanContextRefreshFixture.windowFields.start, "typed during refresh")
        provider.finishRefresh(1, with: PlanContextRefreshFixture.context(
            baselineTimestep: "12.5", baselineDescription: "Saved plan description",
            draftWindowMode: "Plan", draftWindowStart: "stale window response", draftWindowEnd: "stale end"))
        #expect(!(await refresh.value))

        #expect(await waitUntil { provider.refreshRequests.count == 2 })
        let retry = try #require(provider.refreshRequests.last)
        #expect(retry.planTimeWindowEdits.map(\.value) == ["Plan", "coalesced start", "custom end", "later start", "typed during refresh"])
        #expect(Array(retry.planTimeWindowEdits.prefix(firstRequest.planTimeWindowEdits.count)).map(\.id) == firstRequest.planTimeWindowEdits.map(\.id))
        #expect(retry.fields[PlanContextRefreshFixture.windowFields.start] == nil)

        provider.finishRefresh(2, with: PlanContextRefreshFixture.context(
            baselineTimestep: "12.5", baselineDescription: "Saved plan description",
            draftWindowMode: "Plan", draftWindowStart: "canonical returned start", draftWindowEnd: "canonical returned end"))
        #expect(await waitUntil { session.fields[PlanContextRefreshFixture.windowFields.start] == "canonical returned start" && !session.isRefreshingContext })
        #expect(session.fields[PlanContextRefreshFixture.windowFields.end] == "canonical returned end")
        #expect(session.modified)

        session.set(PlanContextRefreshFixture.windowFields.mode, "BoundaryCondition")
        let nextRefresh = Task { await session.refreshProjectContext() }
        #expect(await waitUntil { provider.refreshRequests.count == 3 })
        #expect(provider.refreshRequests[2].planTimeWindowEdits.map(\.fieldID) == [PlanContextRefreshFixture.windowFields.mode])
        provider.finishRefresh(3, with: PlanContextRefreshFixture.context(
            baselineTimestep: "12.5", baselineDescription: "Saved plan description",
            baselineWindowMode: "Plan", baselineWindowStart: "canonical returned start", baselineWindowEnd: "canonical returned end",
            draftWindowMode: "BoundaryCondition", draftWindowStart: "inherited start", draftWindowEnd: "inherited end"))
        #expect(await nextRefresh.value)
        #expect(session.fields[PlanContextRefreshFixture.windowFields.mode] == "BoundaryCondition")
        #expect(session.fields[PlanContextRefreshFixture.windowFields.start] == "inherited start")
        #expect(session.modified)
    }

    @Test @MainActor
    func saveAcknowledgesOnlyCapturedWindowEventsWhenNewInputArrivesDuringSave() async throws {
        let provider = ControlledPlanContextProvider()
        provider.loadSnapshots = [PlanContextRefreshFixture.snapshot(windowModeValue: "Plan")]
        let session = ModelEditorSession(provider: provider)
        await session.load(PlanContextRefreshFixture.asset, kind: .plan)

        session.set(PlanContextRefreshFixture.windowFields.start, "captured start")
        let firstSave = Task { await session.saveLoadedModel() }
        #expect(await waitUntil { provider.saveRequests.count == 1 })
        #expect(provider.saveRequests[0].planTimeWindowEdits.map(\.value) == ["captured start"])

        session.set(PlanContextRefreshFixture.windowFields.start, "newer start")
        provider.finishSave(1, with: PlanContextRefreshFixture.snapshot(
            windowModeValue: "Plan", windowStartValue: "captured start", windowEndValue: "saved end",
            sourceStateValue: "state-after-captured-save"))
        #expect(!(await firstSave.value))
        #expect(session.fields[PlanContextRefreshFixture.windowFields.start] == "newer start")
        #expect(session.modified)

        let secondSave = Task { await session.saveLoadedModel() }
        #expect(await waitUntil { provider.saveRequests.count == 2 })
        #expect(provider.saveRequests[1].planTimeWindowEdits.map(\.value) == ["newer start"])
        provider.finishSave(2, with: PlanContextRefreshFixture.snapshot(
            windowModeValue: "Plan", windowStartValue: "newer start", windowEndValue: "saved end",
            sourceStateValue: "state-after-newer-save"))
        #expect(await secondSave.value)
        #expect(!session.modified)
        #expect(session.fields[PlanContextRefreshFixture.windowFields.start] == "newer start")
    }

    @Test @MainActor
    func overlappingRefreshAndSaveKeepSharedEventPrefixProtectedUntilBothFinish() async throws {
        let provider = ControlledPlanContextProvider()
        provider.loadSnapshots = [PlanContextRefreshFixture.snapshot()]
        let session = ModelEditorSession(provider: provider)
        await session.load(PlanContextRefreshFixture.asset, kind: .plan)

        session.set(PlanContextRefreshFixture.windowFields.mode, "Plan")
        session.set(PlanContextRefreshFixture.windowFields.start, "captured start")
        let oldRefresh = Task { await session.refreshProjectContext() }
        #expect(await waitUntil { provider.refreshRequests.count == 1 })
        provider.refreshEnabled = false

        let save = Task { await session.saveLoadedModel() }
        #expect(await waitUntil { provider.saveRequests.count == 1 })
        #expect(provider.saveRequests[0].planTimeWindowEdits.map(\.value) == ["Plan", "captured start"])

        provider.finishRefresh(1, with: PlanContextRefreshFixture.context(
            baselineTimestep: "12.5", baselineDescription: "Saved plan description",
            draftWindowMode: "Plan", draftWindowStart: "captured start", draftWindowEnd: "existing end"))
        #expect(!(await oldRefresh.value))

        session.set(PlanContextRefreshFixture.windowFields.start, "newer start")
        provider.finishSave(1, with: PlanContextRefreshFixture.snapshot(
            windowModeValue: "Plan", windowStartValue: "captured start", windowEndValue: "saved end",
            sourceStateValue: "state-after-captured-save"))
        #expect(!(await save.value))
        #expect(session.fields[PlanContextRefreshFixture.windowFields.start] == "newer start")
        #expect(session.modified)

        let secondSave = Task { await session.saveLoadedModel() }
        #expect(await waitUntil { provider.saveRequests.count == 2 })
        #expect(provider.saveRequests[1].planTimeWindowEdits.map(\.value) == ["newer start"])
        provider.finishSave(2, with: PlanContextRefreshFixture.snapshot(
            windowModeValue: "Plan", windowStartValue: "newer start", windowEndValue: "saved end",
            sourceStateValue: "state-after-newer-save"))
        #expect(await secondSave.value)
        #expect(!session.modified)

        provider.refreshEnabled = true
        await session.load(PlanContextRefreshFixture.asset, kind: .plan)
        #expect(!session.modified)
    }

    @Test @MainActor
    func lateRefreshCannotOverwriteTypingAndTheNewerRequestCanStillApply() async throws {
        let provider = ControlledPlanContextProvider()
        provider.loadSnapshots = [PlanContextRefreshFixture.snapshot()]
        let session = ModelEditorSession(provider: provider)
        await session.load(PlanContextRefreshFixture.asset, kind: .plan)

        let refresh = Task { await session.refreshProjectContext() }
        #expect(await waitUntil { provider.refreshRequests.count == 1 })
        let exactDraft = "  typed while refresh is running  "
        session.set(PlanContextRefreshFixture.description, exactDraft)
        provider.finishRefresh(1, with: PlanContextRefreshFixture.context(
            baselineTimestep: "88.0", baselineDescription: "stale response", draftDescription: "stale response"))

        #expect(!(await refresh.value))
        #expect(session.fields[PlanContextRefreshFixture.timestep] == "12.5")
        #expect(session.fields[PlanContextRefreshFixture.description] == exactDraft)
        #expect(session.fields[PlanContextRefreshFixture.descriptionAlias] == exactDraft)

        #expect(await waitUntil { provider.refreshRequests.count == 2 })
        provider.finishRefresh(2, with: PlanContextRefreshFixture.context(
            baselineTimestep: "16.0", baselineDescription: "new baseline", draftDescription: "new draft echo"))
        #expect(await waitUntil { session.fields[PlanContextRefreshFixture.timestep] == "16.0" && !session.isRefreshingContext })
        #expect(session.fields[PlanContextRefreshFixture.description] == exactDraft)
        #expect(session.fields[PlanContextRefreshFixture.descriptionAlias] == exactDraft)
    }

    @Test @MainActor
    func loadInvalidatesAnOutstandingContextRefresh() async throws {
        let provider = ControlledPlanContextProvider()
        provider.loadSnapshots = [
            PlanContextRefreshFixture.snapshot(timestepValue: "12.5", descriptionValue: "before reload"),
            PlanContextRefreshFixture.snapshot(timestepValue: "21.0", descriptionValue: "reloaded baseline")
        ]
        let session = ModelEditorSession(provider: provider)
        await session.load(PlanContextRefreshFixture.asset, kind: .plan)

        let refresh = Task { await session.refreshProjectContext() }
        #expect(await waitUntil { provider.refreshRequests.count == 1 })
        await session.load(PlanContextRefreshFixture.asset, kind: .plan)
        #expect(session.fields[PlanContextRefreshFixture.timestep] == "21.0")

        provider.finishRefresh(1, with: PlanContextRefreshFixture.context(
            baselineTimestep: "88.0", baselineDescription: "stale after reload"))

        #expect(!(await refresh.value))
        #expect(session.fields[PlanContextRefreshFixture.timestep] == "21.0")
        #expect(session.fields[PlanContextRefreshFixture.description] == "reloaded baseline")
    }

    @Test @MainActor
    func discardInvalidatesTheOldResponseAndRetriesThePendingAssociationRefresh() async throws {
        let provider = ControlledPlanContextProvider()
        provider.loadSnapshots = [PlanContextRefreshFixture.snapshot()]
        let session = ModelEditorSession(provider: provider)
        await session.load(PlanContextRefreshFixture.asset, kind: .plan)
        session.set(PlanContextRefreshFixture.description, "draft to discard")

        let refresh = Task { await session.refreshProjectContext() }
        #expect(await waitUntil { provider.refreshRequests.count == 1 })
        session.discardEdits()
        #expect(session.fields[PlanContextRefreshFixture.description] == "Saved plan description")
        #expect(!session.modified)
        provider.finishRefresh(1, with: PlanContextRefreshFixture.context(
            baselineTimestep: "88.0", baselineDescription: "stale response after discard"))

        #expect(!(await refresh.value))
        #expect(session.fields[PlanContextRefreshFixture.timestep] == "12.5")
        #expect(session.fields[PlanContextRefreshFixture.description] == "Saved plan description")
        #expect(await waitUntil { provider.refreshRequests.count == 2 })

        provider.finishRefresh(2, with: PlanContextRefreshFixture.context(
            baselineTimestep: "17.0", baselineDescription: "association after discard"))
        #expect(await waitUntil { session.fields[PlanContextRefreshFixture.timestep] == "17.0" && !session.isRefreshingContext })
        #expect(session.fields[PlanContextRefreshFixture.description] == "association after discard")
        #expect(!session.modified)
    }

    @Test @MainActor
    func saveRejectsTheOldResponseAndProcessesAssociationChangesAfterward() async throws {
        let provider = ControlledPlanContextProvider()
        let fixture = try makeWorkspace(provider: provider, name: "Save During Plan Refresh")
        defer { cleanup(fixture) }
        let session = ModelEditorSession(provider: provider)
        fixture.store.registerEditor(session)
        await session.load(fixture.asset, kind: .plan)
        session.set(PlanContextRefreshFixture.description, "saved user draft")

        let refresh = Task { await session.refreshProjectContext() }
        #expect(await waitUntil { provider.refreshRequests.count == 1 })
        let save = Task { await session.saveLoadedModel() }
        #expect(await waitUntil { provider.saveRequests.count == 1 })
        #expect(session.isSaving)

        fixture.store.setAssociation(fixture.association, field: "Geometry", value: "Geometry During Save")
        try await Task.sleep(for: .milliseconds(150))
        #expect(provider.refreshRequests.count == 1)

        provider.finishRefresh(1, with: PlanContextRefreshFixture.context(
            baselineTimestep: "88.0", baselineDescription: "stale while saving"))
        #expect(!(await refresh.value))
        #expect(session.fields[PlanContextRefreshFixture.timestep] == "12.5")
        #expect(session.fields[PlanContextRefreshFixture.description] == "saved user draft")
        #expect(session.isSaving)

        provider.finishSave(1, with: PlanContextRefreshFixture.snapshot(descriptionValue: "saved user draft"))
        #expect(await save.value)
        #expect(!session.modified)
        #expect(provider.saveRequests[0].fields[PlanContextRefreshFixture.description] == "saved user draft")
        #expect(await waitUntil { provider.refreshRequests.count == 2 })
        #expect(provider.refreshRequests[1].fields.isEmpty)

        provider.finishRefresh(2, with: PlanContextRefreshFixture.context(
            baselineTimestep: "18.0", baselineDescription: "saved user draft"))
        #expect(await waitUntil { session.fields[PlanContextRefreshFixture.timestep] == "18.0" && !session.isRefreshingContext })
        #expect(session.fields[PlanContextRefreshFixture.description] == "saved user draft")
        #expect(!session.modified)
    }

    @MainActor
    private func makeWorkspace(provider: ControlledPlanContextProvider, name: String) throws -> (
        store: WorkspaceStore,
        root: URL,
        defaults: UserDefaults,
        suiteName: String,
        asset: ProjectAsset,
        association: ProjectAssociation
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plan-context-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suiteName = "PlanContextRefreshTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let history = RecentProjectHistoryStore(defaults: defaults)
        let store = WorkspaceStore(modelProvider: provider, recentHistoryStore: history)
        store.createProject(name: name, units: "SI", description: "", directory: root, projectionType: "Local", projectionValue: "SI")

        let document = try #require(store.document, "WorkspaceStore.createProject did not install the new project.")
        let projectDirectory = try #require(document.directory, "The installed project has no containing directory.")
        let planURL = projectDirectory.appendingPathComponent("Plans", isDirectory: true)
            .appendingPathComponent(name + " A.h5")
        try Data().write(to: planURL)
        store.refreshAssets()
        let planAssets = store.assets.filter { $0.section == .plans }
        let asset = try #require(planAssets.first { $0.name == planURL.deletingPathExtension().lastPathComponent },
            "Plan file was not catalogued. Project directory: \(projectDirectory.path); expected file: \(planURL.path); file exists: \(FileManager.default.fileExists(atPath: planURL.path)); scanned plan URLs: \(planAssets.map(\.url.path))")
        let expectedPath = planURL.standardizedFileURL.resolvingSymlinksInPath()
        let cataloguedPath = asset.url.standardizedFileURL.resolvingSymlinksInPath()
        #expect(cataloguedPath == expectedPath,
            "The catalogue returned a different plan path. Expected \(expectedPath.path), got \(cataloguedPath.path).")
        let association = try #require(document.associationRows(group: "PlanAssociations").first { $0.name == asset.name })
        return (store, root, defaults, suiteName, asset, association)
    }

    @MainActor
    private func cleanup(_ fixture: (
        store: WorkspaceStore,
        root: URL,
        defaults: UserDefaults,
        suiteName: String,
        asset: ProjectAsset,
        association: ProjectAssociation
    )) {
        fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        try? FileManager.default.removeItem(at: fixture.root)
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}
