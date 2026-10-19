import Foundation
import RASWorkspaceCore

/// The subset of a map-tree request needed to resolve transient TerrainInput
/// contexts. In particular this deliberately has no compute-read lease: the
/// caller must honor the map's ordinary source-read gate before rendering.
struct TerrainInputMapTreeRequest: Encodable, Equatable, Sendable {
    let projectPath: String
    let projectXml: String
    let projectXmlSHA: String
    let mapID: String
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let expectedVisualizationRevision: String
    var resultSelectionOverrides: [MapTreeResultSelectionOverride]

    init(map: MapResultChartMapRequest,
         resultSelectionOverrides: [MapTreeResultSelectionOverride]) {
        projectPath = map.projectPath
        projectXml = map.projectXml
        projectXmlSHA = map.projectXmlSHA
        mapID = map.mapID
        mapIndex = map.mapIndex
        mapName = map.mapName
        mapType = map.mapType
        expectedVisualizationRevision = map.expectedVisualizationRevision
        self.resultSelectionOverrides = resultSelectionOverrides
    }
}

struct TerrainInputMapContextRequest: Encodable, Sendable {
    let map: TerrainInputMapTreeRequest
    let inputNodeID: String
    let expectedSourceClass: String
    let expectedTerrainPath: String
    var renderOptions: TerrainInputMapRenderOptions? = nil
}

struct TerrainInputMapRenderOptions: Encodable, Equatable, Sendable {
    let viewport: RasterMapViewExtent
    let showProfileStations: Bool
    let showTin: Bool
    let debugMode: Bool
    let renderScale: Double
    let tinOptions: TerrainInputMapTinRenderOptions?
}

enum TerrainInputMapTinSurfaceFillMode: String, CaseIterable, Encodable, Identifiable, Sendable {
    case none
    case z
    case m

    var id: String { rawValue }
    @MainActor
    var title: String {
        switch self {
        case .none: return L10n.text("No Surface Fill")
        case .z: return L10n.text("Paint Z Surface")
        case .m: return L10n.text("Paint M Surface")
        }
    }
}

struct TerrainInputMapTinRenderOptions: Encodable, Equatable, Sendable {
    var surfaceFillMode: TerrainInputMapTinSurfaceFillMode = .none
    var renderEdges = true
    var renderPoints = true
    var renderDeletedTriangles = true
    var labelTriangles = false
    var labelEdges = false
    var labelPoints = false

    private enum CodingKeys: String, CodingKey {
        case surfaceFillMode, renderEdges, renderPoints, renderDeletedTriangles
        // This request field is the source PlotOption ID; the reflected source
        // CLR property is separately reported as `LabelTris` in the response.
        case labelTriangles = "labelTriangles"
        case labelEdges, labelPoints
    }

    static let sourceDefault = TerrainInputMapTinRenderOptions()
}

struct TerrainInputMapTinPlotOptionDescriptor: Decodable, Sendable {
    let propertyName: String
    let name: String
    let label: String
    let description: String
    let value: String
    let isEnabled: Bool
    let hasDrawingImplementation: Bool
}

struct TerrainInputMapContextFeature: Decodable, Sendable {
    let id: String
    let kind: String
    let points: [TerrainMapCoordinate]
    let closed: Bool
}

struct TerrainInputMapContextData: Decodable, Sendable {
    let inputNodeID: String
    let inputIndex: Int
    let terrainPath: String
    let terrainRevision: String
    let sourceClass: String
    let features: [TerrainInputMapContextFeature]
    var leveeRenderer: TerrainInputMapLeveeRendererData? = nil

    @MainActor
    func validated(for request: TerrainInputMapContextRequest) throws -> [TerrainInputRenderedFeature] {
        guard inputNodeID == request.inputNodeID, inputIndex >= 0,
              sourceClass == request.expectedSourceClass,
              Self.canonical(terrainPath) == Self.canonical(request.expectedTerrainPath),
              Self.isSHA256(terrainRevision),
              Set(features.map(\.id)).count == features.count,
              features.allSatisfy({ feature in
                  let minimum = feature.kind == "line" ? 2 : feature.kind == "polygon" ? 3 : Int.max
                  return feature.id.hasPrefix(inputNodeID + ":feature:")
                      && feature.points.count >= minimum
                      && feature.points.allSatisfy { $0.x.isFinite && $0.y.isFinite }
                      && feature.closed == (feature.kind == "polygon")
              }) else {
            throw BackendServiceError(code: "protocolFailure",
                message: L10n.text("The selected terrain input no longer matches the current map."))
        }
        return features.map {
            TerrainInputRenderedFeature(id: $0.id, inputNodeID: inputNodeID,
                inputIndex: inputIndex, sourceClass: sourceClass, kind: $0.kind,
                points: $0.points, closed: $0.closed,
                terrainPath: Self.canonical(terrainPath), terrainRevision: terrainRevision)
        }
    }

