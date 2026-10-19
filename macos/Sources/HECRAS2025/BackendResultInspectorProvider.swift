import CryptoKit
import Combine
import Foundation
import RASWorkspaceCore

struct ResultInspectorRequest: Encodable, Sendable {
    let projectPath: String
    let projectXml: String
    let resultPath: String
    let revision: String?
}

struct ResultDeletePreparationRequest: Encodable, Sendable {
    let projectPath: String
    let projectXml: String
    let resultPath: String
    let revision: String
}

struct ResultDeletePreparation: Decodable, Equatable, Sendable {
    let projectPath: String
    let resultPath: String
    let name: String
    let revision: String

    func matches(projectPath: URL, resultPath: URL, revision: String) -> Bool {
        self.projectPath == Self.canonical(projectPath)
            && self.resultPath == Self.canonical(resultPath)
            && self.revision == revision
    }

    private static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

struct ResultInspectorModelIdentity: Decodable, Sendable {
    let name: String
    let description: String?
    let shortID: String?
    let filename: String?
    let dateCreated: String?
    let dateLastModified: String?
    let embeddedInResult: Bool
}

struct ResultInspectorComputeSummary: Decodable, Sendable {
    let startTime: String
    let endTime: String
    let success: Bool
    let failureReason: String?
    let solver: String?
    let softwareVersion: String?
    let totalDuration: String
    let totalDurationSeconds: Double
    let solverInitDuration: String
    let solverInitDurationSeconds: Double
    let outputDuration: String
    let outputDurationSeconds: Double
    let computeLog: String?
}

struct ResultInspectorOutputBlock: Decodable, Identifiable, Sendable {
    let name: String
    let profileCount: Int
    let profileNames: [String]
    let times: [String]
    var id: String { name }
}

struct ResultInspectorLogDatum: Decodable, Equatable, Sendable {
    let key: String
    let value: String?
}

struct ResultInspectorLayerError: Decodable, Equatable, Sendable {
    let code: String
    let severity: String
    let evaluatedMessage: String
    let logData: [ResultInspectorLogDatum]

    func presentation(index: Int) -> TopologyBuildMessagePresentation {
        let mappedSeverity = TopologyMessageSeverity(rawValue: severity.lowercased()) ?? .information
        return TopologyBuildMessagePresentation(
            id: "result-layer-error:\(index):\(code)",
            severity: mappedSeverity,
            code: code,
            text: evaluatedMessage,
            context: logData.map { TopologyBuildContextValue(key: $0.key, value: $0.value ?? "—") }
        )
    }
}

struct ResultInspectorSnapshot: Decodable, Sendable {
    let resultPath: String
    let revision: String
    let name: String
    let hasComputed: Bool
    let needsMigration: Bool
    let profileCount: Int
    let computeSummary: ResultInspectorComputeSummary?
    let plan: ResultInspectorModelIdentity?
    let geometry: ResultInspectorModelIdentity?
    let boundaryCondition: ResultInspectorModelIdentity?
    let exactTerrainName: String?
    let associatedTerrainName: String?
    let overrideTerrainName: String?
    let showAutoDetectedTerrain: Bool
    let terrainChoices: [String]
    let outputBlocks: [ResultInspectorOutputBlock]
    let layerErrors: [ResultInspectorLayerError]

    var layerErrorPresentations: [TopologyBuildMessagePresentation] {
        layerErrors.enumerated().map { index, error in error.presentation(index: index) }
    }

    @MainActor var editorSnapshot: EditorSnapshot {
        var fields: [String: String] = [
            "ResultCatalogSummary/Context_Name": name,
            "ResultCatalogSummary/Context_Filename": resultPath,
            "ResultCatalogSummary/Context_Plan_Layer_DateCreated": plan?.dateCreated ?? "",
            "ResultCatalogSummary/Context_Plan_Layer_DateLastModified": plan?.dateLastModified ?? "",
            "ResultTerrainAssociation/Result_OverrideTerrain": overrideTerrainName ?? "",
            "Result/HasComputed": hasComputed ? "true" : "false",
            "Result/NeedsMigration": needsMigration ? "true" : "false",
            "Result/ProfileCount": String(profileCount)
        ]
        if let plan {
            fields["Result/EmbeddedPlanName"] = plan.name
            fields["Result/EmbeddedPlanDescription"] = plan.description ?? ""
            fields["Result/EmbeddedPlanShortID"] = plan.shortID ?? ""
        }
        if let geometry {
            fields["Result/EmbeddedGeometryName"] = geometry.name
            fields["Result/EmbeddedGeometryDescription"] = geometry.description ?? ""
        }
        if let boundaryCondition {
            fields["Result/EmbeddedBoundaryConditionName"] = boundaryCondition.name
            fields["Result/EmbeddedBoundaryConditionDescription"] = boundaryCondition.description ?? ""
        }
        if let summary = computeSummary {
            fields["ComputeSummaryControl/ComputeSummary_StartTime"] = summary.startTime
            fields["ComputeSummaryControl/ComputeSummary_EndTime"] = summary.endTime
            fields["ComputeSummaryControl/ComputeSummary_TotalDuration"] = summary.totalDuration
            fields["ComputeSummaryControl/ComputeSummary_SolverInitDuration"] = summary.solverInitDuration
            fields["ComputeSummaryControl/ComputeSummary_OutputDuration"] = summary.outputDuration
            fields["ComputeSummaryControl/ComputeSummary_Success"] = summary.success ? "true" : "false"
            fields["ComputeSummaryControl/ComputeSummary_FailureReason"] = summary.failureReason ?? ""
            fields["ComputeSummaryControl/ComputeSummary_Solver"] = summary.solver ?? ""
            fields["ComputeSummaryControl/ComputeSummary_SoftwareVersion"] = summary.softwareVersion ?? ""
            fields["ComputeSummaryControl/ComputeSummary_ComputeLog"] = summary.computeLog ?? ""
        }
        var snapshot = EditorSnapshot(fields: fields, rows: [:], samples: [:], canEdit: false,
                                      images: [:], sourceRevision: revision)
        snapshot.choiceOptions["ResultTerrainAssociation/Result_OverrideTerrain"] =
            [EditorChoice(id: "", title: "(No Association)")] + terrainChoices.map {
                EditorChoice(id: $0, title: $0, titleIsUserData: true)
            }
        snapshot.readOnlyFieldIDs = Set(fields.keys)
        return snapshot
    }
}

@MainActor
final class BackendResultInspectorProvider {
    let client: BackendProcessClient

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func inspect(resultPath: URL, projectPath: URL, projectXML: String,
                 revision: String? = nil) async throws -> ResultInspectorSnapshot {
        let request = ResultInspectorRequest(projectPath: projectPath.standardizedFileURL.path,
            projectXml: projectXML,
            resultPath: resultPath.standardizedFileURL.resolvingSymlinksInPath().path,
            revision: revision)
        return try await client.request("result.inspect", parameters: request, as: ResultInspectorSnapshot.self)
    }

