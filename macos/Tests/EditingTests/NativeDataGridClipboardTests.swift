import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor private final class PerCellPasteProvider: AttributeTableProvider {
    var transformCount = 0
    let source = AttributeTableData(
        sourcePath: "/source.shp",
        shapeType: "Point",
        columns: [.init(id: "depth", name: "Depth", type: "Double"), .init(id: "label", name: "Label", type: "String", readOnly: true)],
        rows: [.init(id: "feature/0", values: ["depth": "1.5", "label": "fixed"]), .init(id: "feature/1", values: ["depth": "2.5", "label": "fixed"])]
    )

    func load(_ url: URL) async throws -> AttributeTableData { source }

    func transform(_ table: AttributeTableData, mutation: AttributeMutation) async throws -> AttributeTableData {
        transformCount += 1
        var result = table
        var rows = result.rows
        for edit in mutation.cells ?? [] {
            guard let column = table.columns.first(where: { $0.id == edit.columnId }),
                  let rowIndex = rows.firstIndex(where: { $0.id == edit.rowId }) else {
                throw BackendServiceError(code: "invalidInput", message: "Cell is unavailable.")
            }
            if column.type == "Double", let value = edit.value, Double(value) == nil {
                throw BackendServiceError(code: "invalidInput", message: "A cell value is not valid for its column type.")
            }
            rows[rowIndex].values.updateValue(edit.value, forKey: edit.columnId)
        }
        result.rows = rows
        return result
    }
}

struct NativeDataGridClipboardTests {
    @Test func parsesQuotedTabsQuotesAndEmbeddedNewlines() {
        let parsed = NativeDataGridClipboard.decode("\"alpha\tbeta\"\t\"quoted\"\"text\"\r\n\"line\nbreak\"\t")
        #expect(parsed == [["alpha\tbeta", "quoted\"text"], ["line\nbreak", ""]])
        #expect(NativeDataGridClipboard.decode("first\r\n\r\nlast\r\n") == [["first"], [""], ["last"]])
        #expect(NativeDataGridClipboard.decode("\"line\r\nbreak\"") == [["line\r\nbreak"]])
        #expect(NativeDataGridClipboard.decode("\"unclosed\tfield") == nil)
        #expect(NativeDataGridClipboard.decode("\"closed\"suffix") == nil)
        #expect(NativeDataGridClipboard.decode("unquoted\"quote") == nil)
    }

    @Test func selectionTracksStableRowAndColumnIDsAcrossSorting() {
        var selection = NativeDataGridSelection()
        selection.select(.init(rowID: "row/a", columnID: "col/one"), extending: false, adding: false)
        selection.select(.init(rowID: "row/c", columnID: "col/three"), extending: true, adding: false)

        let sortedRows = ["row/c", "row/b", "row/a"]
        let sortedColumns = ["col/three", "col/two", "col/one"]
        #expect(selection.bounds(rowIDs: sortedRows, columnIDs: sortedColumns) == .init(rows: 0...2, columns: 0...2))
        #expect(selection.contains(.init(rowID: "row/b", columnID: "col/two"), rowIDs: sortedRows, columnIDs: sortedColumns))
    }

    @Test func copiedCellsAreAQuotedRectangleWithoutHeaders() {
        var selection = NativeDataGridSelection()
        selection.select(.init(rowID: "r2", columnID: "c2"), extending: false, adding: false)
        selection.select(.init(rowID: "r1", columnID: "c1"), extending: true, adding: false)
        let text = NativeDataGridClipboard.copiedText(
            selection: selection,
            rowIDs: ["r1", "r2"],
            columnIDs: ["c1", "c2"],
            value: { row, column in
                ["r1/c1": "a\tb", "r1/c2": "quote\"", "r2/c1": "line\nnext", "r2/c2": "plain"][row + "/" + column]
            }
        )
        #expect(text == "\"a\tb\"\t\"quote\"\"\"\n\"line\nnext\"\tplain")
        guard let text, let decoded = NativeDataGridClipboard.decode(text) else { return }
        #expect(decoded == [["a\tb", "quote\""], ["line\nnext", "plain"]])
    }

    @Test func rowCopyUsesVisibleOrderAndOmitsColumnHeaders() {
        let text = NativeDataGridClipboard.copiedRowsText(
            selectedRowIDs: ["r3", "r1"],
            rowIDs: ["r1", "r2", "r3"],
            columnIDs: ["c1", "c2"],
            value: { row, column in row + "/" + column }
        )
        #expect(text == "r1/c1\tr1/c2\nr3/c1\tr3/c2")
    }

    @Test func commandClickAddsASeparateCellToTheCopiedBounds() {
        var selection = NativeDataGridSelection()
        selection.select(.init(rowID: "r1", columnID: "c1"), extending: false, adding: false)
        selection.select(.init(rowID: "r3", columnID: "c3"), extending: false, adding: true)
        #expect(selection.bounds(rowIDs: ["r1", "r2", "r3"], columnIDs: ["c1", "c2", "c3"]) == .init(rows: 0...2, columns: 0...2))
        #expect(selection.contains(.init(rowID: "r3", columnID: "c3"), rowIDs: ["r1", "r2", "r3"], columnIDs: ["c1", "c2", "c3"]))
    }

