import Foundation
import CryptoKit
#if canImport(FoundationXML)
import FoundationXML
#endif

// UI document and project-browser adapter against the RENAMED Project.cs,
// ProjectionDefinition.cs, and ProjectTreeModeVM.cs. No solver implementation.
public enum ProjectSection: String, CaseIterable, Codable, Identifiable, Sendable {
    case plans = "Plans"
    case results = "Results"
    case geometries = "Geometries"
    case terrains = "Terrains"
    case surfaceLayers = "Surface Layers"
    case mapLayers = "Map Layers"
    case features = "Features"
    case boundaryConditions = "Boundary Conditions"

    public var id: String { rawValue }
    public var symbol: String {
        switch self {
        case .plans: "list.bullet.rectangle"
        case .results: "chart.xyaxis.line"
        case .geometries: "point.3.connected.trianglepath.dotted"
        case .terrains: "mountain.2"
        case .surfaceLayers: "square.3.layers.3d"
        case .mapLayers: "map"
        case .features: "point.topleft.down.to.point.bottomright.curvepath"
        case .boundaryConditions: "water.waves"
        }
    }
}

public struct ProjectAsset: Identifiable, Hashable, Sendable {
    public let url: URL
    public let section: ProjectSection
    // Freeze identity while the entry exists. Foundation path standardization
    // can resolve /var differently after the file is moved to Trash; selection
    // and editor dictionaries must keep the original key during cleanup.
    public let id: String
    public var name: String { url.deletingPathExtension().lastPathComponent }
    // The project browser also lists backing rasters and vectors. Retained
    // model collections load HDF files; those inputs are not model choices.
    public var isModelFile: Bool {
        [.plans, .results, .geometries, .terrains, .surfaceLayers, .boundaryConditions].contains(section)
            && url.pathExtension.lowercased() == "h5"
    }
    public init(url: URL, section: ProjectSection) {
        self.url = url; self.section = section; self.id = url.standardizedFileURL.path
    }
}

public struct ProjectAssociation: Identifiable, Equatable, Sendable {
    public let group: String
    public let element: String
    public let primaryKey: String
    public let name: String
    public let fields: [String: String]
    public var id: String { group + "/" + name }
    public init(group: String, element: String, primaryKey: String, name: String, fields: [String: String]) {
        self.group = group; self.element = element; self.primaryKey = primaryKey; self.name = name; self.fields = fields
    }
}

public struct ProjectConnection: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let type: String
    public let relativePath: String
    public let absolutePath: String
    public let searchPattern: String
    public let recurse: Bool
    public let description: String
    public init(id: String, name: String, type: String, relativePath: String, absolutePath: String, searchPattern: String = "", recurse: Bool = false, description: String = "") {
        self.id = id; self.name = name; self.type = type; self.relativePath = relativePath; self.absolutePath = absolutePath
        self.searchPattern = searchPattern; self.recurse = recurse; self.description = description
    }
    public func resolve(relativeTo directory: URL, mappings: [PathMapping]) throws -> URL {
        guard ["File", "Directory", "FileSystem"].contains(type) else {
            throw ProjectFileError.invalid("The connection \(name) is not a local filesystem connection.")
        }
        func exists(_ url: URL) -> Bool {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
            return type == "Directory" ? isDirectory.boolValue : !isDirectory.boolValue
        }
        if !relativePath.isEmpty, let relative = try? PlatformPaths.resolve(relativePath, relativeTo: directory), exists(relative) { return relative }
        let absolute = try PlatformPaths.resolve(absolutePath, relativeTo: directory, mappings: mappings)
        guard exists(absolute) else { throw ProjectFileError.invalid("The file for connection \(name) was not found at \(absolute.path).") }
        return absolute
    }
    public func files(relativeTo directory: URL, mappings: [PathMapping]) throws -> [URL] {
        let location = try resolve(relativeTo: directory, mappings: mappings)
        if type != "Directory" { return [location] }
        let pattern = searchPattern.isEmpty ? "*" : searchPattern
        guard !pattern.contains("/"), !pattern.contains("\\") else { throw ProjectFileError.invalid("Enter a filename pattern without path separators.") }
        let regexText = "^" + pattern.map { character in
            character == "*" ? ".*" : character == "?" ? "." : NSRegularExpression.escapedPattern(for: String(character))
        }.joined() + "$"
        let regex = try NSRegularExpression(pattern: regexText, options: [.caseInsensitive])
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        var candidates: [URL] = []
        if recurse {
            var failure: Error?
            guard let enumerator = FileManager.default.enumerator(at: location, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in failure = error; return false }) else { throw CocoaError(.fileReadUnknown) }
            while let file = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                let values = try file.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true { enumerator.skipDescendants() }
                if try PlatformPaths.isRegularSourceFile(file) { candidates.append(file) }
            }
            if let failure { throw failure }
        } else { candidates = try FileManager.default.contentsOfDirectory(at: location, includingPropertiesForKeys: Array(keys)) }
        return try candidates.filter { file in
            try Task.checkCancellation()
            let filename = file.lastPathComponent
            return try PlatformPaths.isRegularSourceFile(file)
                && regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)) != nil
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

