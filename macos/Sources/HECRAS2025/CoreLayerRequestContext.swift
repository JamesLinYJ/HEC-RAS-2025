import CryptoKit
import Foundation
import RASWorkspaceCore

struct CoreLayerReferenceCapture: Codable, Hashable, Sendable {
    let referenceID: String
    let projectSessionID: String
    let projectPath: String
    let kind: String
    let sourcePath: String
    let canonicalSourcePath: String
    let sourceRevision: String
    let name: String
    var sessionOnly = true
}

struct CoreLayerRequestContext: Codable, Hashable, Sendable {
    let projectSessionID: String
    let projectPath: String
    let projectRevision: String?
    let references: [CoreLayerReferenceCapture]
    let identityToken: String

    static func capture(projectSessionID: UUID, projectURL: URL, projectRevision: String?,
                        references: [CoreLayerReferenceCapture]) -> Self {
        let session = projectSessionID.uuidString
        let path = canonical(projectURL)
        let normalizedReferences = references.sorted { $0.referenceID < $1.referenceID }
        let material = (["core-layer-context-v1", session.lowercased(), path,
            projectRevision?.uppercased() ?? ""] + normalizedReferences.map { reference in
                [reference.referenceID.lowercased(), reference.kind,
                 canonical(URL(fileURLWithPath: reference.canonicalSourcePath)),
                 reference.sourceRevision.uppercased(), reference.name].joined(separator: "\t")
            }).joined(separator: "\n")
        let token = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return Self(projectSessionID: session, projectPath: path,
                    projectRevision: projectRevision, references: normalizedReferences,
                    identityToken: token)
    }

    static func canonical(_ url: URL) -> String {
        SourceFilePaths.canonical(url)
    }

    static func referenceID(projectSessionID: UUID, projectURL: URL, kind: String,
                            sourceURL: URL, sourceRevision: String) -> String {
        let material = [projectSessionID.uuidString.lowercased(), canonical(projectURL), kind,
                        canonical(sourceURL), sourceRevision.uppercased()].joined(separator: "\n")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func revision(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02X", $0) }.joined()
    }
}

@MainActor
final class CoreLayerReferenceRegistry {
    private var sessionID: UUID?
    private var projectPath: String?
    private var references: [String: CoreLayerReferenceCapture] = [:]

    func context(sessionID: UUID, projectURL: URL, projectRevision: String?) -> CoreLayerRequestContext {
        let path = CoreLayerRequestContext.canonical(projectURL)
        if self.sessionID != sessionID || projectPath != path {
            self.sessionID = sessionID
            projectPath = path
            references.removeAll(keepingCapacity: false)
        }
        return .capture(projectSessionID: sessionID, projectURL: projectURL,
            projectRevision: projectRevision, references: Array(references.values))
    }

    func references(sessionID: UUID, projectURL: URL) -> [CoreLayerReferenceCapture] {
        _ = context(sessionID: sessionID, projectURL: projectURL, projectRevision: nil)
        return Array(references.values)
    }

    @discardableResult
    func register(_ reference: CoreLayerReferenceCapture, sessionID: UUID,
                  projectURL: URL) -> Bool {
        let path = CoreLayerRequestContext.canonical(projectURL)
        let sourcePath = CoreLayerRequestContext.canonical(URL(fileURLWithPath: reference.sourcePath))
        guard reference.sessionOnly,
              reference.projectSessionID == sessionID.uuidString,
              reference.projectPath == path,
              reference.canonicalSourcePath == sourcePath else { return false }
        _ = context(sessionID: sessionID, projectURL: projectURL, projectRevision: nil)
        references = references.filter { _, existing in
            CoreLayerRequestContext.canonical(URL(fileURLWithPath: existing.canonicalSourcePath)) != sourcePath
        }
        references[reference.referenceID] = reference
        return true
    }

    @discardableResult
    func rebaseReference(from capturedContext: CoreLayerRequestContext,
                         sessionID: UUID, projectURL: URL, projectRevision: String,
                         sourceURL: URL, sourceRevision: String, name: String) -> Bool {
        let path = CoreLayerRequestContext.canonical(projectURL)
        let sourcePath = CoreLayerRequestContext.canonical(sourceURL)
        let capturedReferences = capturedContext.references.filter {
            CoreLayerRequestContext.canonical(URL(fileURLWithPath: $0.canonicalSourcePath)) == sourcePath
        }
        guard capturedContext.projectSessionID == sessionID.uuidString,
              capturedContext.projectPath == path,
              capturedReferences.count == 1,
              self.sessionID == sessionID, projectPath == path,
              projectRevision.count == 64, projectRevision.allSatisfy({ $0.isHexDigit }),
              sourceRevision.count == 64, sourceRevision.allSatisfy({ $0.isHexDigit }),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let expectedReference = capturedReferences.first,
              let previous = references[expectedReference.referenceID],
              previous == expectedReference else { return false }
        let normalizedRevision = sourceRevision.uppercased()
        let updated = CoreLayerReferenceCapture(
            referenceID: CoreLayerRequestContext.referenceID(projectSessionID: sessionID,
                projectURL: projectURL, kind: previous.kind, sourceURL: sourceURL,
                sourceRevision: normalizedRevision),
            projectSessionID: sessionID.uuidString, projectPath: path, kind: previous.kind,
            sourcePath: previous.sourcePath, canonicalSourcePath: sourcePath,
            sourceRevision: normalizedRevision, name: name, sessionOnly: true)
        references.removeValue(forKey: previous.referenceID)
        references[updated.referenceID] = updated
        return true
    }

