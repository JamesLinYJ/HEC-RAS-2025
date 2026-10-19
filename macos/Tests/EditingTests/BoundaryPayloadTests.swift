import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class BoundaryPayloadProvider: ModelEditorProvider {
    var snapshot: EditorSnapshot
    var saved: [EditorEdits] = []
    var actions: [EditorAction] = []
    var draftActions: [EditorAction] = []
    init(_ snapshot: EditorSnapshot) { self.snapshot = snapshot }
    func load(_ asset: ProjectAsset, kind: ModelEditorKind) async throws -> EditorSnapshot { snapshot }
    func save(_ asset: ProjectAsset, changes: EditorEdits) async throws {
        saved.append(changes)
    }
    func perform(_ asset: ProjectAsset, action: EditorAction) async throws -> EditorSnapshot {
        actions.append(action); return snapshot
    }
    func editBoundary(_ asset: ProjectAsset, action: EditorAction, edits: EditorEdits) async throws -> EditorSnapshot {
        draftActions.append(action); throw CocoaError(.fileWriteNoPermission)
    }
}

struct BoundaryPayloadTests {
    private var asset: ProjectAsset { .init(url: URL(fileURLWithPath: "/ui-fixture/boundary.h5"), section: .boundaryConditions) }
    private func fixture() -> EditorSnapshot {
        let first = BoundaryPayloadPresentation(id: "a", scope: "payload-a", name: "上游流量", friendlyName: "Constant Flow", editorSchemaID: "ConstantPayloadEditor", isHydraulic: true, isEnabled: true, canDelete: true)
        let second = BoundaryPayloadPresentation(id: "b", scope: "payload-b", name: "上游备用", friendlyName: "Constant Flow", editorSchemaID: "ConstantPayloadEditor", isHydraulic: true, isEnabled: false, canDelete: false)
        let downstream = BoundaryPayloadPresentation(id: "c", scope: "payload-c", name: "下游水位", friendlyName: "Constant Stage", editorSchemaID: "ConstantPayloadEditor", isHydraulic: true, isEnabled: true)
        return .init(fields: [
            "payload-a/ConstantPayloadEditor/ConstantPayload_Value": "1",
            "payload-b/ConstantPayloadEditor/ConstantPayload_Value": "2",
            "payload-c/ConstantPayloadEditor/ConstantPayload_Value": "3"
        ], rows: [:], samples: [:], canEdit: true, images: [:], boundaryLines: .init(lines: [
            .init(id: "upstream", scope: "line-upstream", name: "上游", payloads: [first, second], selectedPayloadID: "a", activeHydraulicPayloadID: "a", newPayload: .init(fields: [:])),
            .init(id: "downstream", scope: "line-downstream", name: "下游", payloads: [downstream], selectedPayloadID: "c", activeHydraulicPayloadID: "c")
        ], selectedLineID: "upstream"))
    }

    @Test @MainActor
    func multiplePayloadsKeepSeparateDraftsAndSelectionsWithoutSaving() async throws {
        let provider = BoundaryPayloadProvider(fixture())
        let session = ModelEditorSession(provider: provider)
        await session.load(asset, kind: .boundaryCondition)
        let source = try #require(SourceEditorLibrary.shared.schema("ConstantPayloadEditor")?.fields.first)
        let first = source.inScope("payload-a"), second = source.inScope("payload-b")
        session.set(first.storageID, "11.25")
        session.renameBoundaryPayload("保留中文名称", lineID: "upstream", payloadID: "a")
        session.selectBoundaryPayload("b", lineID: "upstream")
        session.set(second.storageID, "22.5")
        session.selectBoundaryLine("downstream")
        #expect(session.selectedBoundaryPayload?.id == "c")
        session.selectBoundaryLine("upstream")
        #expect(session.selectedBoundaryPayload?.id == "b")
        session.selectBoundaryPayload("a", lineID: "upstream")
        #expect(session.fields[first.storageID] == "11.25")
        #expect(session.fields[second.storageID] == "22.5")
        #expect(session.boundaryPayloadName(try #require(session.selectedBoundaryPayload)) == "保留中文名称")
        #expect(provider.saved.isEmpty)
        #expect(provider.actions.isEmpty)
        #expect(await session.save(asset))
        #expect(provider.saved.first?.fields[first.storageID] == "11.25")
        #expect(provider.saved.first?.fields[second.storageID] == "22.5")
        session.set(first.storageID, "99")
        session.selectBoundaryPayload("b", lineID: "upstream")
        session.discardEdits()
        #expect(session.fields[first.storageID] == "11.25")
        #expect(session.selectedBoundaryPayload?.id == "b")
        #expect(session.boundaryLines?.lines.count == 2)
    }

    @Test @MainActor
    func hydraulicEnablementOnlyDisablesPeersOnTheSameLine() async throws {
        let provider = BoundaryPayloadProvider(fixture())
        let session = ModelEditorSession(provider: provider)
        await session.load(asset, kind: .boundaryCondition)
        session.setBoundaryPayloadEnabled(true, lineID: "upstream", payloadID: "b")
        let lines = try #require(session.boundaryLines?.lines)
        #expect(!session.boundaryPayloadEnabled(lines[0].payloads[0]))
        #expect(session.boundaryPayloadEnabled(lines[0].payloads[1]))
        #expect(session.boundaryPayloadEnabled(lines[1].payloads[0]))
        #expect(await session.save(asset))
        #expect(provider.saved.first?.fields == [
            "payload-a/PayloadListItem/Payload_IsEnabled": "false",
            "payload-b/PayloadListItem/Payload_IsEnabled": "true"
        ])
    }

    @Test @MainActor
    func failedPayloadDraftMutationRetainsSelectionAndNeverImplicitlySaves() async throws {
        let provider = BoundaryPayloadProvider(fixture())
        let session = ModelEditorSession(provider: provider)
        await session.load(asset, kind: .boundaryCondition)
        session.set("payload-a/ConstantPayloadEditor/ConstantPayload_Value", "中文草稿")
        #expect(!(await session.perform(.removeBoundaryPayload(lineID: "upstream", payloadID: "a"))))
        #expect(session.selectedBoundaryPayload?.id == "a")
        #expect(session.fields["payload-a/ConstantPayloadEditor/ConstantPayload_Value"] == "中文草稿")
        #expect(session.modified)
        #expect(provider.actions.isEmpty)
        // Capability checks run before the draft service, including direct callers.
        #expect(!(await session.perform(.removeBoundaryPayload(lineID: "upstream", payloadID: "b"))))
        #expect(provider.saved.isEmpty && provider.draftActions.count == 1)
    }

    @Test @MainActor
    func scopedReadonlyFieldsAndAmbiguousObjectScopesAreRejected() async throws {
        let provider = BoundaryPayloadProvider(fixture())
        let session = ModelEditorSession(provider: provider)
        await session.load(asset, kind: .boundaryCondition)
        let readonly = try #require(SourceEditorLibrary.shared.schema("ResultCatalogSummary")?.fields.first { $0.readOnly })
        session.set(readonly.inScope("object-id").storageID, "must not become a draft")
        #expect(!session.modified)
        let payload = BoundaryPayloadPresentation(id: "a", scope: "duplicate", name: "", friendlyName: "", editorSchemaID: "ConstantPayloadEditor", isHydraulic: true, isEnabled: true)
        provider.snapshot.boundaryLines = .init(lines: [.init(id: "line", scope: "duplicate", name: "", payloads: [payload])])
        await session.load(asset, kind: .boundaryCondition)
        #expect(!session.loaded)
        #expect(session.error != nil)
        #expect(session.boundaryLines == nil)
    }
}
