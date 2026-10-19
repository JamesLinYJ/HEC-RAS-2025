import Foundation
import XCTest
@testable import HECRAS2025

final class MapRasterLayerImportContractTests: XCTestCase {
    func testInspectionKeepsOriginalSupportedMapTypeAndExactManifest() throws {
        let json = """
        {
          "sourcePath":"/tmp/classes.img",
          "sourceCanonicalPath":"/tmp/classes.img",
          "sourceRevision":"\(String(repeating: "A", count: 64))",
          "driver":"HFA",
          "dataType":"System.UInt32",
          "width":32,
          "height":24,
          "bandCount":1,
          "mapLayerType":"DiscreteRasterMapLayer",
          "supportedMapLayerTypes":["DiscreteRasterMapLayer"],
          "projectionWKT":null,
          "unitSystem":null,
          "cellSizeX":10.0,
          "canRenderPreview":true,
          "info":{"fileName":"classes.img","directory":"/tmp","rasterProjection":"None","projectionFriendlyText":"None","overviewsCount":0,"overviews":[],"cellSize":"10.00","size":"1 KB","uncompressedSize":"3 KB","compressionRatio":"3x","driver":"HFA","bandCount":1,"unitSystem":null},
          "stats":{"min":"1","max":"255","mean":"4","standardDeviation":"2"}
        }
        """
        let result = try JSONDecoder().decode(MapRasterLayerInspectResult.self, from: Data(json.utf8))
        XCTAssertEqual(result.mapLayerType, "DiscreteRasterMapLayer")
        XCTAssertEqual(result.supportedMapLayerTypes, ["DiscreteRasterMapLayer"])
        XCTAssertEqual(result.sourceRevision.count, 64)
        XCTAssertEqual(result.info.driver, "HFA")
    }

    func testPreviewRequiresAWellFormedRGBAFrame() throws {
        let payload = MapRasterLayerImagePayload(id: "preview:revision", sourceMapID: nil,
            name: "rgb", width: 1, height: 1, rgba: Data([255, 0, 0, 255]),
            minX: 0, minY: 0, maxX: 1, maxY: 1)
        XCTAssertNil(payload.sourceMapID)
        XCTAssertEqual(payload.rgba.count, payload.width * payload.height * 4)
    }
}
