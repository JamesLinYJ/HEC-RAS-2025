import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - ChristmasTree source model and native tree

struct SharedVisualChristmasTreeNode: Identifiable {
    let id: String
    var name: String
    var typeName: String = ""
    var context: Any? = nil
    var contextTypeName: String? = nil
    var typeHierarchy: [String] = []
    var contextTypeHierarchy: [String] = []
    var detail: String? = nil
    var isContentTreeItem = false
    var isUnknown = false
    var isCheckable = true
    var isChecked = true
    var isPinnable = true
    var isPinned = false
    var canBeMoved = true
    var childrenIgnoreSortOrder = false
    var isLeaf = false
    var isExpanded = false
    var children: [SharedVisualChristmasTreeNode] = []
}

struct SharedVisualChristmasTreeSection: Identifiable {
    let id: String
    var title: String
    var typeName: String = ""
    var context: Any? = nil
    var contextTypeName: String? = nil
    var typeHierarchy: [String] = []
    var contextTypeHierarchy: [String] = []
    var rootNode: SharedVisualChristmasTreeNode? = nil
    var nodes: [SharedVisualChristmasTreeNode] = []
    var templateTypeName: String? = nil
    var headerWrappingTypeName: String? = nil
    var isVisible = true
    var isVisibleWhenEmpty = true
    var isExpanded = true
}

struct SharedVisualChristmasTreeTemplatePair {
    let typeName: String
    let content: (SharedVisualChristmasTreeNode) -> AnyView

    init<Content: View>(typeName: String, @ViewBuilder content: @escaping (SharedVisualChristmasTreeNode) -> Content) {
        self.typeName = typeName
        self.content = { AnyView(content($0)) }
    }
}

enum SharedVisualChristmasTreeTemplateResolver {
    static func matchingTypeName(
        candidates: [String],
        nodeTypeName: String,
        contextTypeName: String?,
        nodeHierarchy: [String],
        contextHierarchy: [String]
    ) -> String? {
        candidates.first { candidate in
            nodeTypeName == candidate || contextTypeName == candidate
                || nodeHierarchy.contains(candidate) || contextHierarchy.contains(candidate)
        }
    }
}

enum SharedVisualChristmasTreeSelection {
    static func normalizedModeID(selectedID: String?, modeIDs: [String], selectsFirstWhenUnselected: Bool) -> String? {
        guard let firstID = modeIDs.first else { return nil }
        if let selectedID {
            return modeIDs.contains(selectedID) ? selectedID : (selectsFirstWhenUnselected ? firstID : nil)
        }
        return selectsFirstWhenUnselected ? firstID : nil
    }

    static func selectedNodeID(modeID: String?, defaultNodeID: String?, overrides: [String: String?]) -> String? {
        guard let modeID else { return nil }
        if let override = overrides[modeID] { return override }
        return defaultNodeID
    }

    static func settingSelectedNodeID(_ nodeID: String?, for modeID: String, in overrides: [String: String?]) -> [String: String?] {
        var updated = overrides
        updated.updateValue(nodeID, forKey: modeID)
        return updated
    }
}

struct SharedVisualChristmasTreeSectionTemplatePair {
    let typeName: String
    let content: (SharedVisualChristmasTreeSection) -> AnyView

    init<Content: View>(typeName: String, @ViewBuilder content: @escaping (SharedVisualChristmasTreeSection) -> Content) {
        self.typeName = typeName
        self.content = { AnyView(content($0)) }
    }
}

struct SharedVisualChristmasTreeView: View {
    let modes: [SharedVisualChristmasTreeMode]
    private let selectedModeID: Binding<String?>
    private let selectsFirstModeWhenUnselected: Bool
    private let selectedNodeID: Binding<String?>?
    private let selectedNodeIDs: Binding<[String: String?]>?
    let presents: [SharedVisualChristmasTreeNode]
    let nodeTemplates: [SharedVisualChristmasTreeTemplatePair]
    let sectionTemplates: [SharedVisualChristmasTreeSectionTemplatePair]
    let headerWrappingTemplates: [SharedVisualChristmasTreeSectionTemplatePair]
    let defaultNodeContent: ((SharedVisualChristmasTreeNode) -> AnyView)?
    let defaultSectionContent: ((SharedVisualChristmasTreeSection) -> AnyView)?
    let unknownNodeContent: ((SharedVisualChristmasTreeNode) -> AnyView)?
    let contentTreeItemContent: ((SharedVisualChristmasTreeNode) -> AnyView)?
    let onSelectionChanged: ((SharedVisualChristmasTreeNode?) -> Void)?
    let onSelectedItemChanged: ((String, SharedVisualChristmasTreeNode?) -> Void)?
    let onCheckChanged: ((SharedVisualChristmasTreeNode, Bool) -> Void)?
    let onPinChanged: ((SharedVisualChristmasTreeNode, Bool) -> Void)?
    let onSectionExpansionChanged: ((SharedVisualChristmasTreeSection, Bool) -> Void)?
    let onNodeExpansionChanged: ((SharedVisualChristmasTreeNode, Bool) -> Void)?
    let onRequestNodeChildren: ((SharedVisualChristmasTreeNode) -> Void)?
    let onMoveNode: ((String, String) -> Void)?
    let modeHeaderContent: ((SharedVisualChristmasTreeMode) -> AnyView)?
    @State private var localSelectedNodeIDs: [String: String?] = [:]
    @State private var sectionExpansionOverrides: [String: Bool] = [:]
    @State private var nodeExpansionOverrides: [String: Bool] = [:]
    @State private var checkedValues: [String: Bool] = [:]
    @State private var pinnedValues: [String: Bool] = [:]

