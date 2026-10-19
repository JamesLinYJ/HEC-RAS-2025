import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendUnitCalculatorProviderTests {
    @Test
    func timeSpanContextualValuesKeep100NanosecondResolution() {
        #expect(SourceNumericValueNormalization.timeSpanTotalSeconds(0.0000001) == 0.0000001)
        #expect(SourceNumericValueNormalization.timeSpanTotalSeconds(0.00000001) == nil)
        #expect(SourceNumericValueNormalization.timeSpanTotalSeconds(0) == nil)
        #expect(SourceNumericValueNormalization.timeSpanTotalSeconds(-0.0000001) == nil)
    }

    @Test
    func contextualCommitTicketRejectsCancellationAndOwnerChanges() {
        let token = UUID()
        let presentationID = UUID()
        let ticket = UnitCalculatorCommitTicket(
            requestToken: token,
            ownerContextID: "session|field|raw|unit",
            presentationID: presentationID
        )

        #expect(ticket.isCurrent(
            requestToken: token,
            ownerContextID: "session|field|raw|unit",
            presentationID: presentationID,
            ownerCanCommit: true
        ))
        #expect(!ticket.isCurrent(
            requestToken: UUID(),
            ownerContextID: "session|field|raw|unit",
            presentationID: presentationID,
            ownerCanCommit: true
        ))
        #expect(!ticket.isCurrent(
            requestToken: token,
            ownerContextID: "different-session|field|raw|unit",
            presentationID: presentationID,
            ownerCanCommit: true
        ))
        #expect(!ticket.isCurrent(
            requestToken: token,
            ownerContextID: "session|field|raw|unit",
            presentationID: UUID(),
            ownerCanCommit: true
        ))
        #expect(!ticket.isCurrent(
            requestToken: token,
            ownerContextID: "session|field|raw|unit",
            presentationID: nil,
            ownerCanCommit: true
        ))
        #expect(!ticket.isCurrent(
            requestToken: token,
            ownerContextID: "session|field|raw|unit",
            presentationID: presentationID,
            ownerCanCommit: false
        ))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil))
    @MainActor
    func sourceBackedProviderAndDataToolDraftHandleBothDirectionsAndFamilyChanges() async throws {
        let executable = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"]))
        let provider = BackendToolProvider(client: BackendProcessClient(executableURL: executable))
        let state = DataToolSession()
        let editor = ModelEditorSession()
        let context = DataToolContext(projectSessionID: UUID(), mapID: UUID(), assetID: nil, extent: nil)
        let fromUnitKey = "UnitCalculator/FromSelectedUnit"
        let toUnitKey = "UnitCalculator/ToSelectedUnit"
        let fromInputKey = "UnitCalculator/FromInput"
        let toOutputKey = "UnitCalculator/ToOutput"

        let empty = try await provider.prepare(ToolRequest(
            kind: ToolKind.unitCalculator.id,
            fields: [fromUnitKey: "", toUnitKey: ""],
            inputFiles: [], destination: nil, images: [:], context: context, operation: .inspect
        ))
        #expect(empty.unitCalculator?.fromUnits.contains(where: { $0.unitTypeName == "Length" && $0.name == "ft" }) == true)
        #expect(empty.unitCalculator?.toUnits.isEmpty == true)
        #expect(empty.editor.fields[fromUnitKey] == "" && empty.editor.fields[toUnitKey] == "")

        let feet = try #require(empty.unitCalculator?.fromUnits.first(where: { $0.unitTypeName == "Length" && $0.name == "ft" }))
        let flow = try #require(empty.unitCalculator?.fromUnits.first(where: { $0.unitTypeName == "Flow" && $0.name == "cfs" }))
        let length = try await provider.prepare(ToolRequest(
            kind: ToolKind.unitCalculator.id,
            fields: [fromUnitKey: feet.id],
            inputFiles: [], destination: nil, images: [:], context: context, operation: .inspect
        ))
        let meter = try #require(length.unitCalculator?.toUnits.first(where: { $0.title == "m" }))
        let inch = try #require(length.unitCalculator?.toUnits.first(where: { $0.title == "in" }))

        editor.startDraft()
        editor.set(fromUnitKey, feet.id)
        editor.set(toUnitKey, meter.id)
        editor.set(fromInputKey, "1")
        editor.set(toOutputKey, "0")
        state.triggeringField = fromInputKey
        func request() -> ToolRequest {
            state.request(kind: .unitCalculator, editor: editor, context: context, operation: .calculate)
        }

        #expect(request().fields[fromUnitKey] == feet.id)
        await state.prepare(request(), editor: editor, provider: provider, currentRequest: request)?.value
        #expect(state.error == nil)
        #expect(abs((Double(editor.fields[toOutputKey] ?? "") ?? .nan) - 0.3048) < 1e-12)

        editor.set(toOutputKey, "1")
        state.triggeringField = toOutputKey
        await state.prepare(request(), editor: editor, provider: provider, currentRequest: request)?.value
        #expect(abs((Double(editor.fields[fromInputKey] ?? "") ?? .nan) - 3.280839895013123) < 1e-12)
        #expect(editor.fields[toOutputKey] == "1")

        editor.set(toUnitKey, inch.id)
        state.triggeringField = toUnitKey
        await state.prepare(request(), editor: editor, provider: provider, currentRequest: request)?.value
        #expect(editor.fields[toOutputKey] == "1")
        #expect(abs((Double(editor.fields[fromInputKey] ?? "") ?? .nan) - (1.0 / 12.0)) < 1e-12)

        editor.set(fromInputKey, "not a number")
        state.triggeringField = fromInputKey
        await state.prepare(request(), editor: editor, provider: provider, currentRequest: request)?.value
        #expect(editor.fields[fromInputKey] == "not a number")
        #expect(editor.fields[toOutputKey] == "1")

        editor.set(fromUnitKey, flow.id)
        state.triggeringField = fromUnitKey
        await state.prepare(request(), editor: editor, provider: provider, currentRequest: request)?.value
        #expect(state.error == nil)
        #expect(editor.fields[fromUnitKey] == flow.id)
        #expect(editor.fields[toUnitKey] == "")
        #expect(editor.fields[toOutputKey] == "1")
        #expect(state.presentation.unitCalculator?.toUnits.allSatisfy { $0.id.contains("Flow") } == true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil))
    @MainActor
    func contextualCalculatorLoadsTypedUnitIDsAndConvertsBothWaysWithoutEarlyDraftWrites() async throws {
        let executable = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"]))
        let provider = BackendUnitCalculatorProvider(client: BackendProcessClient(executableURL: executable))
        let context = DataToolContext(projectSessionID: UUID(), mapID: UUID(), assetID: nil, extent: nil)
        let inventory = try await provider.prepare(ToolRequest(
            kind: ToolKind.unitCalculator.id,
            fields: ["UnitCalculator/FromSelectedUnit": "", "UnitCalculator/ToSelectedUnit": ""],
            inputFiles: [], destination: nil, images: [:], context: context, operation: .inspect
        ))
        let feet = try #require(inventory.unitCalculator?.fromUnits.first { $0.unitTypeName == "Length" && $0.name == "ft" })
        let catalog = try await provider.loadUnits(fromUnitID: feet.id)
        let meters = try #require(catalog.toUnits.first { $0.title == "m" })

        #expect(catalog.fromUnitID == feet.id)
        #expect(catalog.toUnits.contains { $0.id == meters.id })
        let forward = try await provider.convert(value: 1, fromUnitID: feet.id, toUnitID: meters.id)
        #expect(abs(forward - 0.3048) < 1e-12)
        let reverse = try await provider.convert(
            value: forward,
            fromUnitID: feet.id,
            toUnitID: meters.id,
            direction: .toFrom
        )
        #expect(abs(reverse - 1) < 1e-12)

        // These provider conversions do not write to the scoped editor field.
        // The popover's Cancel action only dismisses; its Apply closure is the
        // only route that invokes the field binding.
        let editor = ModelEditorSession()
        editor.startDraft()
        let fieldID = "SpatialLayer/Input-1/Constant"
        editor.set(fieldID, "1.00")
        let original = try #require(editor.fields[fieldID])
        let displayValue = try await provider.convert(value: 1, fromUnitID: meters.id, toUnitID: feet.id)
        let convertedButNotApplied = String(displayValue)
        #expect(!convertedButNotApplied.isEmpty)
        #expect(editor.fields[fieldID] == original)

        let acceptedRaw = try await provider.convert(value: displayValue + 1, fromUnitID: feet.id, toUnitID: meters.id)
        editor.set(fieldID, String(acceptedRaw))
        #expect(editor.fields[fieldID] == String(acceptedRaw))
    }
}
