import Foundation

struct SeriesTablePasteSelectionIdentity: Equatable, Sendable {
    let anchor: NativeDataGridAddress?
    let extent: NativeDataGridAddress?
    let additionalCells: [NativeDataGridAddress]
}

struct SeriesTablePasteColumnIdentity: Equatable, Sendable {
    let id: String
    let sourceType: String
    let isReadOnly: Bool
    let choiceIDs: [String]
}

struct SeriesTablePasteUnitChoiceIdentity: Equatable, Sendable {
    let id: String
    let scale: Double
    let offset: Double
}

struct SeriesTablePasteUnitIdentity: Equatable, Sendable {
    let columnID: String
    let selectionID: String
    let sourceID: String
    let selectedUnitID: String
    let choices: [SeriesTablePasteUnitChoiceIdentity]
}

struct SeriesTablePasteIdentity: Equatable, Sendable {
    let scope: String
    let projectSessionID: UUID
    let editorSessionID: UUID
    let modelAssetID: String?
    let sourceFileRevision: String?
    let payloadIdentity: String
    let pageID: String
    let pageScope: String?
    let tableID: String
    let datasetID: String
    let rowIDs: [String]
    let columnIDs: [String]
    let columns: [SeriesTablePasteColumnIdentity]
    let units: [SeriesTablePasteUnitIdentity]
    let selection: SeriesTablePasteSelectionIdentity

    func replacingSelection(_ selection: SeriesTablePasteSelectionIdentity) -> SeriesTablePasteIdentity {
        .init(scope: scope, projectSessionID: projectSessionID, editorSessionID: editorSessionID,
              modelAssetID: modelAssetID, sourceFileRevision: sourceFileRevision,
              payloadIdentity: payloadIdentity, pageID: pageID, pageScope: pageScope,
              tableID: tableID, datasetID: datasetID, rowIDs: rowIDs, columnIDs: columnIDs,
              columns: columns, units: units, selection: selection)
    }
}

struct SeriesTablePasteTarget: Equatable, Sendable {
    let identity: SeriesTablePasteIdentity
    let bounds: NativeDataGridBounds
}

enum SeriesTablePasteTargetResolver {
    /// Context-menu paste keeps the active selection only when the clicked cell is
    /// actually part of it. A click in the selection's bounding box but outside its
    /// selected cells becomes a one-cell paste target. Callers without an explicit
    /// context-menu address continue to use the active selection.
    static func resolve(identity: SeriesTablePasteIdentity,
                        contextAddress: NativeDataGridAddress? = nil) -> SeriesTablePasteTarget? {
        let selection = identity.selection
        let gridRange: NativeDataGridRange?
        switch (selection.anchor, selection.extent) {
        case let (anchor?, extent?):
            gridRange = .init(anchor: anchor, extent: extent)
        case (nil, nil):
            gridRange = nil
        default:
            return nil
        }

        let selectionAddresses = [selection.anchor, selection.extent].compactMap { $0 }
            + selection.additionalCells
        guard !identity.rowIDs.isEmpty, !identity.columnIDs.isEmpty,
              Set(identity.rowIDs).count == identity.rowIDs.count,
              Set(identity.columnIDs).count == identity.columnIDs.count,
              selectionAddresses.allSatisfy({
                  identity.rowIDs.contains($0.rowID) && identity.columnIDs.contains($0.columnID)
              }) else { return nil }

        let gridSelection = NativeDataGridSelection(range: gridRange,
                                                    additionalCells: Set(selection.additionalCells))
        if let contextAddress {
            guard let rowIndex = identity.rowIDs.firstIndex(of: contextAddress.rowID),
                  let columnIndex = identity.columnIDs.firstIndex(of: contextAddress.columnID) else { return nil }
            if gridSelection.contains(contextAddress, rowIDs: identity.rowIDs, columnIDs: identity.columnIDs) {
                guard let bounds = gridSelection.bounds(rowIDs: identity.rowIDs,
                                                        columnIDs: identity.columnIDs) else { return nil }
                return .init(identity: identity, bounds: bounds)
            }

            let singleCellSelection = SeriesTablePasteSelectionIdentity(
                anchor: contextAddress, extent: contextAddress, additionalCells: [])
            return .init(identity: identity.replacingSelection(singleCellSelection),
                         bounds: .init(rows: rowIndex...rowIndex, columns: columnIndex...columnIndex))
        }

        guard let bounds = gridSelection.bounds(rowIDs: identity.rowIDs, columnIDs: identity.columnIDs) else {
            return nil
        }
        return .init(identity: identity, bounds: bounds)
    }
}

struct SeriesTablePastePlan: Equatable, Sendable {
    let targetIdentity: SeriesTablePasteIdentity
    let cells: [NativeDataGridPasteCell]
    let skippedReadOnlyCellCount: Int
}

enum SeriesTablePasteError: Error, Equatable {
    case staleSelection
    case invalidClipboard
    case outOfBounds
}

