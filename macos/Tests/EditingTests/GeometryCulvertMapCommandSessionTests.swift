import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class GeometryCulvertMapCommandSessionProvider: GeometryCulvertProvider,
    GeometryCulvertMapCommandProviding {
    var mapPreviewDelayNanoseconds: UInt64 = 0
    var smartAddPreviewDelayNanoseconds: UInt64 = 0
    private(set) var mapPreviewRequest: GeometryCulvertMapCommandPreviewRequest?
    private(set) var smartAddRequest: GeometryCulvertSmartAddPreviewRequest?
    private(set) var lastMutation: GeometryCulvertMutation?
    private(set) var loadedBarrelSelections: [[String]] = []
    var rowsAfterParentSaveReload: [GeometryCulvertFeatureRow]?
    private var currentSnapshot: GeometryCulvertSnapshot?

    func modelRequest(for asset: ProjectAsset) -> GeometryCulvertModelRequest {
        GeometryCulvertModelRequest(assetPath: asset.url.path, kind: "Geometry",
            projectPath: "/fixture/project.ras", projectXml: "terrain=A")
    }

    func load(_ model: GeometryCulvertModelRequest, expectedRevision: String?, draftState: String?,
              selectedBarrelIDs: [String]) async throws -> GeometryCulvertSnapshot {
        loadedBarrelSelections.append(selectedBarrelIDs)
        let loaded: GeometryCulvertSnapshot
        if expectedRevision == "revision-2", let rowsAfterParentSaveReload {
            loaded = snapshot(revision: "revision-2", draftState: draftState ?? "draft-clean-after-parent-save",
                isDirty: draftState != nil, rows: rowsAfterParentSaveReload)
        } else {
            loaded = currentSnapshot ?? snapshot(revision: expectedRevision ?? "revision-1",
                draftState: draftState ?? "draft-clean", isDirty: draftState != nil,
                rows: [row("barrel:source:1", fid: 1, points: [point(0, 0), point(10, 0)]),
                       row("barrel:source:2", fid: 2, points: [point(0, 10), point(10, 10)])])
        }
        currentSnapshot = loaded
        return loaded
    }

    func edit(_ model: GeometryCulvertModelRequest, revision: String, draftState: String,
              mutation: GeometryCulvertMutation,
              selectedBarrelIDs: [String]) async throws -> GeometryCulvertSnapshot {
        lastMutation = mutation
        var rows = currentSnapshot?.barrels.rows ?? []
        if mutation.operation == "addBarrel", let draftID = mutation.draftID,
           let polyline = mutation.polyline {
            rows.append(row("barrel:draft:" + draftID, fid: rows.count + 1, points: polyline))
        } else if ["split", "merge", "offset"].contains(mutation.operation) {
            let removed = Set(mutation.featureIDs)
            rows.removeAll { removed.contains($0.id) }
            for (index, draftID) in (mutation.outputDraftIDs ?? []).enumerated() {
                rows.append(row("barrel:draft:" + draftID, fid: rows.count + index + 1,
                    points: [point(Double(index), 1), point(Double(index + 1), 1)]))
            }
        }
        let updated = snapshot(revision: revision, draftState: "draft-after-" + mutation.operation,
            isDirty: true, rows: rows)
        currentSnapshot = updated
        return updated
    }

    func previewMapCommand(_ request: GeometryCulvertMapCommandPreviewRequest) async throws
        -> GeometryCulvertMapCommandPreviewResponse {
        mapPreviewRequest = request
        if mapPreviewDelayNanoseconds > 0 {
            do { try await Task.sleep(nanoseconds: mapPreviewDelayNanoseconds) }
            catch { /* Deliberately return late to verify the session generation guard. */ }
        }
        let captured = request.operation == "split"
            ? [request.targetFeatureID].compactMap { $0 }
            : request.featureIDs
        let outputCount = request.operation == "split" ? 2 : 1
        let draftIDs = Array((request.outputDraftIDs ?? []).prefix(outputCount))
        let anchor = request.splitPoint ?? point(0, 0)
        let outputs = draftIDs.enumerated().map { index, draftID in
            GeometryCulvertMapCommandOutput(draftID: draftID,
                polyline: [anchor, point(anchor.x + Double(index + 1), anchor.y + 1)])
        }
        let retained = request.operation == "offset" && request.keepOriginal ? captured : []
        let removed = request.operation == "offset" && request.keepOriginal ? [] : captured
        return GeometryCulvertMapCommandPreviewResponse(previewID: request.previewID,
            revision: request.revision, draftState: request.draftState,
            dependencyRevision: "terrain-revision-1", operation: request.operation,
            capturedFeatureIDs: captured, removedFeatureIDs: removed,
            retainedFeatureIDs: retained, outputs: outputs, hasChange: !outputs.isEmpty,
            canApply: !outputs.isEmpty,
            warningCode: outputs.isEmpty ? nil : "generatedBarrelsRequireProperties", errorCode: nil)
    }

    func previewSmartAdd(_ request: GeometryCulvertSmartAddPreviewRequest) async throws
        -> GeometryCulvertSmartAddPreviewResponse {
        smartAddRequest = request
        if smartAddPreviewDelayNanoseconds > 0 {
            do { try await Task.sleep(nanoseconds: smartAddPreviewDelayNanoseconds) }
            catch { /* Deliberately return late to verify the session generation guard. */ }
        }
        let midpoint = point((request.start.x + request.end.x) / 2,
            (request.start.y + request.end.y) / 2 + 0.25)
        return GeometryCulvertSmartAddPreviewResponse(previewID: request.previewID,
            revision: request.revision, draftState: request.draftState,
            dependencyRevision: "terrain-revision-1", terrainName: "Terrain A",
            canAppend: true, path: [request.start, midpoint, request.end], errorCode: nil)
    }

    private func snapshot(revision: String, draftState: String, isDirty: Bool,
                          rows: [GeometryCulvertFeatureRow]) -> GeometryCulvertSnapshot {
        let barrels = GeometryCulvertFeatureTable(featureKind: "barrel", columns: [], editableFields: [], rows: rows)
        let properties = GeometryCulvertFeatureTable(featureKind: "barrelProperties", columns: [], editableFields: [], rows: [])
        let openings = GeometryCulvertFeatureTable(featureKind: "openingProperties", columns: [], editableFields: [], rows: [])
        return GeometryCulvertSnapshot(revision: revision, draftState: draftState,
            canEdit: true, isDirty: isDirty, barrels: barrels, barrelProperties: properties,
            openingProperties: openings, associatedTerrainName: "Terrain A", profiles: [],
            associatedTerrainExtent: GeometryCulvertExtent(minX: 0, minY: 0, maxX: 10, maxY: 10),
            dependencyRevision: "terrain-revision-1")
    }

    private func row(_ id: String, fid: Int, points: [GeometryCulvertCoordinate]) -> GeometryCulvertFeatureRow {
        GeometryCulvertFeatureRow(id: id, fid: fid, values: ["Name": id], polyline: points)
    }

    private func point(_ x: Double, _ y: Double) -> GeometryCulvertCoordinate {
        GeometryCulvertCoordinate(x: x, y: y)
    }
}

