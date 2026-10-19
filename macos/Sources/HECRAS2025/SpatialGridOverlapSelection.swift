import Foundation
import RASWorkspaceCore

struct SpatialGridImportSource: Identifiable, Equatable, Sendable {
    let id: String
    let file: String
    let dataset: String
    let revision: String
    let bandCount: Int
}

struct SpatialGridTimestampSourceGroup: Identifiable, Equatable, Sendable {
    let component: String
    let time: Date
    let bands: [SpatialGridBand]

    var id: String { component + "|" + String(time.timeIntervalSince1970.bitPattern, radix: 16) }
    var selectedBandIDs: [String] { bands.filter(\.included).map(\.id) }
    var selectedBandID: String? { selectedBandIDs.first }
}

enum SpatialGridOverlapSelection {
    private struct Key: Hashable {
        let component: String
        let time: Date
    }

    private struct IndexedBand {
        let index: Int
        let band: SpatialGridBand
        let time: Date
    }

    private struct SourceOrder {
        let sourceID: String
        let firstIssueTime: Date?
        let firstIndex: Int
    }

    static func groups(in bands: [SpatialGridBand]) -> [SpatialGridTimestampSourceGroup] {
        let indexed = bands.enumerated().compactMap { index, band -> IndexedBand? in
            guard let time = band.time.flatMap(SpatialGridBand.date) else { return nil }
            return IndexedBand(index: index, band: band, time: time)
        }
        let sourceRanks = sourceRanks(in: indexed)
        let grouped = Dictionary(grouping: indexed) { Key(component: $0.band.component, time: $0.time) }
        return grouped.map { key, members in
            let candidates = members.sorted { left, right in
                let leftRank = sourceRanks[sourceIdentity(for: left.band)] ?? Int.max
                let rightRank = sourceRanks[sourceIdentity(for: right.band)] ?? Int.max
                if leftRank != rightRank { return leftRank < rightRank }
                if left.band.band != right.band.band { return left.band.band < right.band.band }
                return left.index < right.index
            }.map(\.band)
            return SpatialGridTimestampSourceGroup(component: key.component, time: key.time, bands: candidates)
        }.sorted { left, right in
            if left.time != right.time { return left.time < right.time }
            return left.component < right.component
        }
    }

    /// Lists exact input datasets. File path, dataset selector, and source
    /// revision all participate in identity so repeated display names cannot
    /// select keyframes from a different input file or a refreshed source.
    static func sources(in bands: [SpatialGridBand]) -> [SpatialGridImportSource] {
        struct IndexedSource {
            let sourceID: String
            let firstIndex: Int
            let representative: SpatialGridBand
            var bandCount: Int
        }
        var byID: [String: IndexedSource] = [:]
        for (index, band) in bands.enumerated() where band.time.flatMap(SpatialGridBand.date) != nil {
            let id = sourceIdentity(for: band)
            if var existing = byID[id] {
                existing.bandCount += 1
                byID[id] = existing
            } else {
                byID[id] = IndexedSource(sourceID: id, firstIndex: index,
                    representative: band, bandCount: 1)
            }
        }
        return byID.values.sorted { $0.firstIndex < $1.firstIndex }.map { source in
            SpatialGridImportSource(id: source.sourceID, file: source.representative.file,
                dataset: source.representative.dataset, revision: source.representative.revision,
                bandCount: source.bandCount)
        }
    }

    /// Selects this exact source at every component/time group where it has
    /// exactly one matching band. Groups it does not cover keep their current
    /// selection, matching the original timeline's SelectAllKeyframes action.
    /// Ambiguous duplicate bands are left untouched rather than guessed.
    static func selectingAllKeyframes(from sourceID: String,
                                      in bands: [SpatialGridBand]) -> [SpatialGridBand]? {
        guard bands.contains(where: { sourceIdentity(for: $0) == sourceID }) else { return nil }
        var result = bands
        for group in groups(in: bands) {
            let candidates = group.bands.filter { sourceIdentity(for: $0) == sourceID }
            guard candidates.count == 1,
                  let updated = selecting(candidates[0].id, in: group.id, from: result) else { continue }
            result = updated
        }
        return result
    }

