import Foundation
import CryptoKit
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct SavedMapView: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var lowerLeft: MapPoint
    public var upperRight: MapPoint
    public var shortcut: String
    public init(id: UUID = UUID(), name: String, lowerLeft: MapPoint, upperRight: MapPoint, shortcut: String = "") {
        self.id = id; self.name = name; self.lowerLeft = lowerLeft; self.upperRight = upperRight; self.shortcut = shortcut
    }
}

public struct MeshDiagnosticsVisualSettings: Equatable, Sendable {
    public let checkMeshErrors: Bool
    public let maxFacesPerNode: Int
    public init(checkMeshErrors: Bool = false, maxFacesPerNode: Int = 8) {
        self.checkMeshErrors = checkMeshErrors; self.maxFacesPerNode = maxFacesPerNode
    }
}

// ViewManager.Save/Load and ProjectHelpers.GetVisualFilePath define this .vis
// schema. Focused mutations preserve unrelated maps, UML and symbologies.
public final class VisualizationDocument {
    public let url: URL
    public var projectURL: URL { url.deletingPathExtension().appendingPathExtension("ras") }
    public private(set) var views: [SavedMapView] = []
    public private(set) var modified = false
    private var xml: XMLDocument
    private var savedBytes: Data?
    private var nodes: [UUID: XMLElement] = [:]
    private var root: XMLElement { xml.rootElement()! }
    public var sourceRevision: String? { savedBytes.map { Self.revision(of: $0) } }

    /// Original `.vis` maps in serialized order. The index is part of identity
    /// because source files may legally contain maps with the same display name.
    public var maps: [VisualizationMapIdentity] {
        (root.elements(forName: "Maps").first?.elements(forName: "Map") ?? []).enumerated().compactMap { index, node in
            guard let name = node.attribute(forName: "Name")?.stringValue,
                  let type = node.attribute(forName: "Type")?.stringValue else { return nil }
            return VisualizationMapIdentity(index: index, name: name, type: type)
        }
    }

    public init(projectURL: URL) throws {
        url = projectURL.deletingPathExtension().appendingPathExtension("vis")
        if FileManager.default.fileExists(atPath: url.path) {
            let bytes = try Data(contentsOf: url)
            guard let text = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .utf16),
                  !text.replacingOccurrences(of: "\0", with: "").localizedCaseInsensitiveContains("<!DOCTYPE"),
                  !text.replacingOccurrences(of: "\0", with: "").localizedCaseInsensitiveContains("<!ENTITY") else {
                throw ProjectFileError.invalid("Visualization settings must be XML without entity declarations.")
            }
            xml = try XMLDocument(data: bytes, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
            guard xml.rootElement()?.name == "Ras" else { throw ProjectFileError.invalid("Visualization settings require a Ras root element.") }
            savedBytes = bytes
        } else { xml = XMLDocument(rootElement: XMLElement(name: "Ras")); xml.characterEncoding = "UTF-8" }
        for node in root.elements(forName: "Views").first?.elements(forName: "View") ?? [] {
            guard let extent = node.elements(forName: "Extent").first,
                  let left = Double(extent.attribute(forName: "Left")?.stringValue ?? ""),
                  let top = Double(extent.attribute(forName: "Top")?.stringValue ?? ""),
                  let right = Double(extent.attribute(forName: "Right")?.stringValue ?? ""),
                  let bottom = Double(extent.attribute(forName: "Bottom")?.stringValue ?? ""),
                  [left, top, right, bottom].allSatisfy(\.isFinite), right > left, top > bottom else { continue }
            let view = SavedMapView(name: node.elements(forName: "Name").first?.stringValue ?? "",
                lowerLeft: MapPoint(x: left, y: bottom), upperRight: MapPoint(x: right, y: top),
                shortcut: node.elements(forName: "Bind").first?.stringValue ?? "")
            views.append(view); nodes[view.id] = node
        }
    }

    public func add(_ view: SavedMapView) throws {
        try validate(view)
        let node = XMLElement(name: "View")
        var parent = root.elements(forName: "Views").first
        if parent == nil { let created = XMLElement(name: "Views"); root.addChild(created); parent = created }
        parent!.addChild(node); nodes[view.id] = node; write(view, to: node)
        views.append(view); modified = true
    }
    public func update(_ view: SavedMapView) throws {
        guard let index = views.firstIndex(where: { $0.id == view.id }), let node = nodes[view.id] else { return }
        try validate(view); write(view, to: node); views[index] = view; modified = true
    }
    public func remove(_ id: UUID) {
        guard let node = nodes.removeValue(forKey: id) else { return }
        node.detach(); views.removeAll { $0.id == id }; modified = true
    }

    /// Lists only real single-band raster map nodes from this project's current
    /// `.vis` document. The relative file reference is resolved first, matching
    /// RasProjectTreeBase.AddUnmatchedMapLayer; the absolute reference is used
    /// only when the relative target does not exist.
    public func singleBandRasterMapSources() throws -> [RasterMapSourceDescriptor] {
        let diskBytes: Data
        if FileManager.default.fileExists(atPath: url.path) {
            diskBytes = try Data(contentsOf: url)
            if let savedBytes, savedBytes != diskBytes { throw ProjectFileError.modifiedExternally }
            if savedBytes == nil { throw ProjectFileError.modifiedExternally }
        } else {
            guard savedBytes == nil else { throw ProjectFileError.modifiedExternally }
            return []
        }
        let revision = Self.revision(of: diskBytes)
        let projectDirectory = projectURL.deletingLastPathComponent().standardizedFileURL
        var result: [RasterMapSourceDescriptor] = []
        let mapNodes = root.elements(forName: "Maps").first?.elements(forName: "Map") ?? []
        for (mapIndex, mapNode) in mapNodes.enumerated() {
            guard let mapName = mapNode.attribute(forName: "Name")?.stringValue,
                  let mapType = mapNode.attribute(forName: "Type")?.stringValue,
                  let roots = mapNode.elements(forName: "Tree").first?
                    .elements(forName: "Nodes").first?.elements(forName: "Node") else { continue }
            for (index, node) in roots.enumerated() {
                collectRasterSources(node, path: [index], mapIndex: mapIndex,
                    mapName: mapName, mapType: mapType, revision: revision,
                    projectDirectory: projectDirectory, into: &result)
            }
        }
        return result
    }

    /// Synchronizes the Maps/Symbology portion after the source backend has
    /// atomically applied a raster style. Locally edited saved views stay in
    /// memory, and their next save uses the new disk baseline.
    public func acceptExternalRasterSymbologyChange(expectedPreviousRevision: String, newRevision: String) throws {
        try acceptExternalMapChange(expectedPreviousRevision: expectedPreviousRevision, newRevision: newRevision)
    }

    /// Adopts only a saved Project UML section. Pending views and every other
    /// local section remain drafts. The receipt must describe an actual disk
    /// revision whose changes outside UML match the captured saved baseline.
    public func acceptExternalProjectUMLChange(expectedPreviousRevision: String?, newRevision: String) throws {
        guard sourceRevision?.uppercased() == expectedPreviousRevision?.uppercased() else {
            throw ProjectFileError.modifiedExternally
        }
        let bytes = try Data(contentsOf: url)
        guard Self.revision(of: bytes).caseInsensitiveCompare(newRevision) == .orderedSame else {
            throw ProjectFileError.modifiedExternally
        }
        let external = try Self.parseSavedVisualization(bytes)
        guard let externalRoot = external.rootElement(), externalRoot.elements(forName: "UML").count == 1,
              let savedUML = externalRoot.elements(forName: "UML").first else {
            throw ProjectFileError.invalid("Visualization settings require one Project UML section.")
        }
        if let savedBytes {
            let previous = try Self.parseSavedVisualization(savedBytes)
            guard let previousRoot = previous.rootElement(), previousRoot.elements(forName: "UML").count <= 1,
                  let before = previousRoot.copy() as? XMLElement,
                  let after = externalRoot.copy() as? XMLElement else {
                throw ProjectFileError.invalid("The saved Project UML section is ambiguous.")
            }
            before.elements(forName: "UML").forEach { $0.detach() }
            after.elements(forName: "UML").forEach { $0.detach() }
            guard before.canonicalXMLStringPreservingComments(true) == after.canonicalXMLStringPreservingComments(true) else {
                throw ProjectFileError.invalid("The Project UML receipt also changes unrelated visualization settings.")
            }
            root.elements(forName: "UML").forEach { $0.detach() }
            if let copy = savedUML.copy() as? XMLNode { root.addChild(copy) }
        } else {
            // Match the first-map adoption rule: accept the newly saved
            // sections while retaining any local unsaved Views collection.
            for attribute in externalRoot.attributes ?? [] {
                if let copy = attribute.copy() as? XMLNode { root.addAttribute(copy) }
            }
            for node in externalRoot.children ?? [] where node.name != "Views" {
                if let copy = node.copy() as? XMLNode { root.addChild(copy) }
            }
        }
        savedBytes = bytes
    }

    /// Accept a source map/tree mutation while retaining unsaved local views.
    /// A nil prior revision represents a document that did not exist on disk.
    public func acceptExternalMapChange(expectedPreviousRevision: String?, newRevision: String) throws {
        guard sourceRevision?.uppercased() == expectedPreviousRevision?.uppercased() else {
            throw ProjectFileError.modifiedExternally
        }
        let bytes = try Data(contentsOf: url)
        guard Self.revision(of: bytes).caseInsensitiveCompare(newRevision) == .orderedSame else {
            throw ProjectFileError.modifiedExternally
        }
        let text = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .utf16)
        guard let text,
              !text.replacingOccurrences(of: "\0", with: "").localizedCaseInsensitiveContains("<!DOCTYPE"),
              !text.replacingOccurrences(of: "\0", with: "").localizedCaseInsensitiveContains("<!ENTITY") else {
            throw ProjectFileError.invalid("Visualization settings must be XML without entity declarations.")
        }
        let external = try XMLDocument(data: bytes, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
        guard let externalRoot = external.rootElement(), externalRoot.name == "Ras" else {
            throw ProjectFileError.invalid("Visualization settings require a Ras root element.")
        }
        if savedBytes == nil {
            // A backend may create the first visualization file while a new
            // saved view is still only a local draft. Adopt its other sections
            // without publishing or replacing that draft.
            for attribute in externalRoot.attributes ?? [] {
                if let copy = attribute.copy() as? XMLNode { root.addAttribute(copy) }
            }
            for node in externalRoot.children ?? [] where node.name != "Views" {
                if let copy = node.copy() as? XMLNode { root.addChild(copy) }
            }
        }
        for name in savedBytes == nil ? [] : ["Maps", "Symbology"] {
            root.elements(forName: name).forEach { $0.detach() }
            if let source = externalRoot.elements(forName: name).first,
               let copy = source.copy() as? XMLNode { root.addChild(copy) }
        }
        self.savedBytes = bytes
    }

