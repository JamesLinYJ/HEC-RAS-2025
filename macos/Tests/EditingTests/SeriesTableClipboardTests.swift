import Foundation
import Testing
@testable import HECRAS2025

@MainActor
struct SeriesTableClipboardTests {
    private let tableID = "Boundary/TimeSeriesPayloadTable"
    private let sessionID = UUID()
    private let projectSessionID = UUID()

    private func selection(_ rowID: String = "r1", _ columnID: String = "c1") -> SeriesTablePasteSelectionIdentity {
        let address = NativeDataGridAddress(rowID: rowID, columnID: columnID)
        return .init(anchor: address, extent: address, additionalCells: [])
    }

    private func makeIdentity(rowIDs: [String], columns: [SourceTableColumn],
                              columnIDs: [String]? = nil, selection: SeriesTablePasteSelectionIdentity? = nil,
                              units: [SeriesTablePasteUnitIdentity] = [],
                              editorSessionID: UUID? = nil) -> SeriesTablePasteIdentity {
        .init(scope: "project/editor/asset/payload/page/table", projectSessionID: projectSessionID,
              editorSessionID: editorSessionID ?? sessionID, modelAssetID: nil, sourceFileRevision: nil,
              payloadIdentity: "line/payload", pageID: "page", pageScope: "line/payload",
              tableID: tableID, datasetID: "", rowIDs: rowIDs,
              columnIDs: columnIDs ?? columns.filter { $0.visible != false }.map(\.id),
              columns: columns.map {
                  .init(id: $0.id, sourceType: $0.sourceType, isReadOnly: $0.readOnly == true,
                        choiceIDs: $0.choices?.map(\.id) ?? [])
              }, units: units, selection: selection ?? self.selection())
    }

    private func target(_ identity: SeriesTablePasteIdentity, rows: ClosedRange<Int> = 0...0,
                        columns: ClosedRange<Int> = 0...0) -> SeriesTablePasteTarget {
        .init(identity: identity, bounds: .init(rows: rows, columns: columns))
    }

    private func session(columns: [SourceTableColumn], rows: [EditorRow]) -> ModelEditorSession {
        let session = ModelEditorSession()
        session.startDraft(.init(fields: [:], rows: [tableID: rows], samples: [:], canEdit: true,
            images: [:], tablePresentations: [tableID: .init(columns: columns)]))
        return session
    }

    private func unitIdentity(columnID: String, units: DisplayUnitData, selectedUnitID: String) -> SeriesTablePasteUnitIdentity {
        .init(columnID: columnID, selectionID: units.selectionId, sourceID: units.sourceId,
              selectedUnitID: selectedUnitID,
              choices: units.choices.map { .init(id: $0.id, scale: $0.scale, offset: $0.offset) })
    }

