import Testing
@testable import HECRAS2025

struct SpatialGridAllKeyframesSelectionTests {
    @Test
    func selectsExactSourceAcrossCoveredTimesAndPreservesUncoveredGroups() throws {
        let time0 = "2026-10-18T00:00:00Z"
        let time1 = "2026-10-18T01:00:00Z"
        let time2 = "2026-10-18T02:00:00Z"
        let sourceA0 = band("a-0", file: "/tmp/a/grid.vrt", dataset: "shared-name", revision: "rev-a",
            band: 0, time: time0, issue: "2026-10-17T21:00:00Z", included: false)
        let sourceB0 = band("b-0", file: "/tmp/b/grid.vrt", dataset: "shared-name", revision: "rev-b",
            band: 0, time: time0, issue: "2026-10-17T22:00:00Z", included: true)
        let sourceA1 = band("a-1", file: "/tmp/a/grid.vrt", dataset: "shared-name", revision: "rev-a",
            band: 1, time: time1, issue: "2026-10-17T21:00:00Z", included: false)
        let refreshedA1 = band("a-new-1", file: "/tmp/a/grid.vrt", dataset: "shared-name", revision: "rev-new",
            band: 1, time: time1, issue: "2026-10-17T23:00:00Z", included: true)
        let sourceB2 = band("b-2", file: "/tmp/b/grid.vrt", dataset: "shared-name", revision: "rev-b",
            band: 2, time: time2, issue: "2026-10-17T22:00:00Z", included: true)
        let input = [sourceA0, sourceB0, sourceA1, refreshedA1, sourceB2]

        let sources = SpatialGridOverlapSelection.sources(in: input)
        #expect(sources.count == 3)
        let exactA = try #require(sources.first { $0.file == "/tmp/a/grid.vrt" && $0.revision == "rev-a" })
        let updated = try #require(SpatialGridOverlapSelection.selectingAllKeyframes(from: exactA.id, in: input))

        #expect(updated.first { $0.id == sourceA0.id }?.included == true)
        #expect(updated.first { $0.id == sourceB0.id }?.included == false)
        #expect(updated.first { $0.id == sourceA1.id }?.included == true)
        #expect(updated.first { $0.id == refreshedA1.id }?.included == false)
        #expect(updated.first { $0.id == sourceB2.id }?.included == true)
        #expect(SpatialGridOverlapSelection.groups(in: updated).allSatisfy { $0.selectedBandIDs.count <= 1 })
    }

    private func band(_ id: String, file: String, dataset: String, revision: String,
                      band: Int, time: String, issue: String, included: Bool) -> SpatialGridBand {
        SpatialGridBand(id: id, file: file, dataset: dataset, band: band, revision: revision,
            time: time, issueTime: issue, units: "mm", dataType: "per-cum",
            included: included, component: "Value")
    }
}