    /// Preserve explicit selections by stable band identity and source revision.
    /// A new timestep defaults to the first retained-source ordered candidate,
    /// matching the original timeline's initial source choice.
    static func normalized(_ bands: [SpatialGridBand], preserving previous: [SpatialGridBand]) -> [SpatialGridBand] {
        var result = bands
        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        for group in groups(in: result) {
            let matchingPrevious = group.bands.compactMap { band -> SpatialGridBand? in
                guard let old = previousByID[band.id], old.revision == band.revision,
                      old.component == band.component,
                      old.time.flatMap(SpatialGridBand.date) == group.time else { return nil }
                return old
            }
            let selected: String?
            if !matchingPrevious.isEmpty {
                selected = group.bands.first { candidate in
                    matchingPrevious.contains(where: { $0.id == candidate.id && $0.included })
                }?.id
            } else {
                let serverSelections = group.bands.filter(\.included)
                selected = serverSelections.count == 1 ? serverSelections.first?.id : group.bands.first?.id
            }
            let candidateIDs = Set(group.bands.map(\.id))
            for index in result.indices where candidateIDs.contains(result[index].id) {
                result[index].included = result[index].id == selected
            }
        }
        return result
    }

    static func selecting(_ bandID: String?, in groupID: String, from bands: [SpatialGridBand]) -> [SpatialGridBand]? {
        guard let group = groups(in: bands).first(where: { $0.id == groupID }),
              bandID == nil || group.bands.contains(where: { $0.id == bandID }) else { return nil }
        let groupIDs = Set(group.bands.map(\.id))
        return bands.map { band in
            guard groupIDs.contains(band.id) else { return band }
            var result = band
            result.included = band.id == bandID
            return result
        }
    }

    static func selectingIssueTimes(in bands: [SpatialGridBand], latest: Bool) -> [SpatialGridBand] {
        var result = bands
        for group in groups(in: result) where group.bands.count > 1 {
            guard group.bands.allSatisfy({ $0.issueTime.flatMap(SpatialGridBand.date) != nil }) else { continue }
            var winner = group.bands[0]
            for candidate in group.bands.dropFirst() {
                let candidateTime = candidate.issueTime.flatMap(SpatialGridBand.date)!
                let winnerTime = winner.issueTime.flatMap(SpatialGridBand.date)!
                if latest ? candidateTime > winnerTime : candidateTime < winnerTime {
                    winner = candidate
                }
            }
            guard let updated = selecting(winner.id, in: group.id, from: result) else { continue }
            result = updated
        }
        return result
    }

    private static func sourceRanks(in bands: [IndexedBand]) -> [String: Int] {
        let datasets = Dictionary(grouping: bands, by: { sourceIdentity(for: $0.band) }).map { sourceID, members -> SourceOrder in
            let firstSourceBand = members.first(where: { $0.band.band == 0 }) ?? members.min(by: { $0.index < $1.index })!
            return SourceOrder(sourceID: sourceID, firstIssueTime: firstSourceBand.band.issueTime.flatMap(SpatialGridBand.date),
                firstIndex: members.map(\.index).min() ?? Int.max)
        }.sorted { left, right in
            switch (left.firstIssueTime, right.firstIssueTime) {
            case let (leftTime?, rightTime?) where leftTime != rightTime: return leftTime < rightTime
            case (nil, .some): return true
            case (.some, nil): return false
            default: return left.firstIndex < right.firstIndex
            }
        }
        return Dictionary(uniqueKeysWithValues: datasets.enumerated().map { ($0.element.sourceID, $0.offset) })
    }

    private static func sourceIdentity(for band: SpatialGridBand) -> String {
        let file = SourceFilePaths.canonical(URL(fileURLWithPath: band.file))
        return [file, band.dataset, band.revision]
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
    }
}
