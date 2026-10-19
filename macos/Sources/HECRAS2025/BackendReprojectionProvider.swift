import Foundation
import RASWorkspaceCore

@MainActor
protocol ReprojectionProvider {
    func transform(_ request: ReprojectionRequest) async throws -> ReprojectionSnapshot
    func identify(_ request: ReprojectionIdentifyRequest) async throws -> ReprojectionIdentifySnapshot
}

@MainActor
final class BackendReprojectionProvider: ReprojectionProvider {
    private let client: BackendProcessClient

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func transform(_ request: ReprojectionRequest) async throws -> ReprojectionSnapshot {
        let snapshot = try await client.request(
            "reprojection.transform", parameters: request, as: ReprojectionSnapshot.self)
        try snapshot.validate(for: request)
        return snapshot
    }

    func identify(_ request: ReprojectionIdentifyRequest) async throws -> ReprojectionIdentifySnapshot {
        let snapshot = try await client.request(
            "reprojection.identify", parameters: request, as: ReprojectionIdentifySnapshot.self)
        try snapshot.validate(for: request)
        return snapshot
    }
}

extension ReprojectionSnapshot {
    func validate(for request: ReprojectionRequest) throws {
        let expectedIDs = request.rows.map(\.id)
        guard Set(expectedIDs).count == expectedIDs.count,
              rows.map(\.id) == expectedIDs,
              !sourceSummary.isEmpty,
              !destinationSummary.isEmpty,
              (errorCode == nil) == (errorMessage == nil) else {
            throw ReprojectionProviderError.invalidRowResponse
        }

        if let sourceProjectionSummary,
           sourceProjectionSummary.option != request.sourceOption {
            throw ReprojectionProviderError.invalidRowResponse
        }
        if let destinationProjectionSummary,
           destinationProjectionSummary.option != request.destinationOption {
            throw ReprojectionProviderError.invalidRowResponse
        }

        if errorCode != nil {
            guard rows.allSatisfy({ $0.status == .unavailable && $0.x == nil && $0.y == nil }) else {
                throw ReprojectionProviderError.invalidRowResponse
            }
            return
        }

        guard rows.allSatisfy({ row in
            switch row.status {
            case .transformed:
                guard let x = row.x, let y = row.y else { return false }
                return x.isFinite && y.isFinite
            case .blank, .invalid, .failed:
                return row.x == nil && row.y == nil
            case .unavailable:
                return false
            }
        }) else {
            throw ReprojectionProviderError.invalidRowResponse
        }
    }
}

extension ReprojectionIdentifySnapshot {
    func validate(for request: ReprojectionIdentifyRequest) throws {
        guard !request.paths.isEmpty,
              request.paths.allSatisfy({ URL(fileURLWithPath: $0).isFileURL }) else {
            throw ReprojectionProviderError.invalidProjectionFileResponse
        }

        guard let recognizedPath else {
            guard wkt == nil, projectionSummary == nil else {
                throw ReprojectionProviderError.invalidProjectionFileResponse
            }
            return
        }

        let acceptedPaths = Set(request.paths.map(Self.canonicalPath))
        guard acceptedPaths.contains(Self.canonicalPath(recognizedPath)) else {
            throw ReprojectionProviderError.invalidProjectionFileResponse
        }
        if let errorMessage, !errorMessage.isEmpty {
            guard wkt == nil, projectionSummary == nil else {
                throw ReprojectionProviderError.invalidProjectionFileResponse
            }
            return
        }
        guard let wkt, !wkt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              projectionSummary != nil,
              errorMessage == nil else {
            throw ReprojectionProviderError.invalidProjectionFileResponse
        }
    }

    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
