import Combine
import CryptoKit
import Foundation
import RASWorkspaceCore

struct ResultPlanContextRequest: Encodable, Sendable {
    let projectPath: String
    let projectXml: String
    let resultPath: String
    let revision: String
}

struct ResultPlanPropertyItem: Decodable, Equatable, Identifiable, Sendable {
    let label: String
    let value: String
    let isLocalizedValue: Bool
    var id: String { label }
}

struct ResultPlanPropertyGroup: Decodable, Equatable, Identifiable, Sendable {
    let title: String
    let items: [ResultPlanPropertyItem]
    var id: String { title }
}

struct ResultPlanCandidate: Codable, Equatable, Hashable, Identifiable, Sendable {
    let resultPath: String
    let revision: String
    let name: String
    let planName: String?
    let hasPlan: Bool
    var id: String { resultPath + "\u{1f}" + revision }
}

struct ResultPlanCandidateGroup: Codable, Equatable, Identifiable, Sendable {
    let planName: String?
    let hasPlan: Bool
    let results: [ResultPlanCandidate]
    var id: String { "\(hasPlan ? "plan" : "no-plan")\u{1f}\(planName ?? "")" }
}

struct ResultPlanContextSnapshot: Decodable, Sendable {
    let projectPath: String
    let projectRevision: String
    let resultPath: String
    let revision: String
    let anchorName: String
    let anchorPlanName: String?
    let anchorHasPlan: Bool
    let embeddedPlanGroups: [ResultPlanPropertyGroup]
    let candidateGroups: [ResultPlanCandidateGroup]

    var anchor: ResultPlanCandidate {
        ResultPlanCandidate(resultPath: resultPath, revision: revision, name: anchorName,
            planName: anchorPlanName, hasPlan: anchorHasPlan)
    }
}

/// An accepted PlanPicker result expressed with canonical, revision-bound
/// source Result identities. The app shell can hand this to the shared result
/// profile context; this value alone does not claim that multi-result scrubbing
/// has been attached to that context.
struct LinkedResultSelection: Equatable, Sendable {
    let projectPath: String
    let projectRevision: String
    let anchor: ResultPlanCandidate
    let selectedGroups: [ResultPlanCandidateGroup]

    var results: [ResultPlanCandidate] {
        var seen = Set<String>()
        return ([anchor] + selectedGroups.flatMap(\.results)).filter {
            seen.insert($0.resultPath).inserted
        }
    }

    var planCount: Int { selectedGroups.count + 1 }
}

@MainActor
struct BackendResultPlanContextProvider {
    let client: BackendProcessClient

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func inspect(resultPath: URL, projectPath: URL, projectXml: String,
                 revision: String) async throws -> ResultPlanContextSnapshot {
        let request = ResultPlanContextRequest(
            // Keep the caller's path spelling as the base for project-relative
            // Result references. The service uses canonical paths separately
            // for identity and content hashes.
            projectPath: projectPath.standardizedFileURL.path,
            projectXml: projectXml,
            resultPath: resultPath.standardizedFileURL.resolvingSymlinksInPath().path,
            revision: revision
        )
        return try await client.request("result.planContext", parameters: request,
                                        as: ResultPlanContextSnapshot.self)
    }
}

@MainActor
final class ResultPlanContextSession: ObservableObject {
    @Published private(set) var snapshot: ResultPlanContextSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    private let provider: BackendResultPlanContextProvider
    private var contextIdentity: String?
    private var generation = 0
    private var lastAsset: ProjectAsset?
    private var lastProjectPath: URL?
    private var lastProjectXml: String?
    private var lastInspectorSnapshot: ResultInspectorSnapshot?
    private var lastSourceContextRevision = ""

    init(provider: BackendResultPlanContextProvider) {
        self.provider = provider
    }

