import Foundation
import RASWorkspaceCore

enum LinkedResultMapFrameMode: String, CaseIterable, Identifiable, Sendable {
    case profile = "Profile"
    case minimum = "Minimum"
    case maximum = "Maximum"

    var id: String { rawValue }
}

enum LinkedResultMapType: String, CaseIterable, Identifiable, Sendable {
    case waterSurfaceElevation = "WaterSurfaceElevation"
    case depth = "Depth"
    case velocity = "Velocity"
    case depthTimesVelocity = "DepthTimesVelocity"

    var id: String { rawValue }

    var labelKey: String {
        switch self {
        case .waterSurfaceElevation: "Water Surface"
        case .depth: "Depth"
        case .velocity: "Velocity"
        case .depthTimesVelocity: "D*V"
        }
    }
}

struct LinkedResultMapRequest: Encodable, Sendable {
    let projectPath: String
    let projectXml: String
    let projectRevision: String
    let anchor: ResultPlanCandidate
    let selectedGroups: [ResultPlanCandidateGroup]
    let profileIndex: Int
    let mapType: String
    let frameMode: String
    let viewport: RasterMapViewExtent?
}

struct LinkedResultMapSourceStatus: Decodable, Identifiable, Sendable {
    let resultPath: String
    let revision: String
    let resultName: String
    let terrainPath: String?
    let terrainRevision: String?
    let available: Bool
    let profileIndex: Int?
    let profileName: String?
    let time: String?
    let unavailableReason: String?

    var id: String { SourceFilePaths.canonical(URL(fileURLWithPath: resultPath)) + "|" + revision }
}

struct LinkedResultMapLayer: Decodable, Identifiable, Sendable {
    let id: String
    let resultPath: String
    let revision: String
    let resultName: String
    let mapType: String
    let terrainPath: String
    let terrainRevision: String
    let profileIndex: Int
    let profileName: String
    let time: String
    let units: String
    let width: Int
    let height: Int
    let rgba: Data
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double
    let legendStops: [MapResultRenderLegendStop]

    func makeRaster() throws -> MapRasterLayer {
        try MapRasterLayer(id: id, name: resultName + " · " + mapType,
            width: width, height: height, rgba: rgba,
            lowerLeft: MapPoint(x: minX, y: minY),
            upperRight: MapPoint(x: maxX, y: maxY))
    }
}

struct LinkedResultMapSnapshot: Decodable, Sendable {
    let projectPath: String
    let projectRevision: String
    let anchorPath: String
    let profileIndex: Int
    let frameMode: String
    let mapType: String
    let viewport: RasterMapViewExtent
    let minimumAvailable: Bool
    let maximumAvailable: Bool
    let sources: [LinkedResultMapSourceStatus]
    let layers: [LinkedResultMapLayer]
    let unavailableReason: String?
}

@MainActor
final class LinkedResultMapSession: ObservableObject {
    @Published private(set) var snapshot: LinkedResultMapSnapshot?
    @Published private(set) var rasters: [MapRasterLayer] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorCode: String?
    @Published private(set) var renderRevision = 0

    private let client: BackendProcessClient
    private var generation = 0
    private var requestTask: Task<LinkedResultMapSnapshot, Error>?

    init(client: BackendProcessClient) { self.client = client }

    func render(_ selection: LinkedResultSelection, projectXML: String,
                profileIndex: Int, mapType: LinkedResultMapType,
                frameMode: LinkedResultMapFrameMode, viewport: RasterMapViewExtent?) async {
        requestTask?.cancel()
        generation += 1
        let capture = generation
        isLoading = true
        errorCode = nil
        snapshot = nil
        rasters = []

        let request = LinkedResultMapRequest(projectPath: selection.projectPath,
            projectXml: projectXML, projectRevision: selection.projectRevision,
            anchor: selection.anchor, selectedGroups: selection.selectedGroups,
            profileIndex: profileIndex, mapType: mapType.rawValue,
            frameMode: frameMode.rawValue, viewport: viewport)
        let client = self.client
        let task = Task {
            try await client.request("result.linkedMap", parameters: request,
                                     as: LinkedResultMapSnapshot.self)
        }
        requestTask = task
        defer {
            if generation == capture {
                isLoading = false
                requestTask = nil
            }
        }

        do {
            let loaded = try await withTaskCancellationHandler { try await task.value }
                onCancel: { task.cancel() }
            guard generation == capture, !Task.isCancelled else { return }
            try Self.validate(loaded, selection: selection, profileIndex: profileIndex,
                              mapType: mapType, frameMode: frameMode)
            let mapped = try loaded.layers.map { try $0.makeRaster() }
            guard generation == capture, !Task.isCancelled else { return }
            snapshot = loaded
            rasters = mapped
            renderRevision += 1
        } catch is CancellationError {
            return
        } catch let error as BackendServiceError {
            guard generation == capture, !Task.isCancelled else { return }
            errorCode = error.code
        } catch {
            guard generation == capture, !Task.isCancelled else { return }
            errorCode = "requestFailed"
        }
    }

