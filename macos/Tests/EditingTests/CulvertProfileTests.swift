import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class CulvertProfileSelectionProvider: GeometryCulvertProvider {
    private(set) var selectedBarrelRequests: [[String]] = []

    func modelRequest(for asset: ProjectAsset) -> GeometryCulvertModelRequest {
        GeometryCulvertModelRequest(assetPath: asset.url.path, kind: "Geometry",
            projectPath: "/fixture/project.ras", projectXml: nil)
    }

    func load(_ model: GeometryCulvertModelRequest, expectedRevision: String?, draftState: String?,
              selectedBarrelIDs: [String]) async throws -> GeometryCulvertSnapshot {
        selectedBarrelRequests.append(selectedBarrelIDs)
        return snapshot(revision: expectedRevision ?? "geometry-revision", selectedBarrelIDs: selectedBarrelIDs)
    }

    func edit(_ model: GeometryCulvertModelRequest, revision: String, draftState: String,
              mutation: GeometryCulvertMutation, selectedBarrelIDs: [String]) async throws -> GeometryCulvertSnapshot {
        throw CocoaError(.featureUnsupported)
    }

    private func snapshot(revision: String, selectedBarrelIDs: [String]) -> GeometryCulvertSnapshot {
        let barrelIDs = ["barrel:source:0", "barrel:source:1"]
        let names = ["barrel:source:0": "West", "barrel:source:1": "East"]
        let rows = barrelIDs.enumerated().map { index, id in
            GeometryCulvertFeatureRow(id: id, fid: index, values: ["Name": names[id]!],
                polyline: [GeometryCulvertCoordinate(x: Double(index * 10), y: 0),
                           GeometryCulvertCoordinate(x: Double(index * 10 + 5), y: 2)])
        }
        let profiles = selectedBarrelIDs.compactMap { id -> GeometryCulvertProfile? in
            guard let name = names[id] else { return nil }
            return GeometryCulvertProfile(barrelID: id, barrelName: name, length: 5,
                samples: [
                    GeometryCulvertProfileSample(distance: 0, x: 0, y: 0, elevation: 42),
                    GeometryCulvertProfileSample(distance: 5, x: 5, y: 2, elevation: 43)
                ])
        }
        let barrels = GeometryCulvertFeatureTable(featureKind: "barrel", columns: [], editableFields: [], rows: rows)
        let barrelProperties = GeometryCulvertFeatureTable(featureKind: "barrelProperties", columns: [], editableFields: [], rows: [])
        let openingProperties = GeometryCulvertFeatureTable(featureKind: "openingProperties", columns: [], editableFields: [], rows: [])
        return GeometryCulvertSnapshot(revision: revision, draftState: "source-draft", canEdit: true, isDirty: false,
            barrels: barrels, barrelProperties: barrelProperties, openingProperties: openingProperties,
            associatedTerrainName: "Culvert Terrain", profiles: profiles)
    }
}

struct CulvertProfileTests {
    @Test @MainActor
    func childUsesStableBarrelIdentityAndRefreshesOnlyTheSelectedBarrelsTerrainProfile() async throws {
        let provider = CulvertProfileSelectionProvider()
        let child = GeometryCulvertSession(provider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/culverts.h5"), section: .geometries)

        await child.ensureLoaded(asset: asset, sourceRevision: "geometry-revision")
        let sourceIdentity = child.geometryCulvertIdentity
        #expect(sourceIdentity.hasPrefix(asset.id + "|"))
        #expect(sourceIdentity.contains("|geometry-revision|"))
        #expect(provider.selectedBarrelRequests == [[]])
        #expect(child.snapshot?.profiles.isEmpty == true)
        #expect(child.profileSamples.isEmpty)

        let west = "barrel:source:0"
        await child.select([west], featureKind: "barrel")
        let westProfile = try #require(child.snapshot?.profiles.first)
        #expect(westProfile.id == west)
        #expect(westProfile.barrelName == "West")
        #expect(child.profileSamples.count == westProfile.samples.count)
        #expect(child.profileSamples.allSatisfy { $0.datasetID == west })
        #expect(child.profileSamples.map(\.id) == westProfile.samples.map { west + ":" + $0.id })
        #expect(child.geometryCulvertIdentity == sourceIdentity)

        let east = "barrel:source:1"
        await child.select([east], featureKind: "barrel")
        let eastProfile = try #require(child.snapshot?.profiles.first)
        #expect(eastProfile.id == east)
        #expect(eastProfile.barrelName == "East")
        #expect(child.snapshot?.profiles.map(\.id) == [east])
        #expect(child.profileSamples.allSatisfy { $0.datasetID == east })
        #expect(provider.selectedBarrelRequests == [[], [west], [east]])

        await child.select([], featureKind: "barrel")
        #expect(child.selectedFeatureIDs["barrel"]?.isEmpty == true)
        #expect(child.snapshot?.profiles.isEmpty == true)
        #expect(child.profileSamples.isEmpty)
        #expect(provider.selectedBarrelRequests.last == [])
    }
}
