import AppKit
import CoreGraphics
import Foundation
import RASWorkspaceCore
import SwiftUI

/// Saved-map request owner shared by the retained vector plot routes. The
/// explicit Result slots make a source MapTree read resolve the same embedded
/// rows as the visible map rather than silently falling back to Latest.
struct VectorPlotMapRequest: Encodable, Sendable {
    let projectPath: String
    let projectXml: String
    let projectXmlSHA: String
    let mapID: String
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let expectedVisualizationRevision: String
    let resultSelectionOverrides: [MapTreeResultSelectionOverride]
    var coreLayerContext: CoreLayerRequestContext? = nil
}

struct VectorPlotOptionChoicePayload: Decodable, Sendable {
    let value: String
    let label: String
}

struct VectorPlotOptionPayload: Decodable, Sendable {
    let propertyName: String
    let name: String
    let label: String
    let description: String
    let kind: String
    let value: String
    let enumValues: [VectorPlotOptionChoicePayload]
    let isEnabled: Bool
    let enabledIf: String?
}

struct VectorPlotOptionsResponse: Decodable, Sendable {
    let mapID: String
    let layerID: String
    let sourcePath: String
    let sourceRevision: String
    let visualizationRevision: String
    let plotOptions: [VectorPlotOptionPayload]
}

struct VectorPlotOptionsRequest: Encodable, Sendable {
    let map: VectorPlotMapRequest
    let node: CatalogTreeNodeLocator
    let layerID: String
    let expectedFamily: MapSourceFamilyCapture?
    let sourceRevision: String
    var plotOptions: [String: String]? = nil
}

struct VectorPlotStyleOverride: Encodable, Sendable {
    let sourceFeatureIndex: Int
    let values: VectorStyleValues
}

struct VectorPlotStyle: Encodable, Sendable {
    let definitionID: String
    let base: VectorStyleValues
    let sourceOverrides: [VectorPlotStyleOverride]
}

struct VectorPlotRenderRequest: Encodable, Sendable {
    let map: VectorPlotMapRequest
    let node: CatalogTreeNodeLocator
    let layerID: String
    let expectedFamily: MapSourceFamilyCapture?
    let sourceRevision: String
    let viewport: RasterMapViewExtent
    let plotOptions: [String: String]
    let styles: [VectorPlotStyle]
    /// Source pen/point scale in the returned raster's pixels. Sampling size
    /// and source drawing scale are separate because the raster may be bounded.
    let renderScale: Double
}

struct VectorPlotRenderResponse: Decodable, Sendable {
    let mapID: String
    let layerID: String
    let sourcePath: String
    let sourceRevision: String
    let visualizationRevision: String
    let viewport: RasterMapViewExtent
    let pixelWidth: Int
    let pixelHeight: Int
    let rgba: Data
    let labels: [MapVectorPlotLabel]
    let plotOptions: [VectorPlotOptionPayload]
    let renderScale: Double
}

/// World-coordinate rectangle captured from the live map camera. The backend
/// renderer uses this same rectangle and returns it verbatim with its pixels.
struct MapVectorPlotViewport: Codable, Hashable, Sendable {
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double

    init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
    }

    init(_ extent: RasterMapViewExtent) {
        self.init(minX: extent.minX, minY: extent.minY,
                  maxX: extent.maxX, maxY: extent.maxY)
    }

    var isFiniteAndOrdered: Bool {
        minX.isFinite && minY.isFinite && maxX.isFinite && maxY.isFinite
            && minX < maxX && minY < maxY
    }

    func matches(_ other: Self) -> Bool {
        guard isFiniteAndOrdered, other.isFiniteAndOrdered else { return false }
        return Self.close(minX, other.minX) && Self.close(minY, other.minY)
            && Self.close(maxX, other.maxX) && Self.close(maxY, other.maxY)
    }

    private static func close(_ lhs: Double, _ rhs: Double) -> Bool {
        let scale = max(1, abs(lhs), abs(rhs))
        return abs(lhs - rhs) <= scale * 1e-10
    }
}

