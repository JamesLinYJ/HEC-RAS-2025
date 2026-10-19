import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendWilcockWorkflowTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func bundledCalculatorDecodesSourceResultsAndResizesIndependentArraysImmediately() async throws {
        let session = try makeSession()
        #expect(await session.load())

        let initial = session.draft.state
        let initialRowCount = try #require(session.snapshot?.tables.first { $0.id == "state.grainDistributions" }?.rows.count)
        #expect(initialRowCount == max(initial.grainDiameter.count,
                                       max(initial.firstTransportCdfGrainSize.count, initial.secondTransportCdfGrainSize.count)))
        #expect(session.snapshot?.sbtmResults != nil)
        #expect(session.snapshot?.isbtmResults != nil)
        #expect(session.snapshot?.stabResults != nil)
        #expect(session.snapshot?.stateResults != nil)

        let firstCDFCount = initial.firstTransportCdfGrainSize.count
        let grainCount = initial.grainDiameter.count
        let secondCDFCount = initial.secondTransportCdfGrainSize.count
        #expect(session.appendInputRow(tableID: "state.grainDistributions", columnID: "firstCDF"))
        #expect(session.draft.state.firstTransportCdfGrainSize.count == firstCDFCount + 1)
        #expect(session.draft.state.grainDiameter.count == grainCount)
        #expect(session.draft.state.secondTransportCdfGrainSize.count == secondCDFCount)

        let editedRow = "grain:\(firstCDFCount)"
        #expect(session.setCell(tableID: "state.grainDistributions", rowID: editedRow,
                                columnID: "firstCDF", rawText: "draft μ"))
        #expect(session.draft.state.firstTransportCdfGrainSize[firstCDFCount] == "draft μ")
        let projected = try #require(session.snapshot?.tables.first { $0.id == "state.grainDistributions" })
        let cdfColumn = try #require(projected.columns.firstIndex { $0.id == "firstCDF" })
        let projectedRow = try #require(projected.rows.first { $0.id == editedRow })
        #expect(projectedRow.cells[cdfColumn] == "draft μ")

        #expect(session.removeInputRow(tableID: "state.grainDistributions", rowID: "grain:0", columnID: "grainDiameter"))
        #expect(session.draft.state.grainDiameter.count == grainCount - 1)
        #expect(session.draft.state.firstTransportCdfGrainSize.count == firstCDFCount + 1)
        #expect(session.draft.state.secondTransportCdfGrainSize.count == secondCDFCount)

        let ratesCount = session.draft.state.transportRates.count
        #expect(session.appendInputRow(tableID: "state.transportRates", columnID: "transportRate"))
        #expect(session.draft.state.transportRates.count == ratesCount + 1)
        let rateTable = try #require(session.snapshot?.tables.first { $0.id == "state.transportRates" })
        #expect(rateTable.rows.count == ratesCount + 1)
        #expect(rateTable.rows.last?.id == "value:\(ratesCount)")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func bundledCalculatorUsesSubmittedCultureAndKeepsOtherSectionsAvailableOnBadInput() async throws {
        let session = try makeSession()
        let invariantSession = try makeSession()
        #expect(await session.load(numberCulture: "de-DE"))
        #expect(await invariantSession.load(numberCulture: "en-US"))

        var localized = session.draft
        localized.sbtm.shearVelocity = "0,25"
        session.editDraft(localized)
        #expect(session.draft.numberCulture == "de-DE")
        #expect(await session.calculate())
        #expect(session.snapshot?.draft.sbtm.shearVelocity == "0,25")
        #expect(session.snapshot?.sbtmErrorKey == nil)
        #expect(session.snapshot?.sbtmResults != nil)

        var invariant = invariantSession.draft
        invariant.sbtm.shearVelocity = "0.25"
        invariantSession.editDraft(invariant)
        #expect(await invariantSession.calculate())
        #expect(session.snapshot?.sbtmResults == invariantSession.snapshot?.sbtmResults)
        #expect(session.snapshot?.stabResults != nil)
        #expect(session.snapshot?.stateResults != nil)

        var invalid = session.draft
        let validSBTM = invalid.sbtm
        invalid.sbtm.shearVelocity = "not a number"
        session.editDraft(invalid)
        #expect(await session.calculate())
        #expect(session.snapshot?.sbtmErrorKey != nil)
        #expect(session.snapshot?.stabResults != nil)
        #expect(session.snapshot?.stateResults != nil)
        #expect(!session.calculationIssueKeys.isEmpty)
        #expect(session.snapshot?.draft.sbtm.shearVelocity == "not a number")

        var repaired = session.draft
        repaired.sbtm = validSBTM
        session.editDraft(repaired)
        #expect(session.snapshot?.canImportCase == false)
        #expect(await session.importCaseFromBTM(confirmImport: false))
        #expect(session.hasPendingImportConfirmation)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func bundledCaseOperationsPreserveExistingIdentityAndResetOnlyOnConfirmedReplacement() async throws {
        let session = try makeSession()
        #expect(await session.load())
        let initialChoices = session.caseChoices
        #expect(await session.addCase())
        #expect(session.caseChoices.count == initialChoices.count + 1)
        #expect(Set(initialChoices.map(\.id)).isSubset(of: Set(session.caseChoices.map(\.id))))

        let addedChoice = try #require(session.caseChoices.first { choice in
            !initialChoices.contains(where: { $0.id == choice.id })
        })
        #expect(await session.deleteCase(id: addedChoice.id))
        #expect(Set(session.caseChoices.map(\.id)) == Set(initialChoices.map(\.id)))

        let firstGrain = try #require(session.draft.sbtm.grainDiameter.first.flatMap(Double.init))
        #expect(session.setCell(tableID: "btm.sbtm.input", rowID: "grain:0", columnID: "grainDiameter",
                                rawText: String(firstGrain + 0.01)))
        let beforeImport = session.caseChoices
        #expect(await session.importCaseFromBTM(confirmImport: false))
        #expect(session.snapshot?.importConfirmationRequired == true)
        #expect(session.hasPendingImportConfirmation)
        #expect(session.caseChoices.map(\.id) == beforeImport.map(\.id))
        let preflightDraft = try #require(session.snapshot?.draft)
        #expect(session.draft == preflightDraft)

        var changedAfterPrompt = session.draft
        changedAfterPrompt.sbtm.shearVelocity = "0.251"
        session.editDraft(changedAfterPrompt)
        #expect(!session.hasPendingImportConfirmation)
        #expect(!session.importConfirmationRequired)
        let staleConfirmationAccepted = await session.importCaseFromBTM(confirmImport: true)
        #expect(!staleConfirmationAccepted)
        #expect(session.caseChoices.map(\.id) == beforeImport.map(\.id))

        #expect(await session.importCaseFromBTM(confirmImport: false))
        #expect(session.hasPendingImportConfirmation)
        #expect(await session.importCaseFromBTM(confirmImport: true))
        #expect(session.snapshot?.replacedExistingCases == true)
        #expect(Set(session.caseChoices.map(\.id)).isDisjoint(with: Set(beforeImport.map(\.id))))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func bundledSameGridImportRequiresConfirmationBeforeAppending() async throws {
        let session = try makeSession()
        #expect(await session.load())

        var matching = session.draft
        matching.sbtm.grainDiameter = matching.stab.grainDiameter
        let matchingCDF = try #require(matching.stab.transportGrainSizes.first)
        matching.sbtm.surfaceCdf = matchingCDF
        session.editDraft(matching)
        #expect(await session.calculate())
        let calculated = try #require(session.snapshot)
        #expect(calculated.btmImportPolicy == .append)

        let before = session.caseChoices
        #expect(await session.importCaseFromBTM(confirmImport: false))
        #expect(session.snapshot?.importConfirmationRequired == true)
        #expect(session.hasPendingImportConfirmation)
        #expect(session.caseChoices.map(\.id) == before.map(\.id))
        let preflightDraft = try #require(session.snapshot?.draft)
        #expect(session.draft == preflightDraft)

        #expect(await session.importCaseFromBTM(confirmImport: true))
        #expect(session.snapshot?.replacedExistingCases == false)
        #expect(session.caseChoices.count == before.count + 1)
        #expect(Set(before.map(\.id)).isSubset(of: Set(session.caseChoices.map(\.id))))
    }

    @MainActor
    private func makeSession() throws -> WilcockSession {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let provider = BackendWilcockProvider(client: BackendProcessClient(executableURL: URL(fileURLWithPath: executable)))
        return WilcockSession(provider: provider)
    }
}
