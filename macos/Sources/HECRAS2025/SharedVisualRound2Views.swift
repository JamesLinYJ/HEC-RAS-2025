import AppKit
import Foundation
import SwiftUI

// Additional native presentations for retained Visual.Core.WinUI controls.
// These views render only state supplied by their owning feature. File access,
// reflection, validation, and model mutations remain with their source adapter.

/// SearchText/clear affordance for FilterSearchBar routes that have a real
/// search binding but no typed IStringFilter facet model.
struct SharedVisualSearchField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(L10n.text(placeholder), text: $text)
                .textFieldStyle(.plain)
                .accessibilityLabel(L10n.text(placeholder))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("Clear Search"))
                .help(L10n.text("Clear Search"))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

struct SharedVisualContextAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var isEnabled = true
    var isDestructive = false
    var help: String? = nil
    let perform: (Any?) -> Void
}

struct SharedVisualContextActionGrid: View {
    enum Orientation: Equatable { case horizontal, vertical }

    let actions: [SharedVisualContextAction]
    let context: Any?
    var orientation: Orientation = .horizontal
    var maximumRowsOrColumns = Int.max

    private var groupSize: Int { max(1, maximumRowsOrColumns) }
    private var rows: [[SharedVisualContextAction]] {
        guard !actions.isEmpty else { return [] }
        if orientation == .horizontal {
            return stride(from: 0, to: actions.count, by: groupSize).map {
                Array(actions[$0..<min($0 + groupSize, actions.count)])
            }
        }
        let rowCount = min(groupSize, actions.count)
        let columnCount = (actions.count + rowCount - 1) / rowCount
        return (0..<rowCount).map { row in
            (0..<columnCount).compactMap { column in
                let index = column * rowCount + row
                return index < actions.count ? actions[index] : nil
            }
        }
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                GridRow {
                    ForEach(rows[rowIndex]) { item in
                        Button(role: item.isDestructive ? .destructive : nil) {
                            item.perform(context)
                        } label: {
                            Label(L10n.text(item.title), systemImage: item.systemImage)
                                .labelStyle(.iconOnly)
                                .frame(minWidth: 30, minHeight: 28)
                        }
                        .buttonStyle(.borderless)
                        .disabled(!item.isEnabled)
                        .help(item.help.map(L10n.text) ?? L10n.text(item.title))
                        .accessibilityLabel(L10n.text(item.title))
                    }
                }
            }
        }
    }
}

struct SharedVisualDropTarget<Content: View>: View {
    let canDropFolder: Bool
    let canDropMultipleItems: Bool
    let onFilesDropped: ([URL]) -> Bool
    let content: Content
    @State private var isTargeted = false

    init(canDropFolder: Bool = false, canDropMultipleItems: Bool = true, onFilesDropped: @escaping ([URL]) -> Bool, @ViewBuilder content: () -> Content) {
        self.canDropFolder = canDropFolder
        self.canDropMultipleItems = canDropMultipleItems
        self.onFilesDropped = onFilesDropped
        self.content = content()
    }

    var body: some View {
        content
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self, action: { urls, _ in
                guard !urls.isEmpty, urls.allSatisfy(\.isFileURL), canDropMultipleItems || urls.count == 1 else { return false }
                guard canDropFolder || urls.allSatisfy({ !isFolderURL($0) }) else { return false }
                return onFilesDropped(urls)
            }, isTargeted: { isTargeted = $0 })
    }

    private func isFolderURL(_ url: URL) -> Bool {
        if url.hasDirectoryPath { return true }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

struct SharedVisualFrameBackButton: View {
    let isEnabled: Bool
    let onBack: () -> Void
    var title = "Back"

    var body: some View {
        Button(action: onBack) {
            Label(L10n.text(title), systemImage: "chevron.left")
        }
        .buttonStyle(.borderless)
        .disabled(!isEnabled)
        .keyboardShortcut(.leftArrow, modifiers: [.command])
    }
}

struct SharedVisualFramedContentDialog<Content: View, Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    var symbol = "rectangle.inset.filled"
    let content: Content
    let actions: Actions

    init(title: String, subtitle: String? = nil, symbol: String = "rectangle.inset.filled", @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                WorkspaceDialogHeader(title: title, subtitle: subtitle, symbol: symbol)
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                actions
            }
            .padding(20)
            .frame(minWidth: 420, minHeight: 260)
        }
    }
}

struct SharedVisualEnumFilterOption: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
}

struct SharedVisualGenericEnumFilterControl: View {
    let options: [SharedVisualEnumFilterOption]
    @Binding var checkedIDs: Set<String>
    var filterAllText = "Uncheck All"