    @MainActor
    func validatedLeveeRenderer(for request: TerrainInputMapContextRequest) throws -> TerrainInputMapLeveeRendererData? {
        guard let options = request.renderOptions else {
            guard leveeRenderer == nil else { throw invalidRendererResponse() }
            return nil
        }
        guard sourceClass == "LeveeModTerrainInputVC",
              options.showProfileStations || options.showTin,
              !options.showTin || options.debugMode,
              options.renderScale.isFinite, options.renderScale > 0, options.renderScale <= 64,
              options.showTin == (options.tinOptions != nil),
              options.tinOptions.map(Self.validTinRequest) ?? true,
              let renderer = leveeRenderer,
              renderer.viewport == options.viewport,
              renderer.tinFeatureCount >= 0 else {
            throw invalidRendererResponse()
        }

        if options.showProfileStations {
            guard let frame = renderer.profileStations else { throw invalidRendererResponse() }
            _ = try frame.validated(for: options.viewport)
        } else if renderer.profileStations != nil {
            throw invalidRendererResponse()
        }

        if options.showTin {
            if renderer.tinFeatureCount > 0 {
                guard let frame = renderer.tin, renderer.tinWarning == nil else { throw invalidRendererResponse() }
                _ = try frame.validated(for: options.viewport)
                guard let tinOptions = options.tinOptions,
                      Self.validTinDescriptors(renderer.tinPlotOptions, matching: tinOptions) else {
                    throw invalidRendererResponse()
                }
            } else {
                guard renderer.tin == nil, let warning = renderer.tinWarning, !warning.isEmpty,
                      renderer.tinPlotOptions.isEmpty else {
                    throw invalidRendererResponse()
                }
            }
        } else if renderer.tin != nil || renderer.tinFeatureCount != 0 || renderer.tinWarning != nil
                    || !renderer.tinPlotOptions.isEmpty {
            throw invalidRendererResponse()
        }
        return renderer
    }

    private static func validTinRequest(_ options: TerrainInputMapTinRenderOptions) -> Bool {
        !options.labelEdges && !options.labelPoints
    }

    private static func validTinDescriptors(_ descriptors: [TerrainInputMapTinPlotOptionDescriptor],
                                            matching options: TerrainInputMapTinRenderOptions) -> Bool {
        guard descriptors.count == 8,
              Set(descriptors.map(\.propertyName)).count == descriptors.count else { return false }
        let expected: [String: (String, String, Bool)] = [
            "PaintZ": ("PaintZ", options.surfaceFillMode == .z ? "true" : "false", true),
            "PaintM": ("PaintM", options.surfaceFillMode == .m ? "true" : "false", true),
            "RenderEdges": ("RenderEdges", options.renderEdges ? "true" : "false", true),
            "RenderPoints": ("RenderPoints", options.renderPoints ? "true" : "false", true),
            "RenderDeletedTris": ("RenderDeletedTris", options.renderDeletedTriangles ? "true" : "false", true),
            // The retained PlotOption ID is LabelTriangles, while its actual
            // CLR property (used for reflection identity) is LabelTris.
            "LabelTris": ("LabelTriangles", options.labelTriangles ? "true" : "false", true),
            "LabelEdges": ("LabelEdges", "false", false),
            "LabelPoints": ("LabelPoints", "false", false)
        ]
        return descriptors.allSatisfy { descriptor in
            guard let match = expected[descriptor.propertyName] else { return false }
            return descriptor.name == match.0 && descriptor.value == match.1
                && descriptor.isEnabled == match.2
                && descriptor.hasDrawingImplementation == match.2
        }
    }

    @MainActor
    private func invalidRendererResponse() -> BackendServiceError {
        BackendServiceError(code: "protocolFailure",
            message: L10n.text("The terrain input renderer response does not match its request."))
    }

    private static func canonical(_ path: String) -> String {
        SourceFilePaths.canonical(URL(fileURLWithPath: path))
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }
}

struct TerrainInputMapLeveeRendererData: Decodable, Sendable {
    let viewport: RasterMapViewExtent
    let profileStations: MapSourceRasterFrame?
    let tin: MapSourceRasterFrame?
    let tinFeatureCount: Int
    let tinWarning: String?
    let tinPlotOptions: [TerrainInputMapTinPlotOptionDescriptor]
}

@MainActor
protocol TerrainInputMapContextProvider {
    func renderTerrainInput(_ request: TerrainInputMapContextRequest) async throws -> TerrainInputMapContextData
}

@MainActor
struct BackendTerrainInputMapProvider: TerrainInputMapContextProvider {
    private let client: BackendProcessClient

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func renderTerrainInput(_ request: TerrainInputMapContextRequest) async throws -> TerrainInputMapContextData {
        try await client.request("map.terrainInput.render", parameters: request,
            as: TerrainInputMapContextData.self)
    }
}
