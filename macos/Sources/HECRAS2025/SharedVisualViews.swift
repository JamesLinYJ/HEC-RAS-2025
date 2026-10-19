import AppKit
import SwiftUI

// Native building blocks for Visual.Core.WinUI.Controls. These views keep
// source state and actions explicit; callers provide the real filter, search,
// validation, and job data.

enum SharedVisualMessageSeverity: Hashable, Sendable {
    case information
    case trace
    case debug
    case warning
    case error

    var iconName: String {
        switch self {
        case .information, .trace, .debug: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var isError: Bool { self == .error }
    var isWarning: Bool { self == .warning }

    var confirmationIconName: String {
        switch self {
        case .information: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .trace, .debug, .error: "xmark.octagon.fill"
        }
    }

    var confirmationIsError: Bool { self != .information && self != .warning }
}

struct SharedVisualAlertBox: View {
    let title: String
    let description: String
    var primaryButtonTitle: String?
    var canCancel = true
    var canAccept = true
    var onAccept: (() -> Void)?
    var onCancel: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text(title)).font(.title3.weight(.semibold))
            Text(L10n.text(description)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if canCancel {
                    Button(L10n.text("Cancel"), role: .cancel) {
                        onCancel?()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                if let primaryButtonTitle, !primaryButtonTitle.isEmpty {
                    Button {
                        onAccept?()
                        dismiss()
                    } label: { Text(L10n.text(primaryButtonTitle)) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAccept)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 360, idealWidth: 440, alignment: .leading)
        .accessibilityElement(children: .contain)
        .interactiveDismissDisabled(!canCancel)
    }
}

struct SharedVisualAlertBoxPresentationError: LocalizedError {
    let errorDescription: String?

    // Capture the chosen interface language when the UI creates the error.
    // Error descriptions may later be read outside the main actor.
    @MainActor static var noActiveWindow: Self {
        Self(errorDescription: L10n.text("A window is required to present this dialog."))
    }
    @MainActor static var noActions: Self {
        Self(errorDescription: L10n.text("A primary or cancel action is required to present this dialog."))
    }
}

enum SharedVisualAlertBoxResponse {
    static func isAccepted(hasPrimaryButton: Bool, response: NSApplication.ModalResponse) -> Bool {
        hasPrimaryButton && response == .alertFirstButtonReturn
    }
}

/// Native asynchronous modal host corresponding to AlertBox.ShowDialog.
/// The continuation completes only after the sheet is dismissed, then calls
/// exactly one of the source accept/cancel callbacks.
@MainActor
enum SharedVisualAlertBoxModalHost {
    static func showDialog(
        title: String,
        description: String,
        primaryButtonTitle: String,
        canCancel: Bool = true,
        onAccept: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil,
        window: NSWindow? = NSApp.keyWindow ?? NSApp.mainWindow
    ) async throws -> Bool {
        guard let window else { throw SharedVisualAlertBoxPresentationError.noActiveWindow }
        let hasPrimaryButton = !primaryButtonTitle.isEmpty
        guard hasPrimaryButton || canCancel else { throw SharedVisualAlertBoxPresentationError.noActions }

        let alert = NSAlert()
        alert.messageText = L10n.text(title)
        alert.informativeText = L10n.text(description)
        alert.alertStyle = .informational
        if hasPrimaryButton {
            alert.addButton(withTitle: L10n.text(primaryButtonTitle))
        }
        if canCancel { alert.addButton(withTitle: L10n.text("Cancel")) }

        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
        let accepted = SharedVisualAlertBoxResponse.isAccepted(hasPrimaryButton: hasPrimaryButton, response: response)
        if accepted { onAccept?() }
        else if canCancel { onCancel?() }
        return accepted
    }
}

struct SharedVisualConfirmActionControl: View {
    let text: String
    let severity: SharedVisualMessageSeverity
    var continueTitle = "Continue"
    var cancelTitle = "Cancel"
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label {
                Text(L10n.text(text)).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: severity.confirmationIconName)
                    .foregroundStyle(severity.confirmationIsError ? .red : severity.isWarning ? .orange : .blue)
            }
            HStack {
                Spacer()
                Button(L10n.text(cancelTitle), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text(continueTitle), action: onContinue)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .accessibilityElement(children: .contain)
    }
}

struct SharedVisualConfirmActionDialog: View {
    let text: String
    let severity: SharedVisualMessageSeverity
    @Binding var isPresented: Bool
    @Binding var succeeded: Bool?

    var body: some View {
        SharedVisualConfirmActionControl(text: text, severity: severity, onContinue: {
            succeeded = true
            isPresented = false
        }, onCancel: {
            succeeded = false
            isPresented = false
        })
        .frame(minWidth: 360, idealWidth: 440)
        .interactiveDismissDisabled()
    }
}

struct SharedVisualClearFiltersBanner: View {
    var text = "Filters Active"
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(.tint)
            Text(L10n.text(text)).font(.callout.weight(.medium))
            Spacer(minLength: 8)
            Button(L10n.text("Clear"), systemImage: "xmark", action: clear)
                .labelStyle(.titleAndIcon)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain)
    }
}

