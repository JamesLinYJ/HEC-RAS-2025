import Foundation
import RASWorkspaceCore
import SwiftUI

struct CatalogProjectHeaderActions: View {
    @ObservedObject var store: WorkspaceStore
    @State private var isExporting = false
    @State private var alertMessage: String?

    private var canExportProjection: Bool {
        guard let document = store.document,
              document.url?.isFileURL == true,
              document.sourceRevision != nil,
              !document.projectionType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              store.modelProvider is BackendModelProvider else { return false }
        return !store.isRunningProjectTool && !store.isSavingAll && !store.isClosingTab && !store.isOpeningProject
    }

    var body: some View {
        Menu {
            Button("Export Projection…", systemImage: "square.and.arrow.up") {
                beginProjectionExport()
            }
            .disabled(!canExportProjection || isExporting)
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .help(L10n.text("Project Actions"))
        .disabled(!canExportProjection || isExporting)
        .alert(L10n.text("Projection Export"), isPresented: Binding(
            get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } }
        )) {
            Button(L10n.text("OK"), role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    @MainActor private func beginProjectionExport() {
        guard canExportProjection,
              let document = store.document,
              let projectURL = document.url,
              let revision = document.sourceRevision,
              let backend = store.modelProvider as? BackendModelProvider else { return }
        // Capture the complete owner and draft before presenting the native
        // save panel. A modal can outlive a project close/reopen or a draft
        // edit, even when the replacement project uses the same path.
        let projectSessionID = store.projectSessionID
        let projectPath = SourceFilePaths.canonical(projectURL)
        let projectXML = document.editorXML(overridingDescription: store.descriptionDraft)
        guard let destination = store.system.chooseExportDestination(
            name: "Projection.prj", extensions: ["prj"], title: L10n.text("Export Projection")) else { return }

        guard canExportProjection,
              store.projectSessionID == projectSessionID,
              let activeDocument = store.document,
              activeDocument.url.map({ SourceFilePaths.canonical($0) }) == projectPath,
              activeDocument.sourceRevision?.caseInsensitiveCompare(revision) == .orderedSame,
              activeDocument.editorXML(overridingDescription: store.descriptionDraft) == projectXML else { return }

        let request = ProjectProjectionExportRequest(
            projectPath: projectPath,
            projectXml: projectXML,
            expectedProjectRevision: revision,
            destinationPath: destination.path)
        let expectedOutputDirectory = SourceFilePaths.canonical(destination.deletingLastPathComponent())
        isExporting = true
        Task { @MainActor in
            defer { isExporting = false }
            do {
                let receipt = try await BackendCatalogHeaderActionProvider(client: backend.client)
                    .exportProjection(request)
                let outputURL = URL(fileURLWithPath: receipt.outputPath)
                let outputSize = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard SourceFilePaths.canonical(URL(fileURLWithPath: receipt.projectPath)) == projectPath,
                      receipt.projectRevision.caseInsensitiveCompare(revision) == .orderedSame,
                      outputURL.isFileURL,
                      SourceFilePaths.canonical(outputURL.deletingLastPathComponent()) == expectedOutputDirectory,
                      outputURL.pathExtension.caseInsensitiveCompare("prj") == .orderedSame,
                      FileManager.default.fileExists(atPath: outputURL.path),
                      outputSize > 0 else {
                    throw BackendServiceError(code: "protocolFailure", message: "The projection export receipt does not match the captured project.")
                }
                // The backend has already committed the output. Preserve that
                // receipt if the user switched projects while it was running,
                // but never reveal it or write status into the new project UI.
                guard store.projectSessionID == projectSessionID,
                      let activeDocument = store.document,
                      activeDocument.url.map({ SourceFilePaths.canonical($0) }) == projectPath else { return }
                store.system.reveal(outputURL)
                alertMessage = L10n.format("Projection file exported to %@", receipt.outputPath)
            } catch {
                // The backend verifies the saved project revision both before
                // and after export. The captured draft is never written back.
                guard store.projectSessionID == projectSessionID,
                      let activeDocument = store.document,
                      activeDocument.url.map({ SourceFilePaths.canonical($0) }) == projectPath else { return }
                alertMessage = L10n.text(error.localizedDescription)
            }
        }
    }
}

struct IncompleteResultRemovalCandidate {
    let asset: ProjectAsset
    let nodeID: String
    let sourceName: String
    let sourceRevision: String
}

struct IncompleteResultRemovalPlan {
    let projectSessionID: UUID
    let projectURL: URL
    let projectRevision: String
    let projectXML: String
    let resultRootID: String
    let candidates: [IncompleteResultRemovalCandidate]
    let withheldCount: Int

    @MainActor
    static func capture(root: LayerTreeNode, store: WorkspaceStore) -> Self? {
        guard root.sourceClass == "ResultRootContext", root.name == "Results",
              let document = store.document, let projectURL = document.url,
              let projectRevision = document.sourceRevision,
              projectURL.isFileURL else { return nil }
        let roots = store.catalogTreeSession.roots ?? []
        var matchingRoots: [LayerTreeNode] = []
        var allResults: [LayerTreeNode] = []
        func visit(_ node: LayerTreeNode) {
            if node.sourceClass == "ResultRootContext", node.id == root.id { matchingRoots.append(node) }
            if node.sourceClass == "ObservableResult" { allResults.append(node) }
            for child in node.children ?? [] { visit(child) }
        }
        for item in roots { visit(item) }
        guard matchingRoots.count == 1, let currentRoot = matchingRoots.first,
              let resultRows = currentRoot.children else { return nil }

        let nameCounts = Dictionary(grouping: allResults, by: \.name).mapValues(\.count)
        var candidates: [IncompleteResultRemovalCandidate] = []
        var withheld = 0
        var seenPaths = Set<String>()
        for node in resultRows where node.sourceClass == "ObservableResult" {
            if node.resultComputeState == "completed" { continue }
            let liveEntry = node.resultComputeSourcePath.map(Self.canonical)
                .flatMap { store.liveResultComputeByPath[$0] }
            if let live = liveEntry, live.projectSessionID == store.projectSessionID {
                switch live.status {
                case .running:
                    continue
                case .completed:
                    guard let resultRevision = live.resultRevision else { continue }
                    if node.resultComputeSourceRevision?.caseInsensitiveCompare(resultRevision) == .orderedSame {
                        continue
                    }
                case .unknown:
                    if let liveRevision = live.resultRevision,
                       node.resultComputeSourceRevision?.caseInsensitiveCompare(liveRevision) != .orderedSame {
                        break
                    } else {
                        continue
                    }
                case .failed, .cancelled:
                    if let resultRevision = live.resultRevision,
                       node.resultComputeSourceRevision?.caseInsensitiveCompare(resultRevision) != .orderedSame {
                        withheld += 1
                        continue
                    }
                }
            }
            guard node.resultComputeState == nil || node.resultComputeState == "failed",
                  let rawPath = node.resultComputeSourcePath, !rawPath.isEmpty,
                  let revision = node.resultComputeSourceRevision, Self.isSHA256(revision),
                  let assetID = node.assetID, Self.canonical(rawPath) == Self.canonical(assetID),
                  !node.name.isEmpty, nameCounts[node.name] == 1,
                  let asset = store.assets.first(where: {
                      $0.section == .results && Self.canonical($0.url) == Self.canonical(rawPath)
                  }),
                  store.assets.filter({
                      $0.section == .results && Self.canonical($0.url) == Self.canonical(rawPath)
                  }).count == 1,
                  FileManager.default.fileExists(atPath: asset.url.path) else {
                withheld += 1
                continue
            }
            let path = Self.canonical(rawPath)
            guard seenPaths.insert(path).inserted else { withheld += 1; continue }
            candidates.append(.init(asset: asset, nodeID: node.id,
                                    sourceName: node.name, sourceRevision: revision))
        }

        return .init(projectSessionID: store.projectSessionID,
            projectURL: projectURL, projectRevision: projectRevision,
            projectXML: document.editorXML(overridingDescription: store.descriptionDraft),
            resultRootID: currentRoot.id, candidates: candidates, withheldCount: withheld)
    }

    @MainActor
    func stillOwnsProject(_ store: WorkspaceStore) -> Bool {
        guard projectSessionID == store.projectSessionID,
              let document = store.document,
              document.url.map({ Self.canonical($0) }) == Self.canonical(projectURL),
              document.sourceRevision?.caseInsensitiveCompare(projectRevision) == .orderedSame,
              document.editorXML(overridingDescription: store.descriptionDraft) == projectXML else { return false }
        return true
    }

    @MainActor
    func liveAsset(for candidate: IncompleteResultRemovalCandidate, in store: WorkspaceStore) -> ProjectAsset? {
        let matches = store.assets.filter {
            $0.section == .results && Self.canonical($0.url) == Self.canonical(candidate.asset.url)
        }
        guard matches.count == 1, let asset = matches.first,
              asset.id == candidate.asset.id,
              Self.canonical(URL(fileURLWithPath: asset.id)) == Self.canonical(candidate.asset.url) else { return nil }
        return asset
    }

    private static func canonical(_ url: URL) -> String { SourceFilePaths.canonical(url) }
    private static func canonical(_ path: String) -> String { canonical(URL(fileURLWithPath: path)) }
    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value)
        }
    }
}

