import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct DateTimeInputTests {
    @Test func validatesTheSourceSegmentFormatsAndRejectsIncompleteDrafts() {
        #expect(OriginalDateTimeDraftCodec.parseDate("2026-02-28") != nil)
        #expect(OriginalDateTimeDraftCodec.parseDate("2026-02-29") == nil)
        #expect(OriginalDateTimeDraftCodec.parseDate("2026-2-08") != nil)
        #expect(OriginalDateTimeDraftCodec.parseDate("2026-") == nil)
        #expect(OriginalDateTimeDraftCodec.parseTime("23:59:58")?.second == 58)
        #expect(OriginalDateTimeDraftCodec.parseTime("24:00:00")?.hour == 0)
        #expect(OriginalDateTimeDraftCodec.parseTime("12:3")?.hour == 12)
        #expect(OriginalDateTimeDraftCodec.combine(dateText: "2026-04-02", timeText: "03:04:05") != nil)
        #expect(OriginalDateTimeDraftCodec.combine(dateText: "2026-04-02", timeText: "03:04:") == nil)
    }

    @Test func editingKeepsSecondPrecisionAndDropsUnsupportedFractionalSeconds() throws {
        let source = try #require(OriginalDateTimeDraftCodec.parseStoredValue("2026-04-02T03:04:05.987Z"))
        let parts = OriginalDateTimeDraftCodec.displayParts(of: source)
        #expect(parts.time.hasSuffix(":05"))
        #expect(OriginalDateTimeDraftCodec.parseTime(parts.time)?.second == 5)

        let edited = try #require(OriginalDateTimeDraftCodec.combine(dateText: parts.date, timeText: parts.time))
        let serialized = OriginalDateTimeDraftCodec.serializeStoredValue(edited, dateOnly: false)
        #expect(OriginalDateTimeDraftCodec.parseStoredValue(serialized) == edited)
        #expect(!serialized.contains(".987"))
    }

    @Test func editedSegmentsPreserveStoredSeparatorAndOffsetWhileSourceSetterZerosFractions() throws {
        let source = "2026-04-02 03:04:05.1234567+05:30"
        let dateEdited = try #require(OriginalPropertyDateTimeStorage.replacingDate("2026-04-03", in: source))
        #expect(dateEdited == "2026-04-03 03:04:05.0000000+05:30")

        // DateTimeInputBox's combined setter explicitly strips subsecond
        // ticks; the reusable storage helper also supports preserving them.
        let timeEdited = try #require(OriginalPropertyDateTimeStorage.replacing(
            dateText: "2026-04-02", timeText: "06:07:08",
            dateTouched: false, timeTouched: true, in: source,
            resetSubsecondPrecision: true))
        #expect(timeEdited == "2026-04-02 06:07:08.0000000+05:30")
    }

    @Test func businessRulesComeOnlyFromTheSourceHostAndExactPeerRoutes() throws {
        let planSchema = try #require(SourceEditorLibrary.shared.schema("PlanSettingsPage"))
        let start = try #require(planSchema.fields.first { $0.id == "ViewModel_SelectedPlan_ComputeStartTime" })
        let end = try #require(planSchema.fields.first { $0.id == "ViewModel_SelectedPlan_ComputeEndTime" })
        #expect(OriginalDateTimeBusinessValidator.rule(for: start) == .timeWindowStart(peerFieldID: start.scoped("ViewModel_SelectedPlan_ComputeEndTime")))
        #expect(OriginalDateTimeBusinessValidator.rule(for: end) == .timeWindowEnd(peerFieldID: end.scoped("ViewModel_SelectedPlan_ComputeStartTime")))

        let regularSchema = try #require(SourceEditorLibrary.shared.schema("RegularTimeSeriesPayloadEditor"))
        let fixedStart = try #require(regularSchema.fields.first { $0.id == "TimeSeriesDefinition_FixedStartTime" })
        #expect(OriginalDateTimeBusinessValidator.rule(for: fixedStart) == .fixedStartNotAfterBoundary(
            peerFieldID: fixedStart.scoped("BoundaryConditionLine_BoundaryCondition_StartTime")
        ))
        let spatialSchema = try #require(SourceEditorLibrary.shared.schema("RegularSpatiallyVariableTimeSeriesPayloadEditor"))
        let spatialFixedStart = try #require(spatialSchema.fields.first { $0.id == "TimeSeriesDefinition_FixedStartTime" })
        #expect(OriginalDateTimeBusinessValidator.rule(for: spatialFixedStart) == .fixedStartNotAfterBoundary(
            peerFieldID: spatialFixedStart.scoped("BoundaryConditionLine_BoundaryCondition_StartTime")
        ))

        let unrelated = try #require(regularSchema.fields.first { $0.id == "BoundaryConditionLine_ActualStartTime" })
        #expect(OriginalDateTimeBusinessValidator.rule(for: unrelated) == nil)
    }

    @Test func timeWindowWarningsAndFixedStartErrorsMatchTheSourceDelegate() throws {
        let startDate = Date(timeIntervalSince1970: 100)
        let endDate = Date(timeIntervalSince1970: 200)
        let startRule = OriginalDateTimeBusinessRule.timeWindowStart(peerFieldID: "window/end")
        let endRule = OriginalDateTimeBusinessRule.timeWindowEnd(peerFieldID: "window/start")
        #expect(OriginalDateTimeBusinessValidator.evaluate(startRule, candidate: endDate, peer: .value(endDate)) == .warning("Time window cannot start when it ends."))
        #expect(OriginalDateTimeBusinessValidator.evaluate(startRule, candidate: endDate, peer: .value(startDate)) == .warning("Time window cannot begin after it ends."))
        #expect(OriginalDateTimeBusinessValidator.evaluate(startRule, candidate: startDate, peer: .value(endDate)) == .accepted)
        #expect(OriginalDateTimeBusinessValidator.evaluate(endRule, candidate: startDate, peer: .value(startDate)) == .warning("Time window cannot end when it starts."))
        #expect(OriginalDateTimeBusinessValidator.evaluate(endRule, candidate: startDate, peer: .value(endDate)) == .warning("Time window cannot end before it begins."))
        #expect(OriginalDateTimeBusinessValidator.evaluate(endRule, candidate: endDate, peer: .value(startDate)) == .accepted)

        let fixedStartRule = OriginalDateTimeBusinessRule.fixedStartNotAfterBoundary(peerFieldID: "payload/boundary-start")
        #expect(OriginalDateTimeBusinessValidator.evaluate(fixedStartRule, candidate: startDate, peer: .value(startDate)) == .accepted)
        #expect(OriginalDateTimeBusinessValidator.evaluate(fixedStartRule, candidate: endDate, peer: .missing) == .accepted)
        #expect(OriginalDateTimeBusinessValidator.evaluate(fixedStartRule, candidate: endDate, peer: .pendingInput) == .deferred(
            key: OriginalDateTimeInputIssue.relatedInputIncomplete
        ))
        let rejected = OriginalDateTimeBusinessValidator.evaluate(fixedStartRule, candidate: endDate, peer: .value(startDate))
        guard case .rejected(let key, let argument) = rejected else {
            Issue.record("A fixed start later than its boundary start must be rejected.")
            return
        }
        #expect(key == OriginalDateTimeInputIssue.startsAfterBoundaryTemplate)
        #expect(argument != nil)
    }

    @Test func completeWindowPeerDraftBreaksMutualPendingCycleWithoutUsingStaleValues() throws {
        let originalStart = "2025-08-10T10:00:00Z"
        let originalEnd = "2025-08-10T11:00:00Z"
        let startRule = OriginalDateTimeBusinessRule.timeWindowStart(peerFieldID: "window/end")
        let endRule = OriginalDateTimeBusinessRule.timeWindowEnd(peerFieldID: "window/start")
        let incompleteStart = OriginalDateTimeInputDraft(
            sourceValue: originalStart,
            dateText: "2025-08-10",
            timeText: "12:00:",
            dateTouched: true,
            timeTouched: true,
            issueKey: "Improperly formatted time."
        )
        let completeEndCandidate = OriginalDateTimeInputDraft(
            sourceValue: originalEnd,
            dateText: "2025-08-10",
            timeText: "13:00:00",
            dateTouched: true,
            timeTouched: true,
            issueKey: OriginalDateTimeInputIssue.relatedInputIncomplete
        )

        let staleEndPeer = OriginalDateTimeBusinessValidator.peerValue(
            for: endRule,
            sourceValue: originalStart,
            pendingInput: incompleteStart
        )
        #expect(staleEndPeer == .pendingInput)
        let endCandidate = try #require(OriginalDateTimeDraftCodec.combine(dateText: completeEndCandidate.dateText, timeText: completeEndCandidate.timeText))
        #expect(OriginalDateTimeBusinessValidator.evaluate(endRule, candidate: endCandidate, peer: staleEndPeer) == .deferred(
            key: OriginalDateTimeInputIssue.relatedInputIncomplete
        ))

        let completeStartCandidate = try #require(OriginalDateTimeDraftCodec.combine(dateText: "2025-08-10", timeText: "12:00:00"))
        let currentEndPeer = OriginalDateTimeBusinessValidator.peerValue(
            for: startRule,
            sourceValue: originalEnd,
            pendingInput: completeEndCandidate
        )
        guard case .value(let parsedEndCandidate) = currentEndPeer else {
            Issue.record("A complete, same-baseline endpoint draft should be available to its time-window peer.")
            return
        }
        #expect(parsedEndCandidate == endCandidate)
        #expect(OriginalDateTimeBusinessValidator.evaluate(startRule, candidate: completeStartCandidate, peer: currentEndPeer) == .accepted)

        let committedStart = OriginalDateTimeDraftCodec.serializeStoredValue(completeStartCandidate, dateOnly: false)
        let endAfterStartCommits = OriginalDateTimeBusinessValidator.peerValue(
            for: endRule,
            sourceValue: committedStart,
            pendingInput: nil
        )
        #expect(OriginalDateTimeBusinessValidator.evaluate(endRule, candidate: endCandidate, peer: endAfterStartCommits) == .accepted)

        let staleBaseline = OriginalDateTimeBusinessValidator.peerValue(
            for: startRule,
            sourceValue: "2025-08-10T14:00:00Z",
            pendingInput: completeEndCandidate
        )
        let updatedEnd = try #require(OriginalDateTimeDraftCodec.parseStoredValue("2025-08-10T14:00:00Z"))
        #expect(staleBaseline == .value(updatedEnd))
        let fixedStartRule = OriginalDateTimeBusinessRule.fixedStartNotAfterBoundary(peerFieldID: "payload/boundary-start")
        #expect(OriginalDateTimeBusinessValidator.peerValue(
            for: fixedStartRule,
            sourceValue: originalEnd,
            pendingInput: completeEndCandidate
        ) == .pendingInput)
    }

    @Test func dateTimeDraftCarriesBusinessIssueArgumentWithoutChangingItsSourceBaseline() throws {
        let original = "2025-08-10T11:12:13Z"
        let draft = OriginalDateTimeInputDraft(
            sourceValue: original,
            dateText: "2025-08-10",
            timeText: "12:12:13",
            dateTouched: true,
            timeTouched: true,
            issueKey: OriginalDateTimeInputIssue.startsAfterBoundaryTemplate,
            issueArgument: "8/10/2025, 11:12:13 AM"
        )
        let roundTripped = try JSONDecoder().decode(OriginalDateTimeInputDraft.self, from: JSONEncoder().encode(draft))
        #expect(roundTripped == draft)
        #expect(roundTripped.sourceValue == original)
    }

    @Test @MainActor
    func incompleteInputSurvivesEditorReentryBlocksSaveAndClearsOnDiscardOrReload() async throws {
        let provider = DateTimeDraftProvider()
        let session = ModelEditorSession(provider: provider)
        await session.load(DateTimeDraftProvider.asset, kind: .plan)
        let fieldID = DateTimeDraftProvider.startTimeField
        let original = try #require(session.fields[fieldID])
        let partial = OriginalDateTimeInputDraft(
            sourceValue: original,
            dateText: "2026-04-",
            timeText: "03:04:05",
            dateTouched: true,
            timeTouched: false,
            issueKey: "Improperly formatted date."
        )

        session.setDateTimeInputDraft(partial, for: fieldID)
        #expect(session.hasIncompleteDateTimeInput)
        #expect(session.dateTimeInputDraft(for: fieldID, sourceValue: original) == partial)
        #expect(!(await session.saveLoadedModel()))
        #expect(provider.saveCount == 0)

        session.discardEdits()
        #expect(!session.hasIncompleteDateTimeInput)
        #expect(session.fields[fieldID] == original)

        session.setDateTimeInputDraft(partial, for: fieldID)
        await session.load(DateTimeDraftProvider.asset, kind: .plan)
        #expect(!session.hasIncompleteDateTimeInput)
        #expect(session.dateTimeInputDrafts.isEmpty)
        #expect(provider.saveCount == 0)
    }

    @Test @MainActor
    func rejectedBusinessCandidateRemainsOutsideFieldsAndBlocksSave() async throws {
        let schema = try #require(SourceEditorLibrary.shared.schema("RegularTimeSeriesPayloadEditor"))
        let field = try #require(schema.fields.first { $0.id == "TimeSeriesDefinition_FixedStartTime" })
        let boundary = try #require(schema.fields.first { $0.id == "BoundaryConditionLine_BoundaryCondition_StartTime" })
        let original = "2025-08-10T11:12:13Z"
        let session = ModelEditorSession()
        session.startDraft(.init(fields: [field.storageID: original, boundary.storageID: original], rows: [:], samples: [:], canEdit: true, images: [:]))

        let rejected = OriginalDateTimeInputDraft(
            sourceValue: original,
            dateText: "2025-08-10",
            timeText: "12:12:13",
            dateTouched: true,
            timeTouched: true,
            issueKey: OriginalDateTimeInputIssue.startsAfterBoundaryTemplate,
            issueArgument: "8/10/2025, 11:12:13 AM"
        )
        session.setDateTimeInputDraft(rejected, for: field.storageID)

        #expect(session.fields[field.storageID] == original)
        #expect(session.dateTimeInputDraft(for: field.storageID, sourceValue: original) == rejected)
        #expect(session.hasIncompleteDateTimeInput)
        #expect(!(await session.saveLoadedModel()))
    }

    @Test @MainActor
    func validPlanDateTimeEditsKeepTheSourceTimeWindowEventOrder() async throws {
        let provider = DateTimeDraftProvider()
        let session = ModelEditorSession(provider: provider)
        await session.load(DateTimeDraftProvider.asset, kind: .plan)

        let start = try #require(SourceEditorLibrary.shared.field(storageID: DateTimeDraftProvider.startTimeField))
        let end = try #require(SourceEditorLibrary.shared.field(storageID: DateTimeDraftProvider.endTimeField))
        let newStart = "2025-08-10T12:12:13Z"
        let newEnd = "2025-08-11T13:14:15Z"
        start.setDraftValue(newStart, in: session)
        end.setDraftValue(newEnd, in: session)

        #expect(await session.saveLoadedModel())
        #expect(provider.savedTimeWindowEdits.map(\.fieldID) == [
            DateTimeDraftProvider.startTimeField,
            DateTimeDraftProvider.endTimeField
        ])
        #expect(provider.savedTimeWindowEdits.map(\.value) == [newStart, newEnd])
    }

    @Test @MainActor
    func businessValidationDraftBlocksToolPrepareAndPerformWithoutReplacingTheSavedValue() {
        let fieldID = "PlanSettingsPage/ViewModel_SelectedPlan_ComputeStartTime"
        let savedValue = "2025-08-10T11:12:13Z"
        let editor = ModelEditorSession()
        editor.startDraft(.init(fields: [fieldID: savedValue], rows: [:], samples: [:], canEdit: true, images: [:]))
        let issue = OriginalDateTimeInputDraft(
            sourceValue: savedValue,
            dateText: "2025-08-10",
            timeText: "12:12:13",
            dateTouched: true,
            timeTouched: true,
            issueKey: OriginalDateTimeInputIssue.startsAfterBoundaryTemplate,
            issueArgument: "8/10/2025, 11:12:13 AM"
        )
        editor.setDateTimeInputDraft(issue, for: fieldID)

        let context = DataToolContext(projectSessionID: UUID(), mapID: UUID(), assetID: nil, extent: nil)
        let dataTool = DataToolSession()
        let request = dataTool.request(kind: .newPlan, editor: editor, context: context)
        let provider = DateTimeToolGuardProvider()

        #expect(request.fields[fieldID] == savedValue)
        #expect(request.inputIssue?.contains("%@") == false)
        #expect(request.inputIssue?.contains(issue.issueArgument ?? "") == true)
        #expect(dataTool.prepare(request, editor: editor, provider: provider, currentRequest: { request }) == nil)
        #expect(dataTool.perform(request, editor: editor, provider: provider, currentRequest: { request }) == nil)
        #expect(provider.prepareCount == 0)
        #expect(provider.performCount == 0)
    }
}