public enum ProjectFileError: LocalizedError {
    case invalid(String)
    case modifiedExternally
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .modifiedExternally: "This project changed on disk. Reload it before saving to avoid overwriting those changes."
        }
    }
}

public final class ProjectDocument {
    public private(set) var url: URL?
    public private(set) var assets: [ProjectAsset] = []
    private let xml: XMLDocument
    private var savedBytes: Data?
    public var sourceRevision: String? {
        savedBytes.map { SHA256.hash(data: $0).map { String(format: "%02X", $0) }.joined() }
    }
    // Runtime identity follows the source XML object, never its changing list index.
    private var connectionIdentities: [ObjectIdentifier: String] = [:]
    public var name: String { url?.deletingPathExtension().lastPathComponent ?? unsavedName }
    private var unsavedName: String

    public var description: String {
        get { root.elements(forName: "Description").first?.stringValue ?? "" }
        set { setText("Description", value: newValue) }
    }
    public var projectionType: String { root.elements(forName: "Projection").first?.attribute(forName: "Type")?.stringValue ?? "" }
    public var projectionValue: String { root.elements(forName: "Projection").first?.stringValue ?? "" }
    public var defaultTerrain: String {
        get { root.elements(forName: "DefaultTerrain").first?.stringValue ?? "" }
        set { setText("DefaultTerrain", value: newValue) }
    }
    public var attributes: [String: String] {
        Dictionary(uniqueKeysWithValues: (root.attributes ?? []).compactMap { item in
            guard let name = item.name else { return nil }; return (name, item.stringValue ?? "")
        })
    }
    public var associations: [ProjectAssociation] {
        [("PlanAssociations", "PlanAssociation", "Plan"),
         ("GeometryAssociations", "GeometryAssociation", "Geometry"),
         ("ResultAssociations", "ResultAssociation", "Result")].flatMap { group, element, primaryKey in
            (root.elements(forName: group).first?.elements(forName: element) ?? []).map { item in
                let fields: [String: String] = Dictionary(uniqueKeysWithValues: (item.attributes ?? []).compactMap { attribute in
                    guard let key = attribute.name else { return nil }; return (key, attribute.stringValue ?? "")
                })
                return ProjectAssociation(group: group, element: element, primaryKey: primaryKey,
                    name: fields[primaryKey] ?? "", fields: fields)
            }
        }
    }
    public var connectionXML: String { root.elements(forName: "Connections").first?.xmlString ?? "" }
    public var editorXML: String { xml.xmlString(options: [.nodePrettyPrint]) }
    public func editorXML(overridingDescription description: String) -> String {
        let snapshot = xml.copy() as! XMLDocument
        let element = snapshot.rootElement()!
        if let existing = element.elements(forName: "Description").first { existing.stringValue = description }
        else { element.addChild(XMLElement(name: "Description", stringValue: description)) }
        return snapshot.xmlString(options: [.nodePrettyPrint])
    }
    public func associationRows(group: String) -> [ProjectAssociation] {
        var rows = associations.filter { $0.group == group }
        let section: ProjectSection
        let element: String
        let primaryKey: String
        switch group {
        case "PlanAssociations": section = .plans; element = "PlanAssociation"; primaryKey = "Plan"
        case "GeometryAssociations": section = .geometries; element = "GeometryAssociation"; primaryKey = "Geometry"
        case "ResultAssociations": section = .results; element = "ResultAssociation"; primaryKey = "Result"
        default: return rows
        }
        for asset in assets where asset.section == section && asset.isModelFile && !rows.contains(where: { $0.name == asset.name }) {
            // The original CreateNew association has empty names. Displaying
            // that row does not create XML until the user edits an association.
            rows.append(ProjectAssociation(group: group, element: element, primaryKey: primaryKey, name: asset.name, fields: [primaryKey: asset.name]))
        }
        return rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public var connections: [ProjectConnection] {
        (root.elements(forName: "Connections").first?.elements(forName: "Connection") ?? []).enumerated().map { index, node in
            let source = node.elements(forName: "Source").first ?? node
            let storedType = node.attribute(forName: "Type")?.stringValue ?? source.attribute(forName: "Type")?.stringValue ?? "File"
            let type = storedType == "FileSystem" ? source.attribute(forName: "Target")?.stringValue ?? "File" : storedType
            return ProjectConnection(id: connectionID(node), name: node.attribute(forName: "Name")?.stringValue ?? "Connection \(index + 1)", type: type,
                relativePath: source.elements(forName: "RelativePath").first?.stringValue ?? "",
                absolutePath: source.elements(forName: "AbsolutePath").first?.stringValue ?? "",
                searchPattern: source.elements(forName: "SearchPattern").first?.stringValue ?? "",
                recurse: source.elements(forName: "Recurse").first?.stringValue?.lowercased() == "true",
                description: node.elements(forName: "Description").first?.stringValue ?? "")
        }
    }
    public var directory: URL? { url?.deletingLastPathComponent() }
    private var root: XMLElement { xml.rootElement()! }

    // Build an exclusively owned document off the caller's actor. `sending`
    // transfers its XML tree to the workspace; the mutable tree is never shared.
    @concurrent
    public static func open(contentsOf input: URL) async throws -> sending ProjectDocument {
        try Task.checkCancellation()
        let document = try ProjectDocument(contentsOf: input)
        try Task.checkCancellation()
        return document
    }

    public init(contentsOf input: URL) throws {
        let resolved = try Self.projectURL(in: input)
        let bytes = try Data(contentsOf: resolved)
        let decoded = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .utf16)
        guard let text = decoded,
              !text.replacingOccurrences(of: "\0", with: "").localizedCaseInsensitiveContains("<!DOCTYPE"),
              !text.replacingOccurrences(of: "\0", with: "").localizedCaseInsensitiveContains("<!ENTITY") else {
            throw ProjectFileError.invalid("Projects must be valid XML without external entity declarations.")
        }
        xml = try XMLDocument(data: bytes, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
        guard xml.rootElement()?.name == "Project" else {
            throw ProjectFileError.invalid("The selected file does not contain a HEC-RAS 2025 Project element.")
        }
        url = resolved; savedBytes = bytes
        unsavedName = resolved.deletingPathExtension().lastPathComponent
        try reloadAssets()
    }

    public init(name: String, units: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else {
            throw ProjectFileError.invalid("Enter a project name without path separators.")
        }
        guard units == "SI" || units == "USC" else { throw ProjectFileError.invalid("Select SI or US customary units.") }
        unsavedName = name
        let project = XMLElement(name: "Project")
        let projection = XMLElement(name: "Projection", stringValue: units)
        projection.addAttribute(XMLNode.attribute(withName: "Type", stringValue: "Local") as! XMLNode)
        project.addChild(projection)
        xml = XMLDocument(rootElement: project)
        xml.characterEncoding = "UTF-8"
    }

    public func setProjection(type: String, value: String) throws {
        guard ["Local", "EPSG", "Proj", "ESRI", "WKT"].contains(type) else {
            throw ProjectFileError.invalid("Unknown projection definition type.")
        }
        if type == "Local", !["SI", "USC"].contains(value) {
            throw ProjectFileError.invalid("Local coordinate systems must use SI or USC units.")
        }
        if type == "EPSG", Int(value).map({ $0 > 0 }) != true {
            throw ProjectFileError.invalid("Enter a positive EPSG code.")
        }
        let node = ensureElement("Projection", parent: root)
        setAttribute("Type", value: type, on: node); node.stringValue = value
    }

    public func setAssociation(_ association: ProjectAssociation, field: String, value: String) throws {
        let allowed: [String: Set<String>] = [
            "PlanAssociations": ["Geometry", "BoundaryCondition"],
            "GeometryAssociations": ["Terrain", "N_Values"],
            "ResultAssociations": ["OverrideTerrain"]
        ]
        guard allowed[association.group]?.contains(field) == true else {
            throw ProjectFileError.invalid("This association field is not editable.")
        }
        let group = ensureElement(association.group, parent: root)
        let node = group.elements(forName: association.element).first {
            $0.attribute(forName: association.primaryKey)?.stringValue == association.name
        } ?? {
            let newNode = XMLElement(name: association.element)
            setAttribute(association.primaryKey, value: association.name, on: newNode)
            group.addChild(newNode); return newNode
        }()
        setAttribute(field, value: value, on: node)
    }

    public func prepareModelMetadataMutations(_ mutations: [ProjectModelMetadataMutation]) throws -> PreparedProjectModelMetadataChange {
        let schemas: [String: (row: String, identity: String, attributes: Set<String>)] = [
            "PlanAssociations": ("PlanAssociation", "Plan", ["Plan", "Geometry", "BoundaryCondition"]),
            "GeometryAssociations": ("GeometryAssociation", "Geometry", ["Geometry", "Terrain", "N_Values"]),
            "ResultAssociations": ("ResultAssociation", "Result", ["Result", "OverrideTerrain"])
        ]
        let baseline = editorXML
        var changes: [(node: XMLElement, mutation: ProjectModelMetadataMutation)] = []
        var removed: [(node: XMLElement, parent: XMLElement, index: Int)] = []
        var createdGroups: [XMLElement] = []
        var createdRows: [(node: XMLElement, parent: XMLElement)] = []
        var plannedGroups: [String: XMLElement] = [:]
        var plannedRows: [String: XMLElement] = [:]
        var touched: Set<String> = []
        for mutation in mutations {
            if mutation.section == "Project" {
                guard mutation.rowName == "DefaultTerrain", mutation.identityAttribute.isEmpty,
                      mutation.identityValue.isEmpty, mutation.attribute == "#text", !mutation.removeRow,
                      mutation.newValue != nil, touched.insert("Project/DefaultTerrain").inserted else {
                    throw ProjectFileError.invalid("The default terrain changed before the action could be applied.")
                }
                let nodes = root.elements(forName: "DefaultTerrain")
                guard nodes.count <= 1 else { throw ProjectFileError.modifiedExternally }
                let node = nodes.first ?? XMLElement(name: "DefaultTerrain")
                guard nodes.isEmpty ? mutation.oldValue == nil : node.stringValue == mutation.oldValue else {
                    throw ProjectFileError.modifiedExternally
                }
                if nodes.isEmpty { createdRows.append((node, root)) }
                changes.append((node, mutation)); continue
            }
            guard let schema = schemas[mutation.section], schema.row == mutation.rowName,
                  schema.identity == mutation.identityAttribute,
                  schema.attributes.contains(mutation.attribute), !mutation.identityValue.isEmpty else {
                throw ProjectFileError.invalid("The model action contains an unsupported association change.")
            }
            let group: XMLElement
            if let planned = plannedGroups[mutation.section] { group = planned }
            else {
                let groups = root.elements(forName: mutation.section)
                guard groups.count <= 1 else { throw ProjectFileError.modifiedExternally }
                group = groups.first ?? XMLElement(name: mutation.section)
                if groups.isEmpty { createdGroups.append(group) }
                plannedGroups[mutation.section] = group
            }
            let rowKey = mutation.section + "/" + mutation.identityValue
            let node: XMLElement
            if let planned = plannedRows[rowKey] { node = planned }
            else {
                let candidates = group.elements(forName: mutation.rowName).filter {
                    $0.attribute(forName: mutation.identityAttribute)?.stringValue == mutation.identityValue
                }
                guard candidates.count <= 1 else { throw ProjectFileError.modifiedExternally }
                if let existing = candidates.first { node = existing }
                else {
                    guard !mutation.removeRow, mutation.attribute == schema.identity,
                          mutation.oldValue == nil, mutation.newValue == mutation.identityValue else {
                        throw ProjectFileError.invalid("The model association changed before the action could be applied.")
                    }
                    node = XMLElement(name: mutation.rowName)
                    createdRows.append((node, group))
                }
                plannedRows[rowKey] = node
            }
            guard node.attribute(forName: mutation.attribute)?.stringValue == mutation.oldValue,
                  touched.insert(rowKey + "/" + (mutation.removeRow ? "*" : mutation.attribute)).inserted,
                  !changes.contains(where: { $0.node === node && $0.mutation.removeRow }),
                  !mutation.removeRow || !changes.contains(where: { $0.node === node }) else {
                throw ProjectFileError.invalid("The model action contains conflicting association changes.")
            }
            if mutation.attribute == schema.identity, let newName = mutation.newValue,
               !newName.isEmpty, newName != mutation.identityValue,
               group.elements(forName: mutation.rowName).contains(where: {
                   $0 !== node && $0.attribute(forName: schema.identity)?.stringValue == newName
               }) {
                throw ProjectFileError.invalid("The model action would create ambiguous association rows.")
            }
            if mutation.removeRow {
                guard let index = group.children?.firstIndex(where: { $0 === node }) else { throw ProjectFileError.modifiedExternally }
                removed.append((node, group, index))
            }
            changes.append((node, mutation))
        }
        var seenNodes: Set<ObjectIdentifier> = []
        let attributeSnapshots: [(node: XMLElement, attributes: [XMLNode])] = changes.compactMap { node, _ in
            guard seenNodes.insert(ObjectIdentifier(node)).inserted else { return nil }
            return (node, (node.attributes ?? []).map { $0.copy() as! XMLNode })
        }
        return PreparedProjectModelMetadataChange(validateCurrent: { [weak self] in self?.editorXML == baseline }, apply: { [root] in
            for group in createdGroups { root.addChild(group) }
            for (node, parent) in createdRows { parent.addChild(node) }
            for (node, mutation) in changes {
                if mutation.attribute == "#text" { node.stringValue = mutation.newValue }
                else if mutation.removeRow { node.detach() }
                else if let value = mutation.newValue {
                    if let attribute = node.attribute(forName: mutation.attribute) { attribute.stringValue = value }
                    else { node.addAttribute(XMLNode.attribute(withName: mutation.attribute, stringValue: value) as! XMLNode) }
                } else { node.removeAttribute(forName: mutation.attribute) }
            }
        }, rollback: {
            for (node, mutation) in changes where mutation.attribute == "#text" { node.stringValue = mutation.oldValue }
            for (node, attributes) in attributeSnapshots { node.attributes = attributes.map { $0.copy() as! XMLNode } }
            for (node, parent, index) in removed.sorted(by: { $0.index < $1.index }) {
                parent.insertChild(node, at: min(index, parent.childCount))
            }
            for (node, _) in createdRows { node.detach() }
            for group in createdGroups { group.detach() }
        })
    }

    /// Acknowledge the paired boundary/project commit without replacing the
    /// mutable XML tree. Existing connection identities and newer user drafts
    /// remain owned by their current nodes. No file is written by this method.
    @discardableResult
    public func acceptInitialConditionsCommit(
        expectedSourceRevision: String, capturedDocumentXML: String,
        capturedDraftXML: String, committedProjectXML: String,
        committedProjectRevision: String, connectionName: String
    ) throws -> Bool {
        guard let url, let currentRevision = sourceRevision,
              currentRevision.caseInsensitiveCompare(expectedSourceRevision) == .orderedSame
                || currentRevision.caseInsensitiveCompare(committedProjectRevision) == .orderedSame else {
            throw ProjectFileError.modifiedExternally
        }
        let bytes = Data(committedProjectXML.utf8)
        let revision = SHA256.hash(data: bytes).map { String(format: "%02X", $0) }.joined()
        guard revision.caseInsensitiveCompare(committedProjectRevision) == .orderedSame,
              try Data(contentsOf: url) == bytes else { throw ProjectFileError.modifiedExternally }
        let original = try Self.initialConditionsDocument(capturedDocumentXML)
        let captured = try Self.initialConditionsDocument(capturedDraftXML)
        let committed = try Self.initialConditionsDocument(committedProjectXML)
        guard let capturedRoot = captured.rootElement(), let committedRoot = committed.rootElement(),
              let originalRoot = original.rootElement(), !connectionName.isEmpty,
              capturedRoot.elements(forName: "Connections").count <= 1,
              committedRoot.elements(forName: "Connections").count == 1,
              root.elements(forName: "Connections").count <= 1 else {
            throw ProjectFileError.invalid("The initial conditions project receipt is invalid.")
        }
        let capturedConnections = capturedRoot.elements(forName: "Connections").first
        guard !(capturedConnections?.elements(forName: "Connection") ?? []).contains(where: {
            $0.attribute(forName: "Name")?.stringValue == connectionName
        }) else { throw ProjectFileError.invalid("The initial conditions connection already existed in the captured project.") }
        let committedConnections = committedRoot.elements(forName: "Connections")[0]
        let additions = committedConnections.elements(forName: "Connection").filter {
            $0.attribute(forName: "Name")?.stringValue == connectionName
        }
        guard additions.count == 1 else {
            throw ProjectFileError.invalid("The initial conditions receipt does not identify one new file connection.")
        }
        let addition = additions[0].copy() as! XMLElement
        let source = addition.elements(forName: "Source").first ?? addition
        let storedType = addition.attribute(forName: "Type")?.stringValue
            ?? source.attribute(forName: "Type")?.stringValue
        let target = source.attribute(forName: "Target")?.stringValue
        guard storedType == "File" || storedType == "FileSystem" && target == "File" else {
            throw ProjectFileError.invalid("The initial conditions receipt must contain a file connection.")
        }
        // Verify the whole committed document, including unknown XML and outer
        // comments, against the captured draft with only the new row removed.
        additions[0].detach()
        if capturedConnections == nil {
            guard (committedConnections.attributes ?? []).isEmpty,
                  (committedConnections.children ?? []).allSatisfy({
                      $0.kind == .text && ($0.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }) else {
                throw ProjectFileError.invalid("The initial conditions receipt changed unrelated project metadata.")
            }
            committedConnections.detach()
        }
        guard Self.initialConditionsXMLSignature(committed) == Self.initialConditionsXMLSignature(captured) else {
            throw ProjectFileError.invalid("The initial conditions receipt changed unrelated project metadata.")
        }
        let currentMatches = (root.elements(forName: "Connections").first?.elements(forName: "Connection") ?? []).filter {
            $0.attribute(forName: "Name")?.stringValue == connectionName
        }
        guard currentMatches.count <= 1,
              currentMatches.first.map({ Self.initialConditionsXMLSignature($0) == Self.initialConditionsXMLSignature(addition) }) ?? true else {
            throw ProjectFileError.invalid("A newer project connection conflicts with the committed initial conditions.")
        }
        // These are the only mutations after all receipt/source validation.
        // Merge the captured description only if its live value is still the
        // original value. Newer text remains an unsaved draft.
        let originalDescription = originalRoot.elements(forName: "Description").first?.stringValue ?? ""
        let capturedDescription = capturedRoot.elements(forName: "Description").first?.stringValue ?? ""
        if description == originalDescription { description = capturedDescription }
        if currentMatches.isEmpty { ensureElement("Connections", parent: root).addChild(addition) }
        savedBytes = bytes
        let saved = try Self.initialConditionsDocument(committedProjectXML)
        return Self.initialConditionsXMLSignature(xml) != Self.initialConditionsXMLSignature(saved)
    }

    private static func initialConditionsDocument(_ text: String) throws -> XMLDocument {
        let checked = text.replacingOccurrences(of: "\0", with: "")
        guard !checked.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !checked.localizedCaseInsensitiveContains("<!ENTITY") else {
            throw ProjectFileError.invalid("Projects must be valid XML without external entity declarations.")
        }
        let document = try XMLDocument(xmlString: text, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
        guard document.rootElement()?.name == "Project" else {
            throw ProjectFileError.invalid("The initial conditions receipt does not contain a Project element.")
        }
        return document
    }

    private static func initialConditionsXMLSignature(_ node: XMLNode) -> String {
        func token(_ value: String) -> String { "\(value.utf8.count):\(value)" }
        if let element = node as? XMLElement {
            let attributes = (element.attributes ?? []).map { token($0.name ?? "") + token($0.stringValue ?? "") }.sorted()
            let namespaces = (element.namespaces ?? []).map { token($0.name ?? "") + token($0.stringValue ?? "") }.sorted()
            let children = element.children ?? []
            let hasElements = children.contains { $0.kind == .element }
            let hasMixedText = children.contains {
                $0.kind == .text && !($0.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let meaningful = children.filter {
                !(hasElements && !hasMixedText && $0.kind == .text
                  && ($0.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            return "E" + token(element.name ?? "") + token(attributes.joined()) + token(namespaces.joined())
                + token(meaningful.map(initialConditionsXMLSignature).joined())
        }
        if node.kind == .document {
            return "D" + token((node.children ?? []).filter {
                !($0.kind == .text && ($0.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.map(initialConditionsXMLSignature).joined())
        }
        return "\(node.kind.rawValue)" + token(node.name ?? "") + token(node.stringValue ?? "")
    }

    public func save(to destination: URL? = nil) throws {
        guard let target = destination ?? url else { throw ProjectFileError.invalid("Choose a project location first.") }
        guard target.pathExtension.lowercased() == "ras" else { throw ProjectFileError.invalid("Projects use the .ras extension.") }
        if target == url, let savedBytes, try Data(contentsOf: target) != savedBytes { throw ProjectFileError.modifiedExternally }
        if target != url, FileManager.default.fileExists(atPath: target.path) {
            throw ProjectFileError.invalid("A project already exists at that location. Choose a different filename.")
        }
        let bytes = xml.xmlData(options: [.nodePreserveAll])
        try bytes.write(to: target, options: .atomic)
        url = target; savedBytes = bytes
        try reloadAssets()
    }

    public func reloadAssets() throws {
        guard let directory else { assets = []; return }
        var result: [ProjectAsset] = []
        for section in ProjectSection.allCases {
            let folder = directory.appendingPathComponent(section.rawValue, isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            for file in files where try PlatformPaths.isRegularSourceFile(file) {
                guard ["h5", "s3", "geojson", "json", "tif", "tiff", "shp", "gpkg"].contains(file.pathExtension.lowercased()) else { continue }
                result.append(ProjectAsset(url: file, section: section))
            }
        }
        assets = result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func connectFile(_ file: URL, name customName: String? = nil) throws {
        try connectPath(file, type: "File", name: customName, searchPattern: nil, recurse: false)
    }
    /// A source-service snapshot only. The live connection is added after the
    /// map operation succeeds, so rejected imports cannot mutate the project.
    public func editorXML(connectingFile file: URL, overridingDescription description: String) throws -> String {
        guard let directory else { throw ProjectFileError.invalid("Save the project before adding a file connection.") }
        let snapshot = xml.copy() as! XMLDocument
        let target = snapshot.rootElement()!
        if let existing = target.elements(forName: "Description").first { existing.stringValue = description }
        else { target.addChild(XMLElement(name: "Description", stringValue: description)) }
        appendConnection(file, type: "File", name: nil, searchPattern: nil, recurse: false,
            root: target, directory: directory)
        return snapshot.xmlString(options: [.nodePrettyPrint])
    }
    public func connectDirectory(_ folder: URL, name: String, searchPattern: String = "*", recurse: Bool = false) throws {
        guard !searchPattern.contains("/"), !searchPattern.contains("\\") else { throw ProjectFileError.invalid("Enter a filename pattern without path separators.") }
        try connectPath(folder, type: "Directory", name: name, searchPattern: searchPattern, recurse: recurse)
    }
    private func connectPath(_ file: URL, type: String, name customName: String?, searchPattern: String?, recurse: Bool) throws {
        guard let directory else { throw ProjectFileError.invalid("Save the project before adding a file connection.") }
        appendConnection(file, type: type, name: customName, searchPattern: searchPattern, recurse: recurse,
            root: root, directory: directory)
    }
    private func appendConnection(_ file: URL, type: String, name customName: String?, searchPattern: String?,
                                  recurse: Bool, root: XMLElement, directory: URL) {
        let group = ensureElement("Connections", parent: root)
        let names = Set(group.elements(forName: "Connection").compactMap { $0.attribute(forName: "Name")?.stringValue })
        let baseName = customName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? customName!.trimmingCharacters(in: .whitespacesAndNewlines) : file.deletingPathExtension().lastPathComponent
        var name = baseName; var suffix = 1
        while names.contains(name) { name = baseName + " (\(suffix))"; suffix += 1 }
        let node = XMLElement(name: "Connection")
        setAttribute("Name", value: name, on: node); setAttribute("Type", value: type, on: node)
        let localRoot = directory.standardizedFileURL.path + "/"
        if file.standardizedFileURL.path.hasPrefix(localRoot) {
            node.addChild(XMLElement(name: "RelativePath", stringValue: String(file.standardizedFileURL.path.dropFirst(localRoot.count))))
        }
        node.addChild(XMLElement(name: "AbsolutePath", stringValue: file.standardizedFileURL.path))
        if type == "Directory" {
            if let searchPattern, !searchPattern.isEmpty { node.addChild(XMLElement(name: "SearchPattern", stringValue: searchPattern)) }
            node.addChild(XMLElement(name: "Recurse", stringValue: recurse ? "True" : "False"))
        }
        group.addChild(node)
    }
    public func removeConnection(id: String) throws {
        guard let node = connectionNode(id) else { throw ProjectFileError.invalid("The connection no longer exists.") }
        node.detach()
        connectionIdentities.removeValue(forKey: ObjectIdentifier(node))
    }

    private func connectionID(_ node: XMLElement) -> String {
        let key = ObjectIdentifier(node)
        if let id = connectionIdentities[key] { return id }
        let id = UUID().uuidString; connectionIdentities[key] = id; return id
    }
    private func connectionNode(_ id: String) -> XMLElement? {
        root.elements(forName: "Connections").first?.elements(forName: "Connection").first { connectionID($0) == id }
    }
    public func updateConnection(_ expected: ProjectConnection, target: URL, description: String, searchPattern: String, recurse: Bool) throws {
        guard let current = connections.first(where: { $0.id == expected.id }), current == expected,
              let node = connectionNode(expected.id) else { throw ProjectFileError.invalid("This connection changed. Reopen its details before applying edits.") }
        guard ["File", "Directory", "FileSystem"].contains(current.type) else { throw ProjectFileError.invalid("This connection type cannot be edited as a local file.") }
        try validateConnectionTarget(target, directory: current.type == "Directory")
        guard !searchPattern.contains("/"), !searchPattern.contains("\\") else { throw ProjectFileError.invalid("Enter a filename pattern without path separators.") }
        guard let directory else { throw ProjectFileError.invalid("Save the project before adding a file connection.") }
        let source = node.elements(forName: "Source").first ?? node
        func put(_ key: String, _ value: String, in parent: XMLElement) {
            if let child = parent.elements(forName: key).first { child.stringValue = value }
            else { parent.addChild(XMLElement(name: key, stringValue: value)) }
        }
        let rootPath = directory.standardizedFileURL.path + "/"
        let path = target.standardizedFileURL.path
        put("AbsolutePath", path, in: source)
        put("RelativePath", path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : "", in: source)
        put("Description", description, in: node)
        if current.type == "Directory" { put("SearchPattern", searchPattern, in: source); put("Recurse", recurse ? "True" : "False", in: source) }
    }
    public func renameConnection(_ expected: ProjectConnection, to newName: String) throws {
        guard let current = connections.first(where: { $0.id == expected.id }), current == expected,
              let node = connectionNode(expected.id) else {
            throw ProjectFileError.invalid("This connection changed. Reopen its details before renaming it.")
        }
        guard !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectFileError.invalid("The connection name cannot be blank.")
        }
        guard newName == current.name || !connections.contains(where: { $0.id != expected.id && $0.name == newName }) else {
            throw ProjectFileError.invalid("A connection with this name already exists.")
        }
        guard newName != current.name else { return }
        if let name = node.attribute(forName: "Name") { name.stringValue = newName }
        else { node.addAttribute(XMLNode.attribute(withName: "Name", stringValue: newName) as! XMLNode) }
    }
    public func connectFiles(_ entries: [(name: String, target: URL)]) throws {
        guard directory != nil else { throw ProjectFileError.invalid("Save the project before adding a file connection.") }
        var names = Set(connections.map(\.name))
        for entry in entries {
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, names.insert(name).inserted else { throw ProjectFileError.invalid("Connection names must be unique.") }
            try validateConnectionTarget(entry.target, directory: false)
        }
        for entry in entries { try connectPath(entry.target, type: "File", name: entry.name, searchPattern: nil, recurse: false) }
    }
    private func validateConnectionTarget(_ target: URL, directory: Bool) throws {
        guard target.isFileURL else { throw ProjectFileError.invalid("Choose a local file or folder.") }
        let values = try target.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        guard directory ? values.isDirectory == true : values.isRegularFile == true else { throw ProjectFileError.invalid("Choose a local file or folder.") }
    }

    public func createDirectoryStructure() throws {
        guard let directory else { return }
        for name in ["Geometries", "Plans", "Results", "Boundary Conditions", "Terrains", "Surface Layers", "Hydraulic Design", "Exports", "Downloads"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
        }
    }

    private static func projectURL(in input: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: input.path, isDirectory: &isDirectory) else { throw ProjectFileError.invalid("The selected project no longer exists.") }
        if isDirectory.boolValue {
            let projects = try FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == "ras" }
            guard projects.count == 1 else { throw ProjectFileError.invalid("Choose a folder containing exactly one .ras project.") }
            return projects[0]
        }
        guard input.pathExtension.lowercased() == "ras" else { throw ProjectFileError.invalid("Choose a HEC-RAS 2025 .ras project.") }
        return input
    }
    private func ensureElement(_ name: String, parent: XMLElement) -> XMLElement {
        if let existing = parent.elements(forName: name).first { return existing }
        let element = XMLElement(name: name); parent.addChild(element); return element
    }
    private func setText(_ name: String, value: String) { ensureElement(name, parent: root).stringValue = value }
    private func setAttribute(_ name: String, value: String, on element: XMLElement) {
        if let attribute = element.attribute(forName: name) { attribute.stringValue = value }
        else { element.addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode) }
    }
}
