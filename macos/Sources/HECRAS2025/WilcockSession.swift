import Combine
import Foundation

@MainActor
final class WilcockSession: ObservableObject {
    @Published private(set) var snapshot: WilcockWorkspaceSnapshot?
    @Published private(set) var draft = WilcockDraft.empty
    @Published private(set) var caseChoices: [WilcockSessionCase] = []
    @Published private(set) var selectedCaseID: String?
    @Published private(set) var selectedPlotIndex = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isCalculating = false
    @Published private(set) var isStale = false
    @Published private(set) var inputIssueKey: String?
    @Published private(set) var errorMessage: String?

    private let provider: any WilcockProvider
    private var generation: UInt64 = 0
    private var activeTask: Task<WilcockWorkspaceSnapshot, any Error>?
    private var pendingImportConfirmation: ImportConfirmationTicket?

    var isBusy: Bool { isLoading || isCalculating }
    var canAddCase: Bool { snapshot?.canAddCase == true && !isBusy }
    var canRemoveSelectedCase: Bool { snapshot?.canRemoveSelectedCase == true && selectedCaseID != nil && !isBusy }
    var canImportCase: Bool { snapshot?.canImportCase == true && !isBusy }
    var importConfirmationRequired: Bool { hasPendingImportConfirmation }
    var hasPendingImportConfirmation: Bool {
        guard let ticket = pendingImportConfirmation,
              ticket.generation == generation,
              ticket.draft == requestDraft(sourceCaseID: nil),
              ticket.policy == snapshot?.btmImportPolicy,
              snapshot?.importConfirmationRequired == true,
              !isStale else { return false }
        return true
    }
    var btmImportReasonKey: String? { snapshot?.btmImportReasonKey }
    var tables: [WilcockSourceTable] { snapshot?.tables ?? [] }
    var charts: [WilcockSourceChart] { snapshot?.charts ?? [] }
    var calculationIssueKeys: [String] {
        guard let snapshot else { return [] }
        let keys = snapshot.inputIssues.map(\.messageKey)
            + [snapshot.sbtmErrorKey, snapshot.isbtmErrorKey, snapshot.stabErrorKey, snapshot.stateErrorKey].compactMap { $0 }
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    init(provider: any WilcockProvider) {
        self.provider = provider
    }

    @discardableResult
    func load(numberCulture: String? = nil) async -> Bool {
        // The view may run its task more than once. Never replace an active raw draft
        // with source defaults as a side effect of that lifecycle callback.
        if snapshot != nil { return true }
        guard !isLoading, !isCalculating else { return false }
        generation &+= 1
        let requestGeneration = generation
        errorMessage = nil
        inputIssueKey = nil
        isLoading = true
        let culture = (numberCulture ?? Locale.current.identifier).replacingOccurrences(of: "_", with: "-")
        let task = Task { @MainActor in try await provider.load(numberCulture: culture) }
        activeTask = task
        defer {
            if requestGeneration == generation {
                isLoading = false
                activeTask = nil
            }
        }
        do {
            let loaded = try await task.value
            guard requestGeneration == generation, !Task.isCancelled else { return false }
            try loaded.validate()
            accept(loaded, action: nil, submittedDraft: nil, deletedSourceIndex: nil)
            errorMessage = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard requestGeneration == generation else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Replaces editable input while retaining the exact raw strings supplied by controls.
    func editDraft(_ edited: WilcockDraft) {
        guard snapshot != nil, !isLoading else { return }
        var next = edited
        if next.numberCulture == nil {
            next.numberCulture = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        } else {
            next.numberCulture = next.numberCulture?.replacingOccurrences(of: "_", with: "-")
        }
        next.selectedCaseID = selectedCaseChoice?.sourceID
        next.selectedPlotIndex = selectedPlotIndex
        draft = next
        draftDidChange()
    }

    @discardableResult
    func setCell(tableID: String, rowID: String, columnID: String, rawText: String) -> Bool {
        guard !isLoading,
              let table = snapshot?.tables.first(where: { $0.id == tableID && $0.role == .input }),
              let row = table.rows.first(where: { $0.id == rowID }),
              let columnIndex = table.columns.firstIndex(where: { $0.id == columnID && $0.isEditable }),
              row.cells.indices.contains(columnIndex) else { return false }
        var next = draft
        guard next.setCell(tableID: tableID, rowID: rowID, columnID: columnID, rawText: rawText) else { return false }
        draft = next
        updateInputProjection()
        draftDidChange(updateProjection: false)
        return true
    }

    /// Appends the retained wrapper's default value to exactly one variable-sized array.
    /// Parallel CDF/grain arrays remain independent, matching the source wrappers.
    @discardableResult
    func appendInputRow(tableID: String, columnID: String, rawText: String = "0") -> Bool {
        guard !isLoading,
              let table = snapshot?.tables.first(where: { $0.id == tableID && $0.role == .input }),
              table.columns.contains(where: { $0.id == columnID && $0.isEditable }) else { return false }
        var next = draft
        guard next.appendInputCell(tableID: tableID, columnID: columnID, rawText: rawText) else { return false }
        draft = next
        updateInputProjection()
        draftDidChange(updateProjection: false)
        return true
    }

    /// Removes one indexed cell from one variable-sized array. STAB cases use the
    /// separate source add/delete-case actions so Q, supply and distributions stay paired.
    @discardableResult
    func removeInputRow(tableID: String, rowID: String, columnID: String) -> Bool {
        guard !isLoading,
              let table = snapshot?.tables.first(where: { $0.id == tableID && $0.role == .input }),
              table.columns.contains(where: { $0.id == columnID && $0.isEditable }),
              table.rows.contains(where: { $0.id == rowID }) else { return false }
        var next = draft
        guard next.removeInputCell(tableID: tableID, rowID: rowID, columnID: columnID) else { return false }
        draft = next
        updateInputProjection()
        draftDidChange(updateProjection: false)
        return true
    }

    func selectCase(id: String?) {
        guard !isBusy, let id,
              let choice = caseChoices.first(where: { $0.id == id }) else { return }
        if selectedCaseID != choice.id { pendingImportConfirmation = nil }
        selectedCaseID = choice.id
        draft.selectedCaseID = choice.sourceID
        snapshot?.selectedCaseID = choice.sourceID
        snapshot?.draft.selectedCaseID = choice.sourceID
    }

    func selectPlot(index: Int) {
        guard !isBusy, let snapshot, !snapshot.charts.isEmpty else { return }
        let plotCount = snapshot.charts.filter { $0.section == .stab }.count
        guard plotCount > 0 else { return }
        let bounded = min(max(index, 0), plotCount - 1)
        if selectedPlotIndex != bounded { pendingImportConfirmation = nil }
        selectedPlotIndex = bounded
        draft.selectedPlotIndex = bounded
        self.snapshot?.selectedPlotIndex = bounded
        self.snapshot?.draft.selectedPlotIndex = bounded
    }

    @discardableResult
    func calculate() async -> Bool {
        guard !isBusy else { return false }
        return await perform(.calculate)
    }

    @discardableResult
    func addCase() async -> Bool {
        guard !isBusy, snapshot?.canAddCase == true else { return false }
        return await perform(.addCase)
    }

    @discardableResult
    func deleteCase(id: String) async -> Bool {
        guard !isBusy, snapshot?.canRemoveSelectedCase == true,
              let choice = caseChoices.first(where: { $0.id == id }) else { return false }
        return await perform(.removeCase, sourceCaseID: choice.sourceID)
    }

    /// The retained control asks before either appending a compatible case or
    /// replacing incompatible cases. The exact preflight draft must still match.
    @discardableResult
    func importCaseFromBTM(confirmImport: Bool) async -> Bool {
        // A preflight must be allowed to inspect newly edited raw inputs even
        // when the previous snapshot marked import unavailable. The host owns
        // validation for this exact submitted draft.
        guard !isBusy, snapshot != nil else { return false }
        if confirmImport {
            guard hasPendingImportConfirmation else {
                pendingImportConfirmation = nil
                return false
            }
            pendingImportConfirmation = nil
        } else {
            pendingImportConfirmation = nil
        }
        return await perform(.importCaseFromBTM, confirmImport: confirmImport)
    }

    func invalidate() {
        generation &+= 1
        activeTask?.cancel()
        activeTask = nil
        isLoading = false
        isCalculating = false
        isStale = false
        snapshot = nil
        draft = .empty
        caseChoices = []
        selectedCaseID = nil
        selectedPlotIndex = 0
        pendingImportConfirmation = nil
        inputIssueKey = nil
        errorMessage = nil
    }

    private var selectedCaseChoice: WilcockSessionCase? {
        guard let selectedCaseID else { return nil }
        return caseChoices.first(where: { $0.id == selectedCaseID })
    }

    private func draftDidChange(updateProjection: Bool = true) {
        generation &+= 1
        pendingImportConfirmation = nil
        if isCalculating {
            activeTask?.cancel()
            activeTask = nil
            isCalculating = false
        }
        if updateProjection { updateInputProjection() }
        snapshot?.draft = draft
        isStale = true
        errorMessage = nil
        inputIssueKey = nil
    }

    private func updateInputProjection() {
        guard var current = snapshot else { return }
        for tableIndex in current.tables.indices where current.tables[tableIndex].role == .input {
            let tableID = current.tables[tableIndex].id
            guard let rowCount = draft.inputRowCount(for: tableID) else { continue }
            let previousRows = Dictionary(uniqueKeysWithValues: current.tables[tableIndex].rows.map { ($0.id, $0) })
            let rowPrefix = tableID == "stab.caseInputs" ? "case:" :
                ((tableID == "state.transportRates" || tableID == "state.slopes") ? "value:" : "grain:")
            current.tables[tableIndex].rows = (0..<rowCount).map { rowIndex in
                let rowID = "\(rowPrefix)\(rowIndex)"
                let old = previousRows[rowID]
                var cells = Array(repeating: "", count: current.tables[tableIndex].columns.count)
                for columnIndex in current.tables[tableIndex].columns.indices {
                    let column = current.tables[tableIndex].columns[columnIndex]
                    guard column.isEditable,
                          let value = draft.inputCell(tableID: tableID, rowID: rowID, columnID: column.id) else { continue }
                    cells[columnIndex] = value
                }
                return WilcockSourceRow(id: rowID, titleKey: old?.titleKey, caseIndex: old?.caseIndex, cells: cells)
            }
        }
        current.draft = draft
        snapshot = current
    }

    private func perform(_ action: WilcockAction, sourceCaseID: String? = nil,
                         confirmImport: Bool = false) async -> Bool {
        guard !isLoading, !isCalculating, snapshot != nil else { return false }
        pendingImportConfirmation = nil
        generation &+= 1
        let requestGeneration = generation
        let submitted = requestDraft(sourceCaseID: sourceCaseID)
        isCalculating = true
        errorMessage = nil
        let request = WilcockEvaluateRequest(
            draft: submitted,
            action: action,
            caseID: sourceCaseID,
            confirmImport: action == .importCaseFromBTM ? confirmImport : nil
        )
        let task = Task { @MainActor in try await provider.evaluate(request) }
        activeTask = task
        defer {
            if requestGeneration == generation {
                isCalculating = false
                activeTask = nil
            }
        }
        do {
            var response = try await task.value
            guard requestGeneration == generation, !Task.isCancelled else { return false }
            try response.validate()
            response.draft = preservingRawText(after: action, submitted: submitted, response: response,
                                               sourceCaseID: sourceCaseID)
            installResponseTables(into: &response, draft: response.draft)
            accept(response, action: action, submittedDraft: submitted,
                   deletedSourceIndex: sourceCaseID.flatMap(sourceIndex(from:)))
            if action == .importCaseFromBTM,
               !confirmImport,
               response.importConfirmationRequired {
                pendingImportConfirmation = ImportConfirmationTicket(
                    draft: submitted,
                    generation: requestGeneration,
                    policy: response.btmImportPolicy
                )
            }
            errorMessage = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard requestGeneration == generation else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func requestDraft(sourceCaseID: String?) -> WilcockDraft {
        var result = draft
        result.selectedCaseID = sourceCaseID ?? selectedCaseChoice?.sourceID
        result.selectedPlotIndex = selectedPlotIndex
        return result
    }

    private func preservingRawText(after action: WilcockAction, submitted: WilcockDraft,
                                   response: WilcockWorkspaceSnapshot, sourceCaseID: String?) -> WilcockDraft {
        switch action {
        case .calculate:
            return submitted
        case .addCase:
            var result = submitted
            if response.draft.stab.waterDischarges.count == submitted.stab.waterDischarges.count + 1 {
                result.stab.waterDischarges.append(response.draft.stab.waterDischarges.last ?? "")
            }
            if response.draft.stab.sedimentSupplyRates.count == submitted.stab.sedimentSupplyRates.count + 1 {
                result.stab.sedimentSupplyRates.append(response.draft.stab.sedimentSupplyRates.last ?? "")
            }
            if response.draft.stab.transportGrainSizes.count == submitted.stab.transportGrainSizes.count + 1 {
                result.stab.transportGrainSizes.append(response.draft.stab.transportGrainSizes.last ?? [])
            }
            return result
        case .removeCase:
            guard let sourceCaseID, let index = sourceIndex(from: sourceCaseID) else { return response.draft }
            guard submitted.stab.waterDischarges.indices.contains(index),
                  submitted.stab.sedimentSupplyRates.indices.contains(index),
                  submitted.stab.transportGrainSizes.indices.contains(index) else { return response.draft }
            var result = submitted
            result.stab.waterDischarges.remove(at: index)
            result.stab.sedimentSupplyRates.remove(at: index)
            result.stab.transportGrainSizes.remove(at: index)
            result.selectedCaseID = response.draft.selectedCaseID
            return result
        case .importCaseFromBTM:
            var result = submitted
            if response.draft.stab.waterDischarges != submitted.stab.waterDischarges {
                result.stab.waterDischarges = response.draft.stab.waterDischarges
            }
            if response.draft.stab.sedimentSupplyRates != submitted.stab.sedimentSupplyRates {
                result.stab.sedimentSupplyRates = response.draft.stab.sedimentSupplyRates
            }
            if response.draft.stab.transportGrainSizes != submitted.stab.transportGrainSizes {
                result.stab.transportGrainSizes = response.draft.stab.transportGrainSizes
            }
            if response.draft.stab.grainDiameter != submitted.stab.grainDiameter {
                result.stab.grainDiameter = response.draft.stab.grainDiameter
            }
            result.selectedCaseID = response.draft.selectedCaseID
            return result
        }
    }

    private func sourceIndex(from sourceID: String) -> Int? {
        guard sourceID.hasPrefix("case:"), let value = Int(sourceID.dropFirst("case:".count)), value >= 0 else { return nil }
        return value
    }

    private struct ImportConfirmationTicket {
        let draft: WilcockDraft
        let generation: UInt64
        let policy: WilcockBTMImportPolicy
    }

    private func installResponseTables(into response: inout WilcockWorkspaceSnapshot, draft: WilcockDraft) {
        for tableIndex in response.tables.indices where response.tables[tableIndex].role == .input {
            let tableID = response.tables[tableIndex].id
            for rowIndex in response.tables[tableIndex].rows.indices {
                let rowID = response.tables[tableIndex].rows[rowIndex].id
                for columnIndex in response.tables[tableIndex].columns.indices {
                    let column = response.tables[tableIndex].columns[columnIndex]
                    guard column.isEditable,
                          let value = draft.inputCell(tableID: tableID, rowID: rowID, columnID: column.id) else { continue }
                    response.tables[tableIndex].rows[rowIndex].cells[columnIndex] = value
                }
            }
        }
    }

    private func accept(_ response: WilcockWorkspaceSnapshot, action: WilcockAction?,
                        submittedDraft: WilcockDraft?, deletedSourceIndex: Int?) {
        let oldChoices = caseChoices
        var nextIdentityBySourceID: [String: String] = [:]
        let replacing = action == .importCaseFromBTM && response.replacedExistingCases
        for item in response.cases {
            if let deletedSourceIndex {
                let oldIndex = item.index >= deletedSourceIndex ? item.index + 1 : item.index
                if let old = oldChoices.first(where: { $0.sourceIndex == oldIndex }) {
                    nextIdentityBySourceID[item.id] = old.id
                }
            } else if !replacing, let old = oldChoices.first(where: { $0.sourceID == item.id }) {
                nextIdentityBySourceID[item.id] = old.id
            }
            if nextIdentityBySourceID[item.id] == nil { nextIdentityBySourceID[item.id] = UUID().uuidString }
        }
        caseChoices = response.cases.map { item in
            WilcockSessionCase(id: nextIdentityBySourceID[item.id] ?? UUID().uuidString,
                               sourceID: item.id, sourceIndex: item.index,
                               waterDischarge: item.waterDischarge,
                               sedimentSupplyRate: item.sedimentSupplyRate)
        }
        snapshot = response
        draft = response.draft
        let returnedSourceSelection = response.selectedCaseID ?? response.draft.selectedCaseID
        if let retained = caseChoices.first(where: { $0.sourceID == returnedSourceSelection }) {
            selectedCaseID = retained.id
        } else if let existingSelection = submittedDraft?.selectedCaseID,
                  let retained = caseChoices.first(where: { $0.sourceID == existingSelection }) {
            selectedCaseID = retained.id
        } else {
            selectedCaseID = caseChoices.first?.id
        }
        let stabPlotCount = response.charts.filter { $0.section == .stab }.count
        selectedPlotIndex = min(max(response.selectedPlotIndex, 0), max(stabPlotCount - 1, 0))
        draft.selectedCaseID = selectedCaseChoice?.sourceID
        draft.selectedPlotIndex = selectedPlotIndex
        snapshot?.draft = draft
        snapshot?.selectedCaseID = draft.selectedCaseID
        snapshot?.selectedPlotIndex = selectedPlotIndex
        updateInputProjection()
        inputIssueKey = calculationIssueKeys.first
        isStale = false
    }
}

private extension WilcockDraft {
    func inputCell(tableID: String, rowID: String, columnID: String) -> String? {
        func index(_ raw: String, _ prefix: String) -> Int? {
            guard raw.hasPrefix(prefix), let value = Int(raw.dropFirst(prefix.count)), value >= 0 else { return nil }
            return value
        }
        switch tableID {
        case "btm.sbtm.input":
            guard let i = index(rowID, "grain:") else { return nil }
            switch columnID {
            case "grainDiameter": return sbtm.grainDiameter[safe: i]
            case "surfaceCdf": return sbtm.surfaceCdf[safe: i]
            default: return nil
            }
        case "btm.isbtm.input":
            guard let i = index(rowID, "grain:") else { return nil }
            switch columnID {
            case "grainDiameter": return isbtm.grainDiameter[safe: i]
            case "transportCdf": return isbtm.transportCdf[safe: i]
            default: return nil
            }
        case "stab.caseInputs":
            guard let i = index(rowID, "case:") else { return nil }
            switch columnID {
            case "waterDischarge": return stab.waterDischarges[safe: i]
            case "sedimentSupplyRate": return stab.sedimentSupplyRates[safe: i]
            default: return nil
            }
        case "stab.grainSizeDistributions":
            guard let grain = index(rowID, "grain:") else { return nil }
            if columnID == "grainDiameter" { return stab.grainDiameter[safe: grain] }
            guard let caseIndex = index(columnID, "case:") else { return nil }
            return stab.transportGrainSizes[safe: caseIndex]?[safe: grain]
        case "state.grainDistributions":
            guard let i = index(rowID, "grain:") else { return nil }
            switch columnID {
            case "grainDiameter": return state.grainDiameter[safe: i]
            case "firstCDF": return state.firstTransportCdfGrainSize[safe: i]
            case "secondCDF": return state.secondTransportCdfGrainSize[safe: i]
            default: return nil
            }
        case "state.transportRates":
            guard columnID == "transportRate", let i = index(rowID, "value:") else { return nil }
            return state.transportRates[safe: i]
        case "state.slopes":
            guard columnID == "slope", let i = index(rowID, "value:") else { return nil }
            return state.slopes[safe: i]
        default: return nil
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

