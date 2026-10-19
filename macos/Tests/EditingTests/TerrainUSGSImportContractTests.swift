import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct TerrainUSGSImportContractTests {
    @Test
    func rawSourcePresetRetainsScaleBitsAcrossLocalizedEditorTextAndRejectsChangedSource() throws {
        let revision = String(repeating: "a", count: 64)
        let scale = Double(Float(bitPattern: 0x3f9e0652))
        let preset = TerrainInputImportInitialSettings(sourceRevision: revision,
            scaleFactor: scale, rounding: "ThirtySeconds")
        let source = TerrainInputImportSource(id: "raw", path: "/tmp/raw.tif", name: "raw.tif",
            revision: revision, isValid: true, error: nil, width: 16, height: 16, bandCount: 1,
            cellSize: 1, projection: nil, minimum: 42, maximum: 42, defaultScaleFactor: 1)
        let selection = try preset.selection(for: source)
        #expect(selection.unitConversion == "Custom" && selection.rounding == "ThirtySeconds")
        #expect(selection.customScaleFactor == scale)
        for localeID in ["en_US", "zh_CN", "fr_FR"] {
            let locale = Locale(identifier: localeID)
            let parsed = try #require(OriginalUnitNumberInputCodec.parse(preset.scaleText(locale: locale), locale: locale))
            #expect(Float(parsed).bitPattern == Float(scale).bitPattern)
        }
        let stale = TerrainInputImportInitialSettings(sourceRevision: String(repeating: "b", count: 64),
            scaleFactor: scale, rounding: "ThirtySeconds")
        #expect(throws: ProjectFileError.self) { try stale.selection(for: source) }
    }

    @Test
    func sourceTransferDecodesUSGSUnitAndRoundingDefaults() throws {
        let sourceRevision = String(repeating: "a", count: 64)
        let payload = """
        {
          "state":"completed",
          "cleanupToken":"a3e1b1a154d94f97a41fbb908e29d847",
          "files":[{
            "productId":"opaque-product-id",
            "title":"1/3 arc second elevation DEM",
            "filePath":"/tmp/usgs/source.tif",
            "sourceRevision":"\(sourceRevision)",
            "defaultScaleFactor":3.28084,
            "defaultRounding":"ThirtySeconds"
          }],
          "assetPath":"/project/terrain.hdf",
          "projectPath":"/project/project.ras",
          "sourceRevision":"\(sourceRevision)",
          "inputId":"terrain-input-id",
          "extent":{"minX":10,"maxX":11,"minY":20,"maxY":21},
          "stitchTiles":true
        }
        """

        let transfer = try JSONDecoder().decode(TerrainUSGSDownloadData.self, from: Data(payload.utf8))
        let file = try #require(transfer.files.first)
        #expect(transfer.state == "completed")
        #expect(transfer.cleanupToken == "a3e1b1a154d94f97a41fbb908e29d847")
        #expect(file.productId == "opaque-product-id")
        #expect(file.sourceRevision == sourceRevision)
        #expect(file.defaultScaleFactor == 3.28084)
        #expect(file.defaultRounding == "ThirtySeconds")
        #expect(transfer.extent.isFiniteAndOrdered)
        #expect(transfer.stitchTiles)
    }

    @Test
    func queryExtentAcceptsOnlyFiniteOrderedProjectCoordinates() {
        #expect(TerrainUSGSQueryExtent(minX: 10, maxX: 11, minY: 20, maxY: 21).isFiniteAndOrdered)
        #expect(!TerrainUSGSQueryExtent(minX: 11, maxX: 10, minY: 20, maxY: 21).isFiniteAndOrdered)
        #expect(!TerrainUSGSQueryExtent(minX: .nan, maxX: 11, minY: 20, maxY: 21).isFiniteAndOrdered)
    }
}