    @Test
    func contextPasteKeepsTheCurrentRangeWhenTheClickedCellIsSelected() throws {
        let columns = (1...4).map { SourceTableColumn(id: "c\($0)", title: "C\($0)", sourceType: "string") }
        let selection = SeriesTablePasteSelectionIdentity(
            anchor: .init(rowID: "r1", columnID: "c1"),
            extent: .init(rowID: "r3", columnID: "c3"), additionalCells: [])
        let captured = makeIdentity(rowIDs: ["r1", "r2", "r3", "r4"], columns: columns,
                                    selection: selection)
        let target = try #require(SeriesTablePasteTargetResolver.resolve(identity: captured,
            contextAddress: .init(rowID: "r2", columnID: "c2")))

        #expect(target.bounds == .init(rows: 0...2, columns: 0...2))
        #expect(target.identity.selection == selection)
        let plan = try SeriesTableClipboardPlanner.plan(text: "value", target: target,
                                                        currentIdentity: target.identity)
        #expect(plan.cells.count == 9)
        #expect(plan.cells.allSatisfy { $0.value == "value" })
    }

    @Test
    func contextPasteUsesClickedCellOutsideTheCurrentSelection() throws {
        let columns = (1...5).map { SourceTableColumn(id: "c\($0)", title: "C\($0)", sourceType: "string") }
        let selection = SeriesTablePasteSelectionIdentity(
            anchor: .init(rowID: "r1", columnID: "c1"),
            extent: .init(rowID: "r2", columnID: "c2"), additionalCells: [])
        let captured = makeIdentity(rowIDs: ["r1", "r2", "r3", "r4", "r5"], columns: columns,
                                    selection: selection)
        let clicked = NativeDataGridAddress(rowID: "r4", columnID: "c4")
        let target = try #require(SeriesTablePasteTargetResolver.resolve(identity: captured,
                                                                           contextAddress: clicked))

        #expect(target.bounds == .init(rows: 3...3, columns: 3...3))
        #expect(target.identity.selection == .init(anchor: clicked, extent: clicked, additionalCells: []))
        let plan = try SeriesTableClipboardPlanner.plan(text: "a\tb\nc\td", target: target,
                                                        currentIdentity: target.identity)
        #expect(plan.cells == [
            .init(rowID: "r4", columnID: "c4", value: "a"),
            .init(rowID: "r4", columnID: "c5", value: "b"),
            .init(rowID: "r5", columnID: "c4", value: "c"),
            .init(rowID: "r5", columnID: "c5", value: "d")
        ])
    }

    @Test
    func contextPasteDoesNotTreatAnUnselectedBoundingBoxHoleAsSelected() throws {
        let columns = (1...4).map { SourceTableColumn(id: "c\($0)", title: "C\($0)", sourceType: "string") }
        let isolated = NativeDataGridAddress(rowID: "r4", columnID: "c4")
        let selection = SeriesTablePasteSelectionIdentity(
            anchor: .init(rowID: "r1", columnID: "c1"),
            extent: .init(rowID: "r2", columnID: "c2"), additionalCells: [isolated])
        let captured = makeIdentity(rowIDs: ["r1", "r2", "r3", "r4"], columns: columns,
                                    selection: selection)
        let clickedHole = NativeDataGridAddress(rowID: "r3", columnID: "c3")
        let target = try #require(SeriesTablePasteTargetResolver.resolve(identity: captured,
                                                                           contextAddress: clickedHole))

        #expect(target.bounds == .init(rows: 2...2, columns: 2...2))
        #expect(target.identity.selection == .init(anchor: clickedHole, extent: clickedHole, additionalCells: []))
    }

    @Test
    func contextPasteOnAnAddedSelectedCellPreservesTheFullSelection() throws {
        let columns = (1...4).map { SourceTableColumn(id: "c\($0)", title: "C\($0)", sourceType: "string") }
        let additional = NativeDataGridAddress(rowID: "r4", columnID: "c4")
        let selection = SeriesTablePasteSelectionIdentity(
            anchor: .init(rowID: "r1", columnID: "c1"),
            extent: .init(rowID: "r2", columnID: "c2"), additionalCells: [additional])
        let captured = makeIdentity(rowIDs: ["r1", "r2", "r3", "r4"], columns: columns,
                                    selection: selection)
        let target = try #require(SeriesTablePasteTargetResolver.resolve(identity: captured,
                                                                           contextAddress: additional))

        #expect(target.identity.selection == selection)
        #expect(target.bounds == .init(rows: 0...3, columns: 0...3))
    }

    @Test
    func toolbarPasteWithoutContextAddressKeepsTheCurrentSelection() throws {
        let columns = (1...3).map { SourceTableColumn(id: "c\($0)", title: "C\($0)", sourceType: "string") }
        let selection = SeriesTablePasteSelectionIdentity(
            anchor: .init(rowID: "r1", columnID: "c1"),
            extent: .init(rowID: "r2", columnID: "c2"), additionalCells: [])
        let captured = makeIdentity(rowIDs: ["r1", "r2", "r3"], columns: columns,
                                    selection: selection)
        let target = try #require(SeriesTablePasteTargetResolver.resolve(identity: captured))

        #expect(target.identity.selection == selection)
        #expect(target.bounds == .init(rows: 0...1, columns: 0...1))
    }

    @Test
    func contextPasteRevalidationRejectsASelectionChangedAfterTargetCapture() throws {
        let columns = (1...3).map { SourceTableColumn(id: "c\($0)", title: "C\($0)", sourceType: "string") }
        let captured = makeIdentity(rowIDs: ["r1", "r2", "r3"], columns: columns,
                                    selection: selection("r1", "c1"))
        let clicked = NativeDataGridAddress(rowID: "r3", columnID: "c3")
        let target = try #require(SeriesTablePasteTargetResolver.resolve(identity: captured,
                                                                           contextAddress: clicked))
        let changedSelection = SeriesTablePasteSelectionIdentity(
            anchor: .init(rowID: "r2", columnID: "c2"),
            extent: .init(rowID: "r3", columnID: "c3"), additionalCells: [])
        let changed = makeIdentity(rowIDs: captured.rowIDs, columns: columns,
                                   selection: changedSelection)
        let currentTarget = try #require(SeriesTablePasteTargetResolver.resolve(identity: changed,
                                                                                 contextAddress: clicked))

        do {
            _ = try SeriesTableClipboardPlanner.plan(text: "value", target: target,
                                                     currentIdentity: currentTarget.identity)
            Issue.record("A context paste target survived a changed selection.")
        } catch {
            #expect(error as? SeriesTablePasteError == .staleSelection)
        }
    }

    @Test
    func singleValueFillsSelectedRangeAndCountsReadonlyCells() throws {
        let columns = [
            SourceTableColumn(id: "locked", title: "Locked", sourceType: "string", readOnly: true),
            SourceTableColumn(id: "value", title: "Value", sourceType: "string")
        ]
        let rows = ["r1", "r2"].map { EditorRow(id: $0, values: ["locked": "fixed", "value": "old"]) }
        let captured = makeIdentity(rowIDs: ["r1", "r2"], columns: columns,
                                    columnIDs: ["locked", "value"], selection: selection("r1", "locked"))
        let plan = try SeriesTableClipboardPlanner.plan(text: "new", target: target(captured, rows: 0...1, columns: 0...1),
                                                        currentIdentity: captured)

        #expect(plan.cells == [
            .init(rowID: "r1", columnID: "value", value: "new"),
            .init(rowID: "r2", columnID: "value", value: "new")
        ])
        #expect(plan.skippedReadOnlyCellCount == 2)
        #expect(rows.allSatisfy { $0.values["locked"] == "fixed" })
    }

    @Test
    func raggedRowsKeepUnspecifiedTrailingCellsUntouched() throws {
        let columns = (1...3).map { SourceTableColumn(id: "c\($0)", title: "C\($0)", sourceType: "string") }
        let captured = makeIdentity(rowIDs: ["r1", "r2"], columns: columns, selection: selection("r1", "c1"))
        let plan = try SeriesTableClipboardPlanner.plan(text: "a\tb\tc\nx", target: target(captured, rows: 0...0),
                                                        currentIdentity: captured)

        #expect(plan.cells == [
            .init(rowID: "r1", columnID: "c1", value: "a"),
            .init(rowID: "r1", columnID: "c2", value: "b"),
            .init(rowID: "r1", columnID: "c3", value: "c"),
            .init(rowID: "r2", columnID: "c1", value: "x")
        ])
    }

    @Test
    func plannerReusesTheNativeQuotedTSVParserForEmbeddedTabsAndNewlines() throws {
        let columns = [SourceTableColumn(id: "c1", title: "C1", sourceType: "string"),
                       SourceTableColumn(id: "c2", title: "C2", sourceType: "string")]
        let captured = makeIdentity(rowIDs: ["r1"], columns: columns, selection: selection("r1", "c1"))
        let plan = try SeriesTableClipboardPlanner.plan(text: "\"a\tb\"\t\"line1\nline2\"",
            target: target(captured, columns: 0...0), currentIdentity: captured)

        #expect(plan.cells == [
            .init(rowID: "r1", columnID: "c1", value: "a\tb"),
            .init(rowID: "r1", columnID: "c2", value: "line1\nline2")
        ])
    }

    @Test
    func overflowAndMalformedClipboardAreExplicitlyRejected() {
        let columns = [SourceTableColumn(id: "c1", title: "C1", sourceType: "string"),
                       SourceTableColumn(id: "c2", title: "C2", sourceType: "string")]
        let captured = makeIdentity(rowIDs: ["r1"], columns: columns, selection: selection("r1", "c2"))
        do {
            _ = try SeriesTableClipboardPlanner.plan(text: "a\tb", target: target(captured, columns: 1...1),
                                                     currentIdentity: captured)
            Issue.record("An overflowing paste was accepted.")
        } catch {
            #expect(error as? SeriesTablePasteError == .outOfBounds)
        }
        do {
            _ = try SeriesTableClipboardPlanner.plan(text: "\"unclosed", target: target(captured),
                                                     currentIdentity: captured)
            Issue.record("Malformed clipboard quoting was accepted.")
        } catch {
            #expect(error as? SeriesTablePasteError == .invalidClipboard)
        }
    }

    @Test
    func staleSelectionIdentityCannotReuseAClipboardPlan() throws {
        let columns = [SourceTableColumn(id: "c1", title: "C1", sourceType: "string")]
        let captured = makeIdentity(rowIDs: ["r1", "r2"], columns: columns, selection: selection("r1", "c1"))
        let changed = SeriesTablePasteIdentity(scope: captured.scope, projectSessionID: captured.projectSessionID,
            editorSessionID: captured.editorSessionID, modelAssetID: captured.modelAssetID,
            sourceFileRevision: captured.sourceFileRevision, payloadIdentity: captured.payloadIdentity,
            pageID: captured.pageID, pageScope: captured.pageScope, tableID: captured.tableID,
            datasetID: captured.datasetID, rowIDs: captured.rowIDs, columnIDs: captured.columnIDs,
            columns: captured.columns, units: captured.units, selection: selection("r2", "c1"))
        do {
            _ = try SeriesTableClipboardPlanner.plan(text: "value", target: target(captured), currentIdentity: changed)
            Issue.record("A paste plan was accepted for a different selected cell.")
        } catch {
            #expect(error as? SeriesTablePasteError == .staleSelection)
        }
    }

    @Test
    func invalidChoiceCellIsReportedWithoutDroppingNeighboringValidCell() throws {
        let columns = [
            SourceTableColumn(id: "choice", title: "Choice", sourceType: "string",
                choices: [.init(id: "a", title: "A"), .init(id: "b", title: "B")]),
            SourceTableColumn(id: "label", title: "Label", sourceType: "string")
        ]
        let session = session(columns: columns,
            rows: [.init(id: "r1", values: ["choice": "a", "label": "old"])])
        let captured = makeIdentity(rowIDs: ["r1"], columns: columns,
            selection: selection("r1", "choice"), editorSessionID: session.id)
        let plan = try SeriesTableClipboardPlanner.plan(text: "unsupported\tnew", target: target(captured, columns: 0...0),
                                                        currentIdentity: captured)
        let result = try SeriesTablePasteApplier.apply(plan, currentIdentity: captured, session: session,
            columns: columns, unitsByColumn: [:], isDebugMode: false)

        #expect(result.appliedCellCount == 1)
        #expect(result.failedCellCount == 1)
        #expect(session.rows[tableID]?.first?.values["choice"] == "a")
        #expect(session.rows[tableID]?.first?.values["label"] == "new")
    }

    @Test
    func numericPasteUsesDisplayUnitsAndUpdatesTheSameSessionDraft() throws {
        let column = SourceTableColumn(id: "Value", title: "Value", sourceType: "double")
        let columns = [column]
        let units = DisplayUnitData(sourceId: "m", selectionId: "series/value", choices: [
            .init(id: "m", scale: 1, offset: 0),
            .init(id: "ft", scale: 3.280839895013123, offset: 0)
        ])
        let session = session(columns: columns, rows: [
            .init(id: "r1", values: ["Value": "1"]),
            .init(id: "r2", values: ["Value": "2"])
        ])
        session.selectDisplayUnit("ft", units: units)
        let captured = makeIdentity(rowIDs: ["r1", "r2"], columns: columns,
            selection: selection("r1", "Value"),
            units: [unitIdentity(columnID: "Value", units: units, selectedUnitID: "ft")],
            editorSessionID: session.id)
        let plan = try SeriesTableClipboardPlanner.plan(text: "10\n20", target: target(captured),
                                                        currentIdentity: captured)
        let result = try SeriesTablePasteApplier.apply(plan, currentIdentity: captured,
            session: session, columns: columns, unitsByColumn: ["Value": units], isDebugMode: false,
            locale: Locale(identifier: "en_US"))

        #expect(result.appliedCellCount == 2)
        let value1 = Double(session.rows[tableID]?.first { $0.id == "r1" }?.values["Value"] ?? "") ?? .nan
        let value2 = Double(session.rows[tableID]?.first { $0.id == "r2" }?.values["Value"] ?? "") ?? .nan
        #expect(abs(value1 - 3.048) < 1e-12)
        #expect(abs(value2 - 6.096) < 1e-12)
        #expect(session.modified)
    }

    @Test
    func invalidNumericPasteStaysVisibleAsDraftAndBlocksSave() async throws {
        let column = SourceTableColumn(id: "Value", title: "Value", sourceType: "double")
        let columns = [column]
        let units = SeriesTableClipboardPlanner.identityUnits(tableID: tableID, columnID: "Value")
        let session = session(columns: columns, rows: [.init(id: "r1", values: ["Value": "5"])] )
        let captured = makeIdentity(rowIDs: ["r1"], columns: columns,
            selection: selection("r1", "Value"),
            units: [unitIdentity(columnID: "Value", units: units, selectedUnitID: "source")],
            editorSessionID: session.id)
        let plan = try SeriesTableClipboardPlanner.plan(text: "12x", target: target(captured),
                                                        currentIdentity: captured)
        let result = try SeriesTablePasteApplier.apply(plan, currentIdentity: captured,
            session: session, columns: columns, unitsByColumn: ["Value": units], isDebugMode: false,
            locale: Locale(identifier: "en_US"))
        let owner = OriginalUnitNumberInputOwner.tableCell(tableID: tableID, rowID: "r1", columnID: "Value")

        #expect(result.invalidNumericDraftCount == 1)
        #expect(result.failedCellCount == 0)
        #expect(session.rows[tableID]?.first?.values["Value"] == "5")
        #expect(session.unitNumberInputDraft(for: owner)?.rawDisplayText == "12x")
        #expect(session.hasIncompleteEditorInput)
        #expect(session.incompleteEditorInputIssue == L10n.text(OriginalUnitNumberInputIssue.invalidNumber))
        #expect(!(await session.saveLoadedModel()))
        #expect(session.error == L10n.text(OriginalUnitNumberInputIssue.blockedBeforeSave))
        session.discardEdits()
        #expect(session.rows[tableID]?.first?.values["Value"] == "5")
        #expect(!session.hasIncompleteEditorInput)
    }
}
