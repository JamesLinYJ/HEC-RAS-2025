import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class RecordingCulvertPolylineProvider: GeometryCulvertProvider {
    private let sourceLine = [GeometryCulvertCoordinate(x: 0, y: 0), GeometryCulvertCoordinate(x: 10, y: 0)]
    private(set) var mutations: [GeometryCulvertMutation] = []
    var failNextEdit = false

    func modelRequest(for asset: ProjectAsset) -> GeometryCulvertModelRequest {
        GeometryCulvertModelRequest(assetPath: asset.url.path, kind: "Geometry",
            projectPath: "/fixture/project.ras", projectXml: "<Project />")
    }

    func load(_ model: GeometryCulvertModelRequest, expectedRevision: String?, draftState: String?,
              selectedBarrelIDs: [String]) async throws -> GeometryCulvertSnapshot {
        snapshot(revision: expectedRevision ?? "source-revision", selected: selectedBarrelIDs)
    }

    func edit(_ model: GeometryCulvertModelRequest, revision: String, draftState: String,
              mutation: GeometryCulvertMutation, selectedBarrelIDs: [String]) async throws -> GeometryCulvertSnapshot {
        if failNextEdit {
            failNextEdit = false
            throw PolylineEditFailure.rejected
        }
        if mutation.operation == "undo" {
            if !mutations.isEmpty { mutations.removeLast() }
        } else {
            mutations.append(mutation)
        }
        return snapshot(revision: revision, selected: selectedBarrelIDs)
    }

    private func snapshot(revision: String, selected: [String]) -> GeometryCulvertSnapshot {
        var lines: [String: [GeometryCulvertCoordinate]] = ["barrel:source:0": sourceLine]
        for mutation in mutations {
            switch mutation.operation {
            case "setPolyline":
                if let id = mutation.featureIDs.first, let points = mutation.polyline { lines[id] = points }
            case "addBarrel":
                if let draftID = mutation.draftID, let points = mutation.polyline {
                    lines["barrel:draft:" + draftID] = points
                }
            default: break
            }
        }
        let rows = lines.keys.sorted().compactMap { id -> GeometryCulvertFeatureRow? in
            guard let points = lines[id] else { return nil }
            return GeometryCulvertFeatureRow(id: id, fid: id == "barrel:source:0" ? 0 : 1,
                values: ["Name": id == "barrel:source:0" ? "Source barrel" : "Culvert Barrel"],
                polyline: points)
        }
        let barrelTable = GeometryCulvertFeatureTable(featureKind: "barrel", columns: [], editableFields: [], rows: rows)
        let emptyProperties = GeometryCulvertFeatureTable(featureKind: "barrelProperties", columns: [], editableFields: [], rows: [])
        let emptyOpenings = GeometryCulvertFeatureTable(featureKind: "openingProperties", columns: [], editableFields: [], rows: [])
        let profiles = selected.compactMap { id -> GeometryCulvertProfile? in
            guard let points = lines[id], let first = points.first, let last = points.last else { return nil }
            return GeometryCulvertProfile(barrelID: id, barrelName: id, length: 1, samples: [
                GeometryCulvertProfileSample(distance: 0, x: first.x, y: first.y, elevation: 40),
                GeometryCulvertProfileSample(distance: 1, x: last.x, y: last.y, elevation: 41)
            ])
        }
        let state = mutations.map { $0.operation + ":" + ($0.draftID ?? $0.featureIDs.first ?? "") }
            .joined(separator: "|")
        return GeometryCulvertSnapshot(revision: revision, draftState: state, canEdit: true,
            isDirty: !mutations.isEmpty, barrels: barrelTable, barrelProperties: emptyProperties,
            openingProperties: emptyOpenings, associatedTerrainName: "Terrain", profiles: profiles)
    }
}

private enum PolylineEditFailure: Error, LocalizedError {
    case rejected
    var errorDescription: String? { "The line edit was rejected." }
}

struct CulvertPolylineSessionTests {
    @Test @MainActor
    func drawReshapeAndUndoUseTheParentStagedMutationLedger() async throws {
        let provider = RecordingCulvertPolylineProvider()
        let child = GeometryCulvertSession(provider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/geometry.h5"), section: .geometries)
        await child.ensureLoaded(asset: asset, sourceRevision: "source-revision")
        await child.select(["barrel:source:0"], featureKind: "barrel")
        #expect(child.profileSamples.count == 2)

        let reshaped = [GeometryCulvertCoordinate(x: 0, y: 0), GeometryCulvertCoordinate(x: 5, y: 3),
            GeometryCulvertCoordinate(x: 10, y: 0)]
        #expect(await child.setPolyline(id: "barrel:source:0", points: reshaped))
        #expect(child.isDirty)
        #expect(child.snapshot?.barrels.rows.first?.polyline == reshaped)
        #expect(provider.mutations.last?.operation == "setPolyline")

        let drawn = [GeometryCulvertCoordinate(x: 2, y: 5), GeometryCulvertCoordinate(x: 7, y: 8),
            GeometryCulvertCoordinate(x: 12, y: 4)]
        let newID = try #require(await child.addBarrel(points: drawn))
        #expect(newID.hasPrefix("barrel:draft:"))
        #expect(child.snapshot?.barrels.rows.first(where: { $0.id == newID })?.polyline == drawn)
        #expect(child.selectedFeatureIDs["barrel"] == Set([newID]))
        #expect(provider.mutations.last?.operation == "addBarrel")

        #expect(await child.undoLastEdit())
        #expect(child.isDirty)
        #expect(child.snapshot?.barrels.rows.count == 1)
        #expect(child.snapshot?.barrels.rows.first?.polyline == reshaped)

        #expect(await child.undoLastEdit())
        #expect(!child.isDirty)
        #expect(child.snapshot?.barrels.rows.first?.polyline == [
            GeometryCulvertCoordinate(x: 0, y: 0), GeometryCulvertCoordinate(x: 10, y: 0)
        ])
        #expect(provider.mutations.isEmpty)
    }

    @Test @MainActor
    func rejectedPolylineEditLeavesTheExistingDraftUntouched() async throws {
        let provider = RecordingCulvertPolylineProvider()
        let child = GeometryCulvertSession(provider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/geometry.h5"), section: .geometries)
        await child.ensureLoaded(asset: asset, sourceRevision: "source-revision")
        let original = child.snapshot?.barrels.rows.first?.polyline
        provider.failNextEdit = true

        let accepted = await child.setPolyline(id: "barrel:source:0", points: [
            GeometryCulvertCoordinate(x: 0, y: 0), GeometryCulvertCoordinate(x: 10, y: 5)
        ])

        #expect(!accepted)
        #expect(!child.isDirty)
        #expect(child.snapshot?.barrels.rows.first?.polyline == original)
        #expect(child.error == "The line edit was rejected.")
    }

    @Test @MainActor
    func activeMapPreviewBlocksParentSaveDiscardAndInvalidationUntilResolved() async throws {
        let provider = RecordingCulvertPolylineProvider()
        let child = GeometryCulvertSession(provider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/geometry.h5"), section: .geometries)
        await child.ensureLoaded(asset: asset, sourceRevision: "source-revision")

        child.setSketchActive(true)
        #expect(child.hasActiveSketch)
        #expect(!child.canBeginParentSave)
        #expect(child.beginParentSave() == nil)
        await child.discardDraft()
        child.invalidate()
        #expect(child.hasActiveSketch)
        #expect(child.snapshot != nil)
        #expect(provider.mutations.isEmpty)

        child.setSketchActive(false)
        #expect(!child.hasActiveSketch)
        #expect(child.canBeginParentSave)
    }
}
