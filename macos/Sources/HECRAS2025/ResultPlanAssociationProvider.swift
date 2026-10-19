import Combine
import Foundation
import RASWorkspaceCore

struct PlanResultAssociationRequest: Encodable, Sendable {
    let projectPath: String
    let projectXml: String
    let resultPath: String
    let revision: String
}

/// Names read from the exact `Result.Plan.Plan.Geometry` and
/// `Result.Plan.Plan.BoundaryCondition` source objects.
struct PlanResultAssociationSnapshot: Decodable, Equatable, Sendable {
    let projectPath: String
    let projectRevision: String
    let resultPath: String
    let revision: String
    let hasPlan: Bool
    let planName: String?
    let geometryName: String?
    let boundaryConditionName: String?
}

@MainActor
struct BackendPlanResultAssociationProvider {
    let client: BackendProcessClient

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func inspect(resultPath: URL, projectPath: URL, projectXml: String,
                 revision: String) async throws -> PlanResultAssociationSnapshot {
        let request = PlanResultAssociationRequest(
            projectPath: projectPath.standardizedFileURL.path,
            projectXml: projectXml,
            resultPath: resultPath.standardizedFileURL.resolvingSymlinksInPath().path,
            revision: revision)
        return try await client.request("result.planAssociations", parameters: request,
            as: PlanResultAssociationSnapshot.self)
    }
}

/// Keeps the exact embedded association read tied to the current Result HDF,
/// project draft and project session. Late replies from a previous selection
/// are discarded, and changing the Result never reuses a same-name snapshot.
@MainActor
final class PlanResultAssociationSession: ObservableObject {
    @Published private(set) var snapshot: PlanResultAssociationSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    private let provider: BackendPlanResultAssociationProvider
    private var identity: String?
    private var generation = 0
    private var lastAsset: ProjectAsset?
    private var lastProjectPath: URL?
    private var lastProjectXml: String?
    private var lastInspectorRevision: String?
    private var lastProjectRevision: String?
    private var lastSourceContextRevision = ""

    init(provider: BackendPlanResultAssociationProvider) {
        self.provider = provider
    }

    func ensureLoaded(asset: ProjectAsset?, projectPath: URL?, projectXml: String?,
                      inspectorSnapshot: ResultInspectorSnapshot?, projectRevision: String?,
                      sourceContextRevision: String, force: Bool = false) async {
        guard let asset, asset.section == .results, let projectPath, let projectXml,
              let inspectorSnapshot,
              Self.samePath(inspectorSnapshot.resultPath, asset.url),
              !inspectorSnapshot.revision.isEmpty else {
            invalidate()
            return
        }

        await load(asset: asset, projectPath: projectPath, projectXml: projectXml,
            resultRevision: inspectorSnapshot.revision, projectRevision: projectRevision,
            sourceContextRevision: sourceContextRevision, force: force)
    }

    private func load(asset: ProjectAsset, projectPath: URL, projectXml: String,
                      resultRevision: String, projectRevision: String?,
                      sourceContextRevision: String, force: Bool) async {

        lastAsset = asset
        lastProjectPath = projectPath
        lastProjectXml = projectXml
        lastInspectorRevision = resultRevision
        lastProjectRevision = projectRevision
        lastSourceContextRevision = sourceContextRevision
        let requestIdentity = Self.identity(asset: asset, projectPath: projectPath,
            projectXml: projectXml, resultRevision: resultRevision,
            projectRevision: projectRevision, sourceContextRevision: sourceContextRevision)
        guard force || requestIdentity != identity || (snapshot == nil && !isLoading && error == nil) else { return }

        generation &+= 1
        let current = generation
        identity = requestIdentity
        snapshot = nil
        error = nil
        isLoading = true
        defer { if generation == current { isLoading = false } }

        do {
            let loaded = try await provider.inspect(resultPath: asset.url, projectPath: projectPath,
                projectXml: projectXml, revision: resultRevision)
            guard generation == current, !Task.isCancelled else { return }
            guard Self.samePath(loaded.resultPath, asset.url),
                  Self.samePath(loaded.projectPath, projectPath),
                  loaded.revision.caseInsensitiveCompare(resultRevision) == .orderedSame,
                  !loaded.projectRevision.isEmpty,
                  projectRevision.map({ $0.caseInsensitiveCompare(loaded.projectRevision) == .orderedSame }) ?? true,
                  Self.valid(loaded) else {
                throw BackendServiceError(code: "protocolFailure",
                    message: L10n.text("The embedded Plan associations no longer match the selected Result."))
            }
            snapshot = loaded
        } catch {
            guard generation == current, !Task.isCancelled else { return }
            if !(error is CancellationError) { self.error = L10n.text(error.localizedDescription) }
        }
    }

    func invalidate() {
        generation &+= 1
        identity = nil
        snapshot = nil
        error = nil
        isLoading = false
        lastAsset = nil
        lastProjectPath = nil
        lastProjectXml = nil
        lastInspectorRevision = nil
        lastProjectRevision = nil
        lastSourceContextRevision = ""
    }

    func reloadCurrentContext() async {
        guard let lastAsset, let lastProjectPath, let lastProjectXml,
              let lastInspectorRevision else { return }
        await load(asset: lastAsset, projectPath: lastProjectPath, projectXml: lastProjectXml,
            resultRevision: lastInspectorRevision, projectRevision: lastProjectRevision,
            sourceContextRevision: lastSourceContextRevision, force: true)
    }

    private static func valid(_ snapshot: PlanResultAssociationSnapshot) -> Bool {
        guard snapshot.hasPlan else {
            return snapshot.planName == nil && snapshot.geometryName == nil
                && snapshot.boundaryConditionName == nil
        }
        return snapshot.planName?.isEmpty == false
    }

    private static func identity(asset: ProjectAsset, projectPath: URL, projectXml: String,
                                 resultRevision: String, projectRevision: String?,
                                 sourceContextRevision: String) -> String {
        [asset.id, asset.url.standardizedFileURL.resolvingSymlinksInPath().path,
         projectPath.standardizedFileURL.resolvingSymlinksInPath().path,
         resultRevision, projectRevision ?? "", sourceContextRevision, projectXml]
            .joined(separator: "\n")
    }

    private static func samePath(_ path: String, _ url: URL) -> Bool {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            == url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