    static func validate(_ loaded: LinkedResultMapSnapshot, selection: LinkedResultSelection,
                         profileIndex: Int, mapType: LinkedResultMapType,
                         frameMode: LinkedResultMapFrameMode) throws {
        let expected = Dictionary(selection.results.map {
            (SourceFilePaths.canonical(URL(fileURLWithPath: $0.resultPath)), $0.revision.uppercased())
        }, uniquingKeysWith: { first, _ in first })
        let returned = Dictionary(loaded.sources.map {
            (SourceFilePaths.canonical(URL(fileURLWithPath: $0.resultPath)), $0)
        }, uniquingKeysWith: { first, _ in first })
        let returnedPaths = loaded.sources.map {
            SourceFilePaths.canonical(URL(fileURLWithPath: $0.resultPath))
        }
        let availableSourcePaths = Set(returned.values.filter(\.available).map {
            SourceFilePaths.canonical(URL(fileURLWithPath: $0.resultPath))
        })
        let layerSourcePaths = loaded.layers.map {
            SourceFilePaths.canonical(URL(fileURLWithPath: $0.resultPath))
        }
        guard SourceFilePaths.canonical(URL(fileURLWithPath: loaded.projectPath)) ==
                SourceFilePaths.canonical(URL(fileURLWithPath: selection.projectPath)),
              loaded.projectRevision.uppercased() == selection.projectRevision.uppercased(),
              SourceFilePaths.canonical(URL(fileURLWithPath: loaded.anchorPath)) ==
                SourceFilePaths.canonical(URL(fileURLWithPath: selection.anchor.resultPath)),
              loaded.profileIndex == profileIndex,
              loaded.frameMode == frameMode.rawValue,
              loaded.mapType == mapType.rawValue,
              loaded.viewport.minX.isFinite, loaded.viewport.minY.isFinite,
              loaded.viewport.maxX.isFinite, loaded.viewport.maxY.isFinite,
              loaded.viewport.minX < loaded.viewport.maxX,
              loaded.viewport.minY < loaded.viewport.maxY,
              loaded.viewport.pixelWidth > 0, loaded.viewport.pixelWidth <= 1536,
              loaded.viewport.pixelHeight > 0, loaded.viewport.pixelHeight <= 1536,
              Set(expected.keys).count == selection.results.count,
              Set(returnedPaths).count == loaded.sources.count,
              returned.count == expected.count,
              returned.allSatisfy({ expected[$0.key] == $0.value.revision.uppercased() }),
              Set(layerSourcePaths).count == loaded.layers.count,
              Set(layerSourcePaths) == availableSourcePaths,
              loaded.layers.allSatisfy({ layer in
                  guard expected[SourceFilePaths.canonical(URL(fileURLWithPath: layer.resultPath))] ==
                            layer.revision.uppercased(),
                        layer.mapType == mapType.labelKey,
                        layer.width > 0, layer.width <= 1536,
                        layer.height > 0, layer.height <= 1536,
                        layer.rgba.count == layer.width * layer.height * 4,
                        layer.minX.isFinite, layer.minY.isFinite,
                        layer.maxX.isFinite, layer.maxY.isFinite,
                        layer.minX == loaded.viewport.minX,
                        layer.minY == loaded.viewport.minY,
                        layer.maxX == loaded.viewport.maxX,
                        layer.maxY == loaded.viewport.maxY,
                        layer.width == loaded.viewport.pixelWidth,
                        layer.height == loaded.viewport.pixelHeight,
                        let source = returned[SourceFilePaths.canonical(URL(fileURLWithPath: layer.resultPath))],
                        source.available,
                        source.revision.uppercased() == layer.revision.uppercased(),
                        source.terrainPath.map({ SourceFilePaths.canonical(URL(fileURLWithPath: $0)) }) ==
                            Optional(SourceFilePaths.canonical(URL(fileURLWithPath: layer.terrainPath))),
                        source.terrainRevision?.uppercased() == layer.terrainRevision.uppercased() else {
                      return false
                  }
                  if frameMode == .maximum {
                      return layer.profileName == "Max" &&
                          layer.profileIndex == Int(Int32.max) &&
                          source.profileIndex == Int(Int32.max) &&
                          source.profileName == layer.profileName
                  }
                  return layer.profileIndex >= 0 && source.profileIndex == layer.profileIndex &&
                      source.profileName == layer.profileName && source.time == layer.time
              }) else {
            throw BackendServiceError(code: "sourceChanged", message: "The linked Result map no longer matches the selected source context.")
        }
        if frameMode == .minimum, loaded.minimumAvailable || !loaded.layers.isEmpty {
            throw BackendServiceError(code: "protocolFailure", message: "The linked Result map reported an unsupported minimum frame.")
        }
        if frameMode == .maximum, !loaded.maximumAvailable, !loaded.layers.isEmpty {
            throw BackendServiceError(code: "protocolFailure", message: "The linked Result map returned a maximum frame without source support.")
        }
    }

    func cancel() {
        generation += 1
        requestTask?.cancel()
        requestTask = nil
        isLoading = false
        snapshot = nil
        rasters = []
        errorCode = nil
    }
}