enum SeriesTableClipboardPlanner {
    static func plan(text: String, target: SeriesTablePasteTarget,
                     currentIdentity: SeriesTablePasteIdentity) throws -> SeriesTablePastePlan {
        let identity = target.identity
        guard identity == currentIdentity else { throw SeriesTablePasteError.staleSelection }
        guard !identity.tableID.isEmpty,
              !identity.rowIDs.isEmpty, !identity.columnIDs.isEmpty,
              Set(identity.rowIDs).count == identity.rowIDs.count,
              Set(identity.columnIDs).count == identity.columnIDs.count,
              Set(identity.columns.map(\.id)).count == identity.columns.count,
              Set(identity.columnIDs).isSubset(of: Set(identity.columns.map(\.id))),
              Set(identity.units.map(\.columnID)).count == identity.units.count,
              ([identity.selection.anchor, identity.selection.extent].compactMap { $0 }
                + identity.selection.additionalCells).allSatisfy({
                    identity.rowIDs.contains($0.rowID) && identity.columnIDs.contains($0.columnID)
                }),
              target.bounds.rows.lowerBound >= 0, target.bounds.columns.lowerBound >= 0,
              target.bounds.rows.upperBound < identity.rowIDs.count,
              target.bounds.columns.upperBound < identity.columnIDs.count,
              target.bounds.rows.lowerBound <= target.bounds.rows.upperBound,
              target.bounds.columns.lowerBound <= target.bounds.columns.upperBound else {
            throw SeriesTablePasteError.staleSelection
        }
        guard let matrix = NativeDataGridClipboard.decode(text), !matrix.isEmpty,
              let widestRow = matrix.map(\.count).max(), widestRow > 0 else {
            throw SeriesTablePasteError.invalidClipboard
        }

        let fillsSelection = matrix.count == 1 && widestRow == 1
        let startRow = target.bounds.rows.lowerBound
        let startColumn = target.bounds.columns.lowerBound
        if fillsSelection {
            // The native grid behavior repeats one cell throughout the selected bounds.
        } else {
            guard startRow + matrix.count <= identity.rowIDs.count,
                  matrix.allSatisfy({ startColumn + $0.count <= identity.columnIDs.count }) else {
                throw SeriesTablePasteError.outOfBounds
            }
        }

        var cells: [NativeDataGridPasteCell] = []
        var skippedReadOnlyCellCount = 0
        if fillsSelection {
            for rowIndex in target.bounds.rows {
                for columnIndex in target.bounds.columns {
                    let columnID = identity.columnIDs[columnIndex]
                    if identity.columns.first(where: { $0.id == columnID })?.isReadOnly == true {
                        skippedReadOnlyCellCount += 1
                    } else {
                        cells.append(.init(rowID: identity.rowIDs[rowIndex], columnID: columnID, value: matrix[0][0]))
                    }
                }
            }
        } else {
            for (rowOffset, sourceRow) in matrix.enumerated() {
                for (columnOffset, value) in sourceRow.enumerated() {
                    let rowIndex = startRow + rowOffset
                    let columnIndex = startColumn + columnOffset
                    let columnID = identity.columnIDs[columnIndex]
                    if identity.columns.first(where: { $0.id == columnID })?.isReadOnly == true {
                        skippedReadOnlyCellCount += 1
                    } else {
                        cells.append(.init(rowID: identity.rowIDs[rowIndex], columnID: columnID, value: value))
                    }
                }
            }
        }
        return .init(targetIdentity: identity, cells: cells,
                     skippedReadOnlyCellCount: skippedReadOnlyCellCount)
    }
}

enum SeriesTablePasteValue {
    /// Validates cells that use source-native strings. Numeric values with display units
    /// go through ModelEditorSession.updateUnitNumberInput so invalid text remains a draft.
    static func sourceText(from displayText: String, column: SourceTableColumn,
                           isDebugMode: Bool) -> String? {
        if let choices = column.choices, !choices.isEmpty,
           !choices.filter({ isDebugMode || $0.debugOnly != true }).contains(where: { $0.id == displayText }) {
            return nil
        }
        let trimmed = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch column.sourceType.lowercased() {
        case "int", "int32", "integer":
            return Int32(trimmed) == nil ? nil : displayText
        case "long", "int64":
            return Int64(trimmed) == nil ? nil : displayText
        case "bool", "boolean":
            return ["true", "false"].contains(trimmed.lowercased()) ? displayText : nil
        case "datetime", "datetimeoffset":
            return SourceTimestamp.parse(trimmed) == nil ? nil : displayText
        default:
            return displayText
        }
    }
}

struct SeriesTablePasteApplyResult: Equatable, Sendable {
    let appliedCellCount: Int
    let failedCellCount: Int
    let invalidNumericDraftCount: Int
    let skippedReadOnlyCellCount: Int
}

