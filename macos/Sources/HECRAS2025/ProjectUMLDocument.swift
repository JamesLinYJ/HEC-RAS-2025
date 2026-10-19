import CryptoKit
import Foundation
import RASWorkspaceCore
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A live model's graph position. `id` is the project asset identity used by
/// SwiftUI; `sourceID` is the exact ProjectUML.cs filename-plus-suffix value
/// persisted in the original `.vis` schema.
struct ProjectUMLPosition: Identifiable, Hashable, Sendable {
    let id: String
    let sourceID: String
    let left: Double
    let top: Double
}

struct ProjectUMLSavedPosition: Hashable, Sendable {
    let sourceID: String
    let left: Double
    let top: Double
}

struct ProjectUMLAssociationCandidate: Hashable, Sendable {
    let nodeID: String
    let projectName: String
    let kind: String
}

enum ProjectUMLAssociationResolution: Equatable, Sendable {
    case missing
    case ambiguous(matches: Int)
    case resolved(nodeID: String)
}

/// Resolves the project association value against a source type and project
/// name, returning the actual node identity only when the match is unique.
enum ProjectUMLAssociationIdentity {
    static func resolve(named projectName: String, kind: String,
                        among candidates: [ProjectUMLAssociationCandidate]) -> ProjectUMLAssociationResolution {
        let matches = candidates.filter { $0.kind == kind && $0.projectName == projectName }
        guard !matches.isEmpty else { return .missing }
        guard matches.count == 1, let match = matches.first else { return .ambiguous(matches: matches.count) }
        return .resolved(nodeID: match.nodeID)
    }
}