    init(
        modes: [SharedVisualChristmasTreeMode],
        selectedModeID: Binding<String>,
        selectedNodeID: Binding<String?>? = nil,
        selectedNodeIDs: Binding<[String: String?]>? = nil,
        presents: [SharedVisualChristmasTreeNode] = [],
        nodeTemplates: [SharedVisualChristmasTreeTemplatePair] = [],
        sectionTemplates: [SharedVisualChristmasTreeSectionTemplatePair] = [],
        headerWrappingTemplates: [SharedVisualChristmasTreeSectionTemplatePair] = [],
        defaultNodeContent: ((SharedVisualChristmasTreeNode) -> AnyView)? = nil,
        defaultSectionContent: ((SharedVisualChristmasTreeSection) -> AnyView)? = nil,
        unknownNodeContent: ((SharedVisualChristmasTreeNode) -> AnyView)? = nil,
        contentTreeItemContent: ((SharedVisualChristmasTreeNode) -> AnyView)? = nil,
        onSelectionChanged: ((SharedVisualChristmasTreeNode?) -> Void)? = nil,
        onSelectedItemChanged: ((String, SharedVisualChristmasTreeNode?) -> Void)? = nil,
        onCheckChanged: ((SharedVisualChristmasTreeNode, Bool) -> Void)? = nil,
        onPinChanged: ((SharedVisualChristmasTreeNode, Bool) -> Void)? = nil,
        onSectionExpansionChanged: ((SharedVisualChristmasTreeSection, Bool) -> Void)? = nil,
        onNodeExpansionChanged: ((SharedVisualChristmasTreeNode, Bool) -> Void)? = nil,
        onRequestNodeChildren: ((SharedVisualChristmasTreeNode) -> Void)? = nil,
        onMoveNode: ((String, String) -> Void)? = nil,
        modeHeaderContent: ((SharedVisualChristmasTreeMode) -> AnyView)? = nil
    ) {
        self.modes = modes
        self.selectedModeID = Binding(
            get: { selectedModeID.wrappedValue.isEmpty ? nil : selectedModeID.wrappedValue },
            set: { selectedModeID.wrappedValue = $0 ?? "" }
        )
        selectsFirstModeWhenUnselected = true
        self.selectedNodeID = selectedNodeID
        self.selectedNodeIDs = selectedNodeIDs
        self.presents = presents
        self.nodeTemplates = nodeTemplates
        self.sectionTemplates = sectionTemplates
        self.headerWrappingTemplates = headerWrappingTemplates
        self.defaultNodeContent = defaultNodeContent
        self.defaultSectionContent = defaultSectionContent
        self.unknownNodeContent = unknownNodeContent
        self.contentTreeItemContent = contentTreeItemContent
        self.onSelectionChanged = onSelectionChanged
        self.onSelectedItemChanged = onSelectedItemChanged
        self.onCheckChanged = onCheckChanged
        self.onPinChanged = onPinChanged
        self.onSectionExpansionChanged = onSectionExpansionChanged
        self.onNodeExpansionChanged = onNodeExpansionChanged
        self.onRequestNodeChildren = onRequestNodeChildren
        self.onMoveNode = onMoveNode
        self.modeHeaderContent = modeHeaderContent
    }

    init(
        modes: [SharedVisualChristmasTreeMode],
        selectedModeID: Binding<String?>,
        selectedNodeID: Binding<String?>? = nil,
        selectedNodeIDs: Binding<[String: String?]>? = nil,
        presents: [SharedVisualChristmasTreeNode] = [],
        nodeTemplates: [SharedVisualChristmasTreeTemplatePair] = [],
        sectionTemplates: [SharedVisualChristmasTreeSectionTemplatePair] = [],
        headerWrappingTemplates: [SharedVisualChristmasTreeSectionTemplatePair] = [],
        defaultNodeContent: ((SharedVisualChristmasTreeNode) -> AnyView)? = nil,
        defaultSectionContent: ((SharedVisualChristmasTreeSection) -> AnyView)? = nil,
        unknownNodeContent: ((SharedVisualChristmasTreeNode) -> AnyView)? = nil,
        contentTreeItemContent: ((SharedVisualChristmasTreeNode) -> AnyView)? = nil,
        onSelectionChanged: ((SharedVisualChristmasTreeNode?) -> Void)? = nil,
        onSelectedItemChanged: ((String, SharedVisualChristmasTreeNode?) -> Void)? = nil,
        onCheckChanged: ((SharedVisualChristmasTreeNode, Bool) -> Void)? = nil,
        onPinChanged: ((SharedVisualChristmasTreeNode, Bool) -> Void)? = nil,
        onSectionExpansionChanged: ((SharedVisualChristmasTreeSection, Bool) -> Void)? = nil,
        onNodeExpansionChanged: ((SharedVisualChristmasTreeNode, Bool) -> Void)? = nil,
        onRequestNodeChildren: ((SharedVisualChristmasTreeNode) -> Void)? = nil,
        onMoveNode: ((String, String) -> Void)? = nil,
        modeHeaderContent: ((SharedVisualChristmasTreeMode) -> AnyView)? = nil
    ) {
        self.modes = modes
        self.selectedModeID = selectedModeID
        selectsFirstModeWhenUnselected = false
        self.selectedNodeID = selectedNodeID
        self.selectedNodeIDs = selectedNodeIDs
        self.presents = presents
        self.nodeTemplates = nodeTemplates
        self.sectionTemplates = sectionTemplates
        self.headerWrappingTemplates = headerWrappingTemplates
        self.defaultNodeContent = defaultNodeContent
        self.defaultSectionContent = defaultSectionContent
        self.unknownNodeContent = unknownNodeContent
        self.contentTreeItemContent = contentTreeItemContent
        self.onSelectionChanged = onSelectionChanged
        self.onSelectedItemChanged = onSelectedItemChanged
        self.onCheckChanged = onCheckChanged
        self.onPinChanged = onPinChanged
        self.onSectionExpansionChanged = onSectionExpansionChanged
        self.onNodeExpansionChanged = onNodeExpansionChanged
        self.onRequestNodeChildren = onRequestNodeChildren
        self.onMoveNode = onMoveNode
        self.modeHeaderContent = modeHeaderContent
    }

