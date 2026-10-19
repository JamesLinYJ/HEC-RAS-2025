import Foundation
import Testing
@testable import HECRAS2025

struct SpatialGridOverlapSelectionTests {
    @Test
    func sourceChoicesAreUniquePerComponentAndTimestampAndRemainBoundToBandIdentity() throws {
        let firstTime = "2026-10-18T00:00:00Z"
        let secondTime = "2026-10-18T01:00:00Z"
        let laterIssue = band("source-a-band-0", dataset: "/a/grid.vrt", band: 0, time: firstTime,
            issue: "2026-10-17T23:00:00Z")
        let earlierIssue = band("source-b-band-0", dataset: "/b/grid.vrt", band: 0, time: firstTime,
            issue: "2026-10-17T22:00:00Z")
        let nextTimestep = band("source-a-band-1", dataset: "/a/grid.vrt", band: 1, time: secondTime,
            issue: "2026-10-17T23:00:00Z")
        let windX = band("wind-x", dataset: "/wind/x.vrt", band: 0, time: firstTime,
            issue: nil, component: "X")
        let windY = band("wind-y", dataset: "/wind/y.vrt", band: 0, time: firstTime,
            issue: nil, component: "Y")
        let input = [laterIssue, earlierIssue, nextTimestep, windX, windY]
        let firstTimestamp = try #require(SpatialGridBand.date(firstTime))
        let secondTimestamp = try #require(SpatialGridBand.date(secondTime))

        let initial = SpatialGridOverlapSelection.normalized(input, preserving: [])
        let valueGroup = try #require(SpatialGridOverlapSelection.groups(in: initial).first {
            $0.component == "Value" && $0.time == firstTimestamp
        })
        #expect(valueGroup.bands.map(\.id) == [earlierIssue.id, laterIssue.id])
        #expect(valueGroup.selectedBandID == earlierIssue.id)
        #expect(valueGroup.selectedBandIDs.count == 1)
        #expect(SpatialGridOverlapSelection.groups(in: initial).first { $0.component == "Value" && $0.time == secondTimestamp }?.selectedBandID == nextTimestep.id)
        #expect(SpatialGridOverlapSelection.groups(in: initial).first { $0.component == "X" }?.selectedBandID == windX.id)
        #expect(SpatialGridOverlapSelection.groups(in: initial).first { $0.component == "Y" }?.selectedBandID == windY.id)

        let changed = try #require(SpatialGridOverlapSelection.selecting(laterIssue.id, in: valueGroup.id, from: initial))
        let changedGroup = try #require(SpatialGridOverlapSelection.groups(in: changed).first { $0.id == valueGroup.id })
        #expect(changedGroup.selectedBandID == laterIssue.id)
        #expect(changedGroup.selectedBandIDs.count == 1)
        #expect(SpatialGridOverlapSelection.groups(in: changed).first { $0.component == "Value" && $0.time == secondTimestamp }?.selectedBandID == nextTimestep.id)

        let cleared = try #require(SpatialGridOverlapSelection.selecting(nil, in: valueGroup.id, from: changed))
        #expect(SpatialGridOverlapSelection.groups(in: cleared).first { $0.id == valueGroup.id }?.selectedBandID == nil)
        #expect(SpatialGridOverlapSelection.groups(in: cleared).first { $0.component == "Value" && $0.time == secondTimestamp }?.selectedBandID == nextTimestep.id)

        let refreshed = SpatialGridOverlapSelection.normalized(Array(changed.reversed()), preserving: changed)
        #expect(SpatialGridOverlapSelection.groups(in: refreshed).first { $0.id == valueGroup.id }?.selectedBandID == laterIssue.id)

        let stale = changed.map { source -> SpatialGridBand in
            guard source.id == laterIssue.id else { return source }
            return SpatialGridBand(id: source.id, file: source.file, dataset: source.dataset, band: source.band,
                revision: "new-source-revision", time: source.time, issueTime: source.issueTime, units: source.units,
                dataType: source.dataType, included: source.included, component: source.component)
        }
        let afterSourceChange = SpatialGridOverlapSelection.normalized(stale, preserving: changed)
        #expect(SpatialGridOverlapSelection.groups(in: afterSourceChange).first { $0.id == valueGroup.id }?.selectedBandID == nil)
    }

    @Test
    func latestAndEarliestIssueSelectionAffectOnlyResolvableOverlaps() throws {
        let timestamp = "2026-10-18T00:00:00Z"
        let early = band("early", dataset: "/early.vrt", band: 0, time: timestamp, issue: "2026-10-17T18:00:00Z")
        let latest = band("latest", dataset: "/latest.vrt", band: 0, time: timestamp, issue: "2026-10-17T23:00:00Z")
        let unknown = band("unknown", dataset: "/unknown.vrt", band: 0, time: timestamp, issue: nil, included: false)
        let resolvable = [early, latest]

        let selectedLatest = SpatialGridOverlapSelection.selectingIssueTimes(in: resolvable, latest: true)
        #expect(SpatialGridOverlapSelection.groups(in: selectedLatest).first?.selectedBandID == latest.id)
        let selectedEarliest = SpatialGridOverlapSelection.selectingIssueTimes(in: resolvable, latest: false)
        #expect(SpatialGridOverlapSelection.groups(in: selectedEarliest).first?.selectedBandID == early.id)

        let unresolved = SpatialGridOverlapSelection.selectingIssueTimes(in: [early, unknown], latest: true)
        #expect(SpatialGridOverlapSelection.groups(in: unresolved).first?.selectedBandID == early.id)
    }

    private func band(_ id: String, dataset: String, band: Int, time: String, issue: String?, component: String = "Value",
                      included: Bool = true) -> SpatialGridBand {
        SpatialGridBand(id: id, file: dataset, dataset: dataset, band: band, revision: "source-revision",
            time: time, issueTime: issue, units: "Pa", dataType: "inst-val", included: included, component: component)
    }
}