struct MapVectorPlotCoordinate: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
}

struct MapVectorPlotLabel: Codable, Equatable, Sendable {
    let text: String
    let point: MapVectorPlotCoordinate
    let polyline: [MapVectorPlotCoordinate]
}

/// An immutable CPU-rendered replacement for one exact source map-layer draw.
/// It stays separate from MapVectorLayer, so it cannot enter source selection,
/// feature hit-testing, editing, export, or persisted .vis state.
struct VectorPlotRenderedLayer: Identifiable, @unchecked Sendable {
    let mapID: UUID
    let sourceLayerID: String
    let sourceRevision: String
    let visualizationRevision: String
    let viewport: MapVectorPlotViewport
    let pixelWidth: Int
    let pixelHeight: Int
    /// Premultiplied RGBA bytes, produced by the retained source PlotRequest.
    let rgba: Data
    let labels: [MapVectorPlotLabel]
    /// Constructed once per accepted backend response and reused by Canvas.
    let image: CGImage

    var id: String { sourceLayerID }

    init(mapID: UUID, sourceLayerID: String, sourceRevision: String,
         visualizationRevision: String, viewport: MapVectorPlotViewport,
         pixelWidth: Int, pixelHeight: Int, rgba: Data,
         labels: [MapVectorPlotLabel]) throws {
        let pixels = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        let byteCount = pixels.partialValue.multipliedReportingOverflow(by: 4)
        let rowBytes = pixelWidth.multipliedReportingOverflow(by: 4)
        guard !sourceLayerID.isEmpty, !sourceRevision.isEmpty,
              !visualizationRevision.isEmpty, viewport.isFiniteAndOrdered,
              pixelWidth > 0, pixelHeight > 0, !pixels.overflow, !byteCount.overflow,
              !rowBytes.overflow,
              rgba.count == byteCount.partialValue,
              let provider = CGDataProvider(data: rgba as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: pixelWidth, height: pixelHeight,
                  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes.partialValue,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                      | CGBitmapInfo.byteOrder32Big.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false,
                  intent: .defaultIntent) else {
            throw ProjectFileError.invalid("Invalid source vector plot pixels or owner identity.")
        }
        self.mapID = mapID; self.sourceLayerID = sourceLayerID
        self.sourceRevision = sourceRevision; self.visualizationRevision = visualizationRevision
        self.viewport = viewport; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.rgba = rgba; self.labels = labels; self.image = image
    }

    func matches(mapID: UUID, layerID: String, sourceRevision: String,
                 visualizationRevision: String, viewport: MapVectorPlotViewport,
                 pixelWidth: Int, pixelHeight: Int) -> Bool {
        self.mapID == mapID && sourceLayerID == layerID
            && self.sourceRevision.caseInsensitiveCompare(sourceRevision) == .orderedSame
            && self.visualizationRevision.caseInsensitiveCompare(visualizationRevision) == .orderedSame
            && self.viewport.matches(viewport)
            && self.pixelWidth == pixelWidth && self.pixelHeight == pixelHeight
    }
}

/// A non-modal notice for an explicitly selected source PlotOption whose CPU
/// renderer failed. The map keeps its native drawing and reports the real
/// backend diagnostic so an Apply cannot appear to have changed the display.
@MainActor
struct VectorPlotRenderStatusBanner: View {
    @ObservedObject var provider: WorkspaceVectorSymbologyProvider
    let mapID: UUID

    var body: some View {
        let failures = provider.plotFailures(mapID: mapID)
        if failures.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(failures) { failure in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(L10n.text("The source vector renderer could not update this layer."),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                        Text(failure.layerName).font(.caption)
                        Text(L10n.text(failure.message)).font(.caption2).textSelection(.enabled)
                    }
                }
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.orange.opacity(0.6)))
            .accessibilityElement(children: .contain)
        }
    }
}