    @discardableResult
    func removeExact(_ expected: CoreLayerReferenceCapture,
                     context expectedContext: CoreLayerRequestContext,
                     sessionID: UUID, projectURL: URL, projectRevision: String) -> Bool {
        let path = CoreLayerRequestContext.canonical(projectURL)
        guard self.sessionID == sessionID, projectPath == path,
              expectedContext.projectSessionID == sessionID.uuidString,
              expectedContext.projectPath == path,
              expectedContext.projectRevision?.caseInsensitiveCompare(projectRevision) == .orderedSame,
              context(sessionID: sessionID, projectURL: projectURL,
                  projectRevision: projectRevision) == expectedContext,
              references[expected.referenceID] == expected else { return false }
        references.removeValue(forKey: expected.referenceID)
        return true
    }

    @discardableResult
    func replaceExact(_ expected: CoreLayerReferenceCapture,
                      with replacement: CoreLayerReferenceCapture,
                      context expectedContext: CoreLayerRequestContext,
                      sessionID: UUID, projectURL: URL, projectRevision: String) -> Bool {
        let path = CoreLayerRequestContext.canonical(projectURL)
        let sourcePath = CoreLayerRequestContext.canonical(URL(fileURLWithPath: expected.sourcePath))
        let replacementSource = CoreLayerRequestContext.canonical(URL(fileURLWithPath: replacement.sourcePath))
        guard self.sessionID == sessionID, projectPath == path,
              expectedContext.projectSessionID == sessionID.uuidString,
              expectedContext.projectPath == path,
              expectedContext.projectRevision?.caseInsensitiveCompare(projectRevision) == .orderedSame,
              context(sessionID: sessionID, projectURL: projectURL,
                  projectRevision: projectRevision) == expectedContext,
              references[expected.referenceID] == expected,
              replacement.sessionOnly,
              replacement.projectSessionID == sessionID.uuidString,
              replacement.projectPath == path,
              replacement.kind == expected.kind,
              replacementSource == sourcePath,
              replacement.canonicalSourcePath == sourcePath,
              replacement.sourceRevision.count == 64,
              replacement.sourceRevision.allSatisfy({ $0.isHexDigit }),
              !replacement.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              replacement.referenceID == CoreLayerRequestContext.referenceID(
                  projectSessionID: sessionID, projectURL: projectURL,
                  kind: replacement.kind, sourceURL: URL(fileURLWithPath: sourcePath),
                  sourceRevision: replacement.sourceRevision),
              replacement.referenceID == expected.referenceID || references[replacement.referenceID] == nil else {
            return false
        }
        references.removeValue(forKey: expected.referenceID)
        references[replacement.referenceID] = replacement
        return true
    }

    func reset() {
        sessionID = nil
        projectPath = nil
        references.removeAll(keepingCapacity: false)
    }
}

struct CoreLayerImportRequest: Encodable, Sendable {
    let projectPath: String
    let projectSessionID: String
    let projectRevision: String
    let projectXml: String
    let projectXmlRevision: String
    let sourcePath: String
    let sourceRevision: String
    var action: String? = nil
    let coreLayerContext: CoreLayerRequestContext?
}

struct CoreLayerImportInspection: Decodable, Sendable {
    let projectPath: String
    let projectSessionID: String
    let projectRevision: String
    let projectXmlRevision: String
    let sourcePath: String
    let canonicalSourcePath: String
    let sourceRevision: String
    let kind: String
    let name: String
    let description: String
    let fileSize: Int64
    let availableActions: [String]
    let referenceIsSessionOnly: Bool
}

struct CoreLayerImportReceipt: Decodable, Sendable {
    let action: String
    let projectPath: String
    let projectSessionID: String
    let projectRevision: String
    let projectXmlRevision: String
    let sourcePath: String
    let canonicalSourcePath: String
    let sourceRevision: String
    let kind: String
    let name: String
    let reference: CoreLayerReferenceCapture?
    let importedAssetPath: String?
    let importedAssetRevision: String?
    let referenceIsSessionOnly: Bool
}

struct CoreLayerReferenceReloadRequest: Encodable, Sendable {
    let projectPath: String
    let projectSessionID: String
    let projectRevision: String
    let coreLayerContext: CoreLayerRequestContext
    let targetReferenceID: String
}

struct CoreLayerReferenceReloadReceipt: Decodable, Sendable {
    let projectPath: String
    let projectSessionID: String
    let projectRevision: String
    let previousContextIdentityToken: String
    let previousReferenceID: String
    let reference: CoreLayerReferenceCapture
    let nextContext: CoreLayerRequestContext
}

struct CoreLayerImportPresentation: Identifiable, Sendable {
    let id: UUID
    let projectSessionID: UUID
    let projectURL: URL
    let projectRevision: String
    let projectXML: String
    let projectXMLRevision: String
    let sourceURL: URL
    let sourceRevision: String
    let mapContext: LayerTreeContext
    let coreLayerContext: CoreLayerRequestContext
    let inspection: CoreLayerImportInspection
}
