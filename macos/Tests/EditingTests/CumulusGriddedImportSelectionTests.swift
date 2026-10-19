import Testing
@testable import HECRAS2025

struct CumulusGriddedImportSelectionTests {
    @Test
    func eachValidTimeDefaultsToOneLatestIssueAndSkipDoesNotChangeOtherTimes() throws {
        let time0 = "2026-10-18T00:00:00Z"
        let time1 = "2026-10-18T01:00:00Z"
        let oldIssue = source("old", time: time0, version: "2026-10-17T21:00:00Z")
        let latestIssue = source("latest", time: time0, version: "2026-10-17T23:00:00Z")
        let nextTime = source("next", time: time1, version: time1)

        let groups = CumulusGridSourceProjection.groups([nextTime, oldIssue, latestIssue])
        #expect(groups.map(\.datetimeUtc) == [time0, time1])
        #expect(groups[0].options.map(\.id) == ["latest", "old"])

        let defaults = CumulusGridSourceProjection.defaultSelections([nextTime, oldIssue, latestIssue])
        #expect(defaults == [time0: "latest", time1: "next"])
        #expect(CumulusGridSourceProjection.selectedSources(in: groups, selections: defaults) == [
            CumulusGridImportSource(id: "latest", datetimeUtc: time0, versionUtc: "2026-10-17T23:00:00Z"),
            CumulusGridImportSource(id: "next", datetimeUtc: time1, versionUtc: time1)
        ])

        let skippedFirstTime = CumulusGridSourceProjection.selectedSources(in: groups,
            selections: [time1: "next"])
        #expect(skippedFirstTime == [CumulusGridImportSource(id: "next", datetimeUtc: time1, versionUtc: time1)])
    }

    @Test
    func equalIssueTimesUseStableSourceIdentityAndUnknownSelectionIsNotSubstituted() throws {
        let time = "2026-10-18T00:00:00Z"
        let second = source("source-b", time: time, version: "2026-10-17T23:00:00Z")
        let first = source("source-a", time: time, version: "2026-10-17T23:00:00Z")
        let groups = CumulusGridSourceProjection.groups([second, first])
        #expect(groups.first?.options.map(\.id) == ["source-b", "source-a"])

        let selected = CumulusGridSourceProjection.selectedSources(in: groups, selections: [time: "stale-id"])
        #expect(selected.isEmpty)
    }

    private func source(_ id: String, time: String, version: String) -> CumulusGridSourceOption {
        CumulusGridSourceOption(id: id, datetimeUtc: time, versionUtc: version)
    }
}