struct GeometryCulvertMapCommandSessionTests {
    @Test @MainActor
    func parentSaveReloadClearsSelectionsBeforeSourceFIDReindex() async throws {
        let provider = GeometryCulvertMapCommandSessionProvider()
        var parentDraftChanges: [Bool] = []
        let session = GeometryCulvertSession(provider: provider) { parentDraftChanges.append($0) }
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/geometry.h5"), section: .geometries)

        await session.ensureLoaded(asset: asset, sourceRevision: "revision-1")
        await session.select(["barrel:source:2"], featureKind: "barrel")
        await session.addPropertySet(featureKind: "barrelProperties")
        #expect(session.selectedFeatureIDs["barrel"] == ["barrel:source:2"])
        #expect(session.isDirty)
        #expect(parentDraftChanges == [true])

        provider.rowsAfterParentSaveReload = [
            GeometryCulvertFeatureRow(id: "barrel:source:1", fid: 1,
                values: ["Name": "Previously selected object"], polyline: [
                    GeometryCulvertCoordinate(x: 0, y: 10), GeometryCulvertCoordinate(x: 10, y: 10)
                ]),
            GeometryCulvertFeatureRow(id: "barrel:source:2", fid: 2,
                values: ["Name": "Different object now at FID 2"], polyline: [
                    GeometryCulvertCoordinate(x: 0, y: 20), GeometryCulvertCoordinate(x: 10, y: 20)
                ])
        ]
        let capture = try #require(session.beginParentSave())

        await session.acknowledgeParentSave(capture, newSourceRevision: "revision-2")

        #expect(provider.loadedBarrelSelections.last == [])
        #expect(session.selectedFeatureIDs["barrel", default: []].isEmpty)
        #expect(session.selectedRows(for: "barrel").isEmpty)
        #expect(session.table(for: "barrel").rows.first { $0.id == "barrel:source:2" }?.values["Name"]
            == "Different object now at FID 2")
        #expect(!session.isDirty)
        #expect(parentDraftChanges == [true, false])
    }

    @Test
    func splitAtMultiLineJunctionHasEnoughOutputDraftIDs() {
        let command = GeometryCulvertMapCommand.split(barrelID: "barrel:source:1",
            coordinate: GeometryCulvertCoordinate(x: 5, y: 5), mode: .anywhere, mapCellSize: 0.5)
        let request = command.previewRequest(
            model: GeometryCulvertModelRequest(assetPath: "/fixture/geometry.h5", kind: "Geometry",
                projectPath: "/fixture/project.ras", projectXml: nil),
            revision: "revision-1", draftState: "draft-1", previewID: "junction-preview",
            availableBarrelCount: 3)

        #expect(request.featureIDs.isEmpty)
        #expect(request.targetFeatureID == "barrel:source:1")
        #expect(request.outputDraftIDs?.count == 6)
        #expect(Set(request.outputDraftIDs ?? []).count == 6)
        #expect((request.outputDraftIDs ?? []).allSatisfy { $0.utf8.count == 32 })
    }

    @Test
    func mergeAndOffsetPreserveTheirSourceParametersThroughApplyMapping() throws {
        let model = GeometryCulvertModelRequest(assetPath: "/fixture/geometry.h5", kind: "Geometry",
            projectPath: "/fixture/project.ras", projectXml: nil)
        let output = GeometryCulvertCoordinate(x: 1, y: 1)
        let outputEnd = GeometryCulvertCoordinate(x: 5, y: 6)
        let merge = GeometryCulvertMapCommand.merge(barrelIDs: ["barrel:source:2", "barrel:source:1"],
            tolerance: 5)
        let mergeRequest = merge.previewRequest(model: model, revision: "revision-1",
            draftState: "draft-1", previewID: "merge-preview", availableBarrelCount: 2)
        let mergeDraftID = try #require(mergeRequest.outputDraftIDs?.first)
        let mergeResponse = GeometryCulvertMapCommandPreviewResponse(previewID: "merge-preview",
            revision: "revision-1", draftState: "draft-1", dependencyRevision: "terrain-1",
            operation: "merge", capturedFeatureIDs: ["barrel:source:1", "barrel:source:2"],
            removedFeatureIDs: ["barrel:source:1", "barrel:source:2"], retainedFeatureIDs: [],
            outputs: [GeometryCulvertMapCommandOutput(draftID: mergeDraftID,
                polyline: [output, outputEnd])], hasChange: true, canApply: true,
            warningCode: nil, errorCode: nil)
        let mergeMutation = merge.mutation(preview: GeometryCulvertMapCommandPreview(
            response: mergeResponse, geometryIdentity: "geometry-1"))

        #expect(mergeRequest.featureIDs == ["barrel:source:1", "barrel:source:2"])
        #expect(mergeRequest.mergeTolerance == 5)
        #expect(mergeMutation.operation == "merge")
        #expect(mergeMutation.featureIDs == mergeResponse.capturedFeatureIDs)
        #expect(mergeMutation.mergeTolerance == 5)
        #expect(mergeMutation.outputDraftIDs == [mergeDraftID])

        let offset = GeometryCulvertMapCommand.offset(barrelID: "barrel:source:1", distance: 10,
            sides: .both, includeEndpoints: false, keepOriginal: true)
        let offsetRequest = offset.previewRequest(model: model, revision: "revision-1",
            draftState: "draft-1", previewID: "offset-preview", availableBarrelCount: 2)
        let offsetDraftID = try #require(offsetRequest.outputDraftIDs?.first)
        let offsetResponse = GeometryCulvertMapCommandPreviewResponse(previewID: "offset-preview",
            revision: "revision-1", draftState: "draft-1", dependencyRevision: "terrain-1",
            operation: "offset", capturedFeatureIDs: ["barrel:source:1"], removedFeatureIDs: [],
            retainedFeatureIDs: ["barrel:source:1"], outputs: [GeometryCulvertMapCommandOutput(
                draftID: offsetDraftID, polyline: [output, outputEnd])], hasChange: true, canApply: true,
            warningCode: "generatedBarrelsRequireProperties", errorCode: nil)
        let offsetMutation = offset.mutation(preview: GeometryCulvertMapCommandPreview(
            response: offsetResponse, geometryIdentity: "geometry-1"))

        #expect(offsetRequest.featureIDs == ["barrel:source:1"])
        #expect(offsetRequest.offsetDistance == 10)
        #expect(offsetRequest.offsetSides == "Both")
        #expect(!offsetRequest.includeEndpoints)
        #expect(offsetRequest.keepOriginal)
        #expect(offsetMutation.operation == "offset")
        #expect(offsetMutation.featureIDs == ["barrel:source:1"])
        #expect(offsetMutation.offsetDistance == 10)
        #expect(offsetMutation.offsetSides == "Both")
        #expect(offsetMutation.includeEndpoints == false)
        #expect(offsetMutation.keepOriginal == true)
        #expect(offsetMutation.outputDraftIDs == [offsetDraftID])
    }

    @Test @MainActor
    func splitPreviewCarriesSourceHitIdentityAndAppliesThroughChildLedger() async throws {
        let provider = GeometryCulvertMapCommandSessionProvider()
        provider.mapPreviewDelayNanoseconds = 50_000_000
        let session = GeometryCulvertSession(provider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/geometry.h5"), section: .geometries)
        let splitPoint = GeometryCulvertCoordinate(x: 4, y: 0.1)

        await session.ensureLoaded(asset: asset, sourceRevision: "revision-1")
        await session.select(["barrel:source:1"], featureKind: "barrel")
        let previewTask = Task {
            await session.previewMapCommand(.split(barrelID: "barrel:source:1",
                coordinate: splitPoint, mode: .anywhere, mapCellSize: 0.5))
        }
        for _ in 0..<100 where !session.isLoadingMapCommandPreview { await Task.yield() }
        #expect(session.isLoadingMapCommandPreview)
        #expect(!session.canApplyMapCommandPreview)
        let previewed = await previewTask.value

        #expect(previewed)
        #expect(provider.mapPreviewRequest?.featureIDs == [])
        #expect(provider.mapPreviewRequest?.targetFeatureID == "barrel:source:1")
        #expect(session.mapCommandPreview?.capturedFeatureIDs == ["barrel:source:1"])
        let offeredDraftIDs = provider.mapPreviewRequest?.outputDraftIDs ?? []
        #expect(session.mapCommandPreview?.outputs.map(\.draftID) == Array(offeredDraftIDs.prefix(2)))
        #expect(session.canApplyMapCommandPreview)

        let applied = await session.applyMapCommandPreview()
        #expect(applied)
        #expect(provider.lastMutation?.operation == "split")
        #expect(provider.lastMutation?.featureIDs == ["barrel:source:1"])
        #expect(provider.lastMutation?.targetFeatureID == "barrel:source:1")
        #expect(provider.lastMutation?.splitPoint == splitPoint)
        #expect(provider.lastMutation?.outputDraftIDs?.count == 2)
        #expect(session.geometryCulvertStateForParentSave == "draft-after-split")
        #expect(session.canBeginParentSave)
        #expect(session.mapCommandNotice != nil)
    }

    @Test @MainActor
    func smartAddUsesTerrainPathAndFinishesAsOneAddBarrelDraftMutation() async throws {
        let provider = GeometryCulvertMapCommandSessionProvider()
        let session = GeometryCulvertSession(provider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/geometry.h5"), section: .geometries)
        let start = GeometryCulvertCoordinate(x: 1, y: 1)
        let end = GeometryCulvertCoordinate(x: 9, y: 8)
        let window = GeometryCulvertSmartAddWindow(
            extent: GeometryCulvertExtent(minX: 0, minY: 0, maxX: 10, maxY: 10), rows: 600, columns: 800)

        await session.ensureLoaded(asset: asset, sourceRevision: "revision-1")
        session.beginSmartAddSketch(at: start)
        #expect(session.hasActiveSketch)
        #expect(session.smartAddSketchPoints == [start])
        let previewed = await session.previewSmartAddSegment(from: start, to: end, window: window)

        #expect(previewed)
        #expect(provider.smartAddRequest?.options.algorithm == "HessianRidgeness")
        #expect(provider.smartAddRequest?.window == window)
        #expect(session.smartAddPathPreview?.count == 3)
        #expect(session.acceptSmartAddSegment())
        #expect(session.smartAddSketchPoints.count == 3)
        #expect(session.canFinishSmartAddSketch)

        let barrelID = await session.finishSmartAddSketch()
        #expect(barrelID != nil)
        #expect(provider.lastMutation?.operation == "addBarrel")
        #expect(provider.lastMutation?.featureIDs == [])
        let createdBarrelID = try #require(barrelID)
        let createdBarrel = try #require(session.table(for: "barrel").rows.first { $0.id == createdBarrelID })
        #expect(provider.lastMutation?.polyline == createdBarrel.polyline)
        #expect(session.geometryCulvertStateForParentSave == "draft-after-addBarrel")
        #expect(!session.hasActiveSketch)
        #expect(session.smartAddNotice != nil)
    }

    @Test @MainActor
    func cancelledMapPreviewCannotInstallItsLateResponse() async throws {
        let provider = GeometryCulvertMapCommandSessionProvider()
        provider.mapPreviewDelayNanoseconds = 50_000_000
        let session = GeometryCulvertSession(provider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/geometry.h5"), section: .geometries)

        await session.ensureLoaded(asset: asset, sourceRevision: "revision-1")
        await session.select(["barrel:source:1"], featureKind: "barrel")
        let request = Task {
            await session.previewMapCommand(.offset(barrelID: "barrel:source:1", distance: 10,
                sides: .both, includeEndpoints: false, keepOriginal: false))
        }
        for _ in 0..<100 where !session.isLoadingMapCommandPreview { await Task.yield() }
        #expect(session.isLoadingMapCommandPreview)
        session.cancelMapCommandPreview()
        let result = await request.value

        #expect(!result)
        #expect(session.mapCommandPreview == nil)
        #expect(!session.isLoadingMapCommandPreview)
    }

    @Test @MainActor
    func cancelledSmartAddPreviewCannotAppendItsLateTerrainPath() async throws {
        let provider = GeometryCulvertMapCommandSessionProvider()
        provider.smartAddPreviewDelayNanoseconds = 50_000_000
        let session = GeometryCulvertSession(provider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/geometry.h5"), section: .geometries)
        let start = GeometryCulvertCoordinate(x: 1, y: 1)
        let end = GeometryCulvertCoordinate(x: 9, y: 8)
        let window = GeometryCulvertSmartAddWindow(
            extent: GeometryCulvertExtent(minX: 0, minY: 0, maxX: 10, maxY: 10), rows: 600, columns: 800)

        await session.ensureLoaded(asset: asset, sourceRevision: "revision-1")
        session.beginSmartAddSketch(at: start)
        let request = Task {
            await session.previewSmartAddSegment(from: start, to: end, window: window)
        }
        for _ in 0..<100 where !session.isLoadingSmartAddPreview { await Task.yield() }
        #expect(session.isLoadingSmartAddPreview)
        session.cancelSmartAddSketch()
        let result = await request.value

        #expect(!result)
        #expect(!session.hasActiveSketch)
        #expect(session.smartAddSketchPoints.isEmpty)
        #expect(session.smartAddPathPreview == nil)
        #expect(!session.isLoadingSmartAddPreview)
    }
}