    private var selectedCount: Int { options.filter { checkedIDs.contains($0.id) }.count }
    private var allSelected: Bool { !options.isEmpty && selectedCount == options.count }
    private var someSelected: Bool { selectedCount > 0 && !allSelected }
    private var bulkActionTitle: String {
        let isDefaultAction = filterAllText == "Check All" || filterAllText == "Uncheck All"
        return L10n.text(isDefaultAction ? (allSelected ? "Uncheck All" : "Check All") : filterAllText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggleAll) {
                Label {
                    Text(bulkActionTitle)
                } icon: {
                    Image(systemName: allSelected ? "checkmark.square.fill" : someSelected ? "minus.square.fill" : "square")
                        .foregroundStyle(allSelected || someSelected ? Color.accentColor : Color.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(options.isEmpty)
            .accessibilityLabel(bulkActionTitle)
            .accessibilityValue(L10n.text(allSelected ? "All selected" : someSelected ? "Some selected" : "None selected"))
            if !options.isEmpty { Divider() }
            ForEach(options) { option in
                Toggle(L10n.text(option.title), isOn: Binding(
                    get: { checkedIDs.contains(option.id) },
                    set: { checked in
                        if checked { checkedIDs.insert(option.id) }
                        else { checkedIDs.remove(option.id) }
                    }
                ))
                .toggleStyle(.checkbox)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func toggleAll() {
        if allSelected { checkedIDs.subtract(options.map(\.id)) }
        else { checkedIDs.formUnion(options.map(\.id)) }
    }
}

struct SharedVisualChristmasTreeMode: Identifiable {
    let id: String
    let title: String
    var header: String?
    var sections: [SharedVisualChristmasTreeSection]
    var selectedNodeID: String?

    init(id: String, title: String, header: String? = nil, sections: [SharedVisualChristmasTreeSection] = [], selectedNodeID: String? = nil) {
        self.id = id
        self.title = title
        self.header = header
        self.sections = sections
        self.selectedNodeID = selectedNodeID
    }
}

struct SharedVisualChristmasTree<ModeContent: View, Presents: View>: View {
    let modes: [SharedVisualChristmasTreeMode]
    @Binding var selectedModeID: String
    let modeContent: (SharedVisualChristmasTreeMode) -> ModeContent
    let presents: Presents

    init(modes: [SharedVisualChristmasTreeMode], selectedModeID: Binding<String>, @ViewBuilder modeContent: @escaping (SharedVisualChristmasTreeMode) -> ModeContent, @ViewBuilder presents: () -> Presents) {
        self.modes = modes
        _selectedModeID = selectedModeID
        self.modeContent = modeContent
        self.presents = presents()
    }

    private var selectedMode: SharedVisualChristmasTreeMode? { modes.first { $0.id == selectedModeID } }

    var body: some View {
        VStack(spacing: 10) {
            if !modes.isEmpty {
                Picker(L10n.text("Tree mode"), selection: $selectedModeID) {
                    ForEach(modes) { mode in Text(L10n.text(mode.title)).tag(mode.id) }
                }
                .pickerStyle(.segmented)
            }
            if let selectedMode { modeContent(selectedMode) }
            presents
        }
        .onAppear(perform: normalizeModeSelection)
        .onChange(of: modes.map(\.id)) { _, _ in normalizeModeSelection() }
    }

    private func normalizeModeSelection() {
        let normalized = SharedVisualChristmasTreeSelection.normalizedModeID(
            selectedID: selectedModeID,
            modeIDs: modes.map(\.id),
            selectsFirstWhenUnselected: true
        ) ?? ""
        if selectedModeID != normalized { selectedModeID = normalized }
    }
}

struct SharedVisualIndexedRepeaterItem: Identifiable, Hashable, Sendable {
    let index: Int
    let isFirstIndex: Bool
    let isLastIndex: Bool
    var id: Int { index }
}

struct SharedVisualIndexedRepeater<ItemContent: View>: View {
    enum Orientation: Equatable { case horizontal, vertical }

    let start: Int
    let count: Int
    let skippedIndexes: Set<Int>
    var orientation: Orientation = .vertical
    let itemContent: (SharedVisualIndexedRepeaterItem) -> ItemContent

    @State private var renderedItems: [SharedVisualIndexedRepeaterItem]

    init(
        start: Int,
        count: Int,
        skippedIndexes: Set<Int> = [],
        orientation: Orientation = .vertical,
        @ViewBuilder itemContent: @escaping (SharedVisualIndexedRepeaterItem) -> ItemContent
    ) {
        self.start = start
        self.count = count
        self.skippedIndexes = skippedIndexes
        self.orientation = orientation
        self.itemContent = itemContent
        _renderedItems = State(initialValue: count > 0 ? Self.sourceItems(start: start, count: count, skippedIndexes: skippedIndexes) : [])
    }

    /// Retains the original NRepeater contract: flags refer to source indices,
    /// not visible positions. The source's final `IsLastIndex` assignment is
    /// the Skip membership test, so it intentionally replaces the constructor
    /// value that initially compared against `Count - 1`.
    static func sourceItems(start: Int, count: Int, skippedIndexes: Set<Int>) -> [SharedVisualIndexedRepeaterItem] {
        guard count > 0, start < count else { return [] }
        return (start..<count).compactMap { index in
            guard index <= 0 || !skippedIndexes.contains(index) else { return nil }
            return SharedVisualIndexedRepeaterItem(
                index: index,
                isFirstIndex: index == 0,
                isLastIndex: skippedIndexes.contains(index)
            )
        }
    }

    /// The original Rebuild returns without replacing Items when Count <= 0.
    static func rebuiltItems(
        previous: [SharedVisualIndexedRepeaterItem],
        start: Int,
        count: Int,
        skippedIndexes: Set<Int>
    ) -> [SharedVisualIndexedRepeaterItem] {
        guard count > 0 else { return previous }
        return sourceItems(start: start, count: count, skippedIndexes: skippedIndexes)
    }

    var body: some View {
        Group {
            if orientation == .horizontal {
                HStack(alignment: .top, spacing: 8) { content }
            } else {
                VStack(alignment: .leading, spacing: 8) { content }
            }
        }
        .onChange(of: start) { _, _ in rebuild() }
        .onChange(of: count) { _, _ in rebuild() }
        .onChange(of: skippedIndexes) { _, _ in rebuild() }
    }

    @ViewBuilder private var content: some View {
        ForEach(renderedItems) { item in itemContent(item) }
    }

    private func rebuild() {
        renderedItems = Self.rebuiltItems(previous: renderedItems, start: start, count: count, skippedIndexes: skippedIndexes)
    }
}

struct SharedVisualMetadataSection: Identifiable, Sendable {
    let id: String
    let title: String
    let properties: [SharedVisualMetadataProperty]
}

struct SharedVisualMetadataGroup: View {
    let sections: [SharedVisualMetadataSection]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text(section.title)).font(.headline)
                    SharedVisualMetadataPropertiesRepeater(properties: section.properties)
                }
            }
        }
    }
}

struct SharedVisualPromptValidation: Hashable, Sendable {
    let text: String
    let level: SharedVisualValidationLevel

    var blocksSubmission: Bool { level == .error || level == .typeError }
}

struct SharedVisualSingleStringPrompt: View {
    let header: String
    let label: String
    @Binding var text: String
    var validation: ((String) -> SharedVisualPromptValidation?)? = nil
    var cancelTitle = "Cancel"
    var submitTitle = "OK"
    var canSubmit = true
    var showsHeader = true
    let onCancel: () -> Void
    let onSubmit: (String) -> Void
    @State private var currentValidation: SharedVisualPromptValidation?

    private var submitIsEnabled: Bool { canSubmit && currentValidation?.blocksSubmission != true }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsHeader { Text(L10n.text(header)).font(.headline) }
            TextField(L10n.text(label), text: $text)
                .textFieldStyle(.roundedBorder)
                .onChange(of: text) { _, value in updateValidation(value) }
                .onSubmit { submit() }
            if let currentValidation {
                Label(L10n.text(currentValidation.text), systemImage: currentValidation.level.severity.iconName)
                    .font(.callout)
                    .foregroundStyle(currentValidation.level.severity.isError ? Color.red : currentValidation.level.severity.isWarning ? Color.orange : Color.secondary)
            }
            WorkspaceDialogActionBar(cancelTitle: cancelTitle, actionTitle: submitTitle, actionEnabled: submitIsEnabled, onCancel: onCancel, onAction: submit)
        }
        .onAppear { updateValidation(text) }
    }

    private func updateValidation(_ value: String) { currentValidation = validation?(value) }
    private func submit() {
        let result = validation?(text)
        currentValidation = result
        guard canSubmit, result?.blocksSubmission != true else { return }
        onSubmit(text)
    }
}

