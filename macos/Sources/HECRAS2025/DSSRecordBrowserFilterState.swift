import Foundation

enum DSSPartFilterSelection: Hashable {
    case all
    case blank
    case value(String)

    func matches(_ part: String) -> Bool {
        switch self {
        case .all:
            true
        case .blank:
            part.isEmpty
        case .value(let value):
            part == value
        }
    }
}

/// Filter state for the DSS record browser. A catalog reload resets to the
/// source defaults; incremental type changes keep surviving checks and check
/// newly appearing types, matching GenericEnumFilterControl's ItemsSource path.
struct DSSRecordBrowserFilterState {
    static let partCount = 6

    private(set) var recordTypeOptions: [String] = []
    private(set) var selectedRecordTypes: Set<String> = []
    private(set) var partSelections = Array(
        repeating: DSSPartFilterSelection.all,
        count: DSSRecordBrowserFilterState.partCount
    )
    private var hasRecordTypeSnapshot = false

    var allRecordTypesSelected: Bool {
        !recordTypeOptions.isEmpty && Set(recordTypeOptions).isSubset(of: selectedRecordTypes)
    }

    var selectedRecordTypeCount: Int {
        selectedRecordTypes.intersection(recordTypeOptions).count
    }

    mutating func resetForCatalogLoad() {
        recordTypeOptions = []
        selectedRecordTypes = []
        partSelections = Array(repeating: .all, count: Self.partCount)
        hasRecordTypeSnapshot = false
    }

    mutating func updateRecordTypeOptions(_ values: [String]) {
        var observed = Set<String>()
        let orderedValues = values.filter { observed.insert($0).inserted }
        let oldOptions = Set(recordTypeOptions)
        let newOptions = Set(orderedValues)
        if hasRecordTypeSnapshot {
            selectedRecordTypes = selectedRecordTypes.intersection(newOptions)
                .union(newOptions.subtracting(oldOptions))
        } else {
            selectedRecordTypes = newOptions
        }
        // DssCatalogViewer builds ActiveRecordTypes in first-seen catalog order;
        // keep that order in the native filter menu.
        recordTypeOptions = orderedValues
        hasRecordTypeSnapshot = true
    }

    mutating func setRecordType(_ value: String, selected: Bool) {
        guard recordTypeOptions.contains(value) else { return }
        if selected { selectedRecordTypes.insert(value) }
        else { selectedRecordTypes.remove(value) }
    }

    mutating func toggleAllRecordTypes() {
        guard !recordTypeOptions.isEmpty else { return }
        selectedRecordTypes = allRecordTypesSelected ? [] : Set(recordTypeOptions)
    }

    func includesRecordType(_ value: String) -> Bool {
        selectedRecordTypes.contains(value)
    }

    mutating func setPartSelection(_ selection: DSSPartFilterSelection, at index: Int) {
        guard partSelections.indices.contains(index) else { return }
        partSelections[index] = selection
    }

    func matchesParts(_ parts: [String]) -> Bool {
        partSelections.indices.allSatisfy { index in
            let part = parts.indices.contains(index) ? parts[index] : ""
            return partSelections[index].matches(part)
        }
    }
}
