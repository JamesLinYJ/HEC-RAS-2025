import Foundation
import RASWorkspaceCore
import SwiftUI

private enum ProjectUMLModelKind: String, Hashable {
    case terrain
    case nValue
    case geometry
    case plan
    case boundaryCondition

    var sourceSuffix: String {
        switch self {
        case .terrain: "-Terrain"
        case .nValue: "-NV"
        case .geometry: "-Geo"
        case .plan: "-Plan"
        case .boundaryCondition: "-bc"
        }
    }

    @MainActor var title: String {
        switch self {
        case .terrain: L10n.text("Terrain")
        case .nValue: L10n.text("N-Value Layer")
        case .geometry: L10n.text("Geometry")
        case .plan: L10n.text("Plan")
        case .boundaryCondition: L10n.text("Boundary Condition")
        }
    }

    var associationGroup: String? {
        switch self {
        case .geometry: "GeometryAssociations"
        case .plan: "PlanAssociations"
        case .terrain, .nValue, .boundaryCondition: nil
        }
    }

    var catalogActionKind: CatalogManagedModelKind {
        switch self {
        case .terrain: .terrain
        case .nValue: .nValue
        case .geometry: .geometry
        case .plan: .plan
        case .boundaryCondition: .boundaryCondition
        }
    }

    static func from(_ kind: CatalogManagedModelKind) -> Self? {
        switch kind {
        case .terrain: .terrain
        case .nValue: .nValue
        case .geometry: .geometry
        case .plan: .plan
        case .boundaryCondition: .boundaryCondition
        case .classification: nil
        }
    }
}

private struct ProjectUMLInputDescription: Hashable {
    let sourceProperty: String
    let projectAssociationField: String
    let sourceKind: ProjectUMLModelKind

    @MainActor var label: String {
        switch sourceProperty {
        case "AssociatedTerrain": L10n.text("Associated Terrain")
        case "AssociatedNValueLayer": L10n.text("Associated N-Value Layer")
        case "AssociatedGeometry": L10n.text("Associated Geometry")
        case "AssociatedBoundaryCondition": L10n.text("Associated Boundary Condition")
        default: L10n.text(sourceProperty)
        }
    }
}

private extension ProjectUMLModelKind {
    var inputs: [ProjectUMLInputDescription] {
        switch self {
        case .geometry:
            [
                .init(sourceProperty: "AssociatedTerrain", projectAssociationField: "Terrain", sourceKind: .terrain),
                .init(sourceProperty: "AssociatedNValueLayer", projectAssociationField: "N_Values", sourceKind: .nValue)
            ]
        case .plan:
            [
                .init(sourceProperty: "AssociatedGeometry", projectAssociationField: "Geometry", sourceKind: .geometry),
                .init(sourceProperty: "AssociatedBoundaryCondition", projectAssociationField: "BoundaryCondition", sourceKind: .boundaryCondition)
            ]
        case .terrain, .nValue, .boundaryCondition:
            []
        }
    }
}

private struct ProjectUMLGraphNode: Identifiable, Hashable {
    let id: String
    let sourceID: String
    let name: String
    let asset: ProjectAsset
    let kind: ProjectUMLModelKind

    static func collect(from roots: [LayerTreeNode], assets: [ProjectAsset]) -> [Self] {
        var treeNodes: [LayerTreeNode] = []
        func append(_ node: LayerTreeNode) {
            treeNodes.append(node)
            for child in node.children ?? [] { append(child) }
        }
        for root in roots { append(root) }

        var seenAssets = Set<String>()
        return treeNodes.compactMap { treeNode in
            guard let catalogKind = CatalogManagedModelKind.sourceKind(for: treeNode.sourceClass),
                  let kind = ProjectUMLModelKind.from(catalogKind),
                  let nodeAssetID = treeNode.assetID,
                  let asset = CatalogModelActionTarget.asset(withNodeID: nodeAssetID, in: assets),
                  asset.section == catalogKind.projectSection, asset.isModelFile,
                  seenAssets.insert(asset.id).inserted else { return nil }
            return Self(id: asset.id, sourceID: asset.url.lastPathComponent + kind.sourceSuffix,
                name: treeNode.catalogSummary?.name ?? treeNode.name, asset: asset, kind: kind)
        }
    }
}