@MainActor
enum SeriesTablePasteApplier {
    static func apply(_ plan: SeriesTablePastePlan, currentIdentity: SeriesTablePasteIdentity,
                      session: ModelEditorSession, columns: [SourceTableColumn],
                      unitsByColumn: [String: DisplayUnitData], isDebugMode: Bool,
                      locale: Locale = .autoupdatingCurrent) throws -> SeriesTablePasteApplyResult {
        let identity = plan.targetIdentity
        guard identity == currentIdentity,
              identity.editorSessionID == session.id,
              identity.modelAssetID == session.modelAssetID,
              identity.sourceFileRevision == session.sourceFileRevision,
              session.loaded, session.canEdit, !session.isBusy, !session.loadingSelection,
              session.tablePresentations[identity.tableID]?.columns.filter({ $0.visible != false }).map(\.id) == identity.columnIDs,
              session.tablePresentations[identity.tableID]?.columns.map({ column in
                  SeriesTablePasteColumnIdentity(id: column.id, sourceType: column.sourceType,
                      isReadOnly: column.readOnly == true,
                      choiceIDs: column.choices?.filter { isDebugMode || $0.debugOnly != true }.map(\.id) ?? [])
              }) == identity.columns else {
            throw SeriesTablePasteError.staleSelection
        }
        guard Set(columns.map(\.id)).count == columns.count else {
            throw SeriesTablePasteError.staleSelection
        }
        let columnByID = Dictionary(uniqueKeysWithValues: columns.map { ($0.id, $0) })
        guard identity.columnIDs.allSatisfy({ columnByID[$0] != nil }) else {
            throw SeriesTablePasteError.staleSelection
        }
        let currentUnits = identity.columnIDs.compactMap { columnID -> SeriesTablePasteUnitIdentity? in
            guard let column = columnByID[columnID],
                  ["double", "float"].contains(column.sourceType.lowercased()) else { return nil }
            let units = unitsByColumn[columnID]
                ?? SeriesTableClipboardPlanner.identityUnits(tableID: identity.tableID, columnID: columnID)
            guard let selected = session.displayUnit(units) else { return nil }
            return .init(columnID: columnID, selectionID: units.selectionId, sourceID: units.sourceId,
                selectedUnitID: selected.id,
                choices: units.choices.map { .init(id: $0.id, scale: $0.scale, offset: $0.offset) })
        }
        guard currentUnits == identity.units else { throw SeriesTablePasteError.staleSelection }
        var appliedCellCount = 0
        var failedCellCount = 0
        var invalidNumericDraftCount = 0
        for edit in plan.cells {
            guard let column = columnByID[edit.columnID],
                  let row = session.rows[identity.tableID]?.first(where: { $0.id == edit.rowID }) else {
                throw SeriesTablePasteError.staleSelection
            }
            if column.readOnly == true {
                // A source capability change between planning and application is stale.
                throw SeriesTablePasteError.staleSelection
            }
            let oldSourceValue = row.fieldBindings[edit.columnID].flatMap { session.fields[$0] }
                ?? row.values[edit.columnID] ?? ""
            if ["double", "float"].contains(column.sourceType.lowercased()),
               column.choices?.isEmpty != false {
                let units = unitsByColumn[edit.columnID]
                    ?? SeriesTableClipboardPlanner.identityUnits(tableID: identity.tableID, columnID: edit.columnID)
                let owner = OriginalUnitNumberInputOwner.tableCell(tableID: identity.tableID,
                    rowID: edit.rowID, columnID: edit.columnID)
                guard session.updateUnitNumberInput(rawText: edit.value, owner: owner, units: units,
                                                     locale: locale) != nil else {
                    failedCellCount += 1
                    continue
                }
                if let draft = session.unitNumberInputDraft(for: owner) {
                    if !draft.isStale, draft.issueKey == OriginalUnitNumberInputIssue.invalidNumber,
                       draft.rawDisplayText == edit.value {
                        invalidNumericDraftCount += 1
                    } else {
                        failedCellCount += 1
                    }
                    continue
                }
                let updatedValue = session.rows[identity.tableID]?.first(where: { $0.id == edit.rowID })?.values[edit.columnID]
                if updatedValue != oldSourceValue { appliedCellCount += 1 }
                continue
            }
            guard let sourceValue = SeriesTablePasteValue.sourceText(from: edit.value, column: column,
                                                                     isDebugMode: isDebugMode) else {
                failedCellCount += 1
                continue
            }
            if sourceValue == oldSourceValue { continue }
            session.setCell(table: identity.tableID, rowID: edit.rowID,
                            column: edit.columnID, value: sourceValue)
            let updatedRow = session.rows[identity.tableID]?.first(where: { $0.id == edit.rowID })
            let updatedValue = updatedRow?.fieldBindings[edit.columnID].flatMap { session.fields[$0] }
                ?? updatedRow?.values[edit.columnID]
            if updatedValue == sourceValue {
                appliedCellCount += 1
            } else {
                failedCellCount += 1
            }
        }
        return .init(appliedCellCount: appliedCellCount, failedCellCount: failedCellCount,
                     invalidNumericDraftCount: invalidNumericDraftCount,
                     skippedReadOnlyCellCount: plan.skippedReadOnlyCellCount)
    }
}

extension SeriesTableClipboardPlanner {
    static func identityUnits(tableID: String, columnID: String) -> DisplayUnitData {
        let selectionID = "SeriesTable/\(tableID)/\(columnID)/source"
        return .init(sourceId: "source", selectionId: selectionID,
                     choices: [.init(id: "source", scale: 1, offset: 0)])
    }
}