struct SharedVisualFilterSearchBar<FilterContent: View>: View {
    @Binding var searchText: String
    var placeholder = "Search…"
    var filterIsActive = false
    var clearFilters: (() -> Void)?
    let filterContent: FilterContent

    init(
        searchText: Binding<String>,
        placeholder: String = "Search…",
        filterIsActive: Bool = false,
        clearFilters: (() -> Void)? = nil,
        @ViewBuilder filterContent: () -> FilterContent
    ) {
        _searchText = searchText
        self.placeholder = placeholder
        self.filterIsActive = filterIsActive
        self.clearFilters = clearFilters
        self.filterContent = filterContent()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.text(placeholder), text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(L10n.text(placeholder))
                if !searchText.isEmpty {
                    Button(L10n.text("Clear Search"), systemImage: "xmark.circle.fill") { searchText = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                Menu {
                    filterContent
                    if let clearFilters {
                        Divider()
                        Button(L10n.text("Clear Filters"), systemImage: "line.3.horizontal.decrease.circle") { clearFilters() }
                            .disabled(!filterIsActive)
                    }
                } label: {
                    Label(L10n.text("Filter"), systemImage: filterIsActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .help(L10n.text("Filter"))
                }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            if filterIsActive, let clearFilters {
                SharedVisualClearFiltersBanner(clear: clearFilters)
            }
        }
    }
}

struct SharedVisualSearchResult: Identifiable, Hashable, Sendable {
    let id: String
    let engineID: String
    var engineTitle: String
    let title: String
    var description: String? = nil
    var symbol: String? = nil
    var category: String? = nil
    var score: Double = 0

    init(id: String, title: String, description: String? = nil, symbol: String? = nil, category: String? = nil, score: Double = 0, engineID: String = "", engineTitle: String = "") {
        self.id = id
        self.engineID = engineID
        self.engineTitle = engineTitle
        self.title = title
        self.description = description
        self.symbol = symbol
        self.category = category
        self.score = score
    }
}

@MainActor
struct SharedVisualSearchEngine: Identifiable {
    let id: String
    var title: String
    let search: (String) async -> [SharedVisualSearchResult]
}

struct SharedVisualSearchResultsControl: View {
    let results: [SharedVisualSearchResult]
    @Binding var showMoreResults: Bool
    @Binding var highlightedResultID: String?
    let onSelect: (SharedVisualSearchResult) -> Void

    private var visibleResults: [SharedVisualSearchResult] {
        guard !showMoreResults else { return results }
        var counts: [String: Int] = [:]
        return results.filter { result in
            counts[result.engineID, default: 0] += 1
            return counts[result.engineID, default: 0] <= 6
        }
    }
    private var hasMoreResults: Bool {
        Dictionary(grouping: results, by: \.engineID).values.contains { $0.count > 6 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if results.isEmpty {
                Text(L10n.text("No results")).foregroundStyle(.secondary).padding(14)
            } else {
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(visibleResults) { result in
                                Button {
                                    highlightedResultID = result.id
                                    onSelect(result)
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                                            if let symbol = result.symbol {
                                                Image(systemName: symbol).frame(width: 18)
                                            }
                                            Text(L10n.text(result.title)).font(.body)
                                            Spacer(minLength: 4)
                                            if let category = result.category, !category.isEmpty {
                                                Text(L10n.text(category)).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        if let description = result.description, !description.isEmpty {
                                            Text(L10n.text(description)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .background(highlightedResultID == result.id ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .help(L10n.text(result.engineTitle))
                                .id(result.id)
                                .onHover { isHovering in if isHovering { highlightedResultID = result.id } }
                            }
                        }
                    }
                    .frame(maxHeight: 300)
                    .onChange(of: highlightedResultID) { _, id in if let id { scroll.scrollTo(id, anchor: .center) } }
                }
            }
            if hasMoreResults {
                Divider()
                Toggle(L10n.text(showMoreResults ? "Show Fewer" : "Show More"), isOn: $showMoreResults)
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(8)
            }
        }
        .frame(minWidth: 320, idealWidth: 420)
        .accessibilityLabel(L10n.text("Search Results"))
    }
}

struct SharedVisualSearchBarWithResultsPopup: View {
    @Binding var searchText: String
    let engines: [SharedVisualSearchEngine]
    var placeholder = "Search…"
    var inlineResults = false
    var searchWhenEmpty = false
    var focusOnAppear = false
    var searchRevision = ""
    let onSelect: (SharedVisualSearchResult) -> Void
    @State private var results: [SharedVisualSearchResult] = []
    @State private var showMoreResults = false
    @State private var highlightedResultID: String?
    @State private var popupIsPresented = false
    @State private var isSearching = false
    @FocusState private var isFocused: Bool

    private var requestKey: String {
        [searchText, String(searchWhenEmpty), searchRevision, engines.map(\.id).joined(separator: "\u{1f}")].joined(separator: "\u{1f}")
    }

    var body: some View {
        Group {
            if inlineResults {
                VStack(spacing: 8) {
                    searchField
                    resultsContent
                }
            } else {
                searchField
                    .popover(isPresented: $popupIsPresented, arrowEdge: .bottom) {
                        resultsContent
                    }
            }
        }
        .task(id: requestKey) {
            let query = searchText
            let requestedRevision = searchRevision
            let requestedEngineIDs = engines.map(\.id)
            guard !Task.isCancelled, searchText == query, searchRevision == requestedRevision, engines.map(\.id) == requestedEngineIDs else { return }
            guard searchWhenEmpty || !query.isEmpty, !engines.isEmpty else {
                results = []
                isSearching = false
                return
            }
            isSearching = true
            results = []
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard !Task.isCancelled, searchText == query, searchRevision == requestedRevision, engines.map(\.id) == requestedEngineIDs else { return }
            for engine in engines {
                let found = await engine.search(query)
                    .sorted { $0.score > $1.score }
                    .map { result in
                        SharedVisualSearchResult(
                            id: engine.id + "/" + result.id,
                            title: result.title,
                            description: result.description,
                            symbol: result.symbol,
                            category: result.category,
                            score: result.score,
                            engineID: engine.id,
                            engineTitle: engine.title
                        )
                    }
                guard !Task.isCancelled, searchText == query, searchRevision == requestedRevision, engines.map(\.id) == requestedEngineIDs else { return }
                results.append(contentsOf: found)
            }
            guard !Task.isCancelled, searchText == query, searchRevision == requestedRevision, engines.map(\.id) == requestedEngineIDs else { return }
            isSearching = false
            if !results.contains(where: { $0.id == highlightedResultID }) { highlightedResultID = visibleResults.first?.id }
            popupIsPresented = !inlineResults && (searchWhenEmpty || !query.isEmpty)
        }
        .onChange(of: searchText) { _, query in
            showMoreResults = false
            highlightedResultID = nil
            results = []
            isSearching = searchWhenEmpty || !query.isEmpty
            popupIsPresented = !inlineResults && (searchWhenEmpty || !query.isEmpty)
        }
        .onChange(of: searchRevision) { _, _ in
            showMoreResults = false
            highlightedResultID = nil
            results = []
            isSearching = searchWhenEmpty || !searchText.isEmpty
        }
        .onChange(of: inlineResults) { _, isInline in
            popupIsPresented = !isInline && (searchWhenEmpty || !searchText.isEmpty)
        }
    }

    private var searchField: some View {
        TextField(L10n.text(placeholder), text: $searchText)
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .overlay(alignment: .leading) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).padding(.leading, 8).allowsHitTesting(false)
            }
            .padding(.leading, 24)
            .onAppear { if focusOnAppear { isFocused = true } }
            .onSubmit { performHighlightedSelection() }
            .onKeyPress(.downArrow) { moveSelection(1); return .handled }
            .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
    }

    private var resultsContent: some View {
        VStack(spacing: 0) {
            if isSearching { ProgressView().controlSize(.small).padding(8) }
            SharedVisualSearchResultsControl(results: results, showMoreResults: $showMoreResults, highlightedResultID: $highlightedResultID, onSelect: select)
        }
    }

    private var visibleResults: [SharedVisualSearchResult] {
        guard !showMoreResults else { return results }
        var counts: [String: Int] = [:]
        return results.filter { result in
            counts[result.engineID, default: 0] += 1
            return counts[result.engineID, default: 0] <= 6
        }
    }

    private func moveSelection(_ delta: Int) {
        let items = visibleResults
        guard !items.isEmpty else { highlightedResultID = nil; return }
        let current = items.firstIndex(where: { $0.id == highlightedResultID }) ?? (delta > 0 ? -1 : 0)
        highlightedResultID = items[(current + delta + items.count) % items.count].id
        popupIsPresented = true
    }

    private func performHighlightedSelection() {
        if let result = visibleResults.first(where: { $0.id == highlightedResultID }) ?? visibleResults.first {
            select(result)
        }
    }

    private func select(_ result: SharedVisualSearchResult) {
        onSelect(result)
        popupIsPresented = false
    }
}

enum SharedVisualValidationLevel: Hashable, Sendable {
    case success
    case warn
    case error
    case typeError

    var severity: SharedVisualMessageSeverity {
        switch self {
        case .success: .information
        case .warn: .warning
        case .error, .typeError: .error
        }
    }
}

struct SharedVisualValidationMessage: Identifiable, Hashable, Sendable {
    let id: String
    let text: String
    let level: SharedVisualValidationLevel
    var severity: SharedVisualMessageSeverity { level.severity }
}

struct SharedVisualValidationErrorList: View {
    let errors: [SharedVisualValidationMessage]
    var emptyTitle = "No validation issues"

    var body: some View {
        if errors.isEmpty {
            Label(L10n.text(emptyTitle), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(errors) { error in
                    Label {
                        Text(L10n.text(error.text)).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: error.severity.iconName)
                            .foregroundStyle(error.severity.isError ? .red : error.severity.isWarning ? .orange : .blue)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

struct SharedVisualErrorWarningInfoIcon: View {
    let severity: SharedVisualMessageSeverity
    var showInfoIcon = false
    var message: String? = nil
    var iconSize: CGFloat = 16

    private var shouldShow: Bool { severity != .information && severity != .trace && severity != .debug || showInfoIcon }
    var body: some View {
        if shouldShow {
            Image(systemName: severity.iconName)
                .font(.system(size: iconSize))
                .foregroundStyle(severity.isError ? .red : severity.isWarning ? .orange : .blue)
                .help(message.map(L10n.text) ?? L10n.text(severity.isError ? "Error" : severity.isWarning ? "Warning" : "Information"))
                .accessibilityLabel(L10n.text(severity.isError ? "Error" : severity.isWarning ? "Warning" : "Information"))
        }
    }
}

struct SharedVisualEmptySelectionOverlay<Content: View>: View {
    let isEmpty: Bool
    let text: String
    var symbol = "square.dashed"
    let content: Content

    init(isEmpty: Bool, text: String, symbol: String = "square.dashed", @ViewBuilder content: () -> Content) {
        self.isEmpty = isEmpty
        self.text = text
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        content.overlay {
            if isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text(L10n.text(text)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(22)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

struct SharedVisualCollapsibleContainerItem: Identifiable {
    let id: String
    let title: String
    var description: String?
    var systemImage: String?
    let isVisible: Bool
    let content: AnyView

    init<Content: View>(
        id: String,
        title: String,
        description: String? = nil,
        systemImage: String? = nil,
        isVisible: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.systemImage = systemImage
        self.isVisible = isVisible
        self.content = AnyView(content())
    }
}

struct SharedVisualCollapsibleContainer: View {
    let items: [SharedVisualCollapsibleContainerItem]
    @Binding var isCollapsed: Bool
    @Binding var selectedTabIndex: Int
    var collapseWidth: CGFloat = 0
    var collapseHeight: CGFloat = 0
    var collapseHysteresis: CGFloat = 24
    var flexBoxChangeWidth: CGFloat = 600
    var forceFlexBoxVertical = false
    @State private var visibilityOverrides: [String: Bool] = [:]

    private var visibleIndices: [Int] { items.indices.filter { isVisible(items[$0]) } }

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(items) { item in
                            Toggle(isOn: visibilityBinding(for: item)) {
                                if let systemImage = item.systemImage {
                                    Label(L10n.text(item.title), systemImage: systemImage)
                                } else {
                                    Text(L10n.text(item.title))
                                }
                            }
                            .help(item.description.map(L10n.text) ?? L10n.text(item.title))
                        }
                    } label: {
                        Label(L10n.text("Panels"), systemImage: "square.grid.2x2")
                    }
                    .disabled(items.isEmpty)
                    Spacer()
                    Button {
                        isCollapsed.toggle()
                    } label: {
                        Label(L10n.text(isCollapsed ? "Expand Panels" : "Collapse Panels"), systemImage: isCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.text(isCollapsed ? "Expand Panels" : "Collapse Panels"))
                    .disabled(visibleIndices.isEmpty)
                }
                Group {
                    if isCollapsed {
                        if visibleIndices.isEmpty {
                            EmptyView()
                        } else {
                            TabView(selection: $selectedTabIndex) {
                                ForEach(visibleIndices, id: \.self) { index in
                                    items[index].content
                                        .tabItem {
                                            if let systemImage = items[index].systemImage {
                                                Label(L10n.text(items[index].title), systemImage: systemImage)
                                            } else {
                                                Text(L10n.text(items[index].title))
                                            }
                                        }
                                        .tag(index)
                                }
                            }
                        }
                    } else {
                        let columns = columnCount(for: geometry.size.width)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), alignment: .leading, spacing: 8) {
                            ForEach(visibleIndices, id: \.self) { index in
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack(alignment: .top, spacing: 7) {
                                        if let systemImage = items[index].systemImage {
                                            Image(systemName: systemImage).foregroundStyle(.tint)
                                        }
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(L10n.text(items[index].title)).font(.headline)
                                            if let description = items[index].description, !description.isEmpty {
                                                Text(L10n.text(description)).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    items[index].content
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                }
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(10)
                                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .onAppear { evaluateCollapse(width: geometry.size.width, height: geometry.size.height) }
            .onChange(of: geometry.size) { _, size in evaluateCollapse(width: size.width, height: size.height) }
            .onChange(of: isCollapsed) { _, _ in normalizeSelection() }
            .onChange(of: items.map(\.id)) { _, ids in
                visibilityOverrides = visibilityOverrides.filter { ids.contains($0.key) }
                normalizeSelection()
            }
        }
    }

    private func isVisible(_ item: SharedVisualCollapsibleContainerItem) -> Bool {
        visibilityOverrides[item.id] ?? item.isVisible
    }

    private func visibilityBinding(for item: SharedVisualCollapsibleContainerItem) -> Binding<Bool> {
        Binding(get: { isVisible(item) }, set: { visibilityOverrides[item.id] = $0; normalizeSelection() })
    }

    private func evaluateCollapse(width: CGFloat, height: CGFloat) {
        guard collapseWidth > 0 || collapseHeight > 0 else { return }
        let hysteresis = isCollapsed ? max(0, collapseHysteresis) : 0
        let widthIsBelow = collapseWidth > 0 && width > 0 && width <= collapseWidth + hysteresis
        let heightIsBelow = collapseHeight > 0 && height > 0 && height <= collapseHeight + hysteresis
        let shouldCollapse = widthIsBelow || heightIsBelow
        if shouldCollapse != isCollapsed { isCollapsed = shouldCollapse }
        normalizeSelection()
    }

    private func normalizeSelection() {
        guard let first = visibleIndices.first else { selectedTabIndex = 0; return }
        if !visibleIndices.contains(selectedTabIndex) { selectedTabIndex = first }
    }

    private func columnCount(for width: CGFloat) -> Int {
        guard !forceFlexBoxVertical else { return 1 }
        if flexBoxChangeWidth > 0, width < flexBoxChangeWidth { return 1 }
        return max(1, Int(width / 250))
    }
}

struct SharedVisualCollapsibleListView<Item: Identifiable, Row: View>: View where Item.ID: Hashable {
    enum SelectionMode { case single, multiple, extended }
    let items: [Item]
    @Binding var selectedIDs: Set<Item.ID>
    @Binding var isCollapsed: Bool
    var title = "Items"
    var selectionMode: SelectionMode = .extended
    let row: (Item) -> Row
    @State private var selectionAnchorID: Item.ID?

    init(items: [Item], selectedIDs: Binding<Set<Item.ID>>, isCollapsed: Binding<Bool>, title: String = "Items", selectionMode: SelectionMode = .extended, @ViewBuilder row: @escaping (Item) -> Row) {
        self.items = items
        _selectedIDs = selectedIDs
        _isCollapsed = isCollapsed
        self.title = title
        self.selectionMode = selectionMode
        self.row = row
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.text(title)).font(.headline)
                Spacer()
                Button {
                    isCollapsed.toggle()
                } label: {
                    Label(L10n.text(isCollapsed ? "Expand List" : "Collapse List"), systemImage: isCollapsed ? "chevron.down" : "chevron.up")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(L10n.text(isCollapsed ? "Expand List" : "Collapse List"))
                .accessibilityLabel(L10n.text(isCollapsed ? "Expand List" : "Collapse List"))
            }
            Group {
                if isCollapsed {
                    Menu {
                        rows
                    } label: {
                        HStack {
                            if let selected = items.first(where: { selectedIDs.contains($0.id) }) ?? items.first {
                                row(selected)
                            } else {
                                Text(L10n.text("No items"))
                            }
                            Spacer()
                            Image(systemName: "chevron.down")
                        }
                    }
                    .disabled(items.isEmpty)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) { rows }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .onChange(of: items.map(\.id)) { _, orderedIDs in
            var selection = SharedVisualExtendedSelectionState(selectedIDs: selectedIDs, anchorID: selectionAnchorID)
            selection.retainAvailableItems(orderedIDs)
            selectedIDs = selection.selectedIDs
            selectionAnchorID = selection.anchorID
        }
    }

    @ViewBuilder private var rows: some View {
        ForEach(items) { item in
            Button { select(item) } label: {
                HStack(spacing: 8) {
                    row(item)
                    Spacer(minLength: 4)
                    if selectedIDs.contains(item.id) { Image(systemName: "checkmark").foregroundStyle(.tint) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selectedIDs.contains(item.id) ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func select(_ item: Item) {
        switch selectionMode {
        case .single:
            selectedIDs = [item.id]
            selectionAnchorID = item.id
        case .multiple:
            if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) }
            else { selectedIDs.insert(item.id) }
            selectionAnchorID = item.id
        case .extended:
            var modifiers: SharedVisualListSelectionModifiers = []
            let flags = NSEvent.modifierFlags
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.control) { modifiers.insert(.control) }
            if flags.contains(.shift) { modifiers.insert(.shift) }

            var selection = SharedVisualExtendedSelectionState(selectedIDs: selectedIDs, anchorID: selectionAnchorID)
            selection.select(item.id, orderedIDs: items.map(\.id), modifiers: modifiers)
            selectedIDs = selection.selectedIDs
            selectionAnchorID = selection.anchorID
        }
    }
}

struct SharedVisualDualPanelAdaptiveItem: Identifiable {
    let id: String
    let estimatedHeight: CGFloat
    let content: AnyView

    init<Content: View>(id: String, estimatedHeight: CGFloat = 1, @ViewBuilder content: () -> Content) {
        self.id = id
        self.estimatedHeight = estimatedHeight.isFinite ? max(1, estimatedHeight) : 1
        self.content = AnyView(content())
    }
}

enum SharedVisualDualPanelRebalancer {
    static func rebalance<Item>(items: [Item], height: (Item) -> CGFloat) -> ([Item], [Item]) {
        func measuredHeight(_ item: Item) -> CGFloat {
            let value = height(item)
            return value.isFinite ? max(0, value) : 0
        }
        var left: [Item] = []
        var right = items
        var leftHeight: CGFloat = 0
        var rightHeight = right.reduce(CGFloat.zero) { $0 + measuredHeight($1) }

        // The source starts every item on the right, then moves the last
        // left item right and the first right item left when each move improves
        // the measured height difference.
        while true {
            var didImprove = false
            var bestDifference = abs(leftHeight - rightHeight)
            if let last = left.last {
                let itemHeight = measuredHeight(last)
                let candidateDifference = abs((leftHeight - itemHeight) - (rightHeight + itemHeight))
                if candidateDifference < bestDifference {
                    left.removeLast()
                    right.insert(last, at: 0)
                    leftHeight -= itemHeight
                    rightHeight += itemHeight
                    bestDifference = candidateDifference
                    didImprove = true
                }
            }
            if let first = right.first {
                let itemHeight = measuredHeight(first)
                let candidateDifference = abs((leftHeight + itemHeight) - (rightHeight - itemHeight))
                if candidateDifference < bestDifference {
                    right.removeFirst()
                    left.append(first)
                    leftHeight += itemHeight
                    rightHeight -= itemHeight
                    didImprove = true
                }
            }
            if !didImprove { break }
        }
        return (left, right)
    }

    static func shouldAcceptMeasurement(previousHeight: CGFloat?, proposedHeight: CGFloat, threshold: CGFloat = 10) -> Bool {
        guard proposedHeight.isFinite, proposedHeight >= 0, threshold.isFinite else { return false }
        guard let previousHeight else { return proposedHeight > 0 }
        return abs(previousHeight - proposedHeight) >= max(0, threshold)
    }
}

private struct SharedVisualMeasuredItemHeights: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

struct SharedVisualDualPanelAdaptiveLayout: View {
    let items: [SharedVisualDualPanelAdaptiveItem]
    var desiredItemWidth: CGFloat = 250
    @State private var measuredHeights: [String: CGFloat] = [:]

    private var balancedColumns: ([SharedVisualDualPanelAdaptiveItem], [SharedVisualDualPanelAdaptiveItem]) {
        func height(_ item: SharedVisualDualPanelAdaptiveItem) -> CGFloat {
            measuredHeights[item.id] ?? item.estimatedHeight
        }
        return SharedVisualDualPanelRebalancer.rebalance(items: items, height: height)
    }

    var body: some View {
        GeometryReader { geometry in
            if items.count < 2 || geometry.size.width < max(0, desiredItemWidth) * 2 {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { measuredContent($0) }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            } else {
                let columns = balancedColumns
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 8) { ForEach(columns.0) { measuredContent($0) } }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) { ForEach(columns.1) { measuredContent($0) } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onPreferenceChange(SharedVisualMeasuredItemHeights.self) { newHeights in
            let changed = newHeights.contains { id, height in
                SharedVisualDualPanelRebalancer.shouldAcceptMeasurement(previousHeight: measuredHeights[id], proposedHeight: height)
            }
            guard changed else { return }
            measuredHeights.merge(newHeights, uniquingKeysWith: { _, next in next })
        }
        .onChange(of: items.map(\.id)) { _, ids in
            measuredHeights = measuredHeights.filter { ids.contains($0.key) }
        }
    }

    private func measuredContent(_ item: SharedVisualDualPanelAdaptiveItem) -> some View {
        item.content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: SharedVisualMeasuredItemHeights.self, value: [item.id: geometry.size.height])
                }
            }
    }
}

struct SharedVisualResponsiveListDetailLayout<ListContent: View, DetailContent: View>: View {
    let hasDetail: Bool
    var changeWidth: CGFloat = 500
    var listMaxHeight: CGFloat = 250
    var listMaxWidth: CGFloat = 350
    var onBack: (() -> Void)?
    let listContent: ListContent
    let detailContent: DetailContent

    init(hasDetail: Bool, changeWidth: CGFloat = 500, listMaxHeight: CGFloat = 250, listMaxWidth: CGFloat = 350, onBack: (() -> Void)? = nil, @ViewBuilder listContent: () -> ListContent, @ViewBuilder detailContent: () -> DetailContent) {
        self.hasDetail = hasDetail
        self.changeWidth = changeWidth
        self.listMaxHeight = listMaxHeight
        self.listMaxWidth = listMaxWidth
        self.onBack = onBack
        self.listContent = listContent()
        self.detailContent = detailContent()
    }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= changeWidth {
                HStack(spacing: 0) {
                    listContent.frame(maxWidth: listMaxWidth, maxHeight: .infinity, alignment: .topLeading)
                    Divider()
                    detailContent.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else if hasDetail {
                VStack(alignment: .leading, spacing: 10) {
                    if let onBack {
                        Button(L10n.text("Back"), systemImage: "chevron.left", action: onBack)
                            .labelStyle(.titleAndIcon)
                            .controlSize(.small)
                    }
                    detailContent.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else {
                listContent.frame(maxWidth: .infinity, maxHeight: min(listMaxHeight, geometry.size.height), alignment: .topLeading)
            }
        }
    }
}

struct SharedVisualListDetailPanel<ListContent: View, DetailContent: View>: View {
    let hasDetail: Bool
    var changeWidth: CGFloat = 500
    var listMaxHeight: CGFloat = 250
    var listMaxWidth: CGFloat = 350
    var onBack: (() -> Void)?
    let listContent: ListContent
    let detailContent: DetailContent

    init(hasDetail: Bool, changeWidth: CGFloat = 500, listMaxHeight: CGFloat = 250, listMaxWidth: CGFloat = 350, onBack: (() -> Void)? = nil, @ViewBuilder listContent: () -> ListContent, @ViewBuilder detailContent: () -> DetailContent) {
        self.hasDetail = hasDetail
        self.changeWidth = changeWidth
        self.listMaxHeight = listMaxHeight
        self.listMaxWidth = listMaxWidth
        self.onBack = onBack
        self.listContent = listContent()
        self.detailContent = detailContent()
    }

    var body: some View {
        SharedVisualResponsiveListDetailLayout(hasDetail: hasDetail, changeWidth: changeWidth, listMaxHeight: listMaxHeight, listMaxWidth: listMaxWidth, onBack: onBack, listContent: { listContent }, detailContent: { detailContent })
    }
}

enum SharedVisualTablePresentation: String, CaseIterable, Identifiable {
    case list
    case table
    nonisolated var id: String { rawValue }
    @MainActor
    var title: String {
        L10n.text(rawValue.capitalized)
    }
}

struct SharedVisualTableOrListControl<ListContent: View, TableContent: View>: View {
    @Binding var selectedPresentation: SharedVisualTablePresentation
    let listContent: ListContent
    let tableContent: TableContent

    init(selectedPresentation: Binding<SharedVisualTablePresentation>, @ViewBuilder listContent: () -> ListContent, @ViewBuilder tableContent: () -> TableContent) {
        _selectedPresentation = selectedPresentation
        self.listContent = listContent()
        self.tableContent = tableContent()
    }

    var body: some View {
        VStack(spacing: 8) {
            Picker(L10n.text("Presentation"), selection: $selectedPresentation) {
                ForEach(SharedVisualTablePresentation.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if selectedPresentation == .list { listContent }
            else { tableContent }
        }
    }
}

struct SharedVisualListDetailTableControl<ListContent: View, DetailContent: View, TableContent: View>: View {
    @Binding var selectedPresentation: SharedVisualTablePresentation
    let hasDetail: Bool
    var changeWidth: CGFloat = 500
    var listMaxHeight: CGFloat = 250
    var listMaxWidth: CGFloat = 350
    var onBack: (() -> Void)?
    let listContent: ListContent
    let detailContent: DetailContent
    let tableContent: TableContent

    init(selectedPresentation: Binding<SharedVisualTablePresentation>, hasDetail: Bool, changeWidth: CGFloat = 500, listMaxHeight: CGFloat = 250, listMaxWidth: CGFloat = 350, onBack: (() -> Void)? = nil, @ViewBuilder listContent: () -> ListContent, @ViewBuilder detailContent: () -> DetailContent, @ViewBuilder tableContent: () -> TableContent) {
        _selectedPresentation = selectedPresentation
        self.hasDetail = hasDetail
        self.changeWidth = changeWidth
        self.listMaxHeight = listMaxHeight
        self.listMaxWidth = listMaxWidth
        self.onBack = onBack
        self.listContent = listContent()
        self.detailContent = detailContent()
        self.tableContent = tableContent()
    }

    var body: some View {
        SharedVisualTableOrListControl(
            selectedPresentation: $selectedPresentation,
            listContent: {
                SharedVisualListDetailPanel(hasDetail: hasDetail, changeWidth: changeWidth, listMaxHeight: listMaxHeight, listMaxWidth: listMaxWidth, onBack: onBack, listContent: { listContent }, detailContent: { detailContent })
            },
            tableContent: { tableContent }
        )
    }
}

struct SharedVisualDescriptionGroup<Gallery: View>: View {
    @Binding var description: String
    let gallery: Gallery

    init(description: Binding<String>, @ViewBuilder gallery: () -> Gallery) {
        _description = description
        self.gallery = gallery()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Description")).font(.headline)
            TextEditor(text: $description)
                .frame(minHeight: 90)
                .accessibilityLabel(L10n.text("Description"))
            gallery
        }
    }
}

struct SharedVisualMetadataProperty: Identifiable, Hashable, Sendable {
    let id: String
    let key: String
    let value: String
    var isParagraph = false

    init(id: String? = nil, key: String, value: String, isParagraph: Bool? = nil) {
        self.id = id ?? key
        self.key = key
        self.value = value
        self.isParagraph = isParagraph ?? (value.utf16.count > 16)
    }
}

struct SharedVisualMetadataPropertiesRepeater: View {
    let properties: [SharedVisualMetadataProperty]
    var orientation: SharedVisualMetadataOrientation = .vertical

    var body: some View {
        if orientation == .vertical {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(properties.enumerated()), id: \.offset) { _, property in row(property).frame(maxWidth: .infinity, alignment: .leading) }
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(properties.enumerated()), id: \.offset) { _, property in row(property).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }
    }

    @ViewBuilder private func row(_ property: SharedVisualMetadataProperty) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.text(property.key)).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: property.value)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .lineLimit(property.isParagraph ? nil : 1)
        }
    }
}

enum SharedVisualMetadataOrientation: Hashable, Sendable { case vertical, horizontal }

// JobProgressRow and PlaybackControls in their existing files already cover
// the ProgressBarControl and PauseContinueStop contracts with app state.