struct SharedVisualNewItemDialog: View {
    let icon: String
    var iconColor: Color = .accentColor
    let header: String
    let textLabel: String
    @Binding var text: String
    var canSubmit = true
    var validation: ((String) -> SharedVisualPromptValidation?)? = nil
    let onCancel: () -> Void
    let onCreate: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(iconColor).font(.title2)
                Text(L10n.text(header)).font(.title3.weight(.semibold))
            }
            SharedVisualSingleStringPrompt(header: header, label: textLabel, text: $text, validation: validation, submitTitle: "Create", canSubmit: canSubmit, showsHeader: false, onCancel: onCancel, onSubmit: onCreate)
        }
        .padding(20)
        .frame(minWidth: 360, idealWidth: 440, alignment: .leading)
    }
}

struct SharedVisualOpenFolderButton: View {
    let path: String
    let description: String
    var iconSize: CGFloat = 16
    var title = "Open Folder"
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Image(systemName: "folder").font(.system(size: iconSize))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text(title))
                    Text(verbatim: description.isEmpty ? path : description)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .help(path)
        .accessibilityLabel(L10n.text(title))
    }
}

struct SharedVisualPulsingEllipse: View {
    var isEnabled = true
    var stroke: Color = .red
    var strokeThickness: CGFloat = 1
    var diameter: CGFloat = 32
    var maximumScale: CGFloat = 1.5
    var delayDuration: Double = 0.5
    var duration: Double = 1.5
    @State private var pulsing = false

    var body: some View {
        Circle()
            .stroke(stroke, lineWidth: strokeThickness)
            .frame(width: diameter, height: diameter)
            .scaleEffect(pulsing ? maximumScale : 1)
            .animation(isEnabled ? .easeOut(duration: duration).repeatForever(autoreverses: false).delay(delayDuration) : nil, value: pulsing)
            .onAppear { pulsing = isEnabled }
            .onChange(of: isEnabled) { _, enabled in pulsing = enabled }
            .accessibilityHidden(true)
    }
}

struct SharedVisualReflectionNode: Identifiable, Sendable {
    let id: String
    let propertyName: String
    let typeName: String
    let value: String
    var objectID: String? = nil
    var currentDepth: Int = 0
    var isCollectionItem = false
    var collectionIndex: Int? = nil
    var originalValue: String? = nil
    var isTracking = false
    var hasChanged: Bool? = nil
    var isExpanded = false
    var childrenLoaded = true
    var canTrack = false
    var children: [SharedVisualReflectionNode] = []
}

struct SharedVisualRichDescription<Gallery: View>: View {
    @Binding var description: String
    let maxLength: Int
    let gallery: Gallery

    init(description: Binding<String>, maxLength: Int, @ViewBuilder gallery: () -> Gallery) {
        _description = description
        self.maxLength = max(0, maxLength)
        self.gallery = gallery()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $description)
                .frame(minHeight: 100)
                .onChange(of: description) { _, value in
                    if maxLength > 0 && value.utf16.count > maxLength { description = prefixUTF16(value, limit: maxLength) }
                }
            if maxLength > 0 {
                Text(L10n.format("%d of %d characters", description.utf16.count, maxLength))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
            }
            gallery
        }
    }

    private func prefixUTF16(_ value: String, limit: Int) -> String {
        var result = ""
        var usedUnits = 0
        for scalar in value.unicodeScalars {
            let scalarUnits = scalar.value > 0xFFFF ? 2 : 1
            guard usedUnits + scalarUnits <= limit else { break }
            result.unicodeScalars.append(scalar)
            usedUnits += scalarUnits
        }
        return result
    }
}

struct SharedVisualRunningManControl: View {
    var isRunning: Bool
    var cycleDurationSeconds: Double = 0.65
    @State private var stridePhase = false

    var body: some View {
        Image(systemName: "figure.run")
            .symbolRenderingMode(.hierarchical)
            .scaleEffect(x: stridePhase ? 1 : 0.94, y: stridePhase ? 0.96 : 1, anchor: .bottom)
            .offset(y: stridePhase ? -1 : 1)
            .animation(isRunning ? .easeInOut(duration: max(0.1, cycleDurationSeconds) / 2).repeatForever(autoreverses: true) : .default, value: stridePhase)
            .onAppear { stridePhase = isRunning }
            .onChange(of: isRunning) { _, running in stridePhase = running }
            .accessibilityLabel(L10n.text(isRunning ? "Running" : "Stopped"))
    }
}

struct SharedVisualSafeCanvasControl: View {
    var canvasSize: CGSize
    var accessibilityID: String
    var dpi: CGFloat = 96
    let draw: (inout GraphicsContext, CGSize) -> Void

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in draw(&context, size) }
            .frame(width: max(0, canvasSize.width), height: max(0, canvasSize.height))
            .accessibilityIdentifier(accessibilityID)
            .help(L10n.format("Canvas at %d DPI", Int(dpi.rounded())))
    }
}

struct SharedVisualToastMessage: Identifiable, Sendable {
    let id: String
    let title: String
    let message: String
    let severity: SharedVisualMessageSeverity
    let timeRequested: String
}

struct SharedVisualToastMessagePreview: View {
    let message: SharedVisualToastMessage
    var onDismiss: (() -> Void)? = nil
    var onCopy: (() -> Void)? = nil
    private let actionContent: AnyView

    init(message: SharedVisualToastMessage, onDismiss: (() -> Void)? = nil, onCopy: (() -> Void)? = nil) {
        self.message = message
        self.onDismiss = onDismiss
        self.onCopy = onCopy
        self.actionContent = AnyView(EmptyView())
    }

    init<ActionContent: View>(
        message: SharedVisualToastMessage,
        onDismiss: (() -> Void)? = nil,
        onCopy: (() -> Void)? = nil,
        @ViewBuilder actionContent: () -> ActionContent
    ) {
        self.message = message
        self.onDismiss = onDismiss
        self.onCopy = onCopy
        self.actionContent = AnyView(actionContent())
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            fullCard
            compactCard
        }
        .padding(12)
        .frame(maxWidth: 430, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var fullCard: some View {
        HStack(alignment: .top, spacing: 10) {
            severityLabel
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: message.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(verbatim: message.timeRequested).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                messageBody
                actionRow
            }
            closeButton
        }
    }

