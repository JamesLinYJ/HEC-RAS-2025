import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class GeometryCulvertMapEditProvider: GeometryCulvertProvider {
    private(set) var mutations: [GeometryCulvertMutation] = []
    private var current: GeometryCulvertSnapshot

    init(hasDimensions: Bool = true) {
        let points: [GeometryCulvertCoordinate] = hasDimensions
            ? [GeometryCulvertCoordinate(x: 10, y: 20, z: "3.5", m: "18"),
               GeometryCulvertCoordinate(x: 16, y: 23, z: "2.5", m: "25")]
            : [GeometryCulvertCoordinate(x: 10, y: 20), GeometryCulvertCoordinate(x: 13, y: 22),
               GeometryCulvertCoordinate(x: 16, y: 20), GeometryCulvertCoordinate(x: 19, y: 22),
               GeometryCulvertCoordinate(x: 22, y: 20)]
        let row = GeometryCulvertFeatureRow(id: "barrel:source:7", fid: 7,
            values: ["Name": "West barrel", "BarrelPropertyName": "Round",
                "UpstreamInvert": "12.25", "DownstreamInvert": "11.5",
                "UpstreamOpeningName": "Headwall", "DownstreamOpeningName": "Wingwall"],
            polyline: points)
        current = Self.snapshot(revision: "source-sha", draftState: "clean", isDirty: false, rows: [row])
    }

    func modelRequest(for asset: ProjectAsset) -> GeometryCulvertModelRequest {
        GeometryCulvertModelRequest(assetPath: asset.url.path, kind: "Geometry", projectPath: nil, projectXml: nil)
    }

    func load(_ model: GeometryCulvertModelRequest, expectedRevision: String?, draftState: String?,
              selectedBarrelIDs: [String]) async throws -> GeometryCulvertSnapshot {
        current
    }

    func edit(_ model: GeometryCulvertModelRequest, revision: String, draftState: String,
              mutation: GeometryCulvertMutation, selectedBarrelIDs: [String]) async throws -> GeometryCulvertSnapshot {
        mutations.append(mutation)
        var rows = current.barrels.rows
        switch mutation.operation {
        case "reverseBarrel":
            rows = rows.map { row in
                guard mutation.featureIDs.contains(row.id) else { return row }
                return GeometryCulvertFeatureRow(id: row.id, fid: row.fid, values: row.values,
                    polyline: Array(row.polyline.reversed()))
            }
        case "moveBarrels":
            guard let dx = mutation.deltaX, let dy = mutation.deltaY else { return current }
            rows = rows.map { row in
                guard mutation.featureIDs.contains(row.id) else { return row }
                let translated = row.polyline.map {
                    GeometryCulvertCoordinate(x: $0.x + dx, y: $0.y + dy, z: $0.z, m: $0.m)
                }
                return GeometryCulvertFeatureRow(id: row.id, fid: row.fid, values: row.values, polyline: translated)
            }
        case "pasteBarrels":
            for copied in mutation.copiedBarrels ?? [] {
                let id = "barrel:draft:" + copied.draftID
                rows.append(GeometryCulvertFeatureRow(id: id, fid: rows.count,
                    values: ["Name": copied.name, "BarrelPropertyName": copied.barrelPropertyName,
                        "UpstreamInvert": copied.upstreamInvert, "DownstreamInvert": copied.downstreamInvert,
                        "UpstreamOpeningName": copied.upstreamOpeningName,
                        "DownstreamOpeningName": copied.downstreamOpeningName], polyline: copied.polyline))
            }
        default:
            break
        }
        current = Self.snapshot(revision: revision, draftState: "draft-\(mutations.count)",
            isDirty: true, rows: rows)
        return current
    }

    private static func snapshot(revision: String, draftState: String, isDirty: Bool,
                                 rows: [GeometryCulvertFeatureRow]) -> GeometryCulvertSnapshot {
        let barrels = GeometryCulvertFeatureTable(featureKind: "barrel", columns: [], editableFields: [], rows: rows)
        let barrelProperties = GeometryCulvertFeatureTable(featureKind: "barrelProperties", columns: [], editableFields: [], rows: [])
        let openingProperties = GeometryCulvertFeatureTable(featureKind: "openingProperties", columns: [], editableFields: [], rows: [])
        return GeometryCulvertSnapshot(revision: revision, draftState: draftState, canEdit: true, isDirty: isDirty,
            barrels: barrels, barrelProperties: barrelProperties, openingProperties: openingProperties,
            associatedTerrainName: "Terrain", profiles: [])
    }
}

