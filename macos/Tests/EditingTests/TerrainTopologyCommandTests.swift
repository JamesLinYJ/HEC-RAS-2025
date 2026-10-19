import Foundation
import Testing
@testable import HECRAS2025

struct TerrainTopologyCommandTests {
    @Test
    func splitAndMetadataCommandsKeepSourceOperationPayload() throws {
        let split = TerrainTopologyCommand(operation: .split,
            featureIDs: ["terrain-topology:input:arc:4"],
            points: [.init(x: 12.5, y: 8.25)], mapCellSize: 0.5, splitMode: .atVertex)
        let splitObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(split)) as? [String: Any])
        #expect(splitObject["operation"] as? String == "split")
        #expect(splitObject["featureIDs"] as? [String] == ["terrain-topology:input:arc:4"])
        #expect(splitObject["splitMode"] as? String == "AtVertex")
        #expect(splitObject["mapCellSize"] as? Double == 0.5)
        #expect((splitObject["points"] as? [[String: Double]])?.first?["x"] == 12.5)

        let metadata = TerrainTopologyCommand(operation: .setMetadata,
            featureIDs: ["terrain-topology:input:arc:4"], metadataKind: "arc",
            metadataColumn: "Name", metadataValue: "Updated channel")
        let metadataObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
        #expect(metadataObject["operation"] as? String == "setMetadata")
        #expect(metadataObject["metadataKind"] as? String == "arc")
        #expect(metadataObject["metadataColumn"] as? String == "Name")
        #expect(metadataObject["metadataValue"] as? String == "Updated channel")
    }

    @Test
    func regionDecodingPreservesOuterAndHoleRingsAndSupportsOlderPayloads() throws {
        let regionID = "terrain-topology:input:region:2"
        let withHole = """
        {
          "id":"\(regionID)","kind":"region","points":[{"x":0,"y":0},{"x":20,"y":0},{"x":20,"y":20},{"x":0,"y":20}],
          "controlPointIndex":0,"rings":[
            [{"x":0,"y":0},{"x":20,"y":0},{"x":20,"y":20},{"x":0,"y":20}],
            [{"x":7,"y":7},{"x":7,"y":13},{"x":13,"y":13},{"x":13,"y":7}]
          ]
        }
        """
        let region = try JSONDecoder().decode(TerrainTopologyFeature.self, from: Data(withHole.utf8))
        #expect(region.rings?.count == 2)
        #expect(region.rings?.first?.count == 4)
        #expect(region.rings?.last?.count == 4)

        let legacy = """
        {"id":"\(regionID)","kind":"region","points":[{"x":0,"y":0},{"x":20,"y":0},{"x":20,"y":20}]}
        """
        let decodedLegacy = try JSONDecoder().decode(TerrainTopologyFeature.self, from: Data(legacy.utf8))
        #expect(decodedLegacy.rings == nil)
    }
}
