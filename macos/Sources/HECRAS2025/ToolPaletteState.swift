import Foundation
import SwiftUI

struct ToolOptionDefinition: Codable, Identifiable, Sendable {
    let id: String
    let label: String
    let description: String
    let kind: String
    let defaultValue: String
    let choices: [EditorChoice]
    let source: String
    let sourceLine: Int
    func normalized(_ raw: String) -> String? {
        switch kind {
        case "bool": return ["true", "false"].contains(raw.lowercased()) ? raw.lowercased() : nil
        case "enum": return choices.contains(where: { $0.id == raw }) ? raw : nil
        case "double": return Double(raw).flatMap { $0.isFinite ? String($0) : nil }
        case "int":
            guard let value = Double(raw), value.isFinite else { return nil }
            let rounded = value.rounded(.toNearestOrEven) // Math.Round's original default.
            guard rounded >= Double(Int32.min), rounded <= Double(Int32.max) else { return nil }
            return String(Int32(rounded))
        default: return nil
        }
    }
}
struct PaletteToolDescriptor: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let iconKey: String
    let description: String
    var optionIDs: [String]
    let source: String
    var symbol: String {
        switch iconKey {
        case "Hand": "hand.draw"
        case "Selection": "selection.pin.in.out"
        case "PolyLine": "point.topleft.down.to.point.bottomright.curvepath"
        case "Lasso": "lasso"
        case "Ruler": "ruler"
        case "Area": "pentagon"
        case "Plus": "plus"
        case "Split": "scissors"
        case "Merge": "arrow.triangle.merge"
        case "Pin": "pin"
        case "Filter": "line.3.horizontal.decrease"
        case "Refresh": "arrow.triangle.2.circlepath"
        case "Offset": "arrow.left.and.right"
        case "Smooth": "waveform.path"
        case "AI": "point.topleft.down.to.point.bottomright.curvepath"
        case "Link": "link"
        default: "pencil"
        }
    }
}
enum MapToolText {
    @MainActor static func help(_ value: String) -> String {
        L10n.text(value).replacingOccurrences(of: "Alt+", with: "Option+")
            .replacingOccurrences(of: "Alt swaps", with: "Option swaps")
    }
}
struct ToolFactoryTemplate: Decodable, Sendable {
    struct Tool: Decodable, Sendable {
        let suffix: String
        let name: String
        let iconKey: String
        let description: String
        let optionIDs: [String]
        let availabilityExpression: String?
    }
    let factory: String
    let defaultPrefix: String
    let groupName: String
    let experimental: Bool
    let tools: [Tool]
    let source: String
    func group(prefix: String? = nil, availableIDs: Set<String> = []) -> MapToolNode {
        let prefix = prefix ?? defaultPrefix
        let children = tools.map { tool -> MapToolNode in
            let id = prefix + tool.suffix
            let descriptor = PaletteToolDescriptor(id: id, name: tool.name, iconKey: tool.iconKey, description: tool.description, optionIDs: tool.optionIDs, source: source)
            return MapToolNode(id: id, descriptor: descriptor, available: availableIDs.contains(id))
        }
        return MapToolNode(id: prefix + "/" + groupName, descriptor: children.first?.descriptor, children: children, title: groupName,
            available: children.contains(where: \.available), experimental: experimental)
    }
}
struct ToolPaletteLibrary: Decodable, Sendable {
    let options: [ToolOptionDefinition]
    let tools: [PaletteToolDescriptor]
    let contextOptionIDs: [String: [String]]
    let templates: [ToolFactoryTemplate]
    static let shared: Self = {
        guard let url = Bundle.module.url(forResource: "tool-palette", withExtension: "json") else { preconditionFailure("Missing original tool metadata") }
        do { return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
        catch { preconditionFailure("Invalid original tool metadata: \(error)") }
    }()
    func tool(_ id: String) -> PaletteToolDescriptor? { tools.first { $0.id == id } }
    func option(_ id: String) -> ToolOptionDefinition? { options.first { $0.id == id } }
    func factory(_ name: String) -> ToolFactoryTemplate? { templates.first { $0.factory == name } }
    // Concrete source descriptors are inspectable before model integration.
    // Contributed tools stay unavailable without an actual source context.
    var fallback: [MapToolNode] {
        let base = ["Map.Pan", "Map.SelectExtent", "Map.SelectPath", "Map.SelectLasso", "Map.MeasureLength", "Map.MeasureArea"].compactMap { id in
            tool(id).map { MapToolNode(id: id, descriptor: $0, available: id == "Map.Pan") }
        }
        let contributed = ["Graph", "Topology"].map { prefix -> MapToolNode in
            let scope = contextOptionIDs[prefix + "VisualContext"]?.first { $0.hasSuffix("SelectionScope") }
            let selection = ["Map.SelectExtent", "Map.SelectPath", "Map.SelectLasso"].compactMap { id -> MapToolNode? in
                guard var descriptor = tool(id), let scope else { return nil }
                descriptor.optionIDs = id == "Map.SelectPath" ? [scope] : [scope, "Lasso.HitMode"]
                return MapToolNode(id: prefix + "/" + id, descriptor: descriptor)
            }
            let editing = ["Sketch", "Add", "Edit", "Split"].compactMap { suffix in tool(prefix + "." + suffix).map { MapToolNode(id: $0.id, descriptor: $0) } }
            var groups = [MapToolNode(id: prefix + "/Select", descriptor: selection.first?.descriptor, children: selection, title: "Select"),
                MapToolNode(id: prefix + "/Edit", descriptor: editing.first?.descriptor, children: editing, title: "Edit")]
            if prefix == "Topology", let processing = factory("TopologyGeoprocessingTools") { groups.append(processing.group()) }
            return MapToolNode(id: prefix, descriptor: editing.first?.descriptor, children: groups, title: prefix)
        }
        let polyline = ["PolylineFocusedEditTools", "PolylineGeoprocessingTools"].compactMap { factory($0)?.group() }
        let polygon = factory("PolygonFocusedEditTools").map { [$0.group()] } ?? []
        return [MapToolNode(id: "Map", descriptor: base.first?.descriptor, children: base, title: "Map Tools", available: true)] + contributed +
            [MapToolNode(id: "Polyline", descriptor: polyline.first?.descriptor, children: polyline, title: "Polyline"),
             MapToolNode(id: "Polygon", descriptor: polygon.first?.descriptor, children: polygon, title: "Polygon")]
    }
    func fallback(selectedLayerID: String?) -> [MapToolNode] {
        return fallback.map { node in
            guard node.id == "Map" else { return node }
            let children = (node.children ?? []).map { child in
                MapToolNode(id: child.id, descriptor: child.descriptor,
                    children: child.children, title: child.title,
                    available: child.id == "Map.Pan"
                        || MapSelectionMeasurementTool.measurements.contains(child.id)
                        || MapSelectionMeasurementTool.selectors.contains(child.id),
                    experimental: child.experimental)
            }
            return MapToolNode(id: node.id, descriptor: node.descriptor, children: children,
                title: node.title, available: children.contains(where: \.available),
                experimental: node.experimental)
        }
    }
}
struct MapToolNode: Identifiable, Sendable {
    let id: String
    var descriptor: PaletteToolDescriptor?
    var children: [MapToolNode]? = nil
    var title: String? = nil
    var available = false
    var experimental = false
    func findTool(_ id: String) -> PaletteToolDescriptor? {
        if descriptor?.id == id { return descriptor }
        return children?.lazy.compactMap { $0.findTool(id) }.first
    }
    func containsTool(_ id: String) -> Bool { findTool(id) != nil }
}
struct ToolPaletteContext: Hashable, Sendable {
    let projectSessionID: UUID
    let mapID: UUID
    let selectedLayerID: String?
}
struct ToolPaletteSnapshot: Sendable {
    let nodes: [MapToolNode]
    let optionScopeID: String
    var optionValues: [String: String] = [:]
    var selectedToolID: String? = nil
    var optionDefinitions: [ToolOptionDefinition] = []
}

@MainActor
final class ToolPaletteSession: ObservableObject {
    @Published private(set) var nodes = ToolPaletteLibrary.shared.fallback
    @Published private(set) var busy = false
    @Published private(set) var currentToolID = "select"
    @Published private(set) var groupFaces: [String: String] = [:]
    @Published private(set) var values: [String: String] = [:]
    @Published var error: String?
    private var definitions: [ToolOptionDefinition] = []
    private var scopeID = ""
    private var scopedValues: [String: [String: String]] = [:]
    private var context: ToolPaletteContext?
    private var provider: (any MapInteractionProvider)?
    private var revision = 0
    private struct OptionChange {
        let definitionID: String
        let value: String
        let scopeID: String
        let context: ToolPaletteContext
        let revision: Int
        let provider: any MapInteractionProvider
    }
    private var pendingChanges: [OptionChange] = []
    private var changeTask: Task<Void, Never>?
    private var changeTaskID: UUID?
    var didUpdate: ((MapUpdate, ToolPaletteContext) -> Void)?
    func descriptor(_ id: String) -> PaletteToolDescriptor? {
        nodes.lazy.compactMap { $0.findTool(id) }.first ?? ToolPaletteLibrary.shared.tool(id)
    }
    func face(_ node: MapToolNode) -> PaletteToolDescriptor? { groupFaces[node.id].flatMap { node.findTool($0) } ?? node.descriptor }
    func option(_ id: String) -> ToolOptionDefinition? { definitions.first { $0.id == id } ?? ToolPaletteLibrary.shared.option(id) }
    func value(_ definition: ToolOptionDefinition) -> String { values[definition.id] ?? definition.defaultValue }
    func load(provider: (any MapInteractionProvider)?, context: ToolPaletteContext) async {
        revision += 1; let captured = revision
        changeTask?.cancel(); changeTask = nil; changeTaskID = nil; pendingChanges = []
        self.context = context; self.provider = provider
        scopeID = context.selectedLayerID ?? "map"
        values = scopedValues[scopeID] ?? [:]
        nodes = ToolPaletteLibrary.shared.fallback(selectedLayerID: context.selectedLayerID)
        definitions = []
        error = nil; busy = provider != nil
        defer { if captured == revision { busy = false } }
        guard let provider else { return }
        do {
            if let snapshot = try await provider.toolPalette(context) {
                guard captured == revision, !Task.isCancelled else { return }
                install(snapshot)
            }
        } catch { if captured == revision, !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func activate(_ tool: PaletteToolDescriptor) async {
        guard !busy else { return }
        let captured = revision
        if let provider, let context {
            busy = true; error = nil
            defer { if captured == revision { busy = false } }
            do {
                let update = try await provider.activateTool(tool.id, context: context)
                guard captured == revision, !Task.isCancelled else { return }
                choose(tool.id); didUpdate?(update, context)
            } catch { if captured == revision, !Task.isCancelled { self.error = error.localizedDescription } }
        } else if tool.id == "Map.Pan"
                    || MapSelectionMeasurementTool.measurements.contains(tool.id)
                    || MapSelectionMeasurementTool.selectors.contains(tool.id) {
            choose(tool.id)
        }
    }
    func chooseNavigation(_ id: String) { choose(id) }
    @discardableResult
    func set(_ definition: ToolOptionDefinition, raw: String) -> Bool {
        guard let value = definition.normalized(raw), value != self.value(definition) else { return definition.normalized(raw) != nil }
        values[definition.id] = value; scopedValues[scopeID] = values
        if let provider, let context {
            pendingChanges.append(.init(definitionID: definition.id, value: value, scopeID: scopeID, context: context, revision: revision, provider: provider))
            drainChanges()
        }
        return true
    }
    func invalidate() {
        revision += 1; context = nil; provider = nil; nodes = []; values = [:]; scopedValues = [:]; groupFaces = [:]; definitions = []; busy = false
        changeTask?.cancel(); changeTask = nil; changeTaskID = nil; pendingChanges = []
    }
    private func drainChanges() {
        guard changeTask == nil else { return }
        let taskID = UUID(); changeTaskID = taskID
        changeTask = Task {
            defer { if changeTaskID == taskID { changeTask = nil; changeTaskID = nil } }
            while !pendingChanges.isEmpty, !Task.isCancelled {
                let next = pendingChanges.removeFirst()
                guard next.revision == revision else { continue }
                do {
                    let update = try await next.provider.changeToolOption(next.definitionID, value: next.value, scopeID: next.scopeID, context: next.context)
                    guard next.revision == revision, !Task.isCancelled else { return }
                    didUpdate?(update, next.context)
                } catch { if next.revision == revision, !Task.isCancelled { self.error = error.localizedDescription } }
            }
        }
    }
    private func install(_ snapshot: ToolPaletteSnapshot) {
        nodes = snapshot.nodes; scopeID = snapshot.optionScopeID; definitions = snapshot.optionDefinitions
        values = snapshot.optionValues; scopedValues[scopeID] = values
        if let tool = snapshot.selectedToolID { choose(tool) }
    }
    private func choose(_ id: String) {
        currentToolID = id
        func visit(_ node: MapToolNode) {
            if node.children != nil, node.containsTool(id) { groupFaces[node.id] = id }
            for child in node.children ?? [] { visit(child) }
        }
        for node in nodes { visit(node) }
    }
}