struct GeometryCulvertMapEditingTests {
    @Test @MainActor
    func moveAndDuplicateUseStableRowsAndRetainSourceDimensionsAndAssociations() async throws {
        let provider = GeometryCulvertMapEditProvider()
        let child = GeometryCulvertSession(provider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/geometry.h5"), section: .geometries)
        await child.ensureLoaded(asset: asset, sourceRevision: "source-sha")

        let sourceID = "barrel:source:7"
        #expect(await child.moveBarrels(ids: [sourceID], deltaX: 2.5, deltaY: -1.25))
        let move = try #require(provider.mutations.last)
        #expect(move.operation == "moveBarrels")
        #expect(move.featureIDs == [sourceID])
        #expect(move.deltaX == 2.5 && move.deltaY == -1.25)
        #expect(child.table(for: "barrel").rows.first?.polyline == [
            GeometryCulvertCoordinate(x: 12.5, y: 18.75, z: "3.5", m: "18"),
            GeometryCulvertCoordinate(x: 18.5, y: 21.75, z: "2.5", m: "25")
        ])

        #expect(await child.duplicateSelectedBarrels())
        let paste = try #require(provider.mutations.last)
        #expect(paste.operation == "pasteBarrels" && paste.featureIDs.isEmpty)
        let copied = try #require(paste.copiedBarrels?.first)
        #expect(copied.draftID.count == 32)
        #expect(copied.name == "West barrel" && copied.barrelPropertyName == "Round")
        #expect(copied.upstreamInvert == "12.25" && copied.downstreamInvert == "11.5")
        #expect(copied.upstreamOpeningName == "Headwall" && copied.downstreamOpeningName == "Wingwall")
        #expect(copied.polyline.last?.z == "2.5" && copied.polyline.last?.m == "25")
        #expect(child.table(for: "barrel").rows.count == 2)
        #expect(child.selectedFeatureIDs["barrel"] == ["barrel:draft:" + copied.draftID])
        #expect(child.isDirty)
    }

    @Test @MainActor
    func reverseUsesSelectedStableIDAndPreservesEveryCoordinateDimensionAndBarrelField() async throws {
        let provider = GeometryCulvertMapEditProvider()
        let child = GeometryCulvertSession(provider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/geometry.h5"), section: .geometries)
        await child.ensureLoaded(asset: asset, sourceRevision: "source-sha")
        let id = "barrel:source:7"
        await child.select([id], featureKind: "barrel")
        let valuesBefore = child.table(for: "barrel").rows.first?.values
        let original = try #require(child.table(for: "barrel").rows.first?.polyline)

        #expect(await child.reverseBarrel(id: id))
        let mutation = try #require(provider.mutations.last)
        #expect(mutation.operation == "reverseBarrel" && mutation.featureKind == "barrel")
        #expect(mutation.featureIDs == [id])
        #expect(child.table(for: "barrel").rows.first?.id == id)
        #expect(child.table(for: "barrel").rows.first?.values == valuesBefore)
        #expect(child.table(for: "barrel").rows.first?.polyline == Array(original.reversed()))
        #expect(child.selectedFeatureIDs["barrel"] == [id])
        #expect(child.isDirty)
    }

    @Test @MainActor
    func filterAndSmoothUseSourceParametersAndRejectZOrMInput() async throws {
        let dimensionalProvider = GeometryCulvertMapEditProvider()
        let dimensionalSession = GeometryCulvertSession(provider: dimensionalProvider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/geometry.h5"), section: .geometries)
        await dimensionalSession.ensureLoaded(asset: asset, sourceRevision: "source-sha")
        let id = "barrel:source:7"
        await dimensionalSession.select([id], featureKind: "barrel")
        #expect(!dimensionalSession.selectedBarrelSupportsXYOnlyGeoprocessing(id: id))
        #expect(!(await dimensionalSession.filterBarrel(id: id, tolerance: 1)))
        #expect(!(await dimensionalSession.smoothBarrel(id: id, windowSize: 3, passes: 2)))
        #expect(dimensionalProvider.mutations.isEmpty)

        let xyProvider = GeometryCulvertMapEditProvider(hasDimensions: false)
        let xySession = GeometryCulvertSession(provider: xyProvider)
        await xySession.ensureLoaded(asset: asset, sourceRevision: "source-sha")
        await xySession.select([id], featureKind: "barrel")
        #expect(xySession.selectedBarrelSupportsXYOnlyGeoprocessing(id: id))
        #expect(await xySession.filterBarrel(id: id, tolerance: 1.25))
        let filter = try #require(xyProvider.mutations.last)
        #expect(filter.operation == "filterBarrel" && filter.featureIDs == [id])
        #expect(filter.tolerance == 1.25)
        #expect(await xySession.smoothBarrel(id: id, windowSize: 5, passes: 4))
        let smooth = try #require(xyProvider.mutations.last)
        #expect(smooth.operation == "smoothBarrel" && smooth.featureIDs == [id])
        #expect(smooth.windowSize == 5 && smooth.passes == 4)
        #expect(xySession.isDirty)
    }
}