@MainActor
struct ProjectUMLWorkspaceView: View {
    @ObservedObject var store: WorkspaceStore
    let projectURL: URL
    let projectSessionID: UUID

    @State private var nodes: [ProjectUMLGraphNode] = []
    @State private var positions: [String: CGPoint] = [:]
    @State private var selectionState = ProjectUMLSelectionState()
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var isDirty = false
    @State private var canSavePositions = true
    @State private var loadError: String?
    @State private var positionError: String?
    @State private var interactionError: String?
    @State private var saveError: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var layoutFitRequestID = 0

    private var currentProjectMatches: Bool {
        store.projectSessionID == projectSessionID
            && store.document?.url?.standardizedFileURL == projectURL.standardizedFileURL
    }

    private var operationsAreBlocked: Bool {
        !currentProjectMatches || store.isRunningProjectTool || store.isSavingAll
            || store.isOpeningProject || store.isClosingTab
    }

    private var selectedNode: ProjectUMLGraphNode? {
        selectionState.inspectorNodeID.flatMap { id in nodes.first { $0.id == id } }
    }

    private var visualNodes: [SharedVisualUMLNode] {
        nodes.map { node in
            let currentPosition = positions[node.id] ?? .zero
            let values = node.kind.inputs.map { input -> String? in
                guard let value = associationValue(for: node, input: input), !value.isEmpty else { return nil }
                return value
            }
            let unresolved = zip(node.kind.inputs, values).map { pair in
                let (input, value) = pair
                if associationDestinationProblem(for: node) != nil { return true }
                guard let value, !value.isEmpty else { return false }
                if case .resolved = associationResolution(for: input.sourceKind, named: value) { return false }
                return true
            }
            return SharedVisualUMLNode(
                id: node.id, name: node.name, x: Double(currentPosition.x), y: Double(currentPosition.y),
                inputs: node.kind.inputs.map(\.label), outputName: "Name", typeName: node.kind.title,
                typeID: node.kind.rawValue,
                inputTypeIDs: node.kind.inputs.map { $0.sourceKind.rawValue },
                inputValues: values, unresolvedInputs: unresolved)
        }
    }