    private var compactCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                severityLabel
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: message.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(verbatim: message.timeRequested).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    messageBody
                }
                closeButton
            }
            actionRow
        }
    }

    private var severityLabel: some View {
        HStack(spacing: 5) {
            SharedVisualErrorWarningInfoIcon(severity: message.severity, showInfoIcon: true)
            Text(L10n.text(severityTitle))
                .font(.caption.weight(.medium))
                .foregroundStyle(message.severity.isError ? .red : message.severity.isWarning ? .orange : .secondary)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var messageBody: some View {
        Text(verbatim: message.message)
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .contextMenu {
                if let onCopy { Button(L10n.text("Copy"), action: onCopy) }
            }
    }

    private var closeButton: some View {
        Group {
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help(L10n.text("Dismiss"))
                    .accessibilityLabel(L10n.text("Dismiss"))
            }
        }
    }

    private var actionRow: some View {
        HStack { Spacer(minLength: 0); actionContent }
    }

    private var severityTitle: String {
        switch message.severity {
        case .error: "Error"
        case .warning: "Warning"
        case .information: "Information"
        case .trace: "Trace"
        case .debug: "Debug"
        }
    }
}

struct SharedVisualToastNotificationList: View {
    let messages: [SharedVisualToastMessage]
    var isReversed = false
    var reduceOnPointerOver = true
    var isVisible = true
    let onDismiss: (String) -> Void
    var onPointerPresenceChanged: ((Bool) -> Void)? = nil
    var cardContent: ((SharedVisualToastMessage, @escaping () -> Void) -> AnyView)? = nil

    private var displayedMessages: [SharedVisualToastMessage] { isReversed ? Array(messages.reversed()) : messages }

