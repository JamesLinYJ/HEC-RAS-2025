import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct CoreLayerRequestContextTests {
    @Test
    func wireIdentityMatchesBackendForEmptyAndReferencedCapturesAcrossVarAliases() {
        let sessionID = UUID(uuidString: "12345678-1234-5678-9ABC-DEF012345678")!
        let projectAlias = URL(fileURLWithPath: "/var/tmp/core-layer-token-parity.ras")
        let projectPhysical = URL(fileURLWithPath: "/private/var/tmp/core-layer-token-parity.ras")
        let sourceAlias = URL(fileURLWithPath: "/var/tmp/core-layer-token-parity.h5")
        let sourcePhysical = URL(fileURLWithPath: "/private/var/tmp/core-layer-token-parity.h5")
        let projectRevision: String? = nil
        let sourceRevision = String(repeating: "B", count: 64)

        let emptyAlias = CoreLayerRequestContext.capture(projectSessionID: sessionID,
            projectURL: projectAlias, projectRevision: projectRevision, references: [])
        let emptyPhysical = CoreLayerRequestContext.capture(projectSessionID: sessionID,
            projectURL: projectPhysical, projectRevision: projectRevision, references: [])
        #expect(emptyAlias.projectPath == "/private/var/tmp/core-layer-token-parity.ras")
        #expect(emptyAlias.identityToken == "d0957ea6585ef9200b05109e5187925717f4611bb6520e8295c181ac8aa94cdb")
        #expect(emptyAlias == emptyPhysical)

        func reference(projectURL: URL, sourceURL: URL) -> CoreLayerReferenceCapture {
            CoreLayerReferenceCapture(
                referenceID: CoreLayerRequestContext.referenceID(projectSessionID: sessionID,
                    projectURL: projectURL, kind: "geometry", sourceURL: sourceURL,
                    sourceRevision: sourceRevision),
                projectSessionID: sessionID.uuidString,
                projectPath: CoreLayerRequestContext.canonical(projectURL),
                kind: "geometry", sourcePath: sourceURL.path,
                canonicalSourcePath: CoreLayerRequestContext.canonical(sourceURL),
                sourceRevision: sourceRevision, name: "Wire Geometry")
        }

        let referencedAlias = CoreLayerRequestContext.capture(projectSessionID: sessionID,
            projectURL: projectAlias, projectRevision: projectRevision,
            references: [reference(projectURL: projectAlias, sourceURL: sourceAlias)])
        let referencedPhysical = CoreLayerRequestContext.capture(projectSessionID: sessionID,
            projectURL: projectPhysical, projectRevision: projectRevision,
            references: [reference(projectURL: projectPhysical, sourceURL: sourcePhysical)])
        #expect(referencedAlias.references.first?.referenceID
            == "3d451753535674c344f01d0d8451b379498ccdea4c781ccbc57a67fc41831236")
        #expect(referencedAlias.identityToken
            == "0945bcda129f10bbcfaa75933252d8c8f0f13df66c93380dadbe4b3b43382696")
        #expect(referencedAlias.identityToken == referencedPhysical.identityToken)
        #expect(referencedAlias.references.first?.referenceID == referencedPhysical.references.first?.referenceID)
        #expect(referencedAlias.references.first?.canonicalSourcePath
            == referencedPhysical.references.first?.canonicalSourcePath)
        #expect(referencedAlias.references.first?.sourcePath == sourceAlias.path)
        #expect(referencedPhysical.references.first?.sourcePath == sourcePhysical.path)
    }

    @Test @MainActor
    func typedContextIdentityRoundTripsAndRegistryClearsAcrossProjectSessions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("core-layer-context-" + UUID().uuidString, isDirectory: true)
        let projectURL = root.appendingPathComponent("Session.ras")
        let sourceURL = root.appendingPathComponent("Outside Geometry.h5")
        let sessionID = UUID()
        let projectRevision = String(repeating: "A", count: 64)
        let sourceRevision = String(repeating: "B", count: 64)
        let reference = CoreLayerReferenceCapture(
            referenceID: CoreLayerRequestContext.referenceID(projectSessionID: sessionID,
                projectURL: projectURL, kind: "geometry", sourceURL: sourceURL,
                sourceRevision: sourceRevision),
            projectSessionID: sessionID.uuidString,
            projectPath: CoreLayerRequestContext.canonical(projectURL),
            kind: "geometry", sourcePath: sourceURL.path,
            canonicalSourcePath: CoreLayerRequestContext.canonical(sourceURL),
            sourceRevision: sourceRevision, name: "Outside Geometry")
        let context = CoreLayerRequestContext.capture(projectSessionID: sessionID,
            projectURL: projectURL, projectRevision: projectRevision, references: [reference])

        let mapIdentity = MapTreeMapIdentity(projectPath: projectURL.path,
            projectXml: "<Project />", projectXmlSHA: String(repeating: "C", count: 64),
            mapID: UUID().uuidString, mapIndex: 0, mapName: "Map", mapType: "Buildable",
            expectedVisualizationRevision: String(repeating: "D", count: 64),
            coreLayerContext: context)
        let encoded = try JSONEncoder().encode(mapIdentity)
        let decoded = try JSONDecoder().decode(MapTreeMapIdentity.self, from: encoded)
        #expect(decoded == mapIdentity)
        #expect(decoded.coreLayerContext?.references == [reference])
        #expect(decoded.coreLayerContext?.identityToken == context.identityToken)
        #expect(mapIdentity.coreLayerContextIdentity == context.identityToken)

        let changedProjectRevision = CoreLayerRequestContext.capture(projectSessionID: sessionID,
            projectURL: projectURL, projectRevision: String(repeating: "E", count: 64), references: [reference])
        let changedReferences = CoreLayerRequestContext.capture(projectSessionID: sessionID,
            projectURL: projectURL, projectRevision: projectRevision, references: [])
        let changedSession = CoreLayerRequestContext.capture(projectSessionID: UUID(),
            projectURL: projectURL, projectRevision: projectRevision, references: [])
        #expect(changedProjectRevision.identityToken != context.identityToken)
        #expect(changedReferences.identityToken != context.identityToken)
        #expect(changedSession.identityToken != context.identityToken)

        let registry = CoreLayerReferenceRegistry()
        #expect(registry.register(reference, sessionID: sessionID, projectURL: projectURL))
        #expect(registry.context(sessionID: sessionID, projectURL: projectURL,
            projectRevision: projectRevision).references == [reference])
        let updatedSourceRevision = String(repeating: "F", count: 64)
        #expect(registry.rebaseReference(from: context, sessionID: sessionID, projectURL: projectURL,
            projectRevision: String(repeating: "E", count: 64), sourceURL: sourceURL,
            sourceRevision: updatedSourceRevision, name: "Renamed Geometry"))
        let rebased = registry.context(sessionID: sessionID, projectURL: projectURL,
            projectRevision: String(repeating: "E", count: 64))
        #expect(rebased.references.count == 1)
        #expect(rebased.references[0].sourceRevision == updatedSourceRevision)
        #expect(rebased.references[0].name == "Renamed Geometry")
        #expect(rebased.references[0].referenceID != reference.referenceID)
        #expect(rebased.identityToken != context.identityToken)
        #expect(!registry.rebaseReference(from: context, sessionID: sessionID, projectURL: projectURL,
            projectRevision: String(repeating: "E", count: 64), sourceURL: sourceURL,
            sourceRevision: String(repeating: "0", count: 64), name: "Stale Rename"))
        let nextSession = UUID()
        #expect(registry.context(sessionID: nextSession, projectURL: projectURL,
            projectRevision: projectRevision).references.isEmpty)
        #expect(registry.context(sessionID: nextSession,
            projectURL: root.appendingPathComponent("Other.ras"), projectRevision: projectRevision)
            .references.isEmpty)
    }

    @Test @MainActor
    func exactRecoveryCanRemoveTwoMissingSourcesOneAtATimeAndReplaceOnlyTheCapturedSource() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("core-layer-recovery-" + UUID().uuidString, isDirectory: true)
        let projectURL = root.appendingPathComponent("Recovery.ras")
        let geometryURL = root.appendingPathComponent("Missing Geometry.h5")
        let boundaryURL = root.appendingPathComponent("Missing Boundary.h5")
        let sessionID = UUID()
        let projectRevision = String(repeating: "A", count: 64)
        let geometry = makeReference(sessionID: sessionID, projectURL: projectURL,
            sourceURL: geometryURL, kind: "geometry", revision: String(repeating: "B", count: 64), name: "Old Geometry")
        let boundary = makeReference(sessionID: sessionID, projectURL: projectURL,
            sourceURL: boundaryURL, kind: "boundaryCondition", revision: String(repeating: "C", count: 64), name: "Boundary")
        let registry = CoreLayerReferenceRegistry()
        #expect(registry.register(geometry, sessionID: sessionID, projectURL: projectURL))
        #expect(registry.register(boundary, sessionID: sessionID, projectURL: projectURL))
        let original = registry.context(sessionID: sessionID, projectURL: projectURL,
            projectRevision: projectRevision)

        #expect(registry.removeExact(geometry, context: original, sessionID: sessionID,
            projectURL: projectURL, projectRevision: projectRevision))
        let afterFirstRemoval = registry.context(sessionID: sessionID, projectURL: projectURL,
            projectRevision: projectRevision)
        #expect(afterFirstRemoval.references == [boundary])
        #expect(!registry.removeExact(geometry, context: afterFirstRemoval, sessionID: sessionID,
            projectURL: projectURL, projectRevision: projectRevision))
        #expect(registry.removeExact(boundary, context: afterFirstRemoval, sessionID: sessionID,
            projectURL: projectURL, projectRevision: projectRevision))
        #expect(registry.context(sessionID: sessionID, projectURL: projectURL,
            projectRevision: projectRevision).references.isEmpty)

        #expect(registry.register(geometry, sessionID: sessionID, projectURL: projectURL))
        #expect(registry.register(boundary, sessionID: sessionID, projectURL: projectURL))
        let reloadBase = registry.context(sessionID: sessionID, projectURL: projectURL,
            projectRevision: projectRevision)
        let replacement = makeReference(sessionID: sessionID, projectURL: projectURL,
            sourceURL: geometryURL, kind: "geometry", revision: String(repeating: "D", count: 64),
            name: "Reloaded Geometry")
        #expect(registry.replaceExact(geometry, with: replacement, context: reloadBase,
            sessionID: sessionID, projectURL: projectURL, projectRevision: projectRevision))
        let reloaded = registry.context(sessionID: sessionID, projectURL: projectURL,
            projectRevision: projectRevision)
        #expect(reloaded.references.contains(replacement))
        #expect(reloaded.references.contains(boundary))
        #expect(!registry.replaceExact(geometry, with: replacement, context: reloadBase,
            sessionID: sessionID, projectURL: projectURL, projectRevision: projectRevision))
    }

    @Test @MainActor
    func markingAReferenceConflictKeepsTheUnsavedEditorDraftAndBlocksWrites() async {
        let fieldID = "GeometryCatalogSummary/Context_Description"
        let editor = ModelEditorSession()
        editor.startDraft(EditorSnapshot(fields: [fieldID: "saved value"], rows: [:], samples: [:],
            canEdit: true, images: [:]))
        editor.set(fieldID, "unsaved user draft")
        let originalFields = editor.fields
        let wasModified = editor.modified

        editor.markCoreLayerReferenceConflict("The external source changed.")

        #expect(editor.fields == originalFields)
        #expect(editor.fields[fieldID] == "unsaved user draft")
        #expect(editor.modified == wasModified)
        #expect(editor.hasUnsavedEditorChanges)
        #expect(editor.hasCoreLayerReferenceConflict)
        #expect(!editor.canSave)
        #expect(!(await editor.perform(.compute)))
        await editor.ensureLoaded(nil, kind: .geometry)
        #expect(editor.fields == originalFields)
        #expect(editor.hasCoreLayerReferenceConflict)
        editor.discardEdits()
        #expect(editor.fields[fieldID] == "saved value")
        #expect(editor.hasCoreLayerReferenceConflict)
    }

    private func makeReference(sessionID: UUID, projectURL: URL, sourceURL: URL,
                               kind: String, revision: String, name: String) -> CoreLayerReferenceCapture {
        CoreLayerReferenceCapture(
            referenceID: CoreLayerRequestContext.referenceID(projectSessionID: sessionID,
                projectURL: projectURL, kind: kind, sourceURL: sourceURL, sourceRevision: revision),
            projectSessionID: sessionID.uuidString,
            projectPath: CoreLayerRequestContext.canonical(projectURL),
            kind: kind, sourcePath: sourceURL.path,
            canonicalSourcePath: CoreLayerRequestContext.canonical(sourceURL),
            sourceRevision: revision, name: name)
    }
}