    private var selectedMode: SharedVisualChristmasTreeMode? {
        guard let selectedID = selectedModeID.wrappedValue else { return nil }
        return modes.first(where: { $0.id == selectedID })
    }

    private var selectedNodeBinding: Binding<String?> {
        Binding(
            get: {
                guard let selectedMode else { return nil }
                if let selectedNodeIDs {
                    return SharedVisualChristmasTreeSelection.selectedNodeID(
                        modeID: selectedMode.id,
                        defaultNodeID: selectedMode.selectedNodeID,
                        overrides: selectedNodeIDs.wrappedValue
                    )
                }
                if let selectedNodeID { return selectedNodeID.wrappedValue }
                return SharedVisualChristmasTreeSelection.selectedNodeID(
                    modeID: selectedMode.id,
                    defaultNodeID: selectedMode.selectedNodeID,
                    overrides: localSelectedNodeIDs
                )
            },
            set: { value in
                guard let selectedMode else { return }
                if let selectedNodeIDs {
                    selectedNodeIDs.wrappedValue = SharedVisualChristmasTreeSelection.settingSelectedNodeID(
                        value,
                        for: selectedMode.id,
                        in: selectedNodeIDs.wrappedValue
                    )
                } else if let selectedNodeID {
                    selectedNodeID.wrappedValue = value
                } else {
                    localSelectedNodeIDs.updateValue(value, forKey: selectedMode.id)
                }
                onSelectedItemChanged?(selectedMode.id, value.flatMap { node(id: $0, in: selectedMode) })
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if selectedNodeBinding.wrappedValue != nil {
                HStack {
                    Spacer()
                    Button(L10n.text("Clear Selection")) {
                        selectedNodeBinding.wrappedValue = nil
                        onSelectionChanged?(nil)
                    }
                    .buttonStyle(.borderless)
                }
            }
            if modes.count > 1 {
                Picker(L10n.text("Tree mode"), selection: selectedModeID) {
                    ForEach(modes) { mode in Text(L10n.text(mode.title)).tag(Optional(mode.id)) }
                }
                .pickerStyle(.segmented)
            }
            if let selectedMode {
                if let header = selectedMode.header, !header.isEmpty {
                    Text(L10n.text(header)).font(.headline)
                }
                if let modeHeaderContent { modeHeaderContent(selectedMode) }
                if selectedMode.sections.isEmpty {
                    ContentUnavailableView(L10n.text("No tree sections are available."), systemImage: "list.bullet.indent")
                } else {
                    List {
                        ForEach(selectedMode.sections.filter(sectionIsVisible)) { section in
                            sectionView(section)
                        }
                    }
                    .listStyle(.inset)
                }
            } else {
                ContentUnavailableView(L10n.text("No tree modes are available."), systemImage: "list.bullet.indent")
            }
            if !presents.isEmpty {
                Divider()
                Text(L10n.text("Presents")).font(.headline)
                List {
                    ForEach(presents) { node in
                        nodeView(node)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 80, idealHeight: 160)
            }
        }
        .onAppear(perform: normalizeModeSelection)
        .onChange(of: modeContentSignature) { _, _ in
            normalizeModeSelection()
        }
        .onChange(of: selectedModeID.wrappedValue) { _, _ in
            sectionExpansionOverrides.removeAll()
            nodeExpansionOverrides.removeAll()
            normalizeModeSelection()
        }
    }

    private func sectionIsVisible(_ section: SharedVisualChristmasTreeSection) -> Bool {
        section.isVisible && (section.isVisibleWhenEmpty || !section.nodes.isEmpty)
    }

    private var modeContentSignature: [String] {
        modes.flatMap { mode in
            [mode.id, mode.title, mode.header ?? "", mode.selectedNodeID.map { "some:\($0)" } ?? "nil"]
                + mode.sections.flatMap(sectionSignature)
        } + presents.flatMap(nodeSignature)
    }

    private func sectionSignature(_ section: SharedVisualChristmasTreeSection) -> [String] {
        [
            section.id,
            section.title,
            section.typeName,
            contextSignature(section.context),
            section.contextTypeName ?? "",
            section.typeHierarchy.joined(separator: "\u{1f}"),
            section.contextTypeHierarchy.joined(separator: "\u{1f}"),
            section.templateTypeName ?? "",
            section.headerWrappingTypeName ?? "",
            String(section.isVisible),
            String(section.isVisibleWhenEmpty),
            String(section.isExpanded)
        ]
        + (section.rootNode.map(nodeSignature) ?? [])
        + section.nodes.flatMap(nodeSignature)
    }

    private func nodeSignature(_ node: SharedVisualChristmasTreeNode) -> [String] {
        [
            node.id,
            node.name,
            node.typeName,
            contextSignature(node.context),
            node.contextTypeName ?? "",
            node.typeHierarchy.joined(separator: "\u{1f}"),
            node.contextTypeHierarchy.joined(separator: "\u{1f}"),
            node.detail ?? "",
            String(node.isContentTreeItem),
            String(node.isUnknown),
            String(node.isCheckable),
            String(node.isChecked),
            String(node.isPinnable),
            String(node.isPinned),
            String(node.canBeMoved),
            String(node.childrenIgnoreSortOrder),
            String(node.isLeaf),
            String(node.isExpanded)
        ] + node.children.flatMap(nodeSignature)
    }

    private func contextSignature(_ value: Any?) -> String {
        guard let value else { return "nil" }
        if Mirror(reflecting: value).displayStyle == .class {
            return "\(String(describing: type(of: value)))@\(ObjectIdentifier(value as AnyObject))"
        }
        return String(reflecting: value)
    }

    @ViewBuilder
    private func sectionView(_ section: SharedVisualChristmasTreeSection) -> some View {
        DisclosureGroup(isExpanded: sectionExpansion(section)) {
            ForEach(section.nodes) { node in nodeView(node) }
        } label: {
            Button {
                if let root = section.rootNode { select(root) }
            } label: {
                HStack(spacing: 8) {
                    if let content = headerWrappingContent(for: section) ?? sectionTemplate(for: section) {
                        content
                    } else if let root = section.rootNode {
                        nodeContent(for: root)
                    } else {
                        Text(verbatim: section.title).fontWeight(.semibold)
                    }
                    Spacer(minLength: 0)
                    if let root = section.rootNode, selectedNodeBinding.wrappedValue == root.id {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(section.rootNode == nil)
            .accessibilityLabel(Text(verbatim: section.title))
        }
    }

    private func nodeView(_ node: SharedVisualChristmasTreeNode) -> AnyView {
        if node.isLeaf { return AnyView(nodeLabel(node)) }
        return AnyView(DisclosureGroup(isExpanded: nodeExpansion(node)) {
            ForEach(node.children) { child in nodeView(child) }
        } label: {
            nodeLabel(node)
        })
    }

    @ViewBuilder
    private func nodeLabel(_ node: SharedVisualChristmasTreeNode) -> some View {
        let row = HStack(spacing: 7) {
            if node.isCheckable {
                Toggle(isOn: Binding(
                    get: { checkedValues[node.id] ?? node.isChecked },
                    set: { value in
                        checkedValues[node.id] = value
                        onCheckChanged?(node, value)
                    }
                )) {
                    Text(verbatim: node.name)
                }
                .labelsHidden()
                .toggleStyle(.checkbox)
                .accessibilityLabel(Text(verbatim: node.name))
            }
            Button { select(node) } label: {
                HStack(spacing: 6) {
                    nodeContent(for: node)
                    if let detail = node.detail, !detail.isEmpty {
                        Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
                    }
                    if selectedNodeBinding.wrappedValue == node.id {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if node.isPinnable {
                Button {
                    let next = !(pinnedValues[node.id] ?? node.isPinned)
                    pinnedValues[node.id] = next
                    onPinChanged?(node, next)
                } label: {
                    Image(systemName: (pinnedValues[node.id] ?? node.isPinned) ? "pin.fill" : "pin")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.text("Pin"))
                .accessibilityLabel(L10n.text("Pin"))
            }
            if node.canBeMoved { Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).help(L10n.text("Reorderable")) }
        }
        if node.canBeMoved {
            row.draggable(node.id)
                .dropDestination(for: String.self) { draggedIDs, _ in
                    guard let draggedID = draggedIDs.first, draggedID != node.id else { return false }
                    onMoveNode?(draggedID, node.id)
                    return onMoveNode != nil
                }
        } else {
            row
        }
    }

    private func nodeContent(for node: SharedVisualChristmasTreeNode) -> AnyView {
        if node.isContentTreeItem, let contentTreeItemContent { return contentTreeItemContent(node) }
        if node.isUnknown, let unknownNodeContent { return unknownNodeContent(node) }
        if let templateType = SharedVisualChristmasTreeTemplateResolver.matchingTypeName(
            candidates: nodeTemplates.map(\.typeName),
            nodeTypeName: node.typeName,
            contextTypeName: node.contextTypeName ?? node.context.map { String(describing: type(of: $0)) },
            nodeHierarchy: node.typeHierarchy,
            contextHierarchy: node.contextTypeHierarchy
        ), let template = nodeTemplates.first(where: { $0.typeName == templateType }) { return template.content(node) }
        if let defaultNodeContent { return defaultNodeContent(node) }
        return AnyView(Text(verbatim: node.name))
    }

    private func sectionTemplate(for section: SharedVisualChristmasTreeSection) -> AnyView? {
        if let explicitType = section.templateTypeName,
           let template = sectionTemplates.first(where: { $0.typeName == explicitType }) {
            return template.content(section)
        }
        if let typeName = SharedVisualChristmasTreeTemplateResolver.matchingTypeName(
                candidates: sectionTemplates.map(\.typeName),
                nodeTypeName: section.typeName,
                contextTypeName: section.contextTypeName ?? section.context.map { String(describing: type(of: $0)) },
                nodeHierarchy: section.typeHierarchy,
                contextHierarchy: section.contextTypeHierarchy
            ), let template = sectionTemplates.first(where: { $0.typeName == typeName }) {
            return template.content(section)
        }
        if let defaultSectionContent { return defaultSectionContent(section) }
        return nil
    }

    private func headerWrappingContent(for section: SharedVisualChristmasTreeSection) -> AnyView? {
        if let explicitType = section.headerWrappingTypeName,
           let template = headerWrappingTemplates.first(where: { $0.typeName == explicitType }) {
            return template.content(section)
        }
        guard let typeName = SharedVisualChristmasTreeTemplateResolver.matchingTypeName(
                candidates: headerWrappingTemplates.map(\.typeName),
                nodeTypeName: section.typeName,
                contextTypeName: section.contextTypeName ?? section.context.map { String(describing: type(of: $0)) },
                nodeHierarchy: section.typeHierarchy,
                contextHierarchy: section.contextTypeHierarchy
            ),
              let template = headerWrappingTemplates.first(where: { $0.typeName == typeName }) else { return nil }
        return template.content(section)
    }

    private func sectionExpansion(_ section: SharedVisualChristmasTreeSection) -> Binding<Bool> {
        Binding(
            get: { sectionExpansionOverrides[section.id] ?? section.isExpanded },
            set: { expanded in
                sectionExpansionOverrides[section.id] = expanded
                onSectionExpansionChanged?(section, expanded)
            }
        )
    }

    private func nodeExpansion(_ node: SharedVisualChristmasTreeNode) -> Binding<Bool> {
        Binding(
            get: { nodeExpansionOverrides[node.id] ?? node.isExpanded },
            set: { expanded in
                nodeExpansionOverrides[node.id] = expanded
                onNodeExpansionChanged?(node, expanded)
                if expanded && node.children.isEmpty && !node.isLeaf {
                    onRequestNodeChildren?(node)
                }
            }
        )
    }

    private func select(_ node: SharedVisualChristmasTreeNode) {
        selectedNodeBinding.wrappedValue = node.id
        onSelectionChanged?(node)
    }

    private func normalizeModeSelection() {
        let normalized = SharedVisualChristmasTreeSelection.normalizedModeID(
            selectedID: selectedModeID.wrappedValue,
            modeIDs: modes.map(\.id),
            selectsFirstWhenUnselected: selectsFirstModeWhenUnselected
        )
        if selectedModeID.wrappedValue != normalized {
            selectedModeID.wrappedValue = normalized
        }
        guard selectedMode != nil else {
            if let selectedNodeID, selectedNodeID.wrappedValue != nil {
                selectedNodeID.wrappedValue = nil
                onSelectionChanged?(nil)
            }
            return
        }
        synchronizeNodeState()
        if let selectedID = selectedNodeBinding.wrappedValue,
           !selectedNodeExists(selectedID, in: selectedMode) {
            selectedNodeBinding.wrappedValue = nil
            onSelectionChanged?(nil)
        }
    }

    private func synchronizeNodeState() {
        for section in selectedMode?.sections ?? [] {
            for root in (section.rootNode.map { [$0] } ?? []) + section.nodes {
                synchronizeNodeState(root)
            }
        }
    }

    private func synchronizeNodeState(_ node: SharedVisualChristmasTreeNode) {
        checkedValues[node.id] = node.isChecked
        pinnedValues[node.id] = node.isPinned
        nodeExpansionOverrides[node.id] = node.isExpanded
        for child in node.children { synchronizeNodeState(child) }
    }

    private func selectedNodeExists(_ id: String, in mode: SharedVisualChristmasTreeMode?) -> Bool {
        node(id: id, in: mode) != nil
    }

    private func node(id: String, in mode: SharedVisualChristmasTreeMode?) -> SharedVisualChristmasTreeNode? {
        let sectionNodes = (mode?.sections ?? []).flatMap { section in
            (section.rootNode.map { [$0] } ?? []) + section.nodes
        }
        return (sectionNodes + presents).first { containsNode(id, in: $0) }.flatMap { findNode(id, in: $0) }
    }

    private func findNode(_ id: String, in node: SharedVisualChristmasTreeNode) -> SharedVisualChristmasTreeNode? {
        if node.id == id { return node }
        for child in node.children {
            if let match = findNode(id, in: child) { return match }
        }
        return nil
    }

    private func containsNode(_ id: String, in node: SharedVisualChristmasTreeNode) -> Bool {
        node.id == id || node.children.contains { containsNode(id, in: $0) }
    }
}

// MARK: - LinkableComboBox

struct SharedVisualLinkableOption<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
    var detail: String? = nil
}

enum SharedVisualLinkableSelection {
    static func normalizedID<ID: Hashable>(_ selectedID: ID?, optionIDs: [ID]) -> ID? {
        guard let selectedID, optionIDs.contains(selectedID) else { return nil }
        return selectedID
    }
}

struct SharedVisualLinkableComboBox<ID: Hashable>: View {
    let title: String
    let options: [SharedVisualLinkableOption<ID>]
    @Binding var selectedID: ID?
    @Binding var isLinked: Bool

    var body: some View {
        HStack(spacing: 8) {
            Picker(L10n.text(title), selection: $selectedID) {
                ForEach(options) { option in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: option.title)
                        if let detail = option.detail, !detail.isEmpty {
                            Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(Optional(option.id))
                }
            }
            .pickerStyle(.menu)
            Toggle(L10n.text("Dynamically Linked"), isOn: $isLinked)
                .toggleStyle(.button)
                .accessibilityLabel(L10n.text("Dynamically Linked"))
        }
        .onChange(of: options.map(\.id)) { _, _ in normalizeSelection() }
        .onAppear(perform: normalizeSelection)
    }

    private func normalizeSelection() {
        selectedID = SharedVisualLinkableSelection.normalizedID(selectedID, optionIDs: options.map(\.id))
    }
}

// MARK: - Tri-state controls retained from the source demo

struct SharedVisualTriStateToggleSlider: View {
    @Binding var isChecked: Bool?
    @Binding var isIndeterminate: Bool
    var label: String

    init(isChecked: Binding<Bool?>, isIndeterminate: Binding<Bool> = .constant(false), label: String = "") {
        _isChecked = isChecked
        _isIndeterminate = isIndeterminate
        self.label = label
    }

    private var isVisuallyIndeterminate: Bool { isIndeterminate || isChecked == nil }

    var body: some View {
        Button(action: cycleState) {
            GeometryReader { geometry in
                let thumbX: CGFloat = isVisuallyIndeterminate ? geometry.size.width / 2 : (isChecked == true ? geometry.size.width - 13 : 13)
                ZStack {
                    Capsule().fill(isVisuallyIndeterminate ? Color.secondary.opacity(0.38) : isChecked == true ? Color.accentColor : Color.secondary.opacity(0.32))
                    Circle().fill(.background)
                        .frame(width: 20, height: 20)
                        .position(x: thumbX, y: geometry.size.height / 2)
                }
            }
            .frame(width: 42, height: 26)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text(label.isEmpty ? "Tri-state toggle" : label))
        .accessibilityValue(L10n.text(isVisuallyIndeterminate ? "Indeterminate" : isChecked == true ? "On" : "Off"))
        .accessibilityAddTraits(.isToggle)
    }

    private func cycleState() {
        let next = SharedVisualTriStateState.cycledState(isChecked: isChecked, isIndeterminate: isIndeterminate)
        isChecked = next.isChecked
        isIndeterminate = next.isIndeterminate
    }
}

enum SharedVisualTriStateState {
    static func cycledState(isChecked: Bool?, isIndeterminate: Bool) -> (isChecked: Bool, isIndeterminate: Bool) {
        ((!isIndeterminate && isChecked == true) ? false : true, false)
    }

    static func cycledValue(isChecked: Bool?, isIndeterminate: Bool) -> Bool {
        cycledState(isChecked: isChecked, isIndeterminate: isIndeterminate).isChecked
    }
}

struct SharedVisualTriStateToggleTestControl: View {
    @State private var option1: Bool? = nil
    @State private var option2: Bool? = true
    @State private var option3: Bool? = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("Tri-state toggle test")).font(.headline)
            optionRow("Option 1", value: $option1)
            optionRow("Option 2", value: $option2)
            optionRow("Option 3", value: $option3)
            HStack {
                Button(L10n.text("Set all true")) { setAll(true) }
                Button(L10n.text("Set all false")) { setAll(false) }
                Button(L10n.text("Set all null")) { setAll(nil) }
            }
        }
        .padding(12)
    }

    private func optionRow(_ title: String, value: Binding<Bool?>) -> some View {
        HStack {
            Text(L10n.text(title))
            Spacer()
            Group {
                if value.wrappedValue == nil {
                    Text(L10n.text("null (indeterminate)"))
                } else {
                    Text(verbatim: value.wrappedValue == true ? "true" : "false")
                }
            }
            .foregroundStyle(.secondary)
            .monospaced()
            SharedVisualTriStateToggleSlider(isChecked: value, label: title)
        }
    }

    private func setAll(_ value: Bool?) {
        option1 = value
        option2 = value
        option3 = value
    }
}

typealias SharedVisualTriStateTestControl = SharedVisualTriStateToggleTestControl

// MARK: - Live reflection tree

@MainActor
@Observable
final class SharedVisualReflectionTreeState {
    let provider: () -> Any?
    let rootTitle: String
    let initialDepth: Int
    var roots: [SharedVisualReflectionNode] = []
    var trackingIDs: Set<String> = []
    var baselineValues: [String: String] = [:]
    var changedIDs: Set<String> = []
    var expandedIDs: Set<String> = []
    var expandedDepths: [String: Int] = [:]
    var valuesByID: [String: Any] = [:]
    private var hasInitializedRootExpansion = false
    private var currentRootObjectIdentifier: ObjectIdentifier?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(provider: @escaping () -> Any?, rootTitle: String, maxDepth: Int) {
        self.provider = provider
        self.rootTitle = rootTitle
        initialDepth = max(0, maxDepth)
    }

    func start() {
        guard refreshTask == nil else { return }
        refresh()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.refresh()
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func setExpanded(_ id: String, expanded: Bool) {
        if expanded {
            expandedIDs.insert(id)
            if expandedDepths[id] == nil, let node = node(id: id, in: roots) {
                expandedDepths[id] = node.currentDepth + initialDepth
            }
        } else {
            expandedIDs.remove(id)
        }
        refresh()
    }

    func startTracking(_ id: String) {
        refresh()
        guard node(id: id, in: roots)?.canTrack == true else { return }
        trackingIDs.insert(id)
        refresh()
    }

    func stopTracking(_ id: String) {
        trackingIDs.remove(id)
        refresh()
    }

    func stopAllTracking() {
        trackingIDs.removeAll()
        refresh()
    }

    func resetAllHighlights() {
        refresh()
        baselineValues = Dictionary(uniqueKeysWithValues: flatten(roots).map { ($0.id, $0.value) })
        changedIDs.removeAll()
        refresh()
    }

    func object(for id: String) -> Any? { valuesByID[id] }

    func refresh() {
        valuesByID.removeAll(keepingCapacity: true)
        guard let root = provider() else {
            roots = []
            trackingIDs.removeAll()
            baselineValues.removeAll()
            changedIDs.removeAll()
            expandedIDs.removeAll()
            expandedDepths.removeAll()
            currentRootObjectIdentifier = nil
            hasInitializedRootExpansion = false
            return
        }
        let rootObjectIdentifier = Mirror(reflecting: root).displayStyle == .class
            ? ObjectIdentifier(root as AnyObject)
            : nil
        if currentRootObjectIdentifier != rootObjectIdentifier {
            trackingIDs.removeAll()
            baselineValues.removeAll()
            changedIDs.removeAll()
            expandedIDs.removeAll()
            expandedDepths.removeAll()
            hasInitializedRootExpansion = false
            currentRootObjectIdentifier = rootObjectIdentifier
        }
        let rootID = "root"
        if !hasInitializedRootExpansion {
            expandedIDs.insert(rootID)
            hasInitializedRootExpansion = true
        }
        let rootNode = buildNode(
            root,
            id: rootID,
            propertyName: rootTitle,
            depth: 0,
            effectiveDepthLimit: initialDepth,
            ancestors: []
        )
        roots = [rootNode]

        let visibleIDs = Set(valuesByID.keys)
        trackingIDs.formIntersection(visibleIDs)
        baselineValues = baselineValues.filter { visibleIDs.contains($0.key) }
        changedIDs = changedIDs.filter { visibleIDs.contains($0) }
    }

    private func buildNode(
        _ value: Any,
        id: String,
        propertyName: String,
        depth: Int,
        effectiveDepthLimit: Int,
        ancestors: Set<ObjectIdentifier>
    ) -> SharedVisualReflectionNode {
        let description = Self.displayValue(value)
        valuesByID[id] = value
        let baseline = baselineValues[id] ?? description
        if baselineValues[id] == nil { baselineValues[id] = description }
        let tracksValue = trackingIDs.contains(id) || Self.isCollection(value)
        if tracksValue,
           SharedVisualReflectionHighlightState.hasChanged(currentValue: description, baselineValue: baseline, wasChanged: changedIDs.contains(id)) {
            changedIDs.insert(id)
        }

        let mirror = Mirror(reflecting: value)
        let objectID = Self.objectID(value)
        let objectIdentifier = Self.objectIdentifier(value)
        var nextAncestors = ancestors
        if let objectIdentifier { nextAncestors.insert(objectIdentifier) }
        let isCycle = objectIdentifier.map(ancestors.contains) ?? false
        let entries = isCycle ? [] : Self.children(of: value)
        let currentDepthLimit = max(effectiveDepthLimit, expandedDepths[id] ?? effectiveDepthLimit)
        let isAtDepthLimit = depth >= currentDepthLimit
        let canLoadMore = !entries.isEmpty && isAtDepthLimit && !isCycle
        let shouldBuildChildren = !entries.isEmpty && !isAtDepthLimit && !isCycle
        let children = shouldBuildChildren
            ? entries.map { name, child in
                buildNode(
                    child,
                    id: "\(id)/\(Self.pathComponent(name))",
                    propertyName: name,
                    depth: depth + 1,
                    effectiveDepthLimit: currentDepthLimit,
                    ancestors: nextAncestors
                )
            }
            : []

        let currentValue = description
        let originalValue = baselineValues[id]
        return SharedVisualReflectionNode(
            id: id,
            propertyName: propertyName,
            typeName: Self.typeName(value, mirror: mirror),
            value: currentValue,
            objectID: objectID,
            currentDepth: depth,
            isCollectionItem: propertyName.first == "[",
            collectionIndex: Self.collectionIndex(propertyName),
            originalValue: originalValue,
            isTracking: trackingIDs.contains(id),
            hasChanged: changedIDs.contains(id),
            isExpanded: expandedIDs.contains(id),
            childrenLoaded: !canLoadMore,
            canTrack: depth > 0 && Self.collectionIndex(propertyName) == nil,
            children: children
        )
    }

    private func node(id: String, in nodes: [SharedVisualReflectionNode]) -> SharedVisualReflectionNode? {
        for item in nodes {
            if item.id == id { return item }
            if let child = node(id: id, in: item.children) { return child }
        }
        return nil
    }

    private func flatten(_ nodes: [SharedVisualReflectionNode]) -> [SharedVisualReflectionNode] {
        nodes.flatMap { [$0] + flatten($0.children) }
    }

    private static func children(of value: Any) -> [(String, Any)] {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first?.value else { return [] }
            return children(of: wrapped)
        }
        if mirror.displayStyle == .collection || mirror.displayStyle == .set || mirror.displayStyle == .dictionary {
            return mirror.children.enumerated().map { index, child in
                let rendered = child.value
                return ("[\(index)]", rendered)
            }
        }
        return mirror.children.compactMap { child in
            guard let label = child.label,
                  !label.contains("k__BackingField"),
                  !label.hasPrefix("$"),
                  !["Length", "Values", "Capacity", "SyncRoot", "Count", "IsReadOnly", "IsSynchronized", "Keys"].contains(label) else { return nil }
            return (label.hasPrefix("_") ? label : label, child.value)
        }.sorted { $0.0 < $1.0 }
    }

    private static func displayValue(_ value: Any) -> String {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first?.value else { return "[null]" }
            return displayValue(wrapped)
        }
        if mirror.displayStyle == .collection || mirror.displayStyle == .set || mirror.displayStyle == .dictionary {
            return "Count: \(mirror.children.count)"
        }
        return String(describing: value)
    }

    private static func isCollection(_ value: Any) -> Bool {
        let style = Mirror(reflecting: value).displayStyle
        return style == .collection || style == .set || style == .dictionary
    }

    private static func typeName(_ value: Any, mirror: Mirror) -> String {
        if mirror.displayStyle == .optional, let wrapped = mirror.children.first?.value {
            return String(describing: type(of: wrapped))
        }
        return String(describing: type(of: value))
    }

    private static func objectID(_ value: Any) -> String? {
        guard Mirror(reflecting: value).displayStyle == .class else { return nil }
        let hexadecimal = String(ObjectIdentifier(value as AnyObject).hashValue, radix: 16, uppercase: true)
        return String(hexadecimal.prefix(4)).leftPadded(to: 4, with: "0")
    }

    private static func objectIdentifier(_ value: Any) -> ObjectIdentifier? {
        guard Mirror(reflecting: value).displayStyle == .class else { return nil }
        return ObjectIdentifier(value as AnyObject)
    }

    private static func pathComponent(_ value: String) -> String {
        value.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "/", with: "%2F")
    }

    private static func collectionIndex(_ value: String) -> Int? {
        guard value.first == "[", value.last == "]" else { return nil }
        return Int(value.dropFirst().dropLast())
    }
}

enum SharedVisualReflectionHighlightState {
    static func hasChanged(currentValue: String, baselineValue: String, wasChanged: Bool) -> Bool {
        wasChanged || currentValue != baselineValue
    }
}

private extension String {
    func leftPadded(to length: Int, with character: Character) -> String {
        String(repeating: String(character), count: max(0, length - count)) + self
    }
}

private struct SharedVisualReflectionWindowRoot: Identifiable {
    let id = UUID()
    let value: Any
    let title: String
}

@MainActor
struct SharedVisualReflectionTreeControl: View {
    private let fixedRoots: [SharedVisualReflectionNode]?
    private let legacyRequestChildren: (String) -> Void
    private let legacyExpansionChanged: (String, Bool) -> Void
    private let onReflectNode: ((SharedVisualReflectionNode) -> Void)?
    private let maxDepth: Int
    @State private var model: SharedVisualReflectionTreeState?
    @State private var nestedRoot: SharedVisualReflectionWindowRoot?