    var body: some View {
        if isVisible && !displayedMessages.isEmpty {
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(displayedMessages) { message in
                    Group {
                        if let cardContent {
                            cardContent(message) { onDismiss(message.id) }
                        } else {
                            SharedVisualToastMessagePreview(message: message) { onDismiss(message.id) }
                        }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onHover { hovering in
                if reduceOnPointerOver { onPointerPresenceChanged?(hovering) }
            }
            .accessibilityElement(children: .contain)
        }
    }
}

struct SharedVisualUMLNode: Identifiable, Sendable {
    let id: String
    let name: String
    var x: Double
    var y: Double
    var inputs: [String]
    var outputName: String
    var typeName: String
    var typeID: String? = nil
    var inputTypeIDs: [String] = []
    var inputValues: [String?] = []
    var unresolvedInputs: [Bool] = []
}

struct SharedVisualUMLLink: Identifiable, Sendable {
    let id: String
    let outputNodeID: String
    let inputNodeID: String
    let inputIndex: Int
    var typeID: String? = nil
    var overrideOutputPosition: CGPoint? = nil
    var overrideInputPosition: CGPoint? = nil
    var isBreaking = false
}

enum SharedVisualUMLPalette {
    static func color(for typeID: String?) -> Color {
        switch typeID {
        case "terrain", "Terrain": Color(red: 139.0 / 255, green: 69.0 / 255, blue: 19.0 / 255)
        case "nValue", "N-Value Layer": Color(red: 1, green: 165.0 / 255, blue: 0)
        case "geometry", "Geometry": Color(red: 0, green: 128.0 / 255, blue: 0)
        case "plan", "Plan": Color(red: 100.0 / 255, green: 149.0 / 255, blue: 237.0 / 255)
        case "boundaryCondition", "Boundary Condition": Color(red: 1, green: 192.0 / 255, blue: 203.0 / 255)
        default: .white
        }
    }
}

struct SharedVisualUMLDiagramView: View {
    let nodes: [SharedVisualUMLNode]
    let links: [SharedVisualUMLLink]
    var selectedNodeID: String? = nil
    var selectedNodeIDs: Set<String> = []
    var fitToLayoutRequestID: Int = 0
    var onSelectNode: (String) -> Void = { _ in }
    var onSelectNodeWithModifier: ((String, Bool) -> Void)? = nil
    var onSelectBox: ((Set<String>, Bool) -> Void)? = nil
    var onClearSelection: () -> Void = {}
    var onMoveNode: (String, Double, Double) -> Void = { _, _, _ in }
    var onMoveNodes: (([String: CGPoint]) -> Void)? = nil
    var onStartLink: (String) -> Void = { _ in }
    var onCreateLink: (String, String, Int) -> Bool = { _, _, _ in false }
    var onClearInput: ((String, Int) -> Void)? = nil
    var onOpenNode: ((String) -> Void)? = nil
    var onDeleteNode: ((String) -> Void)? = nil
    var onDeleteSelection: ((Set<String>) -> Void)? = nil
    @State private var pendingOutputNodeID: String?
    @State private var linkDraft: ProjectUMLLinkDraft?
    @State private var viewport = ProjectUMLViewportState()
    @State private var dragOrigins: [String: CGPoint] = [:]
    @State private var dragTranslation = CGSize.zero
    @State private var dragStartedWithModifier = false
    @State private var backgroundMode: BackgroundGestureMode = .none
    @State private var panOrigin = CGSize.zero
    @State private var boxSelectionStart: CGPoint?
    @State private var boxSelection = CGRect.zero
    @State private var magnifyAnchor: CGPoint?
    @State private var lastMagnification: CGFloat = 1
    @State private var didInitialFit = false
    @FocusState private var hasKeyboardFocus: Bool

    private let nodeWidth: CGFloat = 200
    private let nodeHeaderHeight: CGFloat = 28
    private let inputRowHeight: CGFloat = 30

    private enum BackgroundGestureMode: Equatable { case none, pan, select }

    private var activeSelection: Set<String> {
        selectedNodeIDs.isEmpty ? Set(selectedNodeID.map { [$0] } ?? []) : selectedNodeIDs
    }

    private var displayedNodes: [SharedVisualUMLNode] {
        nodes.map { node in
            guard let origin = dragOrigins[node.id], !dragStartedWithModifier else { return node }
            var result = node
            result.x = Double(origin.x + dragTranslation.width / viewport.zoom)
            result.y = Double(origin.y + dragTranslation.height / viewport.zoom)
            return result
        }
    }

    private var nodeByID: [String: SharedVisualUMLNode] {
        Dictionary(uniqueKeysWithValues: displayedNodes.map { ($0.id, $0) })
    }

    private var canvasWidth: CGFloat {
        max(600, displayedNodes.map { CGFloat($0.x) + nodeWidth + 40 }.max() ?? 600)
    }

    private var canvasHeight: CGFloat {
        max(400, displayedNodes.map {
            CGFloat($0.y) + nodeHeight(for: $0) + 40
        }.max() ?? 400)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color(nsColor: .textBackgroundColor)
                    .contentShape(Rectangle())
                    .gesture(backgroundDragGesture)
                    .onTapGesture {
                        hasKeyboardFocus = true
                        if pendingOutputNodeID != nil {
                            pendingOutputNodeID = nil
                            linkDraft = nil
                        }
                        if !selectionModifierIsDown { onClearSelection() }
                    }

                canvas
                    .scaleEffect(viewport.zoom, anchor: .topLeading)
                    .offset(viewport.offset)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                    .allowsHitTesting(true)
            }
            .coordinateSpace(name: "ProjectUMLViewport")
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
            .overlay(alignment: .topTrailing) { cameraControls(in: proxy.size) }
            .overlay(alignment: .topLeading) { interactionHint }
            .overlay {
                ProjectUMLScrollWheelCapture { point, factor in
                    hasKeyboardFocus = true
                    viewport.zoom(by: factor, anchoredAt: point)
                    return true
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .simultaneousGesture(magnifyGesture(in: proxy.size))
            .focusable()
            .focused($hasKeyboardFocus)
            .onDeleteCommand(perform: deleteSelection)
            .onAppear { fitInitialGraph(in: proxy.size) }
            .onChange(of: nodes.map(\.id)) { _, ids in
                if let pendingOutputNodeID, !ids.contains(pendingOutputNodeID) {
                    self.pendingOutputNodeID = nil
                }
                if let linkDraft, !ids.contains(linkDraft.source.nodeID) {
                    self.linkDraft = nil
                }
                if !didInitialFit { fitInitialGraph(in: proxy.size) }
            }
            .onChange(of: proxy.size) { _, size in
                if !didInitialFit { fitInitialGraph(in: size) }
            }
            .onChange(of: fitToLayoutRequestID) { _, _ in
                fitToView(in: proxy.size)
            }
        }
    }

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            ForEach(links) { link in
                if let output = nodeByID[link.outputNodeID], let input = nodeByID[link.inputNodeID] {
                    connection(link: link, output: output, input: input)
                }
            }
            if let linkDraft {
                let endpoints = draftEndpoints(linkDraft)
                curvedLink(from: endpoints.output, to: endpoints.input)
                    .stroke(SharedVisualUMLPalette.color(for: linkDraft.source.typeID),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 3]))
                    .allowsHitTesting(false)
            }
            ForEach(displayedNodes) { node in
                SharedVisualUMLNodeCard(
                    node: node,
                    width: nodeWidth,
                    headerHeight: nodeHeaderHeight,
                    inputRowHeight: inputRowHeight,
                    isSelected: activeSelection.contains(node.id),
                    isInspectorSelection: selectedNodeID == node.id,
                    isLinkSource: pendingOutputNodeID == node.id,
                    onSelect: { additive in selectNode(node.id, additive: additive) },
                    onDragStarted: { additive in beginNodeDrag(node.id, additive: additive) },
                    onDragChanged: { dragTranslation = $0 },
                    onDragEnded: endNodeDrag,
                    onStartLink: { beginClickLink(from: node); onStartLink(node.id) },
                    onBeginLinkDrag: beginLinkDrag,
                    onContinueLinkDrag: continueLinkDrag,
                    onEndLinkDrag: endLinkDrag,
                    onInput: { index in
                        guard let source = pendingOutputNodeID else {
                            selectNode(node.id, additive: selectionModifierIsDown)
                            return
                        }
                        if onCreateLink(source, node.id, index) {
                            pendingOutputNodeID = nil
                            linkDraft = nil
                        }
                    },
                    onClearInput: { index in onClearInput?(node.id, index) },
                    onOpen: { onOpenNode?(node.id) },
                    onDelete: { onDeleteNode?(node.id) },
                    canOpen: onOpenNode != nil,
                    canDelete: onDeleteNode != nil
                )
                .position(x: CGFloat(node.x) + nodeWidth / 2,
                    y: CGFloat(node.y) + nodeHeight(for: node) / 2)
            }
            if backgroundMode == .select {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay(Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [5, 3])))
                    .frame(width: boxSelection.width, height: boxSelection.height)
                    .position(x: boxSelection.midX, y: boxSelection.midY)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: canvasWidth, height: canvasHeight, alignment: .topLeading)
        .onContinuousHover(coordinateSpace: .named("ProjectUMLViewport")) { phase in
            guard let pendingOutputNodeID else { return }
            switch phase {
            case .active(let location): updatePendingOutputDraft(nodeID: pendingOutputNodeID, viewportPoint: location)
            case .ended: linkDraft = nil
            }
        }
    }

    private var interactionHint: some View {
        Group {
            if pendingOutputNodeID != nil {
                HStack(spacing: 8) {
                    Label(L10n.text("Select an output node, then choose a compatible input."), systemImage: "arrow.triangle.branch")
                    Button("Cancel") {
                        pendingOutputNodeID = nil
                        linkDraft = nil
                    }.buttonStyle(.borderless)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("Drag empty canvas to pan; Control- or Command-drag to add nodes to the selection."))
                    Text(L10n.text("Drag between compatible ports to edit an association; drag an input to blank space to remove it."))
                }
            }
        }
        .font(.caption)
        .padding(8)
        .background(.regularMaterial, in: Capsule())
        .padding(10)
        .allowsHitTesting(pendingOutputNodeID != nil)
    }

    private func cameraControls(in size: CGSize) -> some View {
        HStack(spacing: 6) {
            Button {
                viewport.zoom(by: 1 / 1.21, anchoredAt: CGPoint(x: size.width / 2, y: size.height / 2))
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help(L10n.text("Zoom Out"))

            Text("\(Int((viewport.zoom * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .frame(minWidth: 42)

            Button {
                viewport.zoom(by: 1.21, anchoredAt: CGPoint(x: size.width / 2, y: size.height / 2))
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help(L10n.text("Zoom In"))

            Button(L10n.text("Fit to View"), systemImage: "viewfinder") {
                fitToView(in: size)
            }
            .buttonStyle(.borderless)
        }
        .padding(7)
        .background(.regularMaterial, in: Capsule())
        .padding(10)
    }

    private var selectionModifierIsDown: Bool {
        let flags = NSEvent.modifierFlags
        return flags.contains(.control) || flags.contains(.command)
    }

    private var backgroundDragGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("ProjectUMLViewport"))
            .onChanged { value in
                hasKeyboardFocus = true
                if backgroundMode == .none {
                    if selectionModifierIsDown {
                        backgroundMode = .select
                        let start = viewport.canvasPoint(fromViewport: value.startLocation)
                        boxSelectionStart = start
                        boxSelection = CGRect(origin: start, size: .zero)
                    } else {
                        backgroundMode = .pan
                        panOrigin = viewport.offset
                        onClearSelection()
                    }
                }
                switch backgroundMode {
                case .none:
                    break
                case .pan:
                    viewport.setOffset(CGSize(width: panOrigin.width + value.translation.width,
                        height: panOrigin.height + value.translation.height))
                case .select:
                    guard let start = boxSelectionStart else { return }
                    let current = viewport.canvasPoint(fromViewport: value.location)
                    boxSelection = CGRect(x: start.x, y: start.y,
                        width: current.x - start.x, height: current.y - start.y).standardized
                }
            }
            .onEnded { value in
                if backgroundMode == .select {
                    guard let start = boxSelectionStart else {
                        resetBackgroundGesture()
                        return
                    }
                    let end = viewport.canvasPoint(fromViewport: value.location)
                    let rect = CGRect(x: start.x, y: start.y,
                        width: end.x - start.x, height: end.y - start.y).standardized
                    let matched = Set(nodes.compactMap { node -> String? in
                        let bounds = CGRect(x: CGFloat(node.x), y: CGFloat(node.y), width: nodeWidth,
                            height: nodeHeight(for: node))
                        return ProjectUMLCanvasGeometry.intersects(bounds, rect) ? node.id : nil
                    })
                    if let onSelectBox { onSelectBox(matched, true) }
                    else { for id in matched.sorted() { onSelectNode(id) } }
                }
                resetBackgroundGesture()
            }
    }

    private func resetBackgroundGesture() {
        backgroundMode = .none
        boxSelectionStart = nil
        boxSelection = .zero
    }

    private func selectNode(_ id: String, additive: Bool) {
        hasKeyboardFocus = true
        if let onSelectNodeWithModifier { onSelectNodeWithModifier(id, additive) }
        else { onSelectNode(id) }
    }

    private func beginNodeDrag(_ id: String, additive: Bool) {
        hasKeyboardFocus = true
        dragTranslation = .zero
        if additive {
            dragStartedWithModifier = true
            dragOrigins = [:]
            selectNode(id, additive: true)
            return
        }
        dragStartedWithModifier = false
        if !activeSelection.contains(id) { selectNode(id, additive: false) }
        let movingIDs = activeSelection.contains(id) ? activeSelection : Set([id])
        dragOrigins = Dictionary(uniqueKeysWithValues: nodes.filter { movingIDs.contains($0.id) }.map {
            ($0.id, CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)))
        })
    }

    private func endNodeDrag(_ translation: CGSize) {
        defer {
            dragOrigins = [:]
            dragTranslation = .zero
            dragStartedWithModifier = false
        }
        guard !dragStartedWithModifier, !dragOrigins.isEmpty else { return }
        let delta = CGSize(width: translation.width / viewport.zoom,
            height: translation.height / viewport.zoom)
        let moved = Dictionary(uniqueKeysWithValues: dragOrigins.map { id, origin in
            (id, CGPoint(x: origin.x + delta.width, y: origin.y + delta.height))
        })
        if let onMoveNodes {
            var allPositions = Dictionary(uniqueKeysWithValues: nodes.map {
                ($0.id, CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)))
            })
            allPositions.merge(moved, uniquingKeysWith: { _, replacement in replacement })
            let normalized = ProjectUMLCanvasGeometry.shiftNegativeDiagramBounds(allPositions)
            if normalized.shift != .zero {
                viewport.pan(by: CGSize(width: -normalized.shift.width * viewport.zoom,
                    height: -normalized.shift.height * viewport.zoom))
            }
            onMoveNodes(normalized.positions)
        } else {
            for (id, point) in moved { onMoveNode(id, Double(point.x), Double(point.y)) }
        }
    }

    private func deleteSelection() {
        guard !activeSelection.isEmpty else { return }
        if let onDeleteSelection { onDeleteSelection(activeSelection) }
        else if activeSelection.count == 1, let id = activeSelection.first { onDeleteNode?(id) }
    }

    private func magnifyGesture(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let anchor: CGPoint
                if let magnifyAnchor {
                    anchor = magnifyAnchor
                } else {
                    anchor = CGPoint(x: size.width * value.startAnchor.x,
                        y: size.height * value.startAnchor.y)
                    magnifyAnchor = anchor
                    lastMagnification = 1
                }
                viewport.zoom(by: value.magnification / lastMagnification, anchoredAt: anchor)
                lastMagnification = value.magnification
            }
            .onEnded { _ in
                magnifyAnchor = nil
                lastMagnification = 1
            }
    }

    private func fitInitialGraph(in size: CGSize) {
        guard !didInitialFit, !nodes.isEmpty, size.width > 0, size.height > 0 else { return }
        fitToView(in: size)
        didInitialFit = true
    }

    private func fitToView(in size: CGSize) {
        let bounds = displayedNodes.reduce(into: CGRect.null) { result, node in
            let nodeBounds = CGRect(x: CGFloat(node.x), y: CGFloat(node.y), width: nodeWidth,
                height: nodeHeight(for: node))
            result = result.union(nodeBounds)
        }
        guard !bounds.isNull else { return }
        viewport.fit(bounds: bounds, in: size)
    }

    private func nodeHeight(for node: SharedVisualUMLNode) -> CGFloat {
        ProjectUMLCanvasGeometry.nodeHeight(inputCount: node.inputs.count,
            headerHeight: nodeHeaderHeight, inputRowHeight: inputRowHeight)
    }

    private func connection(link: SharedVisualUMLLink, output: SharedVisualUMLNode,
                            input: SharedVisualUMLNode) -> some View {
        let endpoints = ProjectUMLCanvasGeometry.linkEndpoints(
            outputOrigin: CGPoint(x: CGFloat(output.x), y: CGFloat(output.y)),
            inputOrigin: CGPoint(x: CGFloat(input.x), y: CGFloat(input.y)), nodeWidth: nodeWidth,
            outputHeight: nodeHeight(for: output), headerHeight: nodeHeaderHeight,
            inputRowHeight: inputRowHeight, inputIndex: link.inputIndex,
            overrideOutput: link.overrideOutputPosition, overrideInput: link.overrideInputPosition)
        let isBreaking: Bool = {
            guard let linkDraft, case .input(let nodeID, let inputIndex, _) = linkDraft.source else {
                return link.isBreaking
            }
            return link.isBreaking || (nodeID == link.inputNodeID && inputIndex == link.inputIndex
                && linkDraft.hasMovedBeyondSourceThreshold)
        }()
        return curvedLink(from: endpoints.output, to: endpoints.input)
        .stroke(isBreaking ? Color.red : SharedVisualUMLPalette.color(for: link.typeID ?? output.typeID),
            style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: isBreaking ? [5, 3] : []))
        .allowsHitTesting(false)
    }

    private func curvedLink(from output: CGPoint, to input: CGPoint) -> Path {
        Path { path in
            path.move(to: output)
            let midX = (output.x + input.x) / 2
            path.addCurve(to: input, control1: CGPoint(x: midX, y: output.y),
                control2: CGPoint(x: midX, y: input.y))
        }
    }

    private func beginLinkDrag(_ source: ProjectUMLLinkPort, at anchor: CGPoint) {
        hasKeyboardFocus = true
        pendingOutputNodeID = nil
        linkDraft = ProjectUMLLinkDraft(source: source, anchor: anchor)
    }

    private func beginClickLink(from node: SharedVisualUMLNode) {
        pendingOutputNodeID = node.id
        let source = ProjectUMLLinkPort.output(nodeID: node.id, typeID: node.typeID ?? node.typeName)
        let anchor = ProjectUMLCanvasGeometry.outputAnchor(
            origin: CGPoint(x: CGFloat(node.x), y: CGFloat(node.y)), width: nodeWidth,
            height: nodeHeight(for: node))
        linkDraft = ProjectUMLLinkDraft(source: source, anchor: anchor)
    }

    private func updatePendingOutputDraft(nodeID: String, viewportPoint: CGPoint) {
        guard let node = nodeByID[nodeID] else {
            linkDraft = nil
            return
        }
        let source = ProjectUMLLinkPort.output(nodeID: node.id, typeID: node.typeID ?? node.typeName)
        let anchor = ProjectUMLCanvasGeometry.outputAnchor(
            origin: CGPoint(x: CGFloat(node.x), y: CGFloat(node.y)), width: nodeWidth,
            height: nodeHeight(for: node))
        var draft: ProjectUMLLinkDraft
        if let currentDraft = linkDraft, currentDraft.source == source {
            draft = currentDraft
        } else {
            draft = ProjectUMLLinkDraft(source: source, anchor: anchor)
        }
        draft.moveCursor(to: viewport.canvasPoint(fromViewport: viewportPoint))
        linkDraft = draft
    }

    private func continueLinkDrag(to viewportPoint: CGPoint) {
        guard var linkDraft else { return }
        linkDraft.moveCursor(to: viewport.canvasPoint(fromViewport: viewportPoint))
        self.linkDraft = linkDraft
    }

    private func endLinkDrag(at viewportPoint: CGPoint) {
        guard var draft = linkDraft else { return }
        draft.moveCursor(to: viewport.canvasPoint(fromViewport: viewportPoint))
        linkDraft = nil
        guard draft.hasMovedBeyondSourceThreshold else { return }
        let target = nearestPort(at: draft.cursor)
        switch (draft.source, target) {
        case let (.output(sourceID, sourceType), .some(.input(destinationID, inputIndex, targetType)))
            where sourceID != destinationID && sourceType == targetType:
            _ = onCreateLink(sourceID, destinationID, inputIndex)
        case let (.input(destinationID, inputIndex, targetType), .some(.output(sourceID, sourceType)))
            where sourceID != destinationID && sourceType == targetType:
            for targetID in selectedInputNodeIDs(startingAt: destinationID, inputIndex: inputIndex) {
                if sourceID == targetID { onClearInput?(targetID, inputIndex) }
                else { _ = onCreateLink(sourceID, targetID, inputIndex) }
            }
        case let (.input(destinationID, inputIndex, _), _):
            for targetID in selectedInputNodeIDs(startingAt: destinationID, inputIndex: inputIndex) {
                onClearInput?(targetID, inputIndex)
            }
        default:
            break
        }
    }

    private func selectedInputNodeIDs(startingAt sourceNodeID: String, inputIndex: Int) -> [String] {
        let candidates = nodes.filter { activeSelection.contains($0.id) && $0.inputs.indices.contains(inputIndex) }
        guard !candidates.isEmpty else { return [] }
        guard let source = nodeByID[sourceNodeID] else { return [] }
        return candidates.filter { ($0.typeID ?? $0.typeName) == (source.typeID ?? source.typeName) }
            .map(\.id)
    }

    private func nearestPort(at point: CGPoint) -> ProjectUMLLinkPort? {
        let portNodes = displayedNodes.map { node in
            ProjectUMLPortLayoutNode(id: node.id, typeID: node.typeID ?? node.typeName,
                x: node.x, y: node.y, inputTypeIDs: node.inputTypeIDs)
        }
        return ProjectUMLPortHitTesting.nearestPort(to: point, nodes: portNodes,
            nodeWidth: nodeWidth, nodeHeight: { node in
                ProjectUMLCanvasGeometry.nodeHeight(inputCount: node.inputTypeIDs.count,
                    headerHeight: nodeHeaderHeight, inputRowHeight: inputRowHeight)
            }, headerHeight: nodeHeaderHeight, inputRowHeight: inputRowHeight)
    }

    private func draftEndpoints(_ draft: ProjectUMLLinkDraft) -> (output: CGPoint, input: CGPoint) {
        switch draft.source {
        case .output: (draft.anchor, draft.cursor)
        case .input: (draft.cursor, draft.anchor)
        }
    }
}

