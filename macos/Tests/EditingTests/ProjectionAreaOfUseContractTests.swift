import Foundation
import Testing
@testable import HECRAS2025

struct ProjectionAreaOfUseContractTests {
    @Test func evaluationKeepsAcceptanceSeparateFromSourceValidationAndRetainsCRS() throws {
        let json = Data(#"""
        {
          "isValid": false,
          "name": "WGS 84 / Pseudo-Mercator",
          "units": "SI",
          "unitName": "metre",
          "epsgCode": 3857,
          "utmZone": null,
          "wkt": "PROJCRS[\"WGS 84 / Pseudo-Mercator\"]",
          "error": "The projection cannot be used by the project.",
          "normalizedType": "Proj",
          "normalizedValue": "+proj=merc +datum=WGS84",
          "validity": "Unsupported",
          "isVertical": false,
          "isProjected": true,
          "areaOfUse": {
            "geographic": {"left": -180.0, "right": 180.0, "bottom": -85.06, "top": 85.06},
            "projected": {"left": -20037508.34, "right": 20037508.34, "bottom": -20048966.1, "top": 20048966.1}
          }
        }
        """#.utf8)

        let evaluation = try JSONDecoder().decode(ProjectionEvaluation.self, from: json)

        #expect(!evaluation.isValid)
        #expect(evaluation.validity == "Unsupported")
        #expect(evaluation.isProjected == true)
        #expect(evaluation.normalizedValue == "+proj=merc +datum=WGS84")
        #expect(evaluation.areaOfUse?.geographic.left == -180)
        #expect(evaluation.areaOfUse?.projected.top == 20048966.1)
    }

    @Test func reprojectionIdentifySummaryCarriesNullableSourceArea() throws {
        let json = Data(#"""
        {
          "recognizedPath": "/tmp/source.prj",
          "wkt": "PROJCRS[\"Source CRS\"]",
          "projectionSummary": {
            "option": "Custom",
            "projectionName": "Source CRS",
            "validity": "Valid",
            "unitName": "metre",
            "isVertical": false,
            "isProjected": true,
            "epsgCode": "32650",
            "utmZone": "50 N",
            "areaOfUse": null
          }
        }
        """#.utf8)

        let identify = try JSONDecoder().decode(ReprojectionIdentifySnapshot.self, from: json)

        #expect(identify.projectionSummary?.validity == "Valid")
        #expect(identify.projectionSummary?.areaOfUse == nil)
        #expect(identify.projectionSummary?.unitName == "metre")
    }

    @Test func olderEvaluationResponsesRemainDecodableWithoutAreaMetadata() throws {
        let json = Data(#"""
        {
          "isValid": true,
          "name": "Local",
          "units": "SI",
          "unitName": "SI",
          "epsgCode": null,
          "utmZone": null,
          "wkt": null,
          "error": null,
          "normalizedType": "Local",
          "normalizedValue": "SI"
        }
        """#.utf8)

        let evaluation = try JSONDecoder().decode(ProjectionEvaluation.self, from: json)

        #expect(evaluation.isValid)
        #expect(evaluation.areaOfUse == nil)
        #expect(evaluation.validity == nil)
    }
}
