import Foundation
import RASWorkspaceCore

enum ResultProfileSampleLineMode: String, CaseIterable, Identifiable, Sendable {
    case flow = "Flow"
    case cumulativeVolume = "CumulativeVolume"

    var id: String { rawValue }
    var titleKey: String {
        switch self {
        case .flow: "Flow"
        case .cumulativeVolume: "Cumulative Volume"
        }
    }
}

struct ResultProfileSourceIdentity: Codable, Hashable, Sendable {
    let resultPath: String
    let revision: String
}

struct ResultProfileSourcesRequest: Encodable, Sendable {
    let projectPath: String
    let projectXml: String
    let resultPath: String
    let revision: String
}

struct ResultProfileSampleLineProjectContext: Hashable, Sendable {
    let projectPath: String
    let projectXml: String
    let contextID: String
}

struct ResultProfileSampleLineRequest: Encodable, Sendable {
    let projectPath: String
    let projectXml: String
    let resultPath: String
    let revision: String
    let sources: [ResultProfileSourceIdentity]
    let sampleLine: [GeometryTopologyCoordinate]
    let mode: String
}

struct ResultProfileSourceChoice: Decodable, Equatable, Identifiable, Sendable {
    let resultPath: String
    let revision: String
    let resultName: String
    let embeddedPlanName: String
    let profileCount: Int
    let firstFlowAreaName: String?
    let firstFlowAreaCellCount: Int
    let firstFlowAreaFaceCount: Int
    var id: String { resultPath }
}

struct ResultProfileSources: Decodable, Sendable {
    let projectPath: String
    let resultPath: String
    let revision: String
    let embeddedPlanName: String
    let firstFlowAreaName: String?
    let firstFlowAreaCellCount: Int
    let firstFlowAreaFaceCount: Int
    let sources: [ResultProfileSourceChoice]
}

struct ResultProfileSampleLinePoint: Decodable, Identifiable, Sendable {
    let profileIndex: Int
    let time: String
    let value: Double?
    var id: Int { profileIndex }
}

struct ResultProfileSampleLineSeries: Decodable, Sendable {
    let resultPath: String
    let revision: String
    let resultName: String
    let mode: String
    let quantity: String
    let units: String
    let available: Bool
    let unavailableReason: String?
    let points: [ResultProfileSampleLinePoint]
}

struct ResultProfileSampleLineResult: Decodable, Sendable {
    let projectPath: String
    let resultPath: String
    let revision: String
    let mode: String
    let sampleLine: [GeometryTopologyCoordinate]
    let series: [ResultProfileSampleLineSeries]
}

@MainActor
protocol ResultProfileSampleLineProvider {
    func loadSampleSources(projectPath: String, projectXml: String,
                           resultPath: String, revision: String) async throws -> ResultProfileSources
    func computeSampleLine(_ request: ResultProfileSampleLineRequest,
                           progress: @escaping @Sendable (BackendProgressUpdate) -> Void) async throws -> ResultProfileSampleLineResult
}

extension BackendResultProfileProvider: ResultProfileSampleLineProvider {
    func loadSampleSources(projectPath: String, projectXml: String,
                           resultPath: String, revision: String) async throws -> ResultProfileSources {
        let request = ResultProfileSourcesRequest(projectPath: projectPath, projectXml: projectXml,
            resultPath: resultPath, revision: revision)
        return try await client.request("result.profileSources", parameters: request, as: ResultProfileSources.self)
    }

    func computeSampleLine(_ request: ResultProfileSampleLineRequest,
                           progress: @escaping @Sendable (BackendProgressUpdate) -> Void) async throws -> ResultProfileSampleLineResult {
        try await client.request("result.profileSampleLine", parameters: request,
            as: ResultProfileSampleLineResult.self, progress: progress)
    }
}
