import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct ModelEditorCommittedReceiptTests {
    @Test @MainActor
    func committedSaveReportsCapturedAssetWithoutInstallingIntoReplacementEditor() async {
        let provider = DeferredCommittedSaveProvider()
        let session = ModelEditorSession(provider: provider)
        let original = ProjectAsset(url: URL(fileURLWithPath: "/fixture/Original.h5"), section: .boundaryConditions)
        let replacement = ProjectAsset(url: URL(fileURLWithPath: "/fixture/Replacement.h5"), section: .boundaryConditions)
        await session.load(original, kind: .boundaryCondition)
        session.set("Receipt/Description", "submitted draft")
        var receipts: [(ProjectAsset, EditorSnapshot)] = []
        session.didSaveModelSnapshot = { asset, snapshot, _, _ in receipts.append((asset, snapshot)) }
        let saving = Task { await session.save(original) }
        await provider.waitUntilSaving()
        await session.load(replacement, kind: .boundaryCondition)
        let replacementFields = session.fields
        provider.finishSave()

        #expect(await saving.value == false)
        #expect(receipts.count == 1)
        #expect(receipts.first?.0 == original)
        #expect(receipts.first?.1.sourceRevision == DeferredCommittedSaveProvider.committedRevision)
        #expect(session.modelAssetID == replacement.id)
        #expect(session.fields == replacementFields)
        #expect(session.sourceFileRevision == DeferredCommittedSaveProvider.originalRevision)
        #expect(!session.modified)
    }

    @Test(arguments: [false, true]) @MainActor
    func currentEditorReceivesOneCommitAndInstallsCanonicalSnapshot(withRefreshWarning: Bool) async {
        let provider = DeferredCommittedSaveProvider(refreshWarning: withRefreshWarning ? "Saved; refresh is incomplete." : nil)
        let session = ModelEditorSession(provider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/Current.h5"), section: .boundaryConditions)
        await session.load(asset, kind: .boundaryCondition)
        session.set("Receipt/Description", "submitted draft")
        var committedAssets: [ProjectAsset] = []
        session.didSaveModelSnapshot = { asset, _, _, _ in committedAssets.append(asset) }
        let saving = Task { await session.save(asset) }
        await provider.waitUntilSaving()
        provider.finishSave()

        #expect(await saving.value)
        #expect(committedAssets == [asset])
        #expect(session.fields["Receipt/Description"] == "canonical saved value")
        #expect(session.sourceFileRevision == DeferredCommittedSaveProvider.committedRevision)
        #expect(!session.modified)
        #expect(session.saveWarning == provider.refreshWarning)
        #expect(session.error == nil)
    }
}

@MainActor
private final class DeferredCommittedSaveProvider: ModelEditorProvider {
    static let originalRevision = String(repeating: "A", count: 64)
    static let committedRevision = String(repeating: "B", count: 64)
    private var pending: CheckedContinuation<EditorSaveResult, Never>?
    private var started: CheckedContinuation<Void, Never>?
    let refreshWarning: String?

    init(refreshWarning: String? = nil) { self.refreshWarning = refreshWarning }

    func load(_ asset: ProjectAsset, kind: ModelEditorKind) async throws -> EditorSnapshot {
        snapshot("baseline \(asset.url.lastPathComponent)", revision: Self.originalRevision)
    }
    func save(_ asset: ProjectAsset, changes: EditorEdits) async throws { throw CocoaError(.featureUnsupported) }
    func perform(_ asset: ProjectAsset, action: EditorAction) async throws -> EditorSnapshot { throw CocoaError(.featureUnsupported) }
    func saveModel(_ asset: ProjectAsset, changes: EditorEdits) async throws -> EditorSaveResult {
        await withCheckedContinuation { continuation in
            pending = continuation
            started?.resume()
            started = nil
        }
    }
    func waitUntilSaving() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finishSave() {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: EditorSaveResult(sourceRevision: Self.committedRevision,
            snapshot: snapshot("canonical saved value", revision: Self.committedRevision), refreshWarning: refreshWarning))
    }
    private func snapshot(_ value: String, revision: String) -> EditorSnapshot {
        EditorSnapshot(fields: ["Receipt/Description": value], rows: [:], samples: [:], canEdit: true,
            images: [:], sourceRevision: revision)
    }
}