@MainActor
private final class DateTimeDraftProvider: ModelEditorProvider {
    static let asset = ProjectAsset(url: URL(fileURLWithPath: "/task-fixture/date-time-plan.h5"), section: .plans)
    static let startTimeField = "PlanSettingsPage/ViewModel_SelectedPlan_ComputeStartTime"
    static let endTimeField = "PlanSettingsPage/ViewModel_SelectedPlan_ComputeEndTime"
    static let modeField = "PlanSettingsPage/ViewModel_SelectedPlan_TimeWindowMode"
    private let startValue = "2025-08-10T11:12:13Z"
    private(set) var saveCount = 0
    private(set) var savedTimeWindowEdits: [PlanTimeWindowEdit] = []

    func load(_ asset: ProjectAsset, kind: ModelEditorKind) async throws -> EditorSnapshot {
        Self.snapshot(fields: [
            Self.startTimeField: startValue,
            Self.endTimeField: "2025-08-10T12:12:13Z",
            Self.modeField: "BoundaryCondition"
        ])
    }

    func save(_ asset: ProjectAsset, changes: EditorEdits) async throws {
        saveCount += 1
    }

    func saveModel(_ asset: ProjectAsset, changes: EditorEdits) async throws -> EditorSaveResult {
        saveCount += 1
        savedTimeWindowEdits = changes.planTimeWindowEdits
        var fields = [
            Self.startTimeField: startValue,
            Self.endTimeField: "2025-08-10T12:12:13Z",
            Self.modeField: "BoundaryCondition"
        ]
        for edit in changes.planTimeWindowEdits { fields[edit.fieldID] = edit.value }
        return EditorSaveResult(
            sourceRevision: "date-time-fixture-saved",
            snapshot: Self.snapshot(fields: fields)
        )
    }

    func perform(_ asset: ProjectAsset, action: EditorAction) async throws -> EditorSnapshot {
        throw CocoaError(.featureUnsupported)
    }

    private static func snapshot(fields: [String: String]) -> EditorSnapshot {
        EditorSnapshot(
            fields: fields,
            rows: [:], samples: [:], canEdit: true, images: [:],
            sourceRevision: "date-time-fixture-revision",
            planTimeWindowFieldIDs: .init(mode: modeField, start: startTimeField, end: endTimeField)
        )
    }
}

@MainActor
private final class DateTimeToolGuardProvider: ToolProvider {
    private(set) var prepareCount = 0
    private(set) var performCount = 0

    func execute(_ request: ToolRequest) async throws {}

    func prepare(_ request: ToolRequest) async throws -> DataToolPresentation {
        prepareCount += 1
        return DataToolPresentation()
    }

    func perform(_ request: ToolRequest) async throws -> DataToolPresentation {
        performCount += 1
        return DataToolPresentation()
    }
}