    func prepareDelete(resultPath: URL, projectPath: URL, projectXML: String,
                       revision: String) async throws -> ResultDeletePreparation {
        let request = ResultDeletePreparationRequest(
            projectPath: projectPath.standardizedFileURL.resolvingSymlinksInPath().path,
            projectXml: projectXML,
            resultPath: resultPath.standardizedFileURL.resolvingSymlinksInPath().path,
            revision: revision
        )
        return try await client.request("result.delete.prepare", parameters: request,
                                        as: ResultDeletePreparation.self)
    }
}

/// Maintains a result inspection for one selected asset and project draft. A
/// project XML change triggers a fresh source read so terrain auto-detection and
/// override state follow the current, unsaved association draft.
@MainActor
final class ResultInspectorSession: ObservableObject {
    @Published private(set) var snapshot: ResultInspectorSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    private let provider: BackendResultInspectorProvider
    private var contextIdentity: String?
    private var generation = 0

    init(provider: BackendResultInspectorProvider) {
        self.provider = provider
    }

    func ensureLoaded(asset: ProjectAsset?, projectPath: URL?, projectXML: String?,
                      sourceContextRevision: String = "") async {
        guard let asset, asset.section == .results, let projectPath, let projectXML else {
            invalidate()
            return
        }
        let identity = Self.identity(asset: asset, projectPath: projectPath, projectXML: projectXML,
                                     sourceContextRevision: sourceContextRevision)
        guard identity != contextIdentity || (snapshot == nil && !isLoading) else { return }
        generation += 1
        let current = generation
        contextIdentity = identity
        let canonicalResultPath = asset.url.standardizedFileURL.resolvingSymlinksInPath().path
        let expectedRevision = snapshot?.resultPath == canonicalResultPath
            ? snapshot?.revision : nil
        snapshot = nil
        error = nil
        isLoading = true
        defer { if current == generation { isLoading = false } }
        do {
            let result = try await provider.inspect(resultPath: asset.url, projectPath: projectPath,
                projectXML: projectXML, revision: expectedRevision)
            guard current == generation, !Task.isCancelled else { return }
            snapshot = result
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    func prepareDelete(asset: ProjectAsset, projectPath: URL, projectXML: String) async throws -> ResultDeletePreparation {
        guard asset.section == .results, let snapshot else {
            throw BackendServiceError(code: "sourceChanged", message: "Refresh the result before deleting it.")
        }
        let canonicalResultPath = asset.url.standardizedFileURL.resolvingSymlinksInPath().path
        let canonicalProjectPath = projectPath.standardizedFileURL.resolvingSymlinksInPath().path
        guard snapshot.resultPath == canonicalResultPath else {
            throw BackendServiceError(code: "sourceChanged", message: "The selected result changed before it could be moved to Trash.")
        }
        let prepared = try await provider.prepareDelete(resultPath: asset.url, projectPath: projectPath,
                                                        projectXML: projectXML, revision: snapshot.revision)
        guard prepared.matches(projectPath: projectPath, resultPath: asset.url, revision: snapshot.revision),
              prepared.projectPath == canonicalProjectPath else {
            throw BackendServiceError(code: "protocolFailure", message: "The delete preparation no longer matches the selected result.")
        }
        return prepared
    }

    func invalidate() {
        generation += 1
        contextIdentity = nil
        snapshot = nil
        error = nil
        isLoading = false
    }

    private static func identity(asset: ProjectAsset, projectPath: URL, projectXML: String,
                                 sourceContextRevision: String) -> String {
        let data = Data((asset.url.standardizedFileURL.resolvingSymlinksInPath().path + "\n"
            + projectPath.standardizedFileURL.resolvingSymlinksInPath().path
            + "\n" + sourceContextRevision + "\n" + projectXML).utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