    init(
        rootProvider: @escaping () -> Any?,
        rootTitle: String = "Root",
        maxDepth: Int = 3,
        onReflectNode: ((SharedVisualReflectionNode) -> Void)? = nil
    ) {
        fixedRoots = nil
        legacyRequestChildren = { _ in }
        legacyExpansionChanged = { _, _ in }
        self.onReflectNode = onReflectNode
        self.maxDepth = max(0, maxDepth)
        _model = State(initialValue: SharedVisualReflectionTreeState(provider: rootProvider, rootTitle: rootTitle, maxDepth: maxDepth))
    }

    init(
        roots: [SharedVisualReflectionNode],
        onRequestChildren: @escaping (String) -> Void = { _ in },
        onExpansionChanged: @escaping (String, Bool) -> Void = { _, _ in },
        onReflectNode: ((SharedVisualReflectionNode) -> Void)? = nil
    ) {
        fixedRoots = roots
        legacyRequestChildren = onRequestChildren
        legacyExpansionChanged = onExpansionChanged
        self.onReflectNode = onReflectNode
        maxDepth = 3
        _model = State(initialValue: nil)
    }

    var body: some View {
        Group {
            if let model {
                VStack(spacing: 8) {
                    HStack {
                        Button(L10n.text("Reset Highlights")) { model.resetAllHighlights() }
                        Button(L10n.text("Stop Tracking")) { model.stopAllTracking() }
                            .disabled(model.trackingIDs.isEmpty)
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    if model.roots.isEmpty {
                        ContentUnavailableView(L10n.text("No object to inspect."), systemImage: "magnifyingglass")
                    } else {
                        List {
                            ForEach(model.roots) { node in
                                liveRow(node, model: model)
                            }
                        }
                        .listStyle(.inset)
                    }
                }
                .onAppear { model.start() }
                .onDisappear { model.stop() }
            } else {
                List {
                    ForEach(fixedRoots ?? []) { node in
                        SharedVisualReflectionFixedRow(
                            node: node,
                            onRequestChildren: legacyRequestChildren,
                            onExpansionChanged: legacyExpansionChanged,
                            onReflectNode: onReflectNode
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
        .sheet(item: $nestedRoot) { nested in
            AnyView(
                SharedVisualReflectionTreeControl(rootProvider: { nested.value }, rootTitle: nested.title, maxDepth: maxDepth)
                    .frame(minWidth: 640, minHeight: 420)
            )
        }
    }

    private func liveRow(_ node: SharedVisualReflectionNode, model: SharedVisualReflectionTreeState) -> AnyView {
        if node.childrenLoaded && node.children.isEmpty {
            return AnyView(reflectionLabel(node, model: model))
        }
        return AnyView(DisclosureGroup(isExpanded: Binding(
                get: { node.isExpanded },
                set: { model.setExpanded(node.id, expanded: $0) }
            )) {
                if node.childrenLoaded {
                    ForEach(node.children) { child in liveRow(child, model: model) }
                } else {
                    Label(L10n.text("Expand to load values"), systemImage: "ellipsis")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } label: {
                reflectionLabel(node, model: model)
            })
    }

    private func reflectionLabel(_ node: SharedVisualReflectionNode, model: SharedVisualReflectionTreeState) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: node.propertyName).font(.body.monospaced())
            Text(verbatim: node.typeName).font(.caption.monospaced()).foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text(verbatim: node.value).font(.body.monospaced()).lineLimit(2).textSelection(.enabled)
            if node.isTracking { Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.tint).help(L10n.text("Tracking")) }
            if node.hasChanged == true { Image(systemName: "pencil.circle.fill").foregroundStyle(.orange).help(L10n.text("Value changed")) }
        }
        .accessibilityElement(children: .combine)
        .contextMenu {
            if node.canTrack {
                if node.isTracking {
                    Button(L10n.text("Stop Tracking")) { model.stopTracking(node.id) }
                } else {
                    Button(L10n.text("Track Value")) { model.startTracking(node.id) }
                }
            }
            Button(L10n.text("Reflect")) { reflect(node, model: model) }
        }
        .onTapGesture(count: 2) { reflect(node, model: model) }
    }

    private func reflect(_ node: SharedVisualReflectionNode, model: SharedVisualReflectionTreeState) {
        if let onReflectNode {
            onReflectNode(node)
        } else if let value = model.object(for: node.id) {
            nestedRoot = SharedVisualReflectionWindowRoot(value: value, title: L10n.format("Reflection: %@", node.typeName))
        }
    }

}

private struct SharedVisualReflectionFixedRow: View {
    let node: SharedVisualReflectionNode
    let onRequestChildren: (String) -> Void
    let onExpansionChanged: (String, Bool) -> Void
    let onReflectNode: ((SharedVisualReflectionNode) -> Void)?
    @State private var isExpanded: Bool

    init(
        node: SharedVisualReflectionNode,
        onRequestChildren: @escaping (String) -> Void,
        onExpansionChanged: @escaping (String, Bool) -> Void,
        onReflectNode: ((SharedVisualReflectionNode) -> Void)?
    ) {
        self.node = node
        self.onRequestChildren = onRequestChildren
        self.onExpansionChanged = onExpansionChanged
        self.onReflectNode = onReflectNode
        _isExpanded = State(initialValue: node.isExpanded)
    }

    var body: some View {
        if node.childrenLoaded && node.children.isEmpty {
            label
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                if node.childrenLoaded {
                    ForEach(node.children) { child in
                        SharedVisualReflectionFixedRow(
                            node: child,
                            onRequestChildren: onRequestChildren,
                            onExpansionChanged: onExpansionChanged,
                            onReflectNode: onReflectNode
                        )
                    }
                } else {
                    Label(L10n.text("Expand to load values"), systemImage: "ellipsis")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } label: { label }
                .onChange(of: isExpanded) { _, expanded in
                    if expanded != node.isExpanded { onExpansionChanged(node.id, expanded) }
                    if expanded && !node.childrenLoaded { onRequestChildren(node.id) }
                }
                .onChange(of: node.isExpanded) { _, expanded in
                    if isExpanded != expanded { isExpanded = expanded }
                }
        }
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: node.propertyName).font(.body.monospaced())
            Text(verbatim: node.typeName).font(.caption.monospaced()).foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text(verbatim: node.value).font(.body.monospaced()).lineLimit(2).textSelection(.enabled)
            if node.isTracking { Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.tint).help(L10n.text("Tracking")) }
            if node.hasChanged ?? (node.originalValue != nil && node.originalValue != node.value) {
                Image(systemName: "pencil.circle.fill").foregroundStyle(.orange).help(L10n.text("Value changed"))
            }
        }
        .accessibilityElement(children: .combine)
        .contextMenu {
            if let onReflectNode { Button(L10n.text("Reflect")) { onReflectNode(node) } }
        }
    }
}