    /// Result nodes are serialized by source Type + Name. MultiResult nodes
    /// identify a plan and remain for any other results belonging to that plan.
    /// Remove only exact Result nodes, preserving unknown XML and pending views.
    @discardableResult
    public func removeResultReferences(named name: String) throws -> Int {
        guard !name.isEmpty else { return 0 }
        let currentRevision = sourceRevision
        try validateSourceUnchanged()
        guard let bytes = savedBytes else { return 0 }
        let external = try XMLDocument(data: bytes, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
        guard let externalRoot = external.rootElement() else { return 0 }
        func remove(in parent: XMLElement) -> Int {
            var count = 0
            for node in parent.elements(forName: "Node") {
                if node.attribute(forName: "Type")?.stringValue == "Result",
                   node.attribute(forName: "Name")?.stringValue == name {
                    node.detach(); count += 1
                } else { count += remove(in: node) }
            }
            return count
        }
        var removed = 0
        for map in externalRoot.elements(forName: "Maps").first?.elements(forName: "Map") ?? [] {
            if let nodes = map.elements(forName: "Tree").first?.elements(forName: "Nodes").first {
                removed += remove(in: nodes)
            }
        }
        guard removed > 0 else { return 0 }
        try validateSourceUnchanged()
        let updated = external.xmlData(options: [.nodePreserveAll])
        try updated.write(to: url, options: .atomic)
        try acceptExternalMapChange(expectedPreviousRevision: currentRevision, newRevision: Self.revision(of: updated))
        return removed
    }

    private static let backgroundOptionKeys: Set<String> = [
        "UseOSM", "UseHillshade", "UseSatellite", "AreBackgroundMapsOn",
        "OsmStyle", "OsmDensity", "OsmShowLabels", "SatelliteOpacity"
    ]

    public func backgroundMapOptions(map: VisualizationMapIdentity) throws -> [String: String] {
        try validateSourceUnchanged()
        let maps = root.elements(forName: "Maps").first?.elements(forName: "Map") ?? []
        guard maps.indices.contains(map.index),
              maps[map.index].attribute(forName: "Name")?.stringValue == map.name,
              maps[map.index].attribute(forName: "Type")?.stringValue == map.type else {
            throw ProjectFileError.modifiedExternally
        }
        return try Self.readBackgroundOptions(in: maps[map.index])
    }

    /// Publishes only map preferences, preserving unsaved Views in this
    /// document via the same external-map acceptance path as map styling.
    @discardableResult
    public func saveBackgroundMapOptions(_ options: [String: String],
                                        map: VisualizationMapIdentity?) throws -> VisualizationMapIdentity {
        guard Set(options.keys).isSubset(of: Self.backgroundOptionKeys) else {
            throw ProjectFileError.invalid("Unsupported background map option.")
        }
        try validateSourceUnchanged()
        let previousRevision = sourceRevision
        let external = try savedBytes.map {
            try XMLDocument(data: $0, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
        } ?? XMLDocument(rootElement: XMLElement(name: "Ras"))
        guard let externalRoot = external.rootElement(), externalRoot.name == "Ras" else {
            throw ProjectFileError.invalid("Visualization settings require a Ras root element.")
        }
        let maps: XMLElement
        if let existing = externalRoot.elements(forName: "Maps").first { maps = existing }
        else { maps = XMLElement(name: "Maps"); externalRoot.addChild(maps) }
        let mapNodes = maps.elements(forName: "Map")
        let target: XMLElement
        let identity: VisualizationMapIdentity
        if let map {
            guard mapNodes.indices.contains(map.index),
                  mapNodes[map.index].attribute(forName: "Name")?.stringValue == map.name,
                  mapNodes[map.index].attribute(forName: "Type")?.stringValue == map.type else {
                throw ProjectFileError.modifiedExternally
            }
            target = mapNodes[map.index]
            identity = map
        } else {
            // MapTreeService's initial Project-map representation is an empty
            // Map with Name=Map and Type=Project; default nodes are derived
            // from the owning project rather than fabricated here.
            guard mapNodes.isEmpty else { throw ProjectFileError.modifiedExternally }
            target = XMLElement(name: "Map")
            target.addAttribute(XMLNode.attribute(withName: "Name", stringValue: "Map") as! XMLNode)
            target.addAttribute(XMLNode.attribute(withName: "Type", stringValue: "Project") as! XMLNode)
            maps.addChild(target)
            if let selectedMap = maps.attribute(forName: "Maps") { selectedMap.stringValue = "Map" }
            else { maps.addAttribute(XMLNode.attribute(withName: "Maps", stringValue: "Map") as! XMLNode) }
            identity = VisualizationMapIdentity(index: 0, name: "Map", type: "Project")
        }
        _ = try Self.readBackgroundOptions(in: target)
        for (key, value) in options {
            if let element = target.elements(forName: key).first { element.stringValue = value }
            else { target.addChild(XMLElement(name: key, stringValue: value)) }
        }
        try validateSourceUnchanged()
        let bytes = external.xmlData(options: [.nodePreserveAll])
        try bytes.write(to: url, options: .atomic)
        try acceptExternalMapChange(expectedPreviousRevision: previousRevision,
            newRevision: Self.revision(of: bytes))
        return identity
    }

    private static func readBackgroundOptions(in map: XMLElement) throws -> [String: String] {
        var values: [String: String] = [:]
        for key in backgroundOptionKeys {
            let elements = map.elements(forName: key)
            guard elements.count <= 1 else {
                throw ProjectFileError.invalid("Background map options contain duplicate values.")
            }
            if let value = elements.first?.stringValue { values[key] = value }
        }
        return values
    }

    public func validateSourceUnchanged() throws {
        if let savedBytes {
            guard try Data(contentsOf: url) == savedBytes else { throw ProjectFileError.modifiedExternally }
        } else if FileManager.default.fileExists(atPath: url.path) { throw ProjectFileError.modifiedExternally }
    }

    /// Catalog actions affect project models, independently of same-name
    /// snapshots inside Result/MultiResult contexts. This change is reversible
    /// until the surrounding file/association publication has completed.
    public func prepareModelReferenceChange(type: String, oldName: String, newName: String?) throws -> PreparedVisualizationModelChange {
        guard ["Geometry", "Plan", "Terrain", "BoundaryCondition", "NValue", "Classification"].contains(type),
              !oldName.isEmpty, newName == nil || newName?.isEmpty == false else {
            throw ProjectFileError.invalid("The model reference change is invalid.")
        }
        try validateSourceUnchanged()
        let original = savedBytes
        let oldRevision = sourceRevision
        guard let original else {
            return PreparedVisualizationModelChange(affectedNodes: 0, publish: { try self.validateSourceUnchanged() }, restore: {})
        }
        let external = try XMLDocument(data: original, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
        var affected = 0
        func edit(in parent: XMLElement) {
            for node in parent.elements(forName: "Node") {
                let nodeType = node.attribute(forName: "Type")?.stringValue
                if ["Result", "MultiResult"].contains(nodeType ?? "") { continue }
                if nodeType == type, node.attribute(forName: "Name")?.stringValue == oldName {
                    if let newName { node.attribute(forName: "Name")?.stringValue = newName }
                    else { node.detach() }
                    affected += 1
                } else { edit(in: node) }
            }
        }
        for map in external.rootElement()?.elements(forName: "Maps").first?.elements(forName: "Map") ?? [] {
            if let nodes = map.elements(forName: "Tree").first?.elements(forName: "Nodes").first { edit(in: nodes) }
        }
        let updated = external.xmlData(options: [.nodePreserveAll])
        let newRevision = Self.revision(of: updated)
        let count = affected
        return PreparedVisualizationModelChange(affectedNodes: count, publish: {
            try self.validateSourceUnchanged()
            guard count > 0 else { return }
            try updated.write(to: self.url, options: .atomic)
            try self.acceptExternalMapChange(expectedPreviousRevision: oldRevision, newRevision: newRevision)
        }, restore: {
            guard count > 0 else { return }
            try self.validateSourceUnchanged()
            guard self.sourceRevision == newRevision else { throw ProjectFileError.modifiedExternally }
            try original.write(to: self.url, options: .atomic)
            try self.acceptExternalMapChange(expectedPreviousRevision: newRevision, newRevision: Self.revision(of: original))
        })
    }

    /// FlowAreaLayerVisualContext serializes these two attributes on the
    /// owning map's Geometry/FlowAreaLayer node. Other maps keep independent
    /// settings, including a Result's embedded same-name geometry.
    public func meshDiagnosticsSettings(mapIndex: Int, geometryName: String) throws -> MeshDiagnosticsVisualSettings {
        try validateSourceUnchanged()
        let mapNodes = root.elements(forName: "Maps").first?.elements(forName: "Map") ?? []
        guard mapIndex >= 0, mapIndex < mapNodes.count else {
            if mapNodes.isEmpty && mapIndex == 0 { return .init() }
            throw ProjectFileError.invalid("The mesh diagnostics map no longer exists.")
        }
        guard let flow = try meshDiagnosticsNode(in: mapNodes[mapIndex], geometryName: geometryName, create: false) else { return .init() }
        let enabled = flow.attribute(forName: "CheckMeshErrors")?.stringValue?.lowercased() == "true"
        let threshold = Int(flow.attribute(forName: "MaxFacesPerNode")?.stringValue ?? "") ?? 8
        return .init(checkMeshErrors: enabled, maxFacesPerNode: min(64, max(3, threshold)))
    }

    /// Publish only the current map settings. Pending local Views and project
    /// metadata remain drafts; unknown serialized source nodes are preserved.
    public func saveMeshDiagnosticsSettings(_ settings: MeshDiagnosticsVisualSettings,
        mapIndex: Int, geometryName: String) throws {
        guard !geometryName.isEmpty, (3...64).contains(settings.maxFacesPerNode) else {
            throw ProjectFileError.invalid("Mesh diagnostics require a geometry and a threshold from 3 to 64.")
        }
        try validateSourceUnchanged()
        let oldRevision = sourceRevision
        let external = try savedBytes.map { try XMLDocument(data: $0, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever]) }
            ?? XMLDocument(rootElement: XMLElement(name: "Ras"))
        let externalRoot = external.rootElement()!
        let maps: XMLElement
        if let existing = externalRoot.elements(forName: "Maps").first { maps = existing }
        else { maps = XMLElement(name: "Maps"); externalRoot.addChild(maps) }
        var mapNodes = maps.elements(forName: "Map")
        if mapNodes.isEmpty && mapIndex == 0 {
            let created = XMLElement(name: "Map")
            created.addAttribute(XMLNode.attribute(withName: "Name", stringValue: "Map") as! XMLNode)
            created.addAttribute(XMLNode.attribute(withName: "Type", stringValue: "Project") as! XMLNode)
            maps.addChild(created); mapNodes = [created]
        }
        guard mapIndex >= 0, mapIndex < mapNodes.count,
              let flow = try meshDiagnosticsNode(in: mapNodes[mapIndex], geometryName: geometryName, create: true) else {
            throw ProjectFileError.invalid("The mesh diagnostics map no longer exists.")
        }
        for (key, value) in [("CheckMeshErrors", settings.checkMeshErrors ? "true" : "false"),
                             ("MaxFacesPerNode", String(settings.maxFacesPerNode))] {
            if let attribute = flow.attribute(forName: key) { attribute.stringValue = value }
            else { flow.addAttribute(XMLNode.attribute(withName: key, stringValue: value) as! XMLNode) }
        }
        try validateSourceUnchanged()
        let bytes = external.xmlData(options: [.nodePreserveAll])
        try bytes.write(to: url, options: .atomic)
        try acceptExternalMapChange(expectedPreviousRevision: oldRevision, newRevision: Self.revision(of: bytes))
    }

    private func meshDiagnosticsNode(in map: XMLElement, geometryName: String, create: Bool) throws -> XMLElement? {
        func child(_ name: String, in parent: XMLElement) -> XMLElement? {
            if let existing = parent.elements(forName: name).first { return existing }
            guard create else { return nil }
            let new = XMLElement(name: name); parent.addChild(new); return new
        }
        guard let tree = child("Tree", in: map), let roots = child("Nodes", in: tree) else { return nil }
        var geometries: [XMLElement] = []
        func find(in parent: XMLElement) {
            for node in parent.elements(forName: "Node") {
                let type = node.attribute(forName: "Type")?.stringValue
                if type == "Geometry", node.attribute(forName: "Name")?.stringValue == geometryName { geometries.append(node) }
                else if !["Result", "MultiResult"].contains(type ?? "") { find(in: node) }
            }
        }
        find(in: roots)
        guard geometries.count <= 1 else { throw ProjectFileError.invalid("The selected geometry has ambiguous visual contexts in this map.") }
        let geometry: XMLElement
        if let existing = geometries.first { geometry = existing }
        else {
            guard create else { return nil }
            geometry = XMLElement(name: "Node")
            geometry.addAttribute(XMLNode.attribute(withName: "Type", stringValue: "Geometry") as! XMLNode)
            geometry.addAttribute(XMLNode.attribute(withName: "Name", stringValue: geometryName) as! XMLNode)
            roots.addChild(geometry)
        }
        let layers = geometry.elements(forName: "Node").filter { $0.attribute(forName: "Type")?.stringValue == "FlowAreaLayer" }
        guard layers.count <= 1 else { throw ProjectFileError.invalid("The selected geometry has ambiguous mesh visual contexts.") }
        if let layer = layers.first { return layer }
        guard create else { return nil }
        let layer = XMLElement(name: "Node")
        layer.addAttribute(XMLNode.attribute(withName: "Type", stringValue: "FlowAreaLayer") as! XMLNode)
        layer.addAttribute(XMLNode.attribute(withName: "Name", stringValue: "Computational Mesh") as! XMLNode)
        geometry.addChild(layer); return layer
    }

    /// Read the source layer in the selected map, excluding a Result's embedded
    /// same-name boundary condition. No settings from another map are borrowed.
    public func boundaryLineVisualOverrides(mapIndex: Int, boundaryName: String) throws -> BoundaryLineVisualOverrides {
        guard !boundaryName.isEmpty else { throw ProjectFileError.invalid("Select a boundary condition before reading its map style.") }
        try validateSourceUnchanged()
        let mapNodes = root.elements(forName: "Maps").first?.elements(forName: "Map") ?? []
        guard mapIndex >= 0, mapIndex < mapNodes.count else {
            if mapNodes.isEmpty && mapIndex == 0 { return .init() }
            throw ProjectFileError.invalid("The boundary line map no longer exists.")
        }
        guard let layer = try boundaryLineVisualNode(in: mapNodes[mapIndex], boundaryName: boundaryName, create: false) else { return .init() }
        var overrides = BoundaryLineVisualOverrides()
        for (id, isVertex) in [("BC_Line_Symbology", false), ("BC_Line_Vertex_Symbology", true)] {
            let nodes = layer.elements(forName: "Symbology").filter { $0.attribute(forName: "ID")?.stringValue == id }
            guard nodes.count <= 1 else { throw ProjectFileError.invalid("The boundary line style has ambiguous definitions.") }
            guard let node = nodes.first else { continue }
            var style = BoundaryLineVisualStyleOverrides()
            style.penColor = node.attribute(forName: "PenColor")?.stringValue
            if let raw = node.attribute(forName: "PenWidth")?.stringValue {
                guard let value = Double(raw) else { throw ProjectFileError.invalid("The boundary line style contains an invalid width.") }
                style.penWidth = value
            }
            if isVertex {
                style.fillColor = node.attribute(forName: "FillColor")?.stringValue
                if let raw = node.attribute(forName: "PointSize")?.stringValue {
                    guard let value = Int(raw) else { throw ProjectFileError.invalid("The boundary line style contains an invalid point size.") }
                    style.pointSize = value
                }
                overrides.vertex = style
            } else { overrides.line = style }
            let conditions = ["PenColorConditions", "PenWidthConditions", "FillColorConditions", "PointSizeConditions"]
            overrides.hasConditionalOverrides = overrides.hasConditionalOverrides || conditions.contains { name in
                node.elements(forName: name).contains { !$0.elements(forName: "Condition").isEmpty }
            }
        }
        for style in [overrides.line, overrides.vertex] {
            let colors = [style.penColor, style.fillColor].compactMap { $0 }
            guard colors.allSatisfy({ color in
                color.count == 9 && color.first == "#" && UInt32(color.dropFirst(), radix: 16) != nil
            }), style.penWidth.map({ $0.isFinite && $0 >= 0 && $0 <= 256 }) ?? true,
                style.pointSize.map({ (0...256).contains($0) }) ?? true else {
                throw ProjectFileError.invalid("Boundary styles require ARGB colors and sizes from 0 to 256.")
            }
        }
        return overrides
    }

    /// Resolve presence-aware local attributes over the supplied global style
    /// baseline. Existing callers without a baseline keep the original source
    /// defaults.
    public func boundaryLineVisualSettings(mapIndex: Int, boundaryName: String,
        globalDefaults: BoundaryLineVisualSettings? = nil) throws -> BoundaryLineVisualSettings {
        var settings = globalDefaults ?? BoundaryLineVisualSettings()
        let overrides = try boundaryLineVisualOverrides(mapIndex: mapIndex, boundaryName: boundaryName)
        func apply(_ overrides: BoundaryLineVisualStyleOverrides, to style: inout BoundaryVectorVisualStyle) {
            if let penColor = overrides.penColor { style.penColor = penColor }
            if let penWidth = overrides.penWidth { style.penWidth = penWidth }
            if let fillColor = overrides.fillColor { style.fillColor = fillColor }
            if let pointSize = overrides.pointSize { style.pointSize = pointSize }
        }
        apply(overrides.line, to: &settings.line)
        apply(overrides.vertex, to: &settings.vertex)
        settings.hasConditionalOverrides = overrides.hasConditionalOverrides
        try validateBoundaryLineVisualSettings(settings)
        return settings
    }

    /// Replace only the exposed style attributes. Original conditions, other
    /// symbologies and unknown attributes survive; pending local Views stay drafts.
    public func saveBoundaryLineVisualSettings(_ settings: BoundaryLineVisualSettings,
        mapIndex: Int, boundaryName: String,
        globalDefaults: BoundaryLineVisualSettings? = nil) throws {
        try validateBoundaryLineVisualSettings(settings)
        guard !boundaryName.isEmpty else { throw ProjectFileError.invalid("Select a boundary condition before editing its map style.") }
        try validateSourceUnchanged()
        // Applying an untouched sheet must not materialize local overrides and
        // thereby prevent a future global default from reaching this layer.
        let current = try boundaryLineVisualSettings(mapIndex: mapIndex, boundaryName: boundaryName,
            globalDefaults: globalDefaults)
        if current.line.penColor.caseInsensitiveCompare(settings.line.penColor) == .orderedSame,
           current.line.penWidth == settings.line.penWidth,
           current.vertex.penColor.caseInsensitiveCompare(settings.vertex.penColor) == .orderedSame,
           current.vertex.penWidth == settings.vertex.penWidth,
           current.vertex.fillColor.caseInsensitiveCompare(settings.vertex.fillColor) == .orderedSame,
           current.vertex.pointSize == settings.vertex.pointSize { return }
        let previous = sourceRevision
        let external = try savedBytes.map { try XMLDocument(data: $0, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever]) }
            ?? XMLDocument(rootElement: XMLElement(name: "Ras"))
        let externalRoot = external.rootElement()!
        let maps: XMLElement
        if let existing = externalRoot.elements(forName: "Maps").first { maps = existing }
        else { maps = XMLElement(name: "Maps"); externalRoot.addChild(maps) }
        var mapNodes = maps.elements(forName: "Map")
        if mapNodes.isEmpty && mapIndex == 0 {
            let created = XMLElement(name: "Map")
            created.addAttribute(XMLNode.attribute(withName: "Name", stringValue: "Map") as! XMLNode)
            created.addAttribute(XMLNode.attribute(withName: "Type", stringValue: "Project") as! XMLNode)
            maps.addChild(created); mapNodes = [created]
        }
        guard mapIndex >= 0, mapIndex < mapNodes.count,
              let layer = try boundaryLineVisualNode(in: mapNodes[mapIndex], boundaryName: boundaryName, create: true) else {
            throw ProjectFileError.invalid("The boundary line map no longer exists.")
        }
        for (id, style, isVertex) in [("BC_Line_Symbology", settings.line, false),
                                      ("BC_Line_Vertex_Symbology", settings.vertex, true)] {
            let matches = layer.elements(forName: "Symbology").filter { $0.attribute(forName: "ID")?.stringValue == id }
            guard matches.count <= 1 else { throw ProjectFileError.invalid("The boundary line style has ambiguous definitions.") }
            let defaults = globalDefaults ?? BoundaryLineVisualSettings()
            let defaultStyle = isVertex ? defaults.vertex : defaults.line
            let exposedKeys = isVertex ? ["PenColor", "PenWidth", "FillColor", "PointSize"] : ["PenColor", "PenWidth"]
            let equalsDefault = style.penColor.caseInsensitiveCompare(defaultStyle.penColor) == .orderedSame
                && style.penWidth == defaultStyle.penWidth
                && (!isVertex || (style.fillColor.caseInsensitiveCompare(defaultStyle.fillColor) == .orderedSame
                    && style.pointSize == defaultStyle.pointSize))
            let existing = matches.first
            if equalsDefault {
                if let existing {
                    for key in exposedKeys { existing.removeAttribute(forName: key) }
                    if existing.elements(forName: "PenColorConditions").isEmpty,
                       existing.elements(forName: "PenWidthConditions").isEmpty,
                       existing.elements(forName: "FillColorConditions").isEmpty,
                       existing.elements(forName: "PointSizeConditions").isEmpty,
                       (existing.attributes ?? []).allSatisfy({ $0.name == "ID" }),
                       (existing.children ?? []).allSatisfy({ $0.kind == .text && ($0.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                        existing.detach()
                    }
                }
                continue
            }
            let node: XMLElement
            if let existing { node = existing }
            else {
                node = XMLElement(name: "Symbology")
                node.addAttribute(XMLNode.attribute(withName: "ID", stringValue: id) as! XMLNode)
                layer.addChild(node)
            }
            var attributes = [("PenColor", style.penColor.uppercased()), ("PenWidth", String(style.penWidth))]
            if isVertex { attributes += [("FillColor", style.fillColor.uppercased()), ("PointSize", String(style.pointSize))] }
            for (key, value) in attributes {
                if let attribute = node.attribute(forName: key) { attribute.stringValue = value }
                else { node.addAttribute(XMLNode.attribute(withName: key, stringValue: value) as! XMLNode) }
            }
        }
        try validateSourceUnchanged()
        let bytes = external.xmlData(options: [.nodePreserveAll])
        try bytes.write(to: url, options: .atomic)
        try acceptExternalMapChange(expectedPreviousRevision: previous, newRevision: Self.revision(of: bytes))
    }

    private func validateBoundaryLineVisualSettings(_ settings: BoundaryLineVisualSettings) throws {
        for style in [settings.line, settings.vertex] {
            let colors = [style.penColor, style.fillColor]
            guard colors.allSatisfy({ color in
                color.count == 9 && color.first == "#" && UInt32(color.dropFirst(), radix: 16) != nil
            }), style.penWidth.isFinite, style.penWidth >= 0, style.penWidth <= 256,
                (0...256).contains(style.pointSize) else {
                throw ProjectFileError.invalid("Boundary styles require ARGB colors and sizes from 0 to 256.")
            }
        }
    }

    private func boundaryLineVisualNode(in map: XMLElement, boundaryName: String, create: Bool) throws -> XMLElement? {
        guard ["Project", "Buildable"].contains(map.attribute(forName: "Type")?.stringValue ?? "") else {
            throw ProjectFileError.invalid("Boundary line styles require a Project or Buildable map.")
        }
        func child(_ name: String, in parent: XMLElement) -> XMLElement? {
            if let existing = parent.elements(forName: name).first { return existing }
            guard create else { return nil }
            let node = XMLElement(name: name); parent.addChild(node); return node
        }
        guard let tree = child("Tree", in: map), let roots = child("Nodes", in: tree) else { return nil }
        var boundaries: [XMLElement] = []
        func find(in parent: XMLElement) {
            for node in parent.elements(forName: "Node") {
                let type = node.attribute(forName: "Type")?.stringValue ?? ""
                if type == "BoundaryCondition", node.attribute(forName: "Name")?.stringValue == boundaryName { boundaries.append(node) }
                else if !["Result", "MultiResult"].contains(type) { find(in: node) }
            }
        }
        find(in: roots)
        guard boundaries.count <= 1 else { throw ProjectFileError.invalid("The boundary condition has ambiguous visual contexts in this map.") }
        let boundary: XMLElement
        if let existing = boundaries.first { boundary = existing }
        else {
            guard create else { return nil }
            boundary = XMLElement(name: "Node")
            boundary.addAttribute(XMLNode.attribute(withName: "Type", stringValue: "BoundaryCondition") as! XMLNode)
            boundary.addAttribute(XMLNode.attribute(withName: "Name", stringValue: boundaryName) as! XMLNode)
            roots.addChild(boundary)
        }
        let layers = boundary.elements(forName: "Node").filter { $0.attribute(forName: "Type")?.stringValue == "BoundaryConditionLineLayer" }
        guard layers.count <= 1 else { throw ProjectFileError.invalid("The boundary condition has ambiguous line visual contexts.") }
        if let layer = layers.first { return layer }
        guard create else { return nil }
        let layer = XMLElement(name: "Node")
        layer.addAttribute(XMLNode.attribute(withName: "Type", stringValue: "BoundaryConditionLineLayer") as! XMLNode)
        layer.addAttribute(XMLNode.attribute(withName: "Name", stringValue: "Boundary Condition Lines") as! XMLNode)
        boundary.addChild(layer); return layer
    }

    private func collectRasterSources(
        _ node: XMLElement, path: [Int], mapIndex: Int, mapName: String, mapType: String,
        revision: String, projectDirectory: URL, into result: inout [RasterMapSourceDescriptor]
    ) {
        if node.attribute(forName: "Type")?.stringValue == "MapLayer",
           node.attribute(forName: "MapType")?.stringValue == "SingleBandRasterMapLayer",
           let sourceURL = Self.resolveSource(filename: node.attribute(forName: "Filename")?.stringValue,
                                         relative: node.attribute(forName: "FilenameRelative")?.stringValue,
                                         projectDirectory: projectDirectory),
           let name = node.attribute(forName: "Name")?.stringValue {
            let address = path.map { String($0) }.joined(separator: ".")
            let identity = "vis-map-\(mapIndex)-node-\(address)"
            result.append(RasterMapSourceDescriptor(
                id: identity, projectPath: projectURL.path, visualizationPath: url.path,
                visualizationRevision: revision, mapIndex: mapIndex, mapName: mapName,
                mapType: mapType, nodePath: path, nodeName: name,
                mapLayerType: "SingleBandRasterMapLayer",
                filename: node.attribute(forName: "Filename")?.stringValue,
                filenameRelative: node.attribute(forName: "FilenameRelative")?.stringValue,
                sourcePath: sourceURL.path))
        }
        for (index, child) in node.elements(forName: "Node").enumerated() {
            collectRasterSources(child, path: path + [index], mapIndex: mapIndex,
                mapName: mapName, mapType: mapType, revision: revision,
                projectDirectory: projectDirectory, into: &result)
        }
    }

    private static func resolveSource(filename: String?, relative: String?, allowDirectory: Bool = false,
        projectDirectory: URL) -> URL? {
        func candidate(_ value: String) -> URL {
            let normalized = value.replacingOccurrences(of: "\\", with: "/")
            let isPosixAbsolute = normalized.hasPrefix("/")
            let isWindowsAbsolute = normalized.range(of: "^[A-Za-z]:/", options: .regularExpression) != nil
            let url = isPosixAbsolute || isWindowsAbsolute
                ? URL(fileURLWithPath: normalized)
                : projectDirectory.appendingPathComponent(normalized)
            return url.standardizedFileURL.resolvingSymlinksInPath()
        }
        func isAcceptedSource(_ url: URL) -> Bool {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else { return false }
            if values.isRegularFile == true { return true }
            guard allowDirectory,
                  let directoryValues = try? url.resourceValues(forKeys: [.isDirectoryKey]) else { return false }
            return directoryValues.isDirectory == true
        }
        if let relative, !relative.isEmpty {
            let path = candidate(relative)
            if isAcceptedSource(path) { return path }
        }
        if let filename, !filename.isEmpty {
            let path = candidate(filename)
            if isAcceptedSource(path) { return path }
        }
        return nil
    }

    private static func revision(of bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02X", $0) }.joined()
    }
    public func validateSave() throws {
        guard modified else { return }
        if let savedBytes {
            guard try Data(contentsOf: url) == savedBytes else { throw ProjectFileError.modifiedExternally }
        } else if FileManager.default.fileExists(atPath: url.path) { throw ProjectFileError.modifiedExternally }
    }
    public func save() throws {
        guard modified else { return }; try validateSave()
        let bytes = xml.xmlData(options: [.nodePreserveAll])
        try bytes.write(to: url, options: .atomic); savedBytes = bytes; modified = false
    }
    private func validate(_ view: SavedMapView) throws {
        guard !view.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProjectFileError.invalid("Enter a view name.") }
        guard !views.contains(where: { $0.id != view.id && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(view.name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }) else {
            throw ProjectFileError.invalid("Name for view already exists.")
        }
        guard [view.lowerLeft.x, view.lowerLeft.y, view.upperRight.x, view.upperRight.y].allSatisfy(\.isFinite),
              view.upperRight.x > view.lowerLeft.x, view.upperRight.y > view.lowerLeft.y else { throw ProjectFileError.invalid("Enter a nonzero extent.") }
    }
    private func write(_ view: SavedMapView, to node: XMLElement) {
        func child(_ name: String) -> XMLElement {
            if let existing = node.elements(forName: name).first { return existing }
            let created = XMLElement(name: name); node.addChild(created); return created
        }
        child("Name").stringValue = view.name; child("Bind").stringValue = view.shortcut
        let extent = child("Extent")
        for (key, value) in [("Left", view.lowerLeft.x), ("Top", view.upperRight.y), ("Right", view.upperRight.x), ("Bottom", view.lowerLeft.y)] {
            if let attribute = extent.attribute(forName: key) { attribute.stringValue = String(value) }
            else { extent.addAttribute(XMLNode.attribute(withName: key, stringValue: String(value)) as! XMLNode) }
        }
    }
}

public extension VisualizationDocument {
    /// Reads the effective per-definition styles for one persisted vector
    /// MapLayer. The returned revision is the exact saved `.vis` SHA used to
    /// resolve the identity and must be supplied when saving.
    func vectorVisualSettings(
        identity: VectorVisualNodeIdentity,
        defaults: [String: VectorStyleValues]
    ) throws -> VectorVisualSettingsSnapshot {
        try validateSourceUnchanged()
        guard let savedBytes else {
            throw ProjectFileError.invalid("Vector styles require a persisted map layer in an existing .vis file.")
        }
        let document = try Self.parseSavedVisualization(savedBytes)
        let (layer, definitionIDs) = try Self.resolveVectorVisualLayer(identity, in: document, projectDirectory: projectURL.deletingLastPathComponent())
        var options: [String: VectorVisualSettingsOptions] = [:]
        for id in definitionIDs {
            guard let baseline = defaults[id], let definition = SourceVectorStyleCatalog.definition(for: id) else {
                throw ProjectFileError.invalid("A current global default is required for vector style \(id).")
            }
            let matches = layer.elements(forName: "Symbology").filter { $0.attribute(forName: "ID")?.stringValue == id }
            guard matches.count <= 1 else { throw ProjectFileError.invalid("Vector style \(id) has ambiguous definitions.") }
            let styleNode = matches.first
            var values = baseline
            if let styleNode {
                try Self.readVectorStyleAttributes(from: styleNode, type: definition.type, into: &values)
            }
            guard let validated = values.validatedForPersistence() else {
                throw ProjectFileError.invalid("Vector style \(id) contains malformed colors or non-finite measurements.")
            }
            options[id] = VectorVisualSettingsOptions(
                values: validated,
                conditionGroups: try Self.readVectorConditionGroups(from: styleNode)
            )
        }
        return VectorVisualSettingsSnapshot(options: options, revision: Self.revision(of: savedBytes))
    }

    /// Applies only the supplied definition IDs. It edits a copy of the saved
    /// baseline, omits base attributes equal to their current global defaults,
    /// preserves condition rules and unknown XML, and adopts the result through
    /// the same map-section merge used by other source mutations.
    func saveVectorVisualSettings(
        identity: VectorVisualNodeIdentity,
        options: [String: VectorVisualSettingsOptions],
        defaults: [String: VectorStyleValues],
        expectedRevision: String?
    ) throws {
        try validateSourceUnchanged()
        guard let savedBytes else {
            throw ProjectFileError.invalid("Vector styles require a persisted map layer in an existing .vis file.")
        }
        let previousRevision = Self.revision(of: savedBytes)
        guard expectedRevision?.caseInsensitiveCompare(previousRevision) == .orderedSame else {
            throw ProjectFileError.modifiedExternally
        }
        let sourceDocument = try Self.parseSavedVisualization(savedBytes)
        let (_, availableIDs) = try Self.resolveVectorVisualLayer(identity, in: sourceDocument,
            projectDirectory: projectURL.deletingLastPathComponent())
        guard !options.isEmpty, options.keys.allSatisfy(availableIDs.contains) else {
            throw ProjectFileError.invalid("The requested vector styles do not belong to this persisted map layer.")
        }
        for (id, option) in options {
            guard let baseline = defaults[id], let definition = SourceVectorStyleCatalog.definition(for: id) else {
                throw ProjectFileError.invalid("A current global default is required for vector style \(id).")
            }
            guard let values = option.values.validatedForPersistence(), values == option.values else {
                throw ProjectFileError.invalid("Vector style \(id) contains malformed colors or non-finite measurements.")
            }
            try Self.validateVectorConditionGroups(option.conditionGroups)
            guard baseline.validatedForPersistence() != nil,
                  Self.persistedAttributes(for: definition.type) != nil else {
                throw ProjectFileError.invalid("Vector style \(id) has an unsupported persisted style type.")
            }
        }

        let current = try vectorVisualSettings(identity: identity, defaults: defaults)
        guard options.contains(where: { entry in
            let id = entry.key
            let option = entry.value
            guard let old = current.options[id], let definition = SourceVectorStyleCatalog.definition(for: id) else { return true }
            return !Self.vectorOptionsEqualForPersistence(old, option, type: definition.type)
        }) else { return }

        let external = try Self.parseSavedVisualization(savedBytes)
        let (layer, _) = try Self.resolveVectorVisualLayer(identity, in: external,
            projectDirectory: projectURL.deletingLastPathComponent())
        for id in options.keys.sorted() {
            guard let option = options[id], let baseline = defaults[id],
                  let definition = SourceVectorStyleCatalog.definition(for: id) else { continue }
            try Self.writeVectorStyle(option, defaultValues: baseline, definition: definition, id: id, to: layer)
        }

        try validateSourceUnchanged()
        let bytes = external.xmlData(options: [.nodePreserveAll])
        try bytes.write(to: url, options: .atomic)
        try acceptExternalMapChange(expectedPreviousRevision: previousRevision, newRevision: Self.revision(of: bytes))
    }

    /// Reads the Line and Vertex definitions from one exact persisted
    /// BoundaryConditionLineLayer child. Unlike the model-editor convenience
    /// API below, this method never resolves a BoundaryCondition by name or
    /// manufactures a missing BoundaryCondition row.
    func boundaryVectorVisualSettings(
        identity: BoundaryVectorVisualNodeIdentity,
        defaults: [String: VectorStyleValues]
    ) throws -> VectorVisualSettingsSnapshot {
        try validateSourceUnchanged()
        guard let savedBytes else {
            throw ProjectFileError.invalid("Boundary vector styles require an existing .vis file and a persisted Boundary Condition row.")
        }
        let document = try Self.parseSavedVisualization(savedBytes)
        let (_, lineNode) = try Self.resolveBoundaryVectorVisualNode(identity, in: document,
            createMissingLineNode: false)
        var options: [String: VectorVisualSettingsOptions] = [:]
        for id in Self.boundaryVectorStyleDefinitionIDs {
            guard let baseline = defaults[id], let definition = SourceVectorStyleCatalog.definition(for: id) else {
                throw ProjectFileError.invalid("A current global default is required for vector style \(id).")
            }
            let matches = lineNode?.elements(forName: "Symbology").filter {
                $0.attribute(forName: "ID")?.stringValue == id
            } ?? []
            guard matches.count <= 1 else {
                throw ProjectFileError.invalid("Boundary vector style \(id) has ambiguous definitions.")
            }
            var values = baseline
            if let styleNode = matches.first {
                try Self.readVectorStyleAttributes(from: styleNode, type: definition.type, into: &values)
            }
            guard let validated = values.validatedForPersistence(),
                  baseline.validatedForPersistence() != nil else {
                throw ProjectFileError.invalid("Boundary vector style \(id) contains malformed colors or non-finite measurements.")
            }
            options[id] = VectorVisualSettingsOptions(values: validated,
                conditionGroups: try Self.readVectorConditionGroups(from: matches.first))
        }
        return VectorVisualSettingsSnapshot(options: options, revision: Self.revision(of: savedBytes))
    }

    /// Saves only the exposed Line/Vertex base attributes and four condition
    /// groups on the exact BoundaryConditionLineLayer child. An absent line
    /// child may be materialized beneath the already-resolved Boundary row;
    /// the Boundary row and its map roots are never created here.
    func saveBoundaryVectorVisualSettings(
        identity: BoundaryVectorVisualNodeIdentity,
        options: [String: VectorVisualSettingsOptions],
        defaults: [String: VectorStyleValues],
        expectedRevision: String?,
        resetToDefaults: Bool = false
    ) throws {
        try validateSourceUnchanged()
        guard let savedBytes else {
            throw ProjectFileError.invalid("Boundary vector styles require an existing .vis file and a persisted Boundary Condition row.")
        }
        let previousRevision = Self.revision(of: savedBytes)
        guard let expectedRevision,
              expectedRevision.caseInsensitiveCompare(previousRevision) == .orderedSame else {
            throw ProjectFileError.modifiedExternally
        }
        let sourceDocument = try Self.parseSavedVisualization(savedBytes)
        let resolved = try Self.resolveBoundaryVectorVisualNode(identity, in: sourceDocument,
            createMissingLineNode: false)

        if resetToDefaults {
            let definitionIDs = Self.boundaryVectorStyleDefinitionIDs
            guard options.count == definitionIDs.count,
                  definitionIDs.allSatisfy({ options[$0] != nil }) else {
                throw ProjectFileError.invalid("Reset requires both Boundary line style definitions.")
            }
            var attributesByID: [String: [String]] = [:]
            for id in definitionIDs {
                guard let option = options[id], let baseline = defaults[id],
                      let definition = SourceVectorStyleCatalog.definition(for: id),
                      let attributes = Self.persistedAttributes(for: definition.type),
                      let values = option.values.validatedForPersistence(), values == option.values,
                      baseline.validatedForPersistence() != nil,
                      values == baseline else {
                    throw ProjectFileError.invalid("Reset values must match the current global Boundary style defaults.")
                }
                attributesByID[id] = attributes
            }
            guard let lineNode = resolved.lineNode else { return }
            var removedAny = false
            for id in definitionIDs {
                let matches = lineNode.elements(forName: "Symbology").filter {
                    $0.attribute(forName: "ID")?.stringValue == id
                }
                guard matches.count <= 1 else {
                    throw ProjectFileError.invalid("Boundary vector style \(id) has ambiguous definitions.")
                }
                guard let styleNode = matches.first else { continue }
                for name in attributesByID[id] ?? [] where styleNode.attribute(forName: name) != nil {
                    styleNode.removeAttribute(forName: name)
                    removedAny = true
                }
            }
            guard removedAny else { return }
            try validateSourceUnchanged()
            let bytes = sourceDocument.xmlData(options: [.nodePreserveAll])
            try bytes.write(to: url, options: .atomic)
            try acceptExternalMapChange(expectedPreviousRevision: previousRevision,
                newRevision: Self.revision(of: bytes))
            return
        }

        guard !options.isEmpty,
              options.keys.allSatisfy({ Self.boundaryVectorStyleDefinitionIDs.contains($0) }) else {
            throw ProjectFileError.invalid("The requested styles do not belong to a Boundary Condition line layer.")
        }
        for (id, option) in options {
            guard let baseline = defaults[id],
                  let definition = SourceVectorStyleCatalog.definition(for: id),
                  let values = option.values.validatedForPersistence(), values == option.values,
                  baseline.validatedForPersistence() != nil,
                  Self.persistedAttributes(for: definition.type) != nil else {
                throw ProjectFileError.invalid("Boundary vector style \(id) contains unsupported or malformed values.")
            }
            try Self.validateVectorConditionGroups(option.conditionGroups)
        }

        let current = try boundaryVectorVisualSettings(identity: identity, defaults: defaults)
        let hasChanges = options.contains { id, option in
            guard let old = current.options[id],
                  let definition = SourceVectorStyleCatalog.definition(for: id) else { return true }
            guard let attributes = Self.persistedAttributes(for: definition.type) else { return true }
            return !Self.vectorValuesEqual(old.values, option.values, attributes: attributes)
        }
        guard hasChanges else { return }

        let external = try Self.parseSavedVisualization(savedBytes)
        let (_, lineNode) = try Self.resolveBoundaryVectorVisualNode(identity, in: external,
            createMissingLineNode: true)
        guard let lineNode else { throw ProjectFileError.modifiedExternally }
        for id in options.keys.sorted() {
            guard let option = options[id], let baseline = defaults[id],
                  let definition = SourceVectorStyleCatalog.definition(for: id) else { continue }
            guard let savedConditions = current.options[id]?.conditionGroups else {
                throw ProjectFileError.modifiedExternally
            }
            // Boundary line rendering has no typed attribute-table context.
            // Preserve all stored rules exactly while allowing base-style edits.
            let persistedOption = VectorVisualSettingsOptions(values: option.values,
                conditionGroups: savedConditions)
            try Self.writeVectorStyle(persistedOption, defaultValues: baseline,
                definition: definition, id: id, to: lineNode)
        }

        try validateSourceUnchanged()
        let bytes = external.xmlData(options: [.nodePreserveAll])
        try bytes.write(to: url, options: .atomic)
        try acceptExternalMapChange(expectedPreviousRevision: previousRevision, newRevision: Self.revision(of: bytes))
    }

    /// Lists only existing retained geometry visual children in the selected
    /// map. The caller supplies the asset identity of the live Geometry node;
    /// this prevents a UI session from treating a same-name model as its
    /// owner. The `.vis` identity is then verified by map, root, and full node
    /// paths before a child is returned.
    func specializedVectorVisualNodes(
        mapIndex: Int,
        geometryName: String,
        geometryAssetID: String
    ) throws -> [SpecializedVectorVisualNodeIdentity] {
        try validateSourceUnchanged()
        guard !geometryName.isEmpty, !geometryAssetID.isEmpty,
              let savedBytes else {
            throw ProjectFileError.invalid("A saved map and live Geometry asset are required for local geometry styles.")
        }
        let document = try Self.parseSavedVisualization(savedBytes)
        guard let root = document.rootElement() else {
            throw ProjectFileError.invalid("Visualization settings require a Ras root element.")
        }
        let mapContainers = root.elements(forName: "Maps")
        guard mapContainers.count == 1 else {
            throw ProjectFileError.invalid("The visualization file has an ambiguous Maps section.")
        }
        let maps = mapContainers[0].elements(forName: "Map")
        guard mapIndex >= 0, mapIndex < maps.count else {
            throw ProjectFileError.invalid("The selected visualization map no longer exists.")
        }
        let map = maps[mapIndex]
        guard let mapName = map.attribute(forName: "Name")?.stringValue,
              let mapType = map.attribute(forName: "Type")?.stringValue,
              ["Project", "Buildable"].contains(mapType) else {
            throw ProjectFileError.invalid("Specialized geometry styles require a supported project map.")
        }
        let trees = map.elements(forName: "Tree")
        guard trees.count == 1, trees[0].elements(forName: "Nodes").count == 1 else {
            throw ProjectFileError.invalid("The selected map has an ambiguous tree structure.")
        }
        let roots = trees[0].elements(forName: "Nodes")[0].elements(forName: "Node")
        var geometries: [(node: XMLElement, path: [Int], rootName: String)] = []
        for (rootIndex, rootNode) in roots.enumerated() where rootNode.attribute(forName: "Type")?.stringValue == "Root" {
            guard let rootName = rootNode.attribute(forName: "Name")?.stringValue, !rootName.isEmpty else {
                throw ProjectFileError.invalid("The selected map contains a root without a name.")
            }
            Self.collectSpecializedGeometryNodes(rootNode, path: [rootIndex], geometryName: geometryName,
                rootName: rootName, into: &geometries)
        }
        guard geometries.count <= 1 else {
            throw ProjectFileError.invalid("The selected Geometry name is ambiguous in this map.")
        }
        guard let geometry = geometries.first else { return [] }

        var result: [SpecializedVectorVisualNodeIdentity] = []
        var seenTypes: Set<String> = []
        for (index, child) in geometry.node.elements(forName: "Node").enumerated() {
            guard let type = child.attribute(forName: "Type")?.stringValue,
                  let name = child.attribute(forName: "Name")?.stringValue,
                  SpecializedVectorVisualDefinitions.definitionIDs(forNodeType: type) != nil else { continue }
            guard seenTypes.insert(type).inserted else {
                throw ProjectFileError.invalid("The Geometry contains duplicate specialized style owners.")
            }
            result.append(SpecializedVectorVisualNodeIdentity(
                mapIndex: mapIndex,
                mapName: mapName,
                mapType: mapType,
                rootName: geometry.rootName,
                geometryNodePath: geometry.path,
                geometryName: geometryName,
                geometryAssetID: geometryAssetID,
                nodePath: geometry.path + [index],
                nodeType: type,
                nodeName: name
            ))
        }
        return result
    }

    /// Reads styles for one exact persisted source-owned child. No style is
    /// borrowed from another map, Geometry, or equal-name node.
    func specializedVectorVisualSettings(
        identity: SpecializedVectorVisualNodeIdentity,
        defaults: [String: VectorStyleValues]
    ) throws -> VectorVisualSettingsSnapshot {
        try validateSourceUnchanged()
        guard let savedBytes else {
            throw ProjectFileError.invalid("Specialized geometry styles require an existing .vis file.")
        }
        let document = try Self.parseSavedVisualization(savedBytes)
        let (node, definitionIDs) = try Self.resolveSpecializedVectorVisualNode(identity, in: document)
        var options: [String: VectorVisualSettingsOptions] = [:]
        for id in definitionIDs {
            guard let baseline = defaults[id], let definition = SourceVectorStyleCatalog.definition(for: id) else {
                throw ProjectFileError.invalid("A current global default is required for vector style \(id).")
            }
            let matches = node.elements(forName: "Symbology").filter { $0.attribute(forName: "ID")?.stringValue == id }
            guard matches.count <= 1 else { throw ProjectFileError.invalid("Vector style \(id) has ambiguous definitions.") }
            var values = baseline
            if let styleNode = matches.first {
                try Self.readVectorStyleAttributes(from: styleNode, type: definition.type, into: &values)
            }
            guard let validated = values.validatedForPersistence() else {
                throw ProjectFileError.invalid("Vector style \(id) contains malformed colors or non-finite measurements.")
            }
            options[id] = VectorVisualSettingsOptions(values: validated,
                conditionGroups: try Self.readVectorConditionGroups(from: matches.first))
        }
        return VectorVisualSettingsSnapshot(options: options, revision: Self.revision(of: savedBytes))
    }

    /// Saves only supplied source definition IDs on an exact, already
    /// serialized geometry child. It preserves the child tree and unknown XML,
    /// omits values equal to the captured current defaults, and rejects stale
    /// `.vis` revisions before replacing the original file atomically.
    func saveSpecializedVectorVisualSettings(
        identity: SpecializedVectorVisualNodeIdentity,
        options: [String: VectorVisualSettingsOptions],
        defaults: [String: VectorStyleValues],
        expectedRevision: String?
    ) throws {
        try validateSourceUnchanged()
        guard let savedBytes else {
            throw ProjectFileError.invalid("Specialized geometry styles require an existing .vis file.")
        }
        let previousRevision = Self.revision(of: savedBytes)
        guard expectedRevision?.caseInsensitiveCompare(previousRevision) == .orderedSame else {
            throw ProjectFileError.modifiedExternally
        }
        let sourceDocument = try Self.parseSavedVisualization(savedBytes)
        let (_, availableIDs) = try Self.resolveSpecializedVectorVisualNode(identity, in: sourceDocument)
        guard !options.isEmpty, options.keys.allSatisfy(availableIDs.contains) else {
            throw ProjectFileError.invalid("The requested styles do not belong to this specialized geometry node.")
        }
        for (id, option) in options {
            guard let baseline = defaults[id], let definition = SourceVectorStyleCatalog.definition(for: id),
                  let values = option.values.validatedForPersistence(), values == option.values,
                  baseline.validatedForPersistence() != nil,
                  Self.persistedAttributes(for: definition.type) != nil else {
                throw ProjectFileError.invalid("Vector style \(id) contains unsupported or malformed values.")
            }
            try Self.validateVectorConditionGroups(option.conditionGroups)
        }

        let current = try specializedVectorVisualSettings(identity: identity, defaults: defaults)
        guard options.contains(where: { id, option in
            guard let old = current.options[id],
                  let definition = SourceVectorStyleCatalog.definition(for: id) else { return true }
            return !Self.vectorOptionsEqualForPersistence(old, option, type: definition.type)
        }) else { return }

        let external = try Self.parseSavedVisualization(savedBytes)
        let (node, _) = try Self.resolveSpecializedVectorVisualNode(identity, in: external)
        for id in options.keys.sorted() {
            guard let option = options[id], let baseline = defaults[id],
                  let definition = SourceVectorStyleCatalog.definition(for: id) else { continue }
            try Self.writeVectorStyle(option, defaultValues: baseline, definition: definition, id: id, to: node)
        }
        try validateSourceUnchanged()
        let bytes = external.xmlData(options: [.nodePreserveAll])
        try bytes.write(to: url, options: .atomic)
        try acceptExternalMapChange(expectedPreviousRevision: previousRevision, newRevision: Self.revision(of: bytes))
    }
}

private extension VisualizationDocument {
    static var boundaryVectorStyleDefinitionIDs: [String] {
        ["BC_Line_Symbology", "BC_Line_Vertex_Symbology"]
    }

    static var vectorConditionNames: [(VectorStyleField, String)] { [
        (.penColor, "PenColorConditions"),
        (.penWidth, "PenWidthConditions"),
        (.fillColor, "FillColorConditions"),
        (.pointSize, "PointSizeConditions")
    ] }

    /// Resolves only the exact serialized BoundaryCondition row and its
    /// immediate line-rendering child. The line child can be absent only when
    /// its path was explicitly omitted by the source-default tree; in that
    /// case saving may materialize that child beneath this existing row.
    static func resolveBoundaryVectorVisualNode(
        _ identity: BoundaryVectorVisualNodeIdentity,
        in document: XMLDocument,
        createMissingLineNode: Bool
    ) throws -> (boundaryNode: XMLElement, lineNode: XMLElement?) {
        guard identity.mapIndex >= 0,
              !identity.mapName.isEmpty,
              !identity.rootName.isEmpty,
              !identity.boundaryName.isEmpty,
              !identity.lineNodeName.isEmpty,
              identity.lineNodePath != nil || identity.lineNodeName == "Boundary Condition Lines",
              identity.boundaryNodePath.count >= 2,
              identity.boundaryNodePath.allSatisfy({ $0 >= 0 }),
              identity.lineNodePath.map({ $0.allSatisfy({ $0 >= 0 }) }) ?? true,
              identity.lineNodePath.map({ $0.count == identity.boundaryNodePath.count + 1
                  && Array($0.dropLast()) == identity.boundaryNodePath }) ?? true,
              boundaryMapRootAllowed(mapType: identity.mapType, rootName: identity.rootName) else {
            throw ProjectFileError.invalid("The Boundary Condition vector-style identity is invalid or unsupported.")
        }
        guard let root = document.rootElement(), root.name == "Ras" else {
            throw ProjectFileError.invalid("Visualization settings require a Ras root element.")
        }
        let mapsContainers = root.elements(forName: "Maps")
        guard mapsContainers.count == 1 else {
            throw ProjectFileError.invalid("The visualization file has an ambiguous Maps section.")
        }
        let maps = mapsContainers[0].elements(forName: "Map")
        guard identity.mapIndex < maps.count else { throw ProjectFileError.modifiedExternally }
        let map = maps[identity.mapIndex]
        guard map.attribute(forName: "Name")?.stringValue == identity.mapName,
              map.attribute(forName: "Type")?.stringValue == identity.mapType else {
            throw ProjectFileError.modifiedExternally
        }
        let trees = map.elements(forName: "Tree")
        guard trees.count == 1, trees[0].elements(forName: "Nodes").count == 1 else {
            throw ProjectFileError.invalid("The selected map has an ambiguous tree structure.")
        }

        let nodes = trees[0].elements(forName: "Nodes")[0]
        let rootIndex = identity.boundaryNodePath[0]
        let roots = nodes.elements(forName: "Node")
        guard rootIndex < roots.count,
              roots[rootIndex].attribute(forName: "Type")?.stringValue == "Root",
              roots[rootIndex].attribute(forName: "Name")?.stringValue == identity.rootName else {
            throw ProjectFileError.modifiedExternally
        }

        var parent = nodes
        var boundary: XMLElement?
        for index in identity.boundaryNodePath {
            let children = parent.elements(forName: "Node")
            guard index < children.count else { throw ProjectFileError.modifiedExternally }
            boundary = children[index]
            parent = children[index]
        }
        guard let boundary,
              boundary.attribute(forName: "Type")?.stringValue == "BoundaryCondition",
              boundary.attribute(forName: "Name")?.stringValue == identity.boundaryName else {
            throw ProjectFileError.modifiedExternally
        }

        let childNodes = boundary.elements(forName: "Node")
        let lineMatches = childNodes.filter {
            $0.attribute(forName: "Type")?.stringValue == "BoundaryConditionLineLayer"
        }
        guard lineMatches.count <= 1 else {
            throw ProjectFileError.invalid("The Boundary Condition has ambiguous line visual children.")
        }
        let lineNode: XMLElement?
        if let linePath = identity.lineNodePath {
            guard let childIndex = linePath.last, childIndex < childNodes.count,
                  let matched = lineMatches.first, childNodes[childIndex] === matched,
                  matched.attribute(forName: "Name")?.stringValue == identity.lineNodeName else {
                throw ProjectFileError.modifiedExternally
            }
            lineNode = matched
        } else if let matched = lineMatches.first {
            guard matched.attribute(forName: "Name")?.stringValue == identity.lineNodeName else {
                throw ProjectFileError.modifiedExternally
            }
            lineNode = matched
        } else if createMissingLineNode {
            let created = XMLElement(name: "Node")
            created.addAttribute(XMLNode.attribute(withName: "Type",
                stringValue: "BoundaryConditionLineLayer") as! XMLNode)
            created.addAttribute(XMLNode.attribute(withName: "Name",
                stringValue: identity.lineNodeName) as! XMLNode)
            boundary.addChild(created)
            lineNode = created
        } else {
            lineNode = nil
        }
        return (boundary, lineNode)
    }

    static func boundaryMapRootAllowed(mapType: String, rootName: String) -> Bool {
        switch mapType {
        case "Project": ["Boundary Conditions", "Results"].contains(rootName)
        case "Buildable", "Geometry": rootName == "Layers"
        case "Plan": ["Focused Plans", "Matching Layers", "Layers"].contains(rootName)
        default: false
        }
    }

    static func parseSavedVisualization(_ bytes: Data) throws -> XMLDocument {
        let document = try XMLDocument(data: bytes, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
        guard document.rootElement()?.name == "Ras" else {
            throw ProjectFileError.invalid("Visualization settings require a Ras root element.")
        }
        return document
    }

    static func resolveVectorVisualLayer(
        _ identity: VectorVisualNodeIdentity,
        in document: XMLDocument,
        projectDirectory: URL
    ) throws -> (XMLElement, [String]) {
        guard identity.mapIndex >= 0, identity.nodeType == "MapLayer", !identity.nodePath.isEmpty,
              identity.nodePath.allSatisfy({ $0 >= 0 }),
              ["Project", "Buildable"].contains(identity.mapType) else {
            throw ProjectFileError.invalid("The vector map-layer identity is invalid or unsupported.")
        }
        guard let root = document.rootElement(), root.name == "Ras" else {
            throw ProjectFileError.invalid("Visualization settings require a Ras root element.")
        }
        let mapsContainers = root.elements(forName: "Maps")
        guard mapsContainers.count == 1 else {
            throw ProjectFileError.invalid("The visualization file has an ambiguous Maps section.")
        }
        let maps = mapsContainers[0].elements(forName: "Map")
        guard identity.mapIndex < maps.count else { throw ProjectFileError.modifiedExternally }
        let map = maps[identity.mapIndex]
        guard map.attribute(forName: "Name")?.stringValue == identity.mapName,
              map.attribute(forName: "Type")?.stringValue == identity.mapType else {
            throw ProjectFileError.modifiedExternally
        }
        let trees = map.elements(forName: "Tree")
        guard trees.count == 1, trees[0].elements(forName: "Nodes").count == 1 else {
            throw ProjectFileError.invalid("The selected map has an ambiguous tree structure.")
        }
        var parent = trees[0].elements(forName: "Nodes")[0]
        if let rootName = identity.rootName {
            let rootIndex = identity.nodePath[0]
            let roots = parent.elements(forName: "Node")
            guard rootIndex < roots.count,
                  roots[rootIndex].attribute(forName: "Type")?.stringValue == "Root",
                  roots[rootIndex].attribute(forName: "Name")?.stringValue == rootName else {
                throw ProjectFileError.modifiedExternally
            }
        }
        var layer: XMLElement?
        for index in identity.nodePath {
            let nodes = parent.elements(forName: "Node")
            guard index < nodes.count else { throw ProjectFileError.modifiedExternally }
            layer = nodes[index]
            parent = nodes[index]
        }
        guard let layer,
              layer.attribute(forName: "Type")?.stringValue == identity.nodeType,
              layer.attribute(forName: "Name")?.stringValue == identity.nodeName,
              layer.attribute(forName: "MapType")?.stringValue == identity.mapLayerType,
              layer.attribute(forName: "Filename")?.stringValue == identity.filename,
              layer.attribute(forName: "FilenameRelative")?.stringValue == identity.filenameRelative,
              layer.attribute(forName: "GdbLayerName")?.stringValue == identity.gdbLayerName,
              layer.attribute(forName: "GdbVectorType")?.stringValue == identity.gdbVectorType else {
            throw ProjectFileError.modifiedExternally
        }
        guard let assetID = identity.assetID, !assetID.isEmpty,
              let source = Self.resolveSource(filename: identity.filename, relative: identity.filenameRelative,
                  allowDirectory: true,
                  projectDirectory: projectDirectory.standardizedFileURL),
              canonicalVectorPath(assetID) == canonicalVectorPath(source.path) else {
            throw ProjectFileError.modifiedExternally
        }
        guard let ids = VectorVisualStyleDefinitions.ids(mapLayerType: identity.mapLayerType,
            gdbVectorType: identity.gdbVectorType) else {
            throw ProjectFileError.invalid("The selected MapLayer has no supported vector style context.")
        }
        return (layer, ids)
    }

    static func collectSpecializedGeometryNodes(
        _ node: XMLElement,
        path: [Int],
        geometryName: String,
        rootName: String,
        into result: inout [(node: XMLElement, path: [Int], rootName: String)]
    ) {
        if node.attribute(forName: "Type")?.stringValue == "Geometry",
           node.attribute(forName: "Name")?.stringValue == geometryName {
            result.append((node, path, rootName))
        }
        for (index, child) in node.elements(forName: "Node").enumerated() {
            collectSpecializedGeometryNodes(child, path: path + [index], geometryName: geometryName,
                rootName: rootName, into: &result)
        }
    }

    static func resolveSpecializedVectorVisualNode(
        _ identity: SpecializedVectorVisualNodeIdentity,
        in document: XMLDocument
    ) throws -> (XMLElement, [String]) {
        guard identity.mapIndex >= 0,
              ["Project", "Buildable"].contains(identity.mapType),
              !identity.rootName.isEmpty, !identity.geometryName.isEmpty,
              !identity.geometryAssetID.isEmpty,
              !identity.geometryNodePath.isEmpty, !identity.nodePath.isEmpty,
              identity.geometryNodePath.allSatisfy({ $0 >= 0 }),
              identity.nodePath.allSatisfy({ $0 >= 0 }),
              identity.nodePath.count == identity.geometryNodePath.count + 1,
              Array(identity.nodePath.dropLast()) == identity.geometryNodePath,
              let definitionIDs = SpecializedVectorVisualDefinitions.definitionIDs(forNodeType: identity.nodeType) else {
            throw ProjectFileError.invalid("The specialized geometry style identity is invalid or unsupported.")
        }
        guard let root = document.rootElement(), root.name == "Ras" else {
            throw ProjectFileError.invalid("Visualization settings require a Ras root element.")
        }
        let mapContainers = root.elements(forName: "Maps")
        guard mapContainers.count == 1 else {
            throw ProjectFileError.invalid("The visualization file has an ambiguous Maps section.")
        }
        let maps = mapContainers[0].elements(forName: "Map")
        guard identity.mapIndex < maps.count else { throw ProjectFileError.modifiedExternally }
        let map = maps[identity.mapIndex]
        guard map.attribute(forName: "Name")?.stringValue == identity.mapName,
              map.attribute(forName: "Type")?.stringValue == identity.mapType else {
            throw ProjectFileError.modifiedExternally
        }
        let trees = map.elements(forName: "Tree")
        guard trees.count == 1, trees[0].elements(forName: "Nodes").count == 1 else {
            throw ProjectFileError.invalid("The selected map has an ambiguous tree structure.")
        }
        var parent = trees[0].elements(forName: "Nodes")[0]
        let rootIndex = identity.geometryNodePath[0]
        let roots = parent.elements(forName: "Node")
        guard rootIndex < roots.count,
              roots[rootIndex].attribute(forName: "Type")?.stringValue == "Root",
              roots[rootIndex].attribute(forName: "Name")?.stringValue == identity.rootName else {
            throw ProjectFileError.modifiedExternally
        }
        var geometryNode: XMLElement?
        for index in identity.geometryNodePath {
            let children = parent.elements(forName: "Node")
            guard index < children.count else { throw ProjectFileError.modifiedExternally }
            geometryNode = children[index]
            parent = children[index]
        }
        guard let geometryNode,
              geometryNode.attribute(forName: "Type")?.stringValue == "Geometry",
              geometryNode.attribute(forName: "Name")?.stringValue == identity.geometryName else {
            throw ProjectFileError.modifiedExternally
        }
        var sameNameGeometry: [(node: XMLElement, path: [Int], rootName: String)] = []
        for (index, rootNode) in roots.enumerated() where rootNode.attribute(forName: "Type")?.stringValue == "Root" {
            guard let name = rootNode.attribute(forName: "Name")?.stringValue else { continue }
            collectSpecializedGeometryNodes(rootNode, path: [index], geometryName: identity.geometryName,
                rootName: name, into: &sameNameGeometry)
        }
        guard sameNameGeometry.count == 1,
              sameNameGeometry[0].path == identity.geometryNodePath,
              sameNameGeometry[0].rootName == identity.rootName else {
            throw ProjectFileError.invalid("The selected Geometry name is ambiguous in this map.")
        }
        let ownerNodes = geometryNode.elements(forName: "Node")
        let sameTypeNodes = ownerNodes.filter { $0.attribute(forName: "Type")?.stringValue == identity.nodeType }
        guard sameTypeNodes.count == 1 else {
            throw ProjectFileError.invalid("The selected Geometry has an ambiguous specialized style owner.")
        }
        let childIndex = identity.nodePath[identity.nodePath.count - 1]
        guard childIndex < ownerNodes.count else { throw ProjectFileError.modifiedExternally }
        let child = ownerNodes[childIndex]
        guard sameTypeNodes.first === child,
              child.attribute(forName: "Type")?.stringValue == identity.nodeType,
              child.attribute(forName: "Name")?.stringValue == identity.nodeName else {
            throw ProjectFileError.modifiedExternally
        }
        return (child, definitionIDs)
    }

    static func canonicalVectorPath(_ raw: String) -> String {
        URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func persistedAttributes(for type: String) -> [String]? {
        switch type {
        case "Line": ["PenColor", "PenWidth"]
        case "Polygon": ["PenColor", "PenWidth", "FillColor"]
        case "Point": ["PenColor", "PenWidth", "FillColor", "PointSize"]
        default: nil
        }
    }

    static func readVectorStyleAttributes(from node: XMLElement, type: String,
        into values: inout VectorStyleValues) throws {
        guard let attributes = persistedAttributes(for: type) else {
            throw ProjectFileError.invalid("Vector text styles are not persisted by the generic MapLayer contexts.")
        }
        for name in attributes {
            guard let raw = node.attribute(forName: name)?.stringValue else { continue }
            switch name {
            case "PenColor": values.penColor = raw
            case "PenWidth":
                guard let value = Double(raw), value.isFinite else { throw ProjectFileError.invalid("A vector style has an invalid PenWidth.") }
                values.penWidth = value
            case "FillColor": values.fillColor = raw
            case "PointSize":
                guard let value = Int(raw) else { throw ProjectFileError.invalid("A vector style has an invalid PointSize.") }
                values.pointSize = value
            default: break
            }
        }
    }

    static func readVectorConditionGroups(from node: XMLElement?) throws -> [VectorVisualConditionGroup] {
        try vectorConditionNames.map { entry in
            let field = entry.0
            let name = entry.1
            guard let node else { return VectorVisualConditionGroup(field: field) }
            let groups = node.elements(forName: name)
            guard groups.count <= 1 else { throw ProjectFileError.invalid("Vector condition group \(name) is ambiguous.") }
            let rules = (groups.first?.elements(forName: "Condition") ?? []).map { condition in
                let sourceOperator = condition.attribute(forName: "Operator")?.stringValue ?? "Equal"
                return VectorStyleRule(
                    column: condition.attribute(forName: "Column")?.stringValue ?? "",
                    comparison: canonicalVectorConditionOperator(sourceOperator),
                    threshold: condition.attribute(forName: "Threshold")?.stringValue ?? "",
                    resultValue: condition.attribute(forName: "Result")?.stringValue ?? ""
                )
            }
            return VectorVisualConditionGroup(field: field, rules: rules)
        }
    }

    static func validateVectorConditionGroups(_ groups: [VectorVisualConditionGroup]) throws {
        guard groups.map(\.field) == VectorStyleField.allCases else {
            throw ProjectFileError.invalid("Vector condition groups must contain the four source fields in order.")
        }
    }

    static func vectorOptionsEqualForPersistence(_ lhs: VectorVisualSettingsOptions,
        _ rhs: VectorVisualSettingsOptions, type: String) -> Bool {
        guard let attributes = persistedAttributes(for: type),
              vectorValuesEqual(lhs.values, rhs.values, attributes: attributes),
              lhs.conditionGroups.count == rhs.conditionGroups.count else { return false }
        return zip(lhs.conditionGroups, rhs.conditionGroups).allSatisfy { pair in
            pair.0.field == pair.1.field && pair.0.rules.map(ruleSignature) == pair.1.rules.map(ruleSignature)
        }
    }

    static func vectorValuesEqual(_ lhs: VectorStyleValues, _ rhs: VectorStyleValues,
        attributes: [String]) -> Bool {
        attributes.allSatisfy { name in
            switch name {
            case "PenColor": lhs.penColor.caseInsensitiveCompare(rhs.penColor) == .orderedSame
            case "PenWidth": lhs.penWidth == rhs.penWidth
            case "FillColor": lhs.fillColor.caseInsensitiveCompare(rhs.fillColor) == .orderedSame
            case "PointSize": lhs.pointSize == rhs.pointSize
            default: true
            }
        }
    }

    static func ruleSignature(_ rule: VectorStyleRule) -> [String] {
        [rule.column, rule.comparison, rule.threshold, rule.resultValue]
    }

    static func writeVectorStyle(_ option: VectorVisualSettingsOptions,
        defaultValues: VectorStyleValues, definition: VectorStyleDefinition, id: String,
        to layer: XMLElement) throws {
        guard let attributes = persistedAttributes(for: definition.type) else {
            throw ProjectFileError.invalid("Vector text styles are not persisted by the generic MapLayer contexts.")
        }
        let matches = layer.elements(forName: "Symbology").filter { $0.attribute(forName: "ID")?.stringValue == id }
        guard matches.count <= 1 else { throw ProjectFileError.invalid("Vector style \(id) has ambiguous definitions.") }
        let existing = matches.first
        guard let defaultNodeValues = defaultValues.validatedForPersistence(),
              let optionValues = option.values.validatedForPersistence() else {
            throw ProjectFileError.invalid("Vector style \(id) contains malformed colors or non-finite measurements.")
        }
        let hasRules = option.conditionGroups.contains { !$0.rules.isEmpty }
        let hasUnknownAttributes = existing?.attributes?.contains(where: {
            !["ID"].contains($0.name ?? "") && !attributes.contains($0.name ?? "")
        }) ?? false
        let existingElements = existing?.children?.compactMap { $0 as? XMLElement } ?? []
        let hasUnknownChildren = existingElements.contains { child in
            !vectorConditionNames.contains(where: { entry in entry.1 == child.name })
        }
        let isDefault = vectorValuesEqual(optionValues, defaultNodeValues, attributes: attributes)
        if existing == nil && isDefault && !hasRules { return }
        let node: XMLElement
        if let existing { node = existing }
        else {
            node = XMLElement(name: "Symbology")
            node.addAttribute(XMLNode.attribute(withName: "ID", stringValue: id) as! XMLNode)
            layer.addChild(node)
        }
        for name in attributes {
            if isDefault {
                node.removeAttribute(forName: name)
                continue
            }
            let value = vectorAttributeValue(name, values: optionValues)
            if let attribute = node.attribute(forName: name) {
                attribute.stringValue = value
            } else {
                node.addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode)
            }
        }
        for group in option.conditionGroups {
            guard let name = vectorConditionNames.first(where: { $0.0 == group.field })?.1 else { continue }
            try replaceVectorConditionGroup(name, rules: group.rules, in: node)
        }
        if isDefault && !hasRules && !hasUnknownAttributes && !hasUnknownChildren,
           (node.attributes ?? []).allSatisfy({ ["ID"].contains($0.name ?? "") }),
           (node.children ?? []).allSatisfy({ $0.kind == .text && ($0.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            node.detach()
        }
    }

    static func replaceVectorConditionGroup(_ name: String, rules: [VectorStyleRule],
        in node: XMLElement) throws {
        let matches = node.elements(forName: name)
        guard matches.count <= 1 else { throw ProjectFileError.invalid("Vector condition group \(name) is ambiguous.") }
        guard let group = matches.first else {
            guard !rules.isEmpty else { return }
            let created = XMLElement(name: name)
            node.addChild(created)
            for rule in rules { created.addChild(conditionElement(for: rule)) }
            return
        }
        let existingConditions = group.elements(forName: "Condition")
        for (index, rule) in rules.enumerated() {
            if index < existingConditions.count {
                setCondition(rule, on: existingConditions[index])
            } else {
                group.addChild(conditionElement(for: rule))
            }
        }
        if existingConditions.count > rules.count {
            for extra in existingConditions.dropFirst(rules.count) { extra.detach() }
        }
        let unknownContent = (group.attributes ?? []).isEmpty == false
            || (group.children ?? []).contains(where: { child in
                if let element = child as? XMLElement { return element.name != "Condition" }
                if child.kind == .text { return !((child.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                return true
            })
        if rules.isEmpty && !unknownContent { group.detach() }
    }

    static func conditionElement(for rule: VectorStyleRule) -> XMLElement {
        let element = XMLElement(name: "Condition")
        setCondition(rule, on: element)
        return element
    }

    static func setCondition(_ rule: VectorStyleRule, on element: XMLElement) {
        for (name, value) in [("Column", rule.column), ("Operator", sourceVectorConditionOperator(rule.comparison)),
                              ("Threshold", rule.threshold), ("Result", rule.resultValue)] {
            if let attribute = element.attribute(forName: name) { attribute.stringValue = value }
            else { element.addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode) }
        }
    }

    static func vectorAttributeValue(_ name: String, values: VectorStyleValues) -> String {
        switch name {
        case "PenColor": values.penColor.uppercased()
        case "PenWidth": String(values.penWidth)
        case "FillColor": values.fillColor.uppercased()
        case "PointSize": String(values.pointSize)
        default: ""
        }
    }

    static func vectorAttributeEqual(_ name: String, _ first: String, _ second: String) -> Bool {
        switch name {
        case "PenColor", "FillColor": first.caseInsensitiveCompare(second) == .orderedSame
        case "PenWidth": Double(first) == Double(second)
        case "PointSize": Int(first) == Int(second)
        default: first == second
        }
    }

    /// The retained UI binds operators as tokens such as `==` while the .vis
    /// XML stores ConditionOperator enum names such as `Equal`. Unknown values
    /// remain verbatim so loading and saving a future source operator is safe.
    static func canonicalVectorConditionOperator(_ source: String) -> String {
        switch source.lowercased() {
        case "equal": "=="
        case "notequal": "!="
        case "greaterthan": ">"
        case "greaterthanorequal": ">="
        case "lessthan": "<"
        case "lessthanorequal": "<="
        case "stringequals": "equals"
        case "stringnotequals": "not equals"
        case "stringcontains": "contains"
        case "stringstartswith": "starts with"
        case "stringendswith": "ends with"
        default: source
        }
    }

    static func sourceVectorConditionOperator(_ presentation: String) -> String {
        switch presentation.lowercased() {
        case "==": "Equal"
        case "!=": "NotEqual"
        case ">": "GreaterThan"
        case ">=": "GreaterThanOrEqual"
        case "<": "LessThan"
        case "<=": "LessThanOrEqual"
        case "equals": "StringEquals"
        case "not equals": "StringNotEquals"
        case "contains": "StringContains"
        case "starts with": "StringStartsWith"
        case "ends with": "StringEndsWith"
        default: presentation
        }
    }
}
