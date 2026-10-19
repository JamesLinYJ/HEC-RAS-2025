import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendCulvertMapCommandWorkflowTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_CULVERT_COMMAND_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func realMapCommandsSmartAddAndParentSaveUseOneCulvertChildDraft() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixtureRoot = URL(fileURLWithPath: try #require(
            environment["HECRAS_CULVERT_COMMAND_ACCEPTANCE_DIRECTORY"]), isDirectory: true)
        let backendURL = URL(fileURLWithPath: try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"]))
        try #require(FileManager.default.isExecutableFile(atPath: backendURL.path))
        let fixtureBytes = try Self.fileBytes(in: fixtureRoot)
        #expect(!fixtureBytes.isEmpty)

        let workRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("culvert-map-command-workflow-" + UUID().uuidString, isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: workRoot.path))
        try FileManager.default.copyItem(at: fixtureRoot, to: workRoot)
        defer { try? FileManager.default.removeItem(at: workRoot) }
        #expect(try Self.fileBytes(in: workRoot) == fixtureBytes)

        let manifest = try JSONDecoder().decode(CulvertMapCommandFixture.self,
            from: Data(contentsOf: workRoot.appendingPathComponent("manifest.json")))
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.kind == "culvert-map-command-acceptance")
        #expect(manifest.fixtureFresh)
        #expect(manifest.associatedDependencyRevision?.isEmpty == false)
        let geometryURL = workRoot.appendingPathComponent(manifest.geometryRelativePath)
        let projectURL = workRoot.appendingPathComponent(manifest.projectRelativePath)
        let terrainURL = workRoot.appendingPathComponent(manifest.terrainRelativePath)
        let rasterURLs = manifest.rasterRelativePaths.map { workRoot.appendingPathComponent($0) }
        #expect(try Self.filesMatch(manifest.files, root: workRoot))
        #expect(manifest.files[manifest.projectRelativePath] != nil)
        #expect(manifest.files[manifest.geometryRelativePath] != nil)
        #expect(manifest.files[manifest.terrainRelativePath] != nil)
        #expect(manifest.rasterRelativePaths.allSatisfy { manifest.files[$0] != nil })
        #expect(FileManager.default.fileExists(atPath: geometryURL.path))
        #expect(FileManager.default.fileExists(atPath: terrainURL.path))
        #expect(!rasterURLs.isEmpty && rasterURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        let project = try ProjectDocument(contentsOf: projectURL)
        let assetPath = SourceFilePaths.canonical(geometryURL)
        let asset = try #require(project.assets.first {
            $0.section == .geometries && SourceFilePaths.canonical($0.url) == assetPath
        })
        #expect(SourceFilePaths.canonical(asset.url) == assetPath)
        #expect(project.assets.contains {
            $0.section == .terrains && SourceFilePaths.canonical($0.url) == SourceFilePaths.canonical(terrainURL)
        })

        let copyBeforeEdits = try Self.fileBytes(in: workRoot)
        let geometryBefore = try Data(contentsOf: asset.url)
        let projectBefore = try Data(contentsOf: projectURL)
        let terrainBefore = try Data(contentsOf: terrainURL)
        let rasterBefore = try rasterURLs.map { try Data(contentsOf: $0) }

        let client = BackendProcessClient(executableURL: backendURL)
        let modelProvider = BackendModelProvider(client: client)
        modelProvider.setProject(project)
        let parent = ModelEditorSession(provider: modelProvider)
        await parent.load(asset, kind: .geometry)
        #expect(parent.loaded && parent.error == nil)
        await parent.ensureGeometryCulvertLoaded()
        let child = try #require(parent.geometryCulvert)
        let baseline = try #require(child.snapshot)
        #expect(baseline.canEdit && child.error == nil)
        #expect(baseline.revision == manifest.sourceRevision)
        #expect(baseline.associatedTerrainName != nil && baseline.dependencyRevision?.isEmpty == false)
        #expect(Self.matches(manifest.sourceBarrels, baseline.barrels.rows))
        #expect(!parent.modified && !child.isDirty)

        let baselineRows = baseline.barrels.rows
        let baselineByID = Dictionary(uniqueKeysWithValues: baselineRows.map { ($0.id, $0) })
        let splitTarget = try #require(baselineRows.first { $0.polyline.count >= 2 })
        let splitPoint = Self.midpoint(of: splitTarget.polyline[0], and: splitTarget.polyline[1])
        await child.select([splitTarget.id], featureKind: "barrel")
        let splitCommand = GeometryCulvertMapCommand.split(barrelID: splitTarget.id,
            coordinate: splitPoint, mode: .anywhere, mapCellSize: 0.01)

        #expect(await child.previewMapCommand(splitCommand))
        let splitPreview = try #require(child.mapCommandPreview)
        #expect(splitPreview.operation == "split" && splitPreview.canApply && splitPreview.hasChange)
        #expect(splitPreview.capturedFeatureIDs.contains(splitTarget.id) && splitPreview.outputs.count == 2)
        child.cancelMapCommandPreview()
        #expect(child.mapCommandPreview == nil && !child.isDirty)
        #expect(Self.sameRows(baselineRows, child.snapshot?.barrels.rows ?? []))
        #expect(try Self.fileBytes(in: workRoot) == copyBeforeEdits)

        #expect(await child.previewMapCommand(splitCommand))
        let appliedSplitPreview = try #require(child.mapCommandPreview)
        let splitOutputs = appliedSplitPreview.outputs
        #expect(await child.applyMapCommandPreview())
        let splitDraftRows = try splitOutputs.map { try Self.draftRow($0, in: child.snapshot) }
        #expect(child.isDirty && parent.modified)
        #expect(splitDraftRows.allSatisfy { Self.hasSourceDefaults($0) })
        #expect(child.snapshot?.barrels.rows.contains { $0.id == splitTarget.id } == false)
        #expect(await child.undoLastEdit())
        #expect(!child.isDirty && Self.sameRows(baselineRows, child.snapshot?.barrels.rows ?? []))
        #expect(Self.sameRow(baselineByID[splitTarget.id], child.snapshot?.barrels.rows.first { $0.id == splitTarget.id }))

        let offsetTarget = try #require(baselineByID[splitTarget.id])
        await child.select([offsetTarget.id], featureKind: "barrel")
        #expect(await child.previewMapCommand(.offset(barrelID: offsetTarget.id, distance: 2,
            sides: .both, includeEndpoints: true, keepOriginal: true)))
        let offsetPreview = try #require(child.mapCommandPreview)
        let offsetOutputs = offsetPreview.outputs
        #expect(offsetPreview.operation == "offset" && offsetPreview.canApply && offsetOutputs.count == 4)
        #expect(offsetPreview.retainedFeatureIDs.contains(offsetTarget.id))
        #expect(await child.applyMapCommandPreview())
        let offsetDraftRows = try offsetOutputs.map { try Self.draftRow($0, in: child.snapshot) }
        #expect(offsetDraftRows.allSatisfy { Self.hasSourceDefaults($0) })
        #expect(child.snapshot?.barrels.rows.count == baselineRows.count + offsetOutputs.count)
        #expect(Self.sameRow(offsetTarget,
            child.snapshot?.barrels.rows.first { $0.id == offsetTarget.id }))
        #expect(await child.undoLastEdit())
        #expect(!child.isDirty && Self.sameRows(baselineRows, child.snapshot?.barrels.rows ?? []))

        let merge = try Self.mergeSelection(from: baselineRows)
        await child.select(Set(baselineRows.map(\.id)), featureKind: "barrel")
        #expect(await child.previewMapCommand(.merge(barrelIDs: merge.inputIDs, tolerance: merge.tolerance)))
        let mergePreview = try #require(child.mapCommandPreview)
        let mergedPolyline = try #require(mergePreview.outputs.first?.polyline)
        #expect(mergePreview.operation == "merge" && mergePreview.canApply)
        #expect(mergePreview.outputs.count == 1)
        #expect(Set(mergePreview.capturedFeatureIDs) == Set(merge.inputIDs))
        #expect(mergePreview.retainedFeatureIDs == [merge.retainedID])
        #expect(mergePreview.removedFeatureIDs.count == 2)
        #expect(await child.applyMapCommandPreview())
        let mergeDraftRow = try Self.draftRow(try #require(mergePreview.outputs.first), in: child.snapshot)
        #expect(Self.hasSourceDefaults(mergeDraftRow))
        #expect(child.snapshot?.barrels.rows.count == baselineRows.count - 1)
        let retainedDraft = try #require(child.snapshot?.barrels.rows.first { $0.id == merge.retainedID })
        let retainedBaseline = try #require(baselineByID[merge.retainedID])
        #expect(retainedDraft.id == retainedBaseline.id && retainedDraft.fid == 1)
        #expect(retainedDraft.values["FID"] == "1")
        #expect(Self.sameSourceBarrelData(retainedBaseline, retainedDraft))

        var smartAddOptions = child.smartAddOptions
        smartAddOptions.algorithm = "HighGround"
        smartAddOptions.maxSegmentPixels = 120
        smartAddOptions.highGroundSnapRadiusCells = 0
        child.smartAddOptions = smartAddOptions
        let smartStart = GeometryCulvertCoordinate(x: 20, y: 70)
        let smartEnd = GeometryCulvertCoordinate(x: 90, y: 70)
        let smartWindow = GeometryCulvertSmartAddWindow(
            extent: GeometryCulvertExtent(minX: 0, minY: 0, maxX: 128, maxY: 128), rows: 128, columns: 128)
        child.beginSmartAddSketch(at: smartStart)
        #expect(child.hasActiveSketch && child.smartAddError == nil)
        #expect(await child.previewSmartAddSegment(from: smartStart, to: smartEnd, window: smartWindow))
        let smartPreview = try #require(child.smartAddPathPreview)
        #expect(smartPreview.count >= 2 && smartPreview.first == smartStart)
        #expect(smartPreview.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        #expect(child.snapshot?.associatedTerrainName != nil)
        #expect(child.acceptSmartAddSegment())
        let acceptedSmartPath = child.smartAddSketchPoints
        #expect(acceptedSmartPath == smartPreview && child.canFinishSmartAddSketch)
        let smartAddID = try #require(await child.finishSmartAddSketch())
        let smartAddDraftRow = try #require(child.snapshot?.barrels.rows.first { $0.id == smartAddID })
        #expect(smartAddDraftRow.polyline == acceptedSmartPath)
        #expect(Self.hasSourceDefaults(smartAddDraftRow))
        #expect(!child.hasActiveSketch && child.isDirty && parent.modified)
        await child.select([merge.retainedID], featureKind: "barrel")
        #expect(child.selectedFeatureIDs["barrel"] == [merge.retainedID])

        #expect(try Self.fileBytes(in: workRoot) == copyBeforeEdits)
        #expect(try Self.fileBytes(in: fixtureRoot) == fixtureBytes)
        #expect(try Data(contentsOf: asset.url) == geometryBefore)
        #expect(try Data(contentsOf: projectURL) == projectBefore)
        #expect(try Data(contentsOf: terrainURL) == terrainBefore)
        #expect(try rasterURLs.map { try Data(contentsOf: $0) } == rasterBefore)

        #expect(await parent.saveLoadedModel())
        #expect(parent.error == nil && child.error == nil)
        #expect(!parent.modified && !child.isDirty)
        #expect(child.selectedFeatureIDs["barrel"]?.isEmpty == true)
        let saved = try await modelProvider.load(asset, kind: .geometry)
        let independent = BackendGeometryCulvertProvider(client: client, currentProject: { project })
        let reopened = try await independent.load(independent.modelRequest(for: asset),
            expectedRevision: saved.sourceRevision, draftState: nil, selectedBarrelIDs: [])
        #expect(reopened.associatedTerrainName == baseline.associatedTerrainName)
        #expect(reopened.barrels.rows.count == baselineRows.count)
        let savedMerge = try #require(reopened.barrels.rows.first { $0.polyline == mergedPolyline })
        let savedSmartAdd = try #require(reopened.barrels.rows.first { $0.polyline == acceptedSmartPath })
        let savedRetained = try #require(reopened.barrels.rows.first {
            Self.sameSourceBarrelData(retainedBaseline, $0)
        })
        #expect(Self.hasSourceDefaults(savedMerge) && Self.hasSourceDefaults(savedSmartAdd))
        #expect(savedRetained.fid == 1 && savedRetained.values["FID"] == "1")
        #expect(Self.sameSourceBarrelData(retainedBaseline, savedRetained))
        #expect(savedRetained.polyline == retainedBaseline.polyline)
        #expect(try Self.fileBytes(in: fixtureRoot) == fixtureBytes)
        let filesAfterSave = try Self.fileBytes(in: workRoot)
        #expect(Set(filesAfterSave.keys) == Set(copyBeforeEdits.keys))
        for (relativePath, before) in copyBeforeEdits where relativePath != manifest.geometryRelativePath {
            #expect(filesAfterSave[relativePath] == before)
        }
        #expect(filesAfterSave[manifest.geometryRelativePath] != copyBeforeEdits[manifest.geometryRelativePath])
    }

    private static func fileBytes(in root: URL) throws -> [String: Data] {
        let prefix = SourceFilePaths.canonical(root) + "/"
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey]) else { throw CocoaError(.fileReadNoSuchFile) }
        var files: [String: Data] = [:]
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let path = SourceFilePaths.canonical(url)
            guard path.hasPrefix(prefix) else { throw CocoaError(.fileReadInvalidFileName) }
            files[String(path.dropFirst(prefix.count))] = try Data(contentsOf: url)
        }
        return files
    }

    private static func filesMatch(_ manifest: [String: String], root: URL) throws -> Bool {
        guard !manifest.isEmpty else { return false }
        for (relativePath, expectedSHA) in manifest {
            guard !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains("..") else { return false }
            let url = root.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: url.path),
                  MapDynamicProfileRequest.digest(try Data(contentsOf: url)).caseInsensitiveCompare(expectedSHA) == .orderedSame
            else { return false }
        }
        return true
    }

    private static func matches(_ expected: [CulvertMapCommandFixture.SourceBarrel], _ actual: [GeometryCulvertFeatureRow]) -> Bool {
        guard expected.count == actual.count else { return false }
        return expected.allSatisfy { source in
            guard let row = actual.first(where: { $0.id == source.id }) else { return false }
            return row.fid == source.fid && row.values == source.values && row.polyline == source.polyline
        }
    }

    private static func sameRows(_ expected: [GeometryCulvertFeatureRow],
                                 _ actual: [GeometryCulvertFeatureRow]) -> Bool {
        guard expected.count == actual.count else { return false }
        return expected.allSatisfy { row in sameRow(row, actual.first(where: { $0.id == row.id })) }
    }

    private static func sameRow(_ expected: GeometryCulvertFeatureRow?,
                                _ actual: GeometryCulvertFeatureRow?) -> Bool {
        guard let expected, let actual else { return false }
        return expected.id == actual.id && expected.fid == actual.fid
            && expected.values == actual.values && expected.polyline == actual.polyline
    }

    private static func hasSourceDefaults(_ row: GeometryCulvertFeatureRow) -> Bool {
        row.values["Name"] == "Culvert Barrel"
            && row.values["BarrelPropertyName"] == ""
            && row.values["UpstreamInvert"] == "0"
            && row.values["DownstreamInvert"] == "0"
            && row.values["UpstreamOpeningName"] == ""
            && row.values["DownstreamOpeningName"] == ""
    }

    private static func sameSourceBarrelData(_ expected: GeometryCulvertFeatureRow,
                                             _ actual: GeometryCulvertFeatureRow) -> Bool {
        expected.values.filter { $0.key != "FID" } == actual.values.filter { $0.key != "FID" }
            && expected.polyline == actual.polyline
    }

    private static func draftRow(_ output: GeometryCulvertMapCommandOutput,
                                 in snapshot: GeometryCulvertSnapshot?) throws -> GeometryCulvertFeatureRow {
        try #require(snapshot?.barrels.rows.first { $0.id == "barrel:draft:" + output.draftID })
    }

    private static func midpoint(of first: GeometryCulvertCoordinate,
                                 and second: GeometryCulvertCoordinate) -> GeometryCulvertCoordinate {
        GeometryCulvertCoordinate(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
    }

    private static func mergeSelection(from rows: [GeometryCulvertFeatureRow]) throws
        -> (inputIDs: [String], retainedID: String, tolerance: Double) {
        guard rows.count >= 3 else { throw CulvertMapCommandTestError.invalidFixture }
        var candidate: (left: GeometryCulvertFeatureRow, right: GeometryCulvertFeatureRow, gap: Double)?
        for leftIndex in rows.indices {
            for rightIndex in rows.indices where rightIndex > leftIndex {
                let gap = endpointGap(rows[leftIndex].polyline, rows[rightIndex].polyline)
                guard gap.isFinite, gap <= 5 else { continue }
                if let current = candidate {
                    if gap < current.gap { candidate = (rows[leftIndex], rows[rightIndex], gap) }
                } else {
                    candidate = (rows[leftIndex], rows[rightIndex], gap)
                }
            }
        }
        let connected = try #require(candidate)
        let retained = try #require(rows.first { $0.id != connected.left.id && $0.id != connected.right.id })
        return (rows.map(\.id), retained.id, 5)
    }

    private static func endpointGap(_ left: [GeometryCulvertCoordinate],
                                    _ right: [GeometryCulvertCoordinate]) -> Double {
        guard let leftFirst = left.first, let leftLast = left.last,
              let rightFirst = right.first, let rightLast = right.last else { return .infinity }
        return [leftFirst, leftLast].flatMap { a in
            [rightFirst, rightLast].map { b in hypot(a.x - b.x, a.y - b.y) }
        }.min() ?? .infinity
    }
}

private struct CulvertMapCommandFixture: Decodable {
    let schemaVersion: Int
    let kind: String
    let fixtureFresh: Bool
    let projectRelativePath: String
    let geometryRelativePath: String
    let terrainRelativePath: String
    let rasterRelativePaths: [String]
    let sourceRevision: String
    let associatedDependencyRevision: String?
    let sourceBarrels: [SourceBarrel]
    let files: [String: String]

    struct SourceBarrel: Decodable {
        let id: String
        let fid: Int
        let values: [String: String]
        let polyline: [GeometryCulvertCoordinate]
    }
}

private enum CulvertMapCommandTestError: Error {
    case invalidFixture
}