struct CatalogResultHeaderRemovalAction: View {
    let root: LayerTreeNode
    @ObservedObject var store: WorkspaceStore
    @State private var pendingPlan: IncompleteResultRemovalPlan?
    @State private var isRemoving = false
    @State private var alertMessage: String?
    @State private var confirmationPresented = false

    private var currentPlan: IncompleteResultRemovalPlan? {
        IncompleteResultRemovalPlan.capture(root: root, store: store)
    }

    var body: some View {
        Menu {
            Button("Remove Incomplete Results…", systemImage: "trash") {
                pendingPlan = currentPlan
                confirmationPresented = pendingPlan?.candidates.isEmpty == false
            }
            .disabled(currentPlan?.candidates.isEmpty != false || isRemoving
                || store.isRunningProjectTool || store.isSavingAll || store.isClosingTab || store.isOpeningProject)
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .disabled(currentPlan?.candidates.isEmpty != false || isRemoving
            || store.isRunningProjectTool || store.isSavingAll || store.isClosingTab || store.isOpeningProject)
        .help(L10n.text("Result actions"))
        .confirmationDialog(L10n.text("Remove Incomplete Results?"), isPresented: $confirmationPresented,
                            titleVisibility: .visible) {
            Button(L10n.format("Move %d incomplete results to the macOS Trash",
                               pendingPlan?.candidates.count ?? 0), role: .destructive) {
                guard let plan = pendingPlan else { return }
                Task { await remove(plan) }
            }
            Button(L10n.text("Cancel"), role: .cancel) { pendingPlan = nil }
        } message: {
            if let plan = pendingPlan, plan.withheldCount > 0 {
                Text(L10n.format("%d other incomplete results have ambiguous or unavailable source identities and will be left untouched.",
                                 plan.withheldCount))
            } else {
                Text(L10n.text("Each Result will be revalidated before it is moved. Referenced terrain and model files are kept."))
            }
        }
        .alert(L10n.text("Result Removal"), isPresented: Binding(
            get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } }
        )) {
            Button(L10n.text("OK"), role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    @MainActor
    private func remove(_ plan: IncompleteResultRemovalPlan) async {
        guard !isRemoving, !plan.candidates.isEmpty, plan.stillOwnsProject(store),
              let anchor = plan.liveAsset(for: plan.candidates[0], in: store),
              let backend = store.modelProvider as? BackendModelProvider else {
            alertMessage = L10n.text("The incomplete Result set changed or a project operation is in progress.")
            return
        }
        guard store.beginResultDeletion(assetID: anchor.id, projectSessionID: plan.projectSessionID) else {
            alertMessage = L10n.text("The incomplete Result set changed or a project operation is in progress.")
            return
        }
        isRemoving = true
        defer {
            store.endResultDeletion(projectSessionID: plan.projectSessionID)
            isRemoving = false
            pendingPlan = nil
        }

        let provider = BackendCatalogHeaderActionProvider(client: backend.client)
        var removedCount = 0
        do {
            // Preflight the complete captured set before the first destructive
            // action so stale rows do not cause avoidable partial deletion.
            for candidate in plan.candidates {
                guard plan.stillOwnsProject(store), plan.liveAsset(for: candidate, in: store) != nil else {
                    throw BackendServiceError(code: "sourceChanged", message: "The incomplete Result set changed before removal.")
                }
                _ = try await validate(candidate, plan: plan, provider: provider, store: store)
            }

            for candidate in plan.candidates {
                guard plan.stillOwnsProject(store),
                      let asset = plan.liveAsset(for: candidate, in: store) else {
                    throw BackendServiceError(code: "sourceChanged", message: "The incomplete Result set changed before removal.")
                }
                // Re-read exact Result and project revisions immediately before
                // moving this file, even after the batch preflight.
                let preparation = try await validate(candidate, plan: plan, provider: provider, store: store)
                guard plan.stillOwnsProject(store), plan.liveAsset(for: candidate, in: store) != nil else {
                    throw BackendServiceError(code: "sourceChanged", message: "The incomplete Result changed before it was moved to Trash.")
                }
                try store.system.trash(asset.url)
                removedCount += 1
                try store.completeResultDeletion(assetID: asset.id, sourceName: preparation.resultName,
                                                  projectSessionID: plan.projectSessionID)
            }
            alertMessage = L10n.format("Moved %d incomplete results to the macOS Trash.", removedCount)
        } catch {
            let failure = L10n.text(error.localizedDescription)
            if removedCount == 0 {
                alertMessage = failure
            } else {
                alertMessage = L10n.format("Moved %d of %d incomplete results to the macOS Trash before stopping: %@",
                                           removedCount, plan.candidates.count, failure)
            }
        }
    }

    @MainActor
    private func validate(_ candidate: IncompleteResultRemovalCandidate,
                          plan: IncompleteResultRemovalPlan,
                          provider: BackendCatalogHeaderActionProvider,
                          store: WorkspaceStore) async throws -> IncompleteResultDeletePreparation {
        guard plan.stillOwnsProject(store),
              plan.liveAsset(for: candidate, in: store) != nil else {
            throw BackendServiceError(code: "sourceChanged", message: "The incomplete Result set changed before removal.")
        }
        let request = IncompleteResultDeletePreparationRequest(
            projectPath: SourceFilePaths.canonical(plan.projectURL),
            projectXml: plan.projectXML,
            projectRevision: plan.projectRevision,
            resultPath: SourceFilePaths.canonical(candidate.asset.url),
            resultRevision: candidate.sourceRevision)
        let preparation = try await provider.prepareIncompleteResultRemoval(request)
        guard plan.stillOwnsProject(store),
              preparation.matches(projectPath: plan.projectURL, projectRevision: plan.projectRevision,
                                  resultPath: candidate.asset.url, resultRevision: candidate.sourceRevision),
              preparation.resultName == candidate.sourceName else {
            throw BackendServiceError(code: "sourceChanged", message: "The incomplete Result changed before removal.")
        }
        return preparation
    }
}