enum ProjectUMLVisualizationFile {
    static func loadPositions(projectURL: URL) throws -> [ProjectUMLSavedPosition] {
        let url = visualizationURL(for: projectURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let bytes = try Data(contentsOf: url)
        let document = try parse(bytes)
        guard let root = document.rootElement(), root.name == "Ras" else {
            throw ProjectFileError.invalid("Visualization settings require a Ras root element.")
        }
        let umlSections = root.elements(forName: "UML")
        guard umlSections.count <= 1 else {
            throw ProjectFileError.invalid("Visualization settings contain more than one Project UML section.")
        }
        guard let uml = umlSections.first else { return [] }
        let nodeSections = uml.elements(forName: "Nodes")
        guard nodeSections.count <= 1 else {
            throw ProjectFileError.invalid("Project UML contains more than one Nodes section.")
        }
        guard let nodes = nodeSections.first else { return [] }

        let positions = try nodes.elements(forName: "Node").map { node in
            guard let sourceID = node.attribute(forName: "ID")?.stringValue, !sourceID.isEmpty,
                  let leftText = node.attribute(forName: "Left")?.stringValue,
                  let topText = node.attribute(forName: "Top")?.stringValue else {
                throw ProjectFileError.invalid("A Project UML node is missing its source ID or saved position.")
            }
            // UMLDiagram.LoadXML defaults malformed numeric text to zero.
            let left = Double(leftText).flatMap { $0.isFinite ? $0 : nil } ?? 0
            let top = Double(topText).flatMap { $0.isFinite ? $0 : nil } ?? 0
            return ProjectUMLSavedPosition(sourceID: sourceID, left: max(0, left), top: max(0, top))
        }
        let sourceIDs = positions.map(\.sourceID)
        guard Set(sourceIDs).count == sourceIDs.count else {
            throw ProjectFileError.invalid("Project UML contains duplicate serialized node IDs; saved positions cannot be matched safely.")
        }
        return positions
    }

    /// Writes only Ras/UML/Nodes. Existing XML is parsed with nodePreserveAll,
    /// and unrelated `.vis` nodes stay in place so map/view drafts and unknown
    /// source XML survive a position save.
    @discardableResult
    static func savePositions(projectURL: URL, positions: [ProjectUMLPosition],
                              expectedPreviousRevision: String?) throws -> String {
        try validate(positions)
        let url = visualizationURL(for: projectURL)
        let previousBytes: Data?
        if FileManager.default.fileExists(atPath: url.path) {
            let bytes = try Data(contentsOf: url)
            guard revision(of: bytes).caseInsensitiveCompare(expectedPreviousRevision ?? "") == .orderedSame else {
                throw ProjectFileError.modifiedExternally
            }
            previousBytes = bytes
        } else {
            guard expectedPreviousRevision == nil else { throw ProjectFileError.modifiedExternally }
            previousBytes = nil
        }

        let document: XMLDocument
        if let previousBytes {
            document = try parse(previousBytes)
        } else {
            let created = XMLDocument(rootElement: XMLElement(name: "Ras"))
            created.characterEncoding = "UTF-8"
            document = created
        }
        guard let root = document.rootElement(), root.name == "Ras" else {
            throw ProjectFileError.invalid("Visualization settings require a Ras root element.")
        }
        let umlSections = root.elements(forName: "UML")
        guard umlSections.count <= 1 else {
            throw ProjectFileError.invalid("Visualization settings contain more than one Project UML section.")
        }
        let uml: XMLElement
        if let existing = umlSections.first {
            uml = existing
        } else {
            uml = XMLElement(name: "UML")
            root.addChild(uml)
        }
        let nodeSections = uml.elements(forName: "Nodes")
        guard nodeSections.count <= 1 else {
            throw ProjectFileError.invalid("Project UML contains more than one Nodes section.")
        }
        let nodes: XMLElement
        if let existing = nodeSections.first {
            nodes = existing
        } else {
            nodes = XMLElement(name: "Nodes")
            uml.addChild(nodes)
        }

        // The source format persists only IDs, not asset paths. Repeated IDs
        // cannot safely identify a model, so reject them instead of matching
        // the first occurrence or guessing from display names.
        var existingBySourceID: [String: XMLElement] = [:]
        for element in nodes.elements(forName: "Node") {
            guard let sourceID = element.attribute(forName: "ID")?.stringValue, !sourceID.isEmpty else {
                throw ProjectFileError.invalid("A saved Project UML node is missing its source ID.")
            }
            guard existingBySourceID.updateValue(element, forKey: sourceID) == nil else {
                throw ProjectFileError.invalid("Project UML contains duplicate serialized node IDs; saved positions cannot be matched safely.")
            }
        }
        var retainedSourceIDs = Set<String>()
        for position in positions {
            let element: XMLElement
            if let existing = existingBySourceID[position.sourceID] {
                element = existing
            } else {
                element = XMLElement(name: "Node")
                setAttribute("ID", value: position.sourceID, on: element)
                nodes.addChild(element)
            }
            setAttribute("Left", value: number(position.left), on: element)
            setAttribute("Top", value: number(position.top), on: element)
            retainedSourceIDs.insert(position.sourceID)
        }

        // Update existing nodes in place within the existing UML section.
        // Remove only nodes whose models are no longer present; comments and
        // unknown child elements retain their original position.
        for (sourceID, element) in existingBySourceID where !retainedSourceIDs.contains(sourceID) {
            element.detach()
        }

        let updated = document.xmlData(options: [.nodePreserveAll])
        try updated.write(to: url, options: .atomic)
        return revision(of: updated)
    }

    private static func validate(_ positions: [ProjectUMLPosition]) throws {
        var identityIDs = Set<String>()
        var sourceIDs = Set<String>()
        for position in positions {
            guard !position.id.isEmpty, !position.sourceID.isEmpty,
                  position.left.isFinite, position.top.isFinite,
                  position.left >= 0, position.top >= 0,
                  identityIDs.insert(position.id).inserted else {
                throw ProjectFileError.invalid("Project UML positions require unique model identities and finite nonnegative coordinates.")
            }
            guard sourceIDs.insert(position.sourceID).inserted else {
                throw ProjectFileError.invalid("Project UML model IDs are ambiguous; saved positions cannot be matched safely.")
            }
        }
    }

    private static func parse(_ bytes: Data) throws -> XMLDocument {
        guard let text = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .utf16),
              !text.replacingOccurrences(of: "\0", with: "").localizedCaseInsensitiveContains("<!DOCTYPE"),
              !text.replacingOccurrences(of: "\0", with: "").localizedCaseInsensitiveContains("<!ENTITY") else {
            throw ProjectFileError.invalid("Visualization settings must be XML without entity declarations.")
        }
        return try XMLDocument(data: bytes, options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
    }

    private static func setAttribute(_ name: String, value: String, on element: XMLElement) {
        if let attribute = element.attribute(forName: name) {
            attribute.stringValue = value
        } else {
            element.addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode)
        }
    }

    private static func visualizationURL(for projectURL: URL) -> URL {
        projectURL.deletingPathExtension().appendingPathExtension("vis")
    }

    private static func number(_ value: Double) -> String {
        String(value)
    }

    private static func revision(of bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02X", $0) }.joined()
    }
}