private struct SharedVisualUMLNodeCard: View {
    let node: SharedVisualUMLNode
    let width: CGFloat
    let headerHeight: CGFloat
    let inputRowHeight: CGFloat
    let isSelected: Bool
    let isInspectorSelection: Bool
    let isLinkSource: Bool
    let onSelect: (Bool) -> Void
    let onDragStarted: (Bool) -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: (CGSize) -> Void
    let onStartLink: () -> Void
    let onBeginLinkDrag: (ProjectUMLLinkPort, CGPoint) -> Void
    let onContinueLinkDrag: (CGPoint) -> Void
    let onEndLinkDrag: (CGPoint) -> Void
    let onInput: (Int) -> Void
    let onClearInput: (Int) -> Void
    let onOpen: () -> Void
    let onDelete: () -> Void
    let canOpen: Bool
    let canDelete: Bool
    @State private var dragStarted = false
    @State private var outputLinkDragStarted = false
    @State private var inputLinkDragIndex: Int?
    @State private var suppressOutputClick = false
    @State private var suppressInputClickIndex: Int?

    private var headerTint: Color { SharedVisualUMLPalette.color(for: node.typeID ?? node.typeName) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: node.name).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(verbatim: node.typeName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 9).frame(height: headerHeight).background(headerTint.opacity(0.16))
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("ProjectUMLViewport"))
                .onChanged { value in
                    if !dragStarted {
                        dragStarted = true
                        onDragStarted(projectUMLSelectionModifierIsDown())
                    }
                    onDragChanged(value.translation)
                }
                .onEnded { value in
                    if !dragStarted { onDragStarted(projectUMLSelectionModifierIsDown()) }
                    onDragEnded(value.translation)
                    dragStarted = false
                })
            ForEach(Array(node.inputs.enumerated()), id: \.offset) { index, title in
                HStack(spacing: 6) {
                    Button {
                        guard suppressInputClickIndex != index else { return }
                        onInput(index)
                    } label: {
                        Circle().fill(SharedVisualUMLPalette.color(for: inputTypeID(index)))
                            .overlay {
                                if inputIsUnresolved(index) {
                                    Circle().strokeBorder(Color.red, lineWidth: 1.75)
                                }
                            }
                            .frame(width: 9, height: 9)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.text(title))
                    .offset(x: -13.5)
                    .simultaneousGesture(inputLinkDragGesture(index))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.text(title)).font(.caption).lineLimit(1)
                        if let value = inputValue(index), !value.isEmpty {
                            Text(verbatim: value).font(.caption2)
                                .foregroundStyle(inputIsUnresolved(index) ? Color.red : Color.secondary)
                                .lineLimit(1)
                        } else {
                            Text(L10n.text("Not assigned")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if inputValue(index) != nil {
                        Button(role: .destructive) { onClearInput(index) } label: {
                            Image(systemName: "xmark.circle.fill").font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help(L10n.text("Remove Association"))
                    }
                }
                .padding(.horizontal, 9).frame(height: inputRowHeight)
                .contextMenu {
                    if inputValue(index)?.isEmpty == false {
                        Button("Remove Association", systemImage: "link.badge.minus", role: .destructive) { onClearInput(index) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: width, height: ProjectUMLCanvasGeometry.nodeHeight(inputCount: node.inputs.count,
            headerHeight: headerHeight, inputRowHeight: inputRowHeight), alignment: .top)
        .overlay(alignment: .trailing) {
            Button {
                guard !suppressOutputClick else { return }
                onStartLink()
            } label: {
                Circle().fill(isLinkSource ? Color.orange : headerTint).frame(width: 11, height: 11)
            }
            .buttonStyle(.plain)
            .help(L10n.text(node.outputName))
            .offset(x: 5.5)
            .simultaneousGesture(outputLinkDragGesture)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isInspectorSelection ? headerTint : isSelected ? headerTint.opacity(0.72) : Color.secondary.opacity(0.35),
                    lineWidth: isInspectorSelection ? 2.5 : isSelected ? 1.75 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onTapGesture { onSelect(projectUMLSelectionModifierIsDown()) }
        .contextMenu {
            if canOpen { Button("Open Model", systemImage: "square.and.pencil", action: onOpen) }
            if canDelete { Button("Delete Model…", systemImage: "trash", role: .destructive, action: onDelete) }
        }
        .accessibilityElement(children: .contain)
    }

    private func inputValue(_ index: Int) -> String? {
        node.inputValues.indices.contains(index) ? node.inputValues[index] : nil
    }

    private func inputIsUnresolved(_ index: Int) -> Bool {
        node.unresolvedInputs.indices.contains(index) && node.unresolvedInputs[index]
    }

    private func inputTypeID(_ index: Int) -> String {
        node.inputTypeIDs.indices.contains(index) ? node.inputTypeIDs[index] : (node.typeID ?? node.typeName)
    }

    private var outputLinkDragGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("ProjectUMLViewport"))
            .onChanged { value in
                if !outputLinkDragStarted {
                    outputLinkDragStarted = true
                    suppressOutputClick = true
                    let anchor = ProjectUMLCanvasGeometry.outputAnchor(
                        origin: CGPoint(x: CGFloat(node.x), y: CGFloat(node.y)), width: width,
                        height: ProjectUMLCanvasGeometry.nodeHeight(inputCount: node.inputs.count,
                            headerHeight: headerHeight, inputRowHeight: inputRowHeight))
                    onBeginLinkDrag(.output(nodeID: node.id, typeID: node.typeID ?? node.typeName), anchor)
                }
                onContinueLinkDrag(value.location)
            }
            .onEnded { value in
                guard outputLinkDragStarted else { return }
                onEndLinkDrag(value.location)
                outputLinkDragStarted = false
                DispatchQueue.main.async { suppressOutputClick = false }
            }
    }

    private func inputLinkDragGesture(_ index: Int) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("ProjectUMLViewport"))
            .onChanged { value in
                if inputLinkDragIndex != index {
                    inputLinkDragIndex = index
                    suppressInputClickIndex = index
                    let anchor = ProjectUMLCanvasGeometry.inputAnchor(
                        origin: CGPoint(x: CGFloat(node.x), y: CGFloat(node.y)),
                        headerHeight: headerHeight, inputRowHeight: inputRowHeight, inputIndex: index)
                    onBeginLinkDrag(.input(nodeID: node.id, index: index, typeID: inputTypeID(index)), anchor)
                }
                onContinueLinkDrag(value.location)
            }
            .onEnded { value in
                guard inputLinkDragIndex == index else { return }
                onEndLinkDrag(value.location)
                inputLinkDragIndex = nil
                DispatchQueue.main.async {
                    if suppressInputClickIndex == index { suppressInputClickIndex = nil }
                }
            }
    }
}

@MainActor
private func projectUMLSelectionModifierIsDown() -> Bool {
    let flags = NSEvent.modifierFlags
    return flags.contains(.control) || flags.contains(.command)
}