    @Test func commandShiftClickAddsAnotherCellRange() {
        var selection = NativeDataGridSelection()
        selection.select(.init(rowID: "r1", columnID: "c1"), extending: false, adding: false)
        selection.select(.init(rowID: "r2", columnID: "c2"), extending: true, adding: false)
        selection.select(.init(rowID: "r3", columnID: "c3"), extending: true, adding: true)

        #expect(selection.additionalRanges.count == 1)
        #expect(selection.contains(.init(rowID: "r1", columnID: "c1"), rowIDs: ["r1", "r2", "r3"], columnIDs: ["c1", "c2", "c3"]))
        #expect(selection.contains(.init(rowID: "r3", columnID: "c3"), rowIDs: ["r1", "r2", "r3"], columnIDs: ["c1", "c2", "c3"]))
    }

    @Test func sourceIdentityPruningPreservesSelectionAcrossTemporaryFilters() {
        var selection = NativeDataGridSelection()
        selection.select(.init(rowID: "r2", columnID: "c1"), extending: false, adding: false)
        selection.select(.init(rowID: "r3", columnID: "c2"), extending: true, adding: false)
        selection.prune(rowIDs: Set(["r1", "r2", "r3"]), columnIDs: Set(["c1", "c2"]))

        #expect(selection.bounds(rowIDs: ["r2"], columnIDs: ["c1", "c2"]) == nil)
        #expect(selection.bounds(rowIDs: ["r1", "r2", "r3"], columnIDs: ["c1", "c2"]) == .init(rows: 1...2, columns: 0...1))
    }

    @Test func contextClickKeepsSelectedRowsIncludingFilteredOutRows() {
        let rows = NativeDataGridContextSelection.rowIDs(clickedRowID: "r3",
            selectedRowIDs: ["r2", "r3", "hidden"],
            sourceRowIDs: ["r1", "r2", "r3", "hidden"], addsToSelection: false)
        #expect(rows == ["r2", "r3", "hidden"])
    }

    @Test func commandContextClickAddsNewRowButPlainClickReplacesSelection() {
        let sourceRows = ["r1", "hidden", "r2", "r3"]
        let existing = Set(["hidden", "r2"])
        #expect(NativeDataGridContextSelection.rowIDs(clickedRowID: "r3",
            selectedRowIDs: existing, sourceRowIDs: sourceRows, addsToSelection: true)
            == ["hidden", "r2", "r3"])
        #expect(NativeDataGridContextSelection.rowIDs(clickedRowID: "r3",
            selectedRowIDs: existing, sourceRowIDs: sourceRows, addsToSelection: false)
            == ["r3"])
    }

    @Test func selectAllCreatesTheVisibleCellRectangle() {
        var selection = NativeDataGridSelection()
        selection.selectAll(rowIDs: ["r1", "r2"], columnIDs: ["c1", "c2", "c3"])
        #expect(selection.bounds(rowIDs: ["r1", "r2"], columnIDs: ["c1", "c2", "c3"]) == .init(rows: 0...1, columns: 0...2))
    }

    @Test func exactPasteUsesTheSelectionOriginAndSkipsReadOnlyColumns() {
        var selection = NativeDataGridSelection()
        selection.select(.init(rowID: "r2", columnID: "c2"), extending: false, adding: false)
        selection.select(.init(rowID: "r1", columnID: "c1"), extending: true, adding: false)
        let edits = NativeDataGridClipboard.pasteCells(
            "first\tlocked\nsecond\tlocked-too\nextra\tignored",
            selection: selection,
            rowIDs: ["r1", "r2"],
            columnIDs: ["c1", "c2"],
            readOnlyColumnIDs: ["c2"]
        )
        #expect(edits == [
            .init(rowID: "r1", columnID: "c1", value: "first"),
            .init(rowID: "r2", columnID: "c1", value: "second")
        ])
    }

    @Test func oneCellPasteFillsTheSelectedRectangleAndPreservesEmptyValues() {
        var selection = NativeDataGridSelection()
        selection.select(.init(rowID: "r1", columnID: "c1"), extending: false, adding: false)
        selection.select(.init(rowID: "r2", columnID: "c2"), extending: true, adding: false)
        let edits = NativeDataGridClipboard.pasteCells(
            "",
            selection: selection,
            rowIDs: ["r1", "r2"],
            columnIDs: ["c1", "c2"]
        )
        #expect(edits.count == 4)
        #expect(edits.allSatisfy { $0.value.isEmpty })
    }

    @Test @MainActor func attributePasteKeepsValidCellsWhenATypeCheckRejectsAnotherCell() async {
        let provider = PerCellPasteProvider()
        let session = AttributeTableSession(provider: provider)
        await session.load(URL(filePath: "/source.shp"))
        let result = await session.applyPaste([
            .init(rowID: "feature/0", columnID: "depth", value: "3.25"),
            .init(rowID: "feature/1", columnID: "depth", value: "invalid")
        ])

        #expect(result == 1)
        #expect(provider.transformCount == 3)
        #expect(session.data?.rows[0].value("depth") == "3.25")
        #expect(session.data?.rows[1].value("depth") == "2.5")
        #expect(session.modified && session.drafts.isEmpty && session.error?.contains("1") == true)
    }
}
