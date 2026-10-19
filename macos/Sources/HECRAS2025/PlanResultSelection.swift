import CryptoKit
import Foundation
import RASWorkspaceCore
import SwiftUI

struct PlanResultChoice: Decodable, Equatable, Identifiable, Sendable {
    let resultPath: String
    let revision: String
    let name: String
    let embeddedPlanName: String
    let hasComputed: Bool
    let profileCount: Int
    var id: String { resultPath }
}

struct PlanResultCatalog: Decodable, Sendable {
    let projectPath: String
    let planPath: String
    let revision: String
    let planName: String
    let results: [PlanResultChoice]
}

struct PlanResultContext: Equatable, Sendable {
    let projectSessionID: UUID
    let projectPath: String
    let projectXML: String
    let planPath: String
    let revision: String
    let assetsRevision: Int
    var id: String {
        let xmlHash = SHA256.hash(data: Data(projectXML.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(projectSessionID)|\(projectPath)|\(planPath)|\(revision)|\(assetsRevision)|\(xmlHash)"
    }
}

@MainActor
protocol PlanResultCatalogProvider {
    func load(_ context: PlanResultContext) async throws -> PlanResultCatalog
}

@MainActor
struct BackendPlanResultCatalogProvider: PlanResultCatalogProvider {
    let client: BackendProcessClient
    func load(_ context: PlanResultContext) async throws -> PlanResultCatalog {
        struct Request: Encodable, Sendable {
            let projectPath: String
            let projectXml: String
            let planPath: String
            let revision: String
        }
        return try await client.request("plan.results.catalog", parameters: Request(
            projectPath: context.projectPath, projectXml: context.projectXML,
            planPath: context.planPath, revision: context.revision), as: PlanResultCatalog.self)
    }
}

/// The original ActiveResult is visual-context state, not a saved Plan field.
/// One model-editor context retains its selection when changing editor pages.
@MainActor
final class PlanResultSelectionSession: ObservableObject {
    private let provider: any PlanResultCatalogProvider
    @Published private(set) var catalog: PlanResultCatalog?
    @Published private(set) var selection: String?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private(set) var context: PlanResultContext?
    private var generation = 0
    private var pending: Task<PlanResultCatalog, Error>?
    var selectedResult: PlanResultChoice? { catalog?.results.first { $0.id == selection } }

    init(provider: any PlanResultCatalogProvider) { self.provider = provider }

    func load(_ incoming: PlanResultContext?, force: Bool = false) async {
        guard let incoming else { invalidate(); return }
        if !force, context == incoming { return }
        let previous = selectedResult
        let sameOwner = context?.projectSessionID == incoming.projectSessionID
            && context?.planPath == incoming.planPath
        generation += 1
        let currentGeneration = generation
        pending?.cancel()
        context = incoming; catalog = nil; selection = nil; error = nil; isLoading = true
        let task = Task { try await provider.load(incoming) }
        pending = task
        do {
            let response = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard currentGeneration == generation, !Task.isCancelled else { return }
            guard Self.canonical(response.projectPath) == Self.canonical(incoming.projectPath),
                  Self.canonical(response.planPath) == Self.canonical(incoming.planPath),
                  response.revision == incoming.revision,
                  Set(response.results.map(\.id)).count == response.results.count,
                  response.results.allSatisfy({ $0.embeddedPlanName == response.planName && !$0.revision.isEmpty }) else {
                throw BackendServiceError(code: "protocolFailure", message: "The related results no longer match the selected plan.")
            }
            catalog = response
            if sameOwner, let previous,
               response.results.contains(where: { $0.id == previous.id && $0.revision == previous.revision }) {
                selection = previous.id
            }
            pending = nil; isLoading = false
        } catch {
            guard currentGeneration == generation else { return }
            pending = nil; isLoading = false
            if !Task.isCancelled, !(error is CancellationError) { self.error = L10n.text(error.localizedDescription) }
        }
    }

    func select(_ resultPath: String?) {
        guard !isLoading else { return }
        guard let resultPath else { selection = nil; return }
        guard catalog?.results.contains(where: { $0.id == resultPath }) == true else { return }
        selection = resultPath
    }

    func removeResult(at path: String) {
        guard let catalog, catalog.results.contains(where: { Self.canonical($0.resultPath) == Self.canonical(path) }) else { return }
        invalidate()
    }

    func invalidate() {
        generation += 1; pending?.cancel(); pending = nil
        catalog = nil; selection = nil; context = nil; isLoading = false; error = nil
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

extension ModelEditorSession {
    func planResultContext(projectSessionID: UUID, assetsRevision: Int) -> PlanResultContext? {
        guard loaded, let planPath = modelAssetID, let revision = sourceFileRevision,
              let backend = provider as? BackendModelProvider,
              let project = backend.project, let url = project.url,
              project.assets.contains(where: { $0.id == planPath && $0.section == .plans }) else { return nil }
        return .init(projectSessionID: projectSessionID, projectPath: url.path,
            projectXML: project.editorXML, planPath: planPath, revision: revision, assetsRevision: assetsRevision)
    }
}

struct PlanResultPicker: View {
    @ObservedObject var results: PlanResultSelectionSession
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    private var context: PlanResultContext? {
        session.planResultContext(projectSessionID: store.projectSessionID, assetsRevision: store.assetsRevision)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if results.isLoading {
                ProgressView("Loading related results…").controlSize(.small)
            } else if let catalog = results.catalog, !catalog.results.isEmpty {
                Picker("Result", selection: Binding(get: { results.selection ?? "" }, set: {
                    results.select($0.isEmpty ? nil : $0)
                })) {
                    Text("None").tag("")
                    ForEach(catalog.results) { result in Text(verbatim: result.name).tag(result.id) }
                }.pickerStyle(.menu)
                if let selected = results.selectedResult {
                    LabeledContent("File", value: selected.resultPath).textSelection(.enabled)
                    HStack {
                        Label(selected.hasComputed ? "Computed" : "Not computed", systemImage: selected.hasComputed ? "checkmark.circle" : "circle.dotted")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Result") {
                            guard let asset = store.document?.assets.first(where: {
                                $0.section == .results && $0.url.standardizedFileURL.resolvingSymlinksInPath().path == selected.resultPath
                            }) else { return }
                            store.openEditor(.result, assetID: asset.id)
                        }.disabled(store.isSavingAll || store.isClosingTab || store.isRunningProjectTool)
                    }
                }
            } else {
                Text("No matching results are available.").foregroundStyle(.secondary)
            }
            if let error = results.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Button("Refresh") { Task { await results.load(context, force: true) } }
                .disabled(context == nil || results.isLoading || store.isRunningProjectTool)
        }
        .task(id: context?.id) { await results.load(context) }
    }
}