    func ensureLoaded(asset: ProjectAsset?, projectPath: URL?, projectXml: String?,
                      inspectorSnapshot: ResultInspectorSnapshot?, sourceContextRevision: String,
                      force: Bool = false) async {
        guard let asset, asset.section == .results, let projectPath, let projectXml,
              let inspectorSnapshot else {
            invalidate()
            return
        }
        let canonicalResultPath = asset.url.standardizedFileURL.resolvingSymlinksInPath().path
        guard inspectorSnapshot.resultPath == canonicalResultPath,
              !inspectorSnapshot.revision.isEmpty else {
            invalidate()
            return
        }
        lastAsset = asset
        lastProjectPath = projectPath
        lastProjectXml = projectXml
        lastInspectorSnapshot = inspectorSnapshot
        lastSourceContextRevision = sourceContextRevision
        let identity = Self.identity(asset: asset, projectPath: projectPath, projectXml: projectXml,
            revision: inspectorSnapshot.revision, sourceContextRevision: sourceContextRevision)
        guard force || identity != contextIdentity || (snapshot == nil && !isLoading && error == nil) else { return }

        generation &+= 1
        let current = generation
        contextIdentity = identity
        snapshot = nil
        error = nil
        isLoading = true
        defer { if current == generation { isLoading = false } }

        do {
            let loaded = try await provider.inspect(resultPath: asset.url, projectPath: projectPath,
                projectXml: projectXml, revision: inspectorSnapshot.revision)
            guard current == generation, !Task.isCancelled else { return }
            guard Self.samePath(loaded.projectPath, projectPath),
                  Self.samePath(loaded.resultPath, asset.url),
                  loaded.revision == inspectorSnapshot.revision,
                  !loaded.projectRevision.isEmpty,
                  Self.valid(loaded) else {
                throw BackendServiceError(code: "protocolFailure",
                    message: L10n.text("The linked Result context no longer matches the selected result."))
            }
            snapshot = loaded
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            if !(error is CancellationError) {
                self.error = L10n.text(error.localizedDescription)
            }
        }
    }

    func accepts(_ selection: LinkedResultSelection, asset: ProjectAsset?, projectPath: URL?,
                 projectXml: String?, inspectorSnapshot: ResultInspectorSnapshot?,
                 sourceContextRevision: String) -> Bool {
        guard !isLoading, error == nil, let snapshot, let asset, asset.section == .results,
              let projectPath, let projectXml, let inspectorSnapshot,
              Self.samePath(inspectorSnapshot.resultPath, asset.url),
              contextIdentity == Self.identity(asset: asset, projectPath: projectPath,
                  projectXml: projectXml, revision: inspectorSnapshot.revision,
                  sourceContextRevision: sourceContextRevision),
              Self.samePath(snapshot.resultPath, asset.url),
              snapshot.revision == inspectorSnapshot.revision,
              Self.samePath(selection.projectPath, projectPath),
              selection.projectRevision == snapshot.projectRevision,
              selection.anchor == snapshot.anchor, !selection.selectedGroups.isEmpty,
              Set(selection.selectedGroups.map(\.id)).count == selection.selectedGroups.count,
              selection.selectedGroups.allSatisfy({ snapshot.candidateGroups.contains($0) }),
              selection.results.count == 1 + selection.selectedGroups.reduce(0, { $0 + $1.results.count })
        else { return false }
        return true
    }

    func invalidate() {
        generation &+= 1
        contextIdentity = nil
        snapshot = nil
        error = nil
        isLoading = false
        lastAsset = nil
        lastProjectPath = nil
        lastProjectXml = nil
        lastInspectorSnapshot = nil
        lastSourceContextRevision = ""
    }

    func reloadCurrentContext() async {
        guard let lastAsset, let lastProjectPath, let lastProjectXml,
              let lastInspectorSnapshot else { return }
        await ensureLoaded(asset: lastAsset, projectPath: lastProjectPath,
            projectXml: lastProjectXml, inspectorSnapshot: lastInspectorSnapshot,
            sourceContextRevision: lastSourceContextRevision, force: true)
    }

    private static func valid(_ snapshot: ResultPlanContextSnapshot) -> Bool {
        guard snapshot.candidateGroups.allSatisfy({ !$0.results.isEmpty }) else { return false }
        if snapshot.anchorHasPlan && snapshot.anchorPlanName == nil { return false }
        if !snapshot.anchorHasPlan && snapshot.anchorPlanName != nil { return false }

        var paths = Set<String>([canonicalPath(snapshot.resultPath)])
        for group in snapshot.candidateGroups {
            if group.hasPlan && group.planName == nil { return false }
            if !group.hasPlan && group.planName != nil { return false }
            for result in group.results {
                guard !result.revision.isEmpty,
                      result.hasPlan == group.hasPlan,
                      result.planName == group.planName,
                      paths.insert(canonicalPath(result.resultPath)).inserted else { return false }
            }
        }

        if snapshot.anchorHasPlan {
            return snapshot.embeddedPlanGroups.map(\.title) == ["Time Window", "Computation Options"]
        }
        return snapshot.embeddedPlanGroups.isEmpty
    }

    private static func samePath(_ first: String, _ second: URL) -> Bool {
        canonicalPath(first) == canonicalPath(second.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func identity(asset: ProjectAsset, projectPath: URL, projectXml: String,
                                  revision: String, sourceContextRevision: String) -> String {
        let source = [asset.url.standardizedFileURL.resolvingSymlinksInPath().path,
            projectPath.standardizedFileURL.path,
            revision, sourceContextRevision, projectXml].joined(separator: "\n")
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