    private var visualLinks: [SharedVisualUMLLink] {
        var result: [SharedVisualUMLLink] = []
        for destination in nodes {
            for (inputIndex, input) in destination.kind.inputs.enumerated() {
                guard let value = associationValue(for: destination, input: input), !value.isEmpty,
                      let source = uniqueTarget(for: input.sourceKind, named: value) else { continue }
                result.append(SharedVisualUMLLink(id: "\(source.id)->\(destination.id):\(input.sourceProperty)",
                    outputNodeID: source.id, inputNodeID: destination.id, inputIndex: inputIndex,
                    typeID: source.kind.rawValue))
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if isLoading {
                ProgressView(L10n.text("Loading Project UML…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                ContentUnavailableView {
                    Label(L10n.text("Project UML"), systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text(verbatim: loadError)
                } actions: {
                    Button("Refresh") { Task { await loadGraph(context: store.catalogTreeContext) } }
                        .disabled(!currentProjectMatches || store.catalogTreeSession.busy)
                }
            } else if nodes.isEmpty {
                ContentUnavailableView(L10n.text("No Project UML model nodes are available."),
                    systemImage: "point.3.connected.trianglepath.dotted")
            } else {
                HStack(spacing: 0) {
                    SharedVisualUMLDiagramView(
                        nodes: visualNodes,
                        links: visualLinks,
                        selectedNodeID: selectionState.inspectorNodeID,
                        selectedNodeIDs: selectionState.selectedNodeIDs,
                        fitToLayoutRequestID: layoutFitRequestID,
                        onSelectNodeWithModifier: selectGraphNode,
                        onSelectBox: selectGraphBox,
                        onClearSelection: { selectionState.clear() },
                        onMoveNode: moveNode,
                        onMoveNodes: moveNodes,
                        onStartLink: { _ in interactionError = nil },
                        onCreateLink: createLink,
                        onClearInput: clearLink,
                        onOpenNode: openNode,
                        onDeleteNode: presentDelete,
                        onDeleteSelection: deleteSelection
                    )
                    .frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
                    .id(store.projectSessionID)
                    Divider()
                    inspector
                        .frame(width: 300)
                }
            }
            if let positionError {
                Label(positionError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
        .frame(minWidth: 980, minHeight: 660)
        .task(id: store.catalogTreeContext) { await loadGraph(context: store.catalogTreeContext) }
        .onDisappear { saveTask?.cancel() }
        .onChange(of: store.projectSessionID) { _, newSessionID in
            guard newSessionID != projectSessionID else { return }
            saveTask?.cancel()
            selectionState.clear()
            isDirty = false
        }
        .alert(L10n.text("Project UML"), isPresented: Binding(
            get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK") { saveError = nil }
        } message: {
            Text(verbatim: saveError ?? "")
        }
        .alert(L10n.text("Project UML"), isPresented: Binding(
            get: { interactionError != nil }, set: { if !$0 { interactionError = nil } })) {
            Button("OK") { interactionError = nil }
        } message: {
            Text(verbatim: interactionError ?? "")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Label(L10n.text("Project UML"), systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)
            Text("\(nodes.count) \(L10n.text("Models"))")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            if isSaving {
                ProgressView().controlSize(.small)
            } else if isDirty {
                Label(L10n.text("Unsaved Positions"), systemImage: "pencil.circle")
                    .font(.caption).foregroundStyle(.orange)
            } else if !nodes.isEmpty && canSavePositions {
                Label(L10n.text("Positions saved"), systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Auto Layout", systemImage: "rectangle.3.group") {
                applyAutomaticLayout()
            }
            .disabled(operationsAreBlocked || isLoading || nodes.isEmpty || isSaving)
            Button("Save Positions", systemImage: "square.and.arrow.down") {
                persistPositions()
            }
            .disabled(operationsAreBlocked || isLoading || nodes.isEmpty || !canSavePositions || !isDirty || isSaving)
        }
        .padding(12)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let node = selectedNode {
                Label(node.name, systemImage: node.kind.catalogActionKind.projectSection.symbol)
                    .font(.headline).lineLimit(2).textSelection(.enabled)
                LabeledContent(L10n.text("Type"), value: node.kind.title)
                LabeledContent(L10n.text("Source ID"), value: node.sourceID)
                    .font(.caption.monospaced()).textSelection(.enabled)
                LabeledContent(L10n.text("Filename"), value: node.asset.url.path)
                    .font(.caption2).textSelection(.enabled)

                if !node.kind.inputs.isEmpty {
                    Divider()
                    Text(L10n.text("Associations")).font(.subheadline.weight(.semibold))
                    ForEach(Array(node.kind.inputs.enumerated()), id: \.offset) { _, input in
                        associationPicker(node: node, input: input)
                        if let associationProblem = associationDestinationProblem(for: node) {
                            Label(L10n.text(associationProblem),
                                systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.red)
                        } else if let value = associationValue(for: node, input: input), !value.isEmpty {
                            switch associationResolution(for: input.sourceKind, named: value) {
                            case .missing:
                                Label("\(L10n.text("Missing target")): \(value)", systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.red)
                            case .ambiguous:
                                Label("\(L10n.text("Ambiguous target")): \(value)", systemImage: "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(.red)
                            case .resolved:
                                EmptyView()
                            }
                        }
                    }
                }

                Spacer(minLength: 10)
                HStack {
                    Button("Open Model", systemImage: "square.and.pencil") { openNode(node.id) }
                        .disabled(operationsAreBlocked || !canUseCatalogActions)
                    Spacer()
                    Button("Delete Model…", systemImage: "trash", role: .destructive) {
                        presentDelete(node.id)
                    }
                    .disabled(operationsAreBlocked || !canUseCatalogActions)
                }
            } else {
                ContentUnavailableView(L10n.text("Select a model node to inspect its associations."),
                    systemImage: "cursorarrow.click")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            if let interactionError {
                Text(verbatim: interactionError).font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled).padding(10)
            }
        }
    }

    private var canUseCatalogActions: Bool {
        store.modelProvider is BackendModelProvider && store.document?.url != nil
    }

    private func associationPicker(node: ProjectUMLGraphNode, input: ProjectUMLInputDescription) -> some View {
        let current = associationValue(for: node, input: input) ?? ""
        let choices = uniqueTargets(for: input.sourceKind)
        let candidates = nodes.filter { $0.kind == input.sourceKind }
        return Picker(input.label, selection: Binding(
            get: { associationValue(for: node, input: input) ?? "" },
            set: { _ = setAssociation(node: node, input: input, value: $0) }
        )) {
            Text(L10n.text("Not assigned")).tag("")
            ForEach(choices) { target in Text(verbatim: target.name).tag(target.asset.name) }
            if !current.isEmpty && candidates.filter({ $0.asset.name == current }).count != 1 {
                Text("\(current) (\(L10n.text(candidates.isEmpty ? "Missing target" : "Ambiguous target")))")
                    .tag(current)
            }
        }
        .disabled(operationsAreBlocked || store.hasBusyModelEditors || isSaving
            || associationDestinationProblem(for: node) != nil)
    }

    private func loadGraph(context: LayerTreeContext) async {
        guard currentProjectMatches, context.projectSessionID == projectSessionID,
              context.projectURL?.standardizedFileURL == projectURL.standardizedFileURL else {
            loadError = L10n.text("The project changed while Project UML was open.")
            isLoading = false
            return
        }
        isLoading = true
        loadError = nil
        interactionError = nil
        if store.catalogTreeSession.roots == nil {
            await store.catalogTreeSession.load(provider: store.catalogTreeProvider, context: context)
        }
        guard currentProjectMatches else {
            loadError = L10n.text("The project changed while Project UML was open.")
            isLoading = false
            return
        }
        guard let roots = store.catalogTreeSession.roots else {
            loadError = store.catalogTreeSession.error ?? L10n.text("The catalog model list could not be loaded.")
            isLoading = false
            return
        }

        let refreshedNodes = ProjectUMLGraphNode.collect(from: roots, assets: store.assets)
        let sourceIDs = refreshedNodes.map(\.sourceID)
        guard Set(sourceIDs).count == sourceIDs.count else {
            nodes = refreshedNodes
            positions = automaticLayout(for: refreshedNodes)
            canSavePositions = false
            positionError = L10n.text("Project UML model IDs are ambiguous; saved positions cannot be matched safely.")
            isDirty = false
            reconcileSelection(with: refreshedNodes)
            isLoading = false
            return
        }
        do {
            let savedPositions = try ProjectUMLVisualizationFile.loadPositions(projectURL: projectURL)
            let savedByID = Dictionary(uniqueKeysWithValues: savedPositions.map { ($0.sourceID, $0) })
            let layout = automaticLayout(for: refreshedNodes)
            var updatedPositions: [String: CGPoint] = [:]
            for node in refreshedNodes {
                let point = savedByID[node.sourceID].map { CGPoint(x: CGFloat($0.left), y: CGFloat($0.top)) }
                updatedPositions[node.id] = point
                    ?? layout[node.id] ?? .zero
            }
            nodes = refreshedNodes
            positions = updatedPositions
            canSavePositions = true
            positionError = nil
            isDirty = false
            reconcileSelection(with: refreshedNodes)
        } catch {
            nodes = refreshedNodes
            positions = automaticLayout(for: refreshedNodes)
            canSavePositions = false
            positionError = L10n.text(error.localizedDescription)
            isDirty = false
            reconcileSelection(with: refreshedNodes)
        }
        isLoading = false
    }

    private func reconcileSelection(with graphNodes: [ProjectUMLGraphNode]) {
        let orderedIDs = graphNodes.map(\.id)
        selectionState.reconcile(orderedIDs: orderedIDs)
        if selectionState.selectedNodeIDs.isEmpty, let firstID = orderedIDs.first {
            selectionState.select(firstID, additive: false)
        }
    }

    private func selectGraphNode(_ id: String, additive: Bool) {
        guard currentProjectMatches, nodes.contains(where: { $0.id == id }) else { return }
        selectionState.select(id, additive: additive)
        interactionError = nil
    }

    private func selectGraphBox(_ ids: Set<String>, additive: Bool) {
        guard currentProjectMatches else { return }
        let validIDs = ids.intersection(Set(nodes.map(\.id)))
        selectionState.selectBox(validIDs, additive: additive, orderedIDs: nodes.map(\.id))
        interactionError = nil
    }

    private func moveNode(_ id: String, left: Double, top: Double) {
        guard !operationsAreBlocked, !isSaving, left.isFinite, top.isFinite else { return }
        positions[id] = CGPoint(x: max(0, left), y: max(0, top))
        isDirty = true
        scheduleSave()
    }

    private func moveNodes(_ moved: [String: CGPoint]) {
        guard !operationsAreBlocked, !isSaving, !moved.isEmpty,
              moved.keys.allSatisfy({ id in nodes.contains(where: { $0.id == id }) }) else { return }
        guard moved.values.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return }
        for (id, point) in moved {
            positions[id] = CGPoint(x: max(0, point.x), y: max(0, point.y))
        }
        isDirty = true
        scheduleSave()
    }

    private func applyAutomaticLayout() {
        positions = automaticLayout(for: nodes)
        layoutFitRequestID &+= 1
        isDirty = true
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            persistPositions()
        }
    }

    private func persistPositions() {
        guard !isSaving, canSavePositions, currentProjectMatches else { return }
        guard nodes.allSatisfy({ positions[$0.id] != nil }) else {
            saveError = L10n.text("A model position is unavailable. Apply Auto Layout and try again.")
            return
        }
        let payload = nodes.compactMap { node -> ProjectUMLPosition? in
            guard let point = positions[node.id] else { return nil }
            return ProjectUMLPosition(id: node.id, sourceID: node.sourceID,
                left: Double(point.x), top: Double(point.y))
        }
        guard payload.count == nodes.count else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try store.saveProjectUMLPositions(payload)
            isDirty = false
            saveError = nil
            positionError = nil
        } catch {
            saveError = L10n.text(error.localizedDescription)
        }
    }

    private func associationValue(for node: ProjectUMLGraphNode,
                                  input: ProjectUMLInputDescription) -> String? {
        associationValue(for: node, input: input, in: nodes)
    }

    private func associationValue(for node: ProjectUMLGraphNode,
                                  input: ProjectUMLInputDescription,
                                  in graphNodes: [ProjectUMLGraphNode]) -> String? {
        guard associationDestinationProblem(for: node, in: graphNodes) == nil else { return nil }
        let rows = matchingAssociationRows(for: node)
        guard rows.count == 1 else { return nil }
        return rows[0].fields[input.projectAssociationField]
    }

    private func matchingAssociationRows(for node: ProjectUMLGraphNode) -> [ProjectAssociation] {
        guard let group = node.kind.associationGroup, let document = store.document else { return [] }
        return document.associationRows(group: group).filter { $0.name == node.asset.name }
    }

    private func associationDestinationProblem(for node: ProjectUMLGraphNode,
                                               in graphNodes: [ProjectUMLGraphNode]? = nil) -> String? {
        let candidates = graphNodes ?? nodes
        switch associationResolution(for: node.kind, named: node.asset.name, in: candidates) {
        case .missing:
            return "The association target changed. Refresh the project tree and try again."
        case .ambiguous:
            return "This project has multiple models with the same name; their UML associations cannot be distinguished safely."
        case .resolved(let nodeID) where nodeID != node.id:
            return "The association target changed. Refresh the project tree and try again."
        case .resolved:
            let rows = matchingAssociationRows(for: node)
            if rows.count > 1 {
                return "The project has multiple association rows for this model; repair it before editing UML links."
            }
            if rows.isEmpty { return "The association target changed. Refresh the project tree and try again." }
            return nil
        }
    }

    private func uniqueTargets(for kind: ProjectUMLModelKind) -> [ProjectUMLGraphNode] {
        let targets = nodes.filter { $0.kind == kind }
        let counts = Dictionary(grouping: targets, by: \.asset.name).mapValues(\.count)
        return targets.filter { counts[$0.asset.name] == 1 }
    }

    private func associationResolution(for kind: ProjectUMLModelKind,
                                       named projectName: String) -> ProjectUMLAssociationResolution {
        associationResolution(for: kind, named: projectName, in: nodes)
    }

    private func associationResolution(for kind: ProjectUMLModelKind, named projectName: String,
                                       in graphNodes: [ProjectUMLGraphNode]) -> ProjectUMLAssociationResolution {
        ProjectUMLAssociationIdentity.resolve(named: projectName, kind: kind.rawValue,
            among: graphNodes.map { ProjectUMLAssociationCandidate(nodeID: $0.id,
                projectName: $0.asset.name, kind: $0.kind.rawValue) })
    }

    private func uniqueTarget(for kind: ProjectUMLModelKind, named projectName: String) -> ProjectUMLGraphNode? {
        uniqueTarget(for: kind, named: projectName, in: nodes)
    }

    private func uniqueTarget(for kind: ProjectUMLModelKind, named projectName: String,
                              in graphNodes: [ProjectUMLGraphNode]) -> ProjectUMLGraphNode? {
        guard case .resolved(let nodeID) = associationResolution(for: kind, named: projectName,
            in: graphNodes) else { return nil }
        return graphNodes.first { $0.id == nodeID }
    }

    @discardableResult
    private func setAssociation(node: ProjectUMLGraphNode, input: ProjectUMLInputDescription,
                                value: String) -> Bool {
        guard currentProjectMatches, !operationsAreBlocked else {
            interactionError = L10n.text("Another project operation is in progress.")
            return false
        }
        if !value.isEmpty {
            switch associationResolution(for: input.sourceKind, named: value) {
            case .resolved:
                break
            case .missing:
                interactionError = L10n.text("The selected source node is not compatible with this input.")
                return false
            case .ambiguous:
                interactionError = L10n.text("The selected model name is ambiguous in the project and cannot be linked safely.")
                return false
            }
        }
        guard let group = node.kind.associationGroup,
              let document = store.document else {
            interactionError = L10n.text("The association target changed. Refresh the project tree and try again.")
            return false
        }
        if let destinationProblem = associationDestinationProblem(for: node) {
            interactionError = L10n.text(destinationProblem)
            return false
        }
        let rows = matchingAssociationRows(for: node)
        guard rows.count == 1, let row = rows.first else {
            interactionError = L10n.text(rows.count > 1
                ? "The project has multiple association rows for this model; repair it before editing UML links."
                : "The association target changed. Refresh the project tree and try again.")
            return false
        }
        if row.fields[input.projectAssociationField] == value { return true }
        store.setAssociation(row, field: input.projectAssociationField, value: value)
        let updatedRows = document.associationRows(group: group).filter { $0.name == node.asset.name }
        let saved = updatedRows.count == 1 ? updatedRows[0].fields[input.projectAssociationField] : nil
        guard saved == value else {
            interactionError = store.errorMessage ?? L10n.text("The association target changed. Refresh the project tree and try again.")
            return false
        }
        interactionError = nil
        return true
    }

    private func createLink(sourceID: String, destinationID: String, inputIndex: Int) -> Bool {
        guard let source = nodes.first(where: { $0.id == sourceID }),
              let destination = nodes.first(where: { $0.id == destinationID }),
              destination.kind.inputs.indices.contains(inputIndex) else {
            interactionError = L10n.text("The association target changed. Refresh the project tree and try again.")
            return false
        }
        let input = destination.kind.inputs[inputIndex]
        guard source.kind == input.sourceKind else {
            interactionError = L10n.text("The selected source node is not compatible with this input.")
            return false
        }
        return setAssociation(node: destination, input: input, value: source.asset.name)
    }

    private func clearLink(nodeID: String, inputIndex: Int) {
        guard let node = nodes.first(where: { $0.id == nodeID }),
              node.kind.inputs.indices.contains(inputIndex) else { return }
        _ = setAssociation(node: node, input: node.kind.inputs[inputIndex], value: "")
    }

    private func openNode(_ nodeID: String) {
        guard !operationsAreBlocked, let node = nodes.first(where: { $0.id == nodeID }), canUseCatalogActions else { return }
        store.edit(node.asset, fromTree: true)
    }

    private func presentDelete(_ nodeID: String) {
        guard !operationsAreBlocked, let node = nodes.first(where: { $0.id == nodeID }), canUseCatalogActions,
              store.assets.first(where: { $0.id == node.asset.id }) == node.asset,
              let presentation = CatalogModelActionPresentation.make(asset: node.asset,
                kind: node.kind.catalogActionKind, intent: .delete, caller: .projectTree, store: store) else {
            interactionError = L10n.text("The association target changed. Refresh the project tree and try again.")
            return
        }
        store.catalogModelActionPresentation = presentation
    }

    private func deleteSelection(_ selectedIDs: Set<String>) {
        guard currentProjectMatches, !operationsAreBlocked, canUseCatalogActions else { return }
        guard selectedIDs.count == 1, let nodeID = selectedIDs.first else {
            interactionError = L10n.text("Select one model node before deleting.")
            return
        }
        guard selectionState.inspectorNodeID == nodeID,
              selectionState.selectedNodeIDs.contains(nodeID) else {
            interactionError = L10n.text("Select one model node before deleting.")
            return
        }
        presentDelete(nodeID)
    }

    private func automaticLayout(for nodes: [ProjectUMLGraphNode]) -> [String: CGPoint] {
        var columnIndices: [Int: Int] = [:]
        var positions: [String: CGPoint] = [:]

        func rank(of node: ProjectUMLGraphNode, visiting: Set<String>) -> Int {
            guard !visiting.contains(node.id) else { return 0 }
            let nextVisiting = visiting.union([node.id])
            let parentRanks = node.kind.inputs.compactMap { input -> Int? in
                guard let value = associationValue(for: node, input: input, in: nodes), !value.isEmpty,
                      let parent = uniqueTarget(for: input.sourceKind, named: value, in: nodes) else { return nil }
                return rank(of: parent, visiting: nextVisiting) + 1
            }
            return parentRanks.max() ?? 0
        }

        for node in nodes {
            let column = rank(of: node, visiting: [])
            let index = columnIndices[column, default: 0]
            columnIndices[column] = index + 1
            positions[node.id] = CGPoint(x: CGFloat(40 + Double(column) * 500),
                y: CGFloat(40 + Double(index) * 170))
        }
        return positions
    }
}
