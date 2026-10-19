import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BoundaryMapRenderStyleTests {
    @Test @MainActor
    func exactCaptureInstallsGlobalStyleGroupsAndRetainedCatalogBaselines() async throws {
        let fixture = try BoundaryMapRenderStyleFixture()
        defer { fixture.remove() }
        let capture = try fixture.directCapture(name: "Boundary", source: fixture.sourceA,
            nodePath: [0, 0], sourceRevision: fixture.sha("A"))
        let session = BoundaryMapSession(provider: FixtureBoundaryMapProvider())
        await session.configure(captures: [capture])

        let lineDefinition = try #require(SourceVectorStyleCatalog.definition(for: "BC_Line_Symbology"))
        let vertexDefinition = try #require(SourceVectorStyleCatalog.definition(for: "BC_Line_Vertex_Symbology"))
        #expect(lineDefinition.defaultStyle == VectorStyleValues(
            penColor: "#FF05D5FF", penWidth: 3, fillColor: "#FF05D5FF"))
        #expect(vertexDefinition.defaultStyle == VectorStyleValues())

        let baseline = session.visualStyle(for: capture.sourceIdentity)
        #expect(baseline.line == lineDefinition.defaultStyle)
        #expect(baseline.vertex == vertexDefinition.defaultStyle)

        let lineValues = VectorStyleValues(
            penColor: "#FF123456", penWidth: 4.5, fillColor: "#FF123456")
        let vertexValues = VectorStyleValues(
            penColor: "#FF654321", penWidth: 2, fillColor: "#80654321", pointSize: 7)
        let lineRule = VectorStyleRule(column: "Stage", comparison: ">", threshold: "2",
                                       resultValue: "#FFABCDEF")
        let options = [
            "BC_Line_Symbology": VectorVisualSettingsOptions(values: lineValues,
                conditionGroups: [VectorVisualConditionGroup(field: .penWidth, rules: [lineRule])]),
            "BC_Line_Vertex_Symbology": VectorVisualSettingsOptions(values: vertexValues)
        ]

        #expect(session.installVisualStyles(options, for: capture))
        let installed = session.visualStyle(for: capture.sourceIdentity)
        #expect(installed.line == lineValues)
        #expect(installed.vertex == vertexValues)
        #expect(installed.lineConditionGroups == options["BC_Line_Symbology"]!.conditionGroups)
        #expect(installed.vertexConditionGroups == options["BC_Line_Vertex_Symbology"]!.conditionGroups)
    }

    @Test @MainActor
    func staleOrWrongCaptureCannotInstallStylesForTheActiveMapRow() async throws {
        let fixture = try BoundaryMapRenderStyleFixture()
        defer { fixture.remove() }
        let active = try fixture.directCapture(name: "Boundary", source: fixture.sourceA,
            nodePath: [0, 0], sourceRevision: fixture.sha("A"))
        let wrongMap = try fixture.directCapture(name: "Boundary", source: fixture.sourceA,
            nodePath: [0, 0], sourceRevision: fixture.sha("A"), mapID: UUID().uuidString)
        let session = BoundaryMapSession(provider: FixtureBoundaryMapProvider())
        await session.configure(captures: [active])
        let original = session.visualStyle(for: active.sourceIdentity)
        let unrelated = Self.options(line: VectorStyleValues(penColor: "#FF010203"),
                                     vertex: VectorStyleValues(penColor: "#FF040506"))

        #expect(!session.installVisualStyles(unrelated, for: wrongMap))
        #expect(session.visualStyle(for: active.sourceIdentity) == original)
    }

    @Test @MainActor
    func sameNamedBoundaryRowsKeepTheirOwnInstalledStyles() async throws {
        let fixture = try BoundaryMapRenderStyleFixture()
        defer { fixture.remove() }
        let first = try fixture.directCapture(name: "Boundary", source: fixture.sourceA,
            nodePath: [0, 0], sourceRevision: fixture.sha("A"))
        let second = try fixture.directCapture(name: "Boundary", source: fixture.sourceB,
            nodePath: [0, 1], sourceRevision: fixture.sha("B"))
        let session = BoundaryMapSession(provider: FixtureBoundaryMapProvider())
        await session.configure(captures: [first, second])
        let firstStyles = Self.options(
            line: VectorStyleValues(penColor: "#FF111111", penWidth: 2),
            vertex: VectorStyleValues(penColor: "#FF222222", pointSize: 4))
        let secondStyles = Self.options(
            line: VectorStyleValues(penColor: "#FFAAAAAA", penWidth: 6),
            vertex: VectorStyleValues(penColor: "#FFBBBBBB", pointSize: 9))

        #expect(first.boundaryNode.nodeName == second.boundaryNode.nodeName)
        #expect(first.sourceIdentity != second.sourceIdentity)
        #expect(session.installVisualStyles(firstStyles, for: first))
        #expect(session.installVisualStyles(secondStyles, for: second))
        #expect(session.visualStyle(for: first.sourceIdentity).line == firstStyles["BC_Line_Symbology"]!.values)
        #expect(session.visualStyle(for: first.sourceIdentity).vertex == firstStyles["BC_Line_Vertex_Symbology"]!.values)
        #expect(session.visualStyle(for: second.sourceIdentity).line == secondStyles["BC_Line_Symbology"]!.values)
        #expect(session.visualStyle(for: second.sourceIdentity).vertex == secondStyles["BC_Line_Vertex_Symbology"]!.values)
    }

    @Test @MainActor
    func strokeVertexOptionDefaultsOffAndChangesNoHDFOrVisualizationBytes() async throws {
        let fixture = try BoundaryMapRenderStyleFixture()
        defer { fixture.remove() }
        let capture = try fixture.directCapture(name: "Boundary", source: fixture.sourceA,
            nodePath: [0, 0], sourceRevision: fixture.sha("A"))
        let sourceBefore = try Data(contentsOf: fixture.sourceA)
        let visualizationBefore = try Data(contentsOf: fixture.visualization)
        let session = BoundaryMapSession(provider: FixtureBoundaryMapProvider())
        await session.configure(captures: [capture])

        #expect(!session.showsStrokeVertices(for: capture.sourceIdentity))
        session.setShowsStrokeVertices(true, sourceIdentity: capture.sourceIdentity)
        #expect(session.showsStrokeVertices(for: capture.sourceIdentity))
        session.setShowsStrokeVertices(false, sourceIdentity: capture.sourceIdentity)
        #expect(!session.showsStrokeVertices(for: capture.sourceIdentity))
        #expect(try Data(contentsOf: fixture.sourceA) == sourceBefore)
        #expect(try Data(contentsOf: fixture.visualization) == visualizationBefore)
    }

    @Test @MainActor
    func visualizationAndResultContextRefreshPreservesStrokeVertexChoiceButHDFChangesResetIt() async throws {
        let fixture = try BoundaryMapRenderStyleFixture()
        defer { fixture.remove() }
        let initial = try fixture.resultCapture(source: fixture.sourceA,
            sourceRevision: fixture.sha("A"), visualizationRevision: fixture.sha("B"),
            contextToken: "result-context-1")
        let session = BoundaryMapSession(provider: FixtureBoundaryMapProvider())
        await session.configure(captures: [initial])
        session.setShowsStrokeVertices(true, sourceIdentity: initial.sourceIdentity)
        #expect(session.showsStrokeVertices(for: initial.sourceIdentity))

        let styleOnlyRefresh = try fixture.resultCapture(source: fixture.sourceA,
            sourceRevision: fixture.sha("A"), visualizationRevision: fixture.sha("C"),
            contextToken: "result-context-2")
        await session.configure(captures: [styleOnlyRefresh])
        #expect(session.showsStrokeVertices(for: styleOnlyRefresh.sourceIdentity),
            "A style-only .vis revision and Result chart token do not change the HDF owner.")

        session.setShowsStrokeVertices(true, sourceIdentity: styleOnlyRefresh.sourceIdentity)
        let changedHDFRevision = try fixture.resultCapture(source: fixture.sourceA,
            sourceRevision: fixture.sha("D"), visualizationRevision: fixture.sha("E"),
            contextToken: "result-context-3")
        await session.configure(captures: [changedHDFRevision])
        #expect(!session.showsStrokeVertices(for: changedHDFRevision.sourceIdentity),
            "A changed selected Result HDF revision creates a new runtime owner.")

        session.setShowsStrokeVertices(true, sourceIdentity: changedHDFRevision.sourceIdentity)
        let changedOwner = try fixture.resultCapture(source: fixture.sourceB,
            sourceRevision: fixture.sha("F"), visualizationRevision: fixture.sha("G"),
            contextToken: "result-context-4")
        await session.configure(captures: [changedOwner])
        #expect(!session.showsStrokeVertices(for: changedOwner.sourceIdentity),
            "A different selected Result HDF is a different runtime owner even when its row name matches.")
    }

    @Test @MainActor
    func boundaryLineSelectionSupportsFilteredRangesAndSourceContextMenuRules() async throws {
        let fixture = try BoundaryMapRenderStyleFixture()
        defer { fixture.remove() }
        let first = try fixture.directCapture(name: "Boundary A", source: fixture.sourceA,
            nodePath: [0, 0], sourceRevision: fixture.sha("A"))
        let second = try fixture.directCapture(name: "Boundary B", source: fixture.sourceB,
            nodePath: [0, 1], sourceRevision: fixture.sha("B"))
        let third = try fixture.directCapture(name: "Boundary C", source: fixture.sourceA,
            nodePath: [0, 2], sourceRevision: fixture.sha("C"))
        let session = BoundaryMapSession(provider: FixtureBoundaryMapProvider(lineCount: 2))
        await session.configure(captures: [first, second, third])
        let firstIDs = session.visibleLines.filter { $0.sourceIdentity == first.sourceIdentity }.map(\.id)
        let secondIDs = session.visibleLines.filter { $0.sourceIdentity == second.sourceIdentity }.map(\.id)
        let thirdIDs = session.visibleLines.filter { $0.sourceIdentity == third.sourceIdentity }.map(\.id)
        #expect(firstIDs.count == 2 && secondIDs.count == 2 && thirdIDs.count == 2)

        session.selectLine(firstIDs[0], mode: .list(modifiers: []))
        session.selectLine(firstIDs[1], mode: .list(modifiers: [.shift]))
        #expect(session.selectedLineIDs == Set(firstIDs),
            "Shift selection is scoped to the exact BoundaryConditionLine layer owner.")

        session.selectLineForContextMenu(firstIDs[1])
        #expect(session.selectedLineIDs == Set(firstIDs),
            "A context action on an already selected feature preserves the multi-selection.")
        session.selectLine(secondIDs[0], mode: .list(modifiers: []))
        #expect(session.selectedLineIDs == Set(firstIDs + [secondIDs[0]]),
            "Selecting a line in another BoundaryConditionLine layer preserves the first layer's independent SelectedSet.")
        session.selectLine(firstIDs[1], mode: .list(modifiers: [.command]))
        #expect(session.selectedLineIDs == Set([firstIDs[0], secondIDs[0]]),
            "Command toggles the clicked feature in the selected set.")
        session.selectLineForContextMenu(firstIDs[1])
        #expect(session.selectedLineIDs == Set([firstIDs[1], secondIDs[0]]),
            "A context action on an unselected feature replaces only that layer's set and preserves other layer owners.")
    }

    private static func options(line: VectorStyleValues,
                                vertex: VectorStyleValues) -> [String: VectorVisualSettingsOptions] {
        [
            "BC_Line_Symbology": VectorVisualSettingsOptions(values: line),
            "BC_Line_Vertex_Symbology": VectorVisualSettingsOptions(values: vertex)
        ]
    }
}

@MainActor
private final class FixtureBoundaryMapProvider: BoundaryMapProvider {
    private(set) var loadCount = 0
    private let lineCount: Int

    init(lineCount: Int = 1) { self.lineCount = lineCount }

    func load(_ capture: BoundaryMapCapture, boundarySourceState: String?,
              contextToken: String?) async throws -> BoundaryMapSnapshot {
        loadCount += 1
        return BoundaryMapSnapshot(
            projectCanonicalPath: capture.map.projectPath,
            projectRevision: String(repeating: "D", count: 64),
            projectXmlSHA: capture.map.projectXmlSHA,
            visualizationRevision: capture.map.expectedVisualizationRevision,
            mapID: capture.map.mapID,
            mapIndex: capture.map.mapIndex,
            mapName: capture.map.mapName,
            mapType: capture.map.mapType,
            contextToken: contextToken ?? "fixture-context-\(loadCount)",
            boundaryNode: capture.boundaryNode,
            boundaryPath: capture.sourcePath,
            boundaryRevision: capture.sourceRevision,
            boundarySourceState: boundarySourceState ?? "fixture-state",
            boundaryChecked: capture.isChecked,
            boundaryEffectiveVisible: capture.effectiveVisible,
            lines: (0..<lineCount).map { ordinal in
                BoundaryMapLineData(id: "line-\(loadCount)-\(ordinal)", sourceOrdinal: ordinal,
                    name: capture.boundaryNode.nodeName + " \(ordinal + 1)",
                    coordinates: [BoundaryMapCoordinateData(x: 0, y: 0),
                                  BoundaryMapCoordinateData(x: 1, y: 1)])
            },
            resultOwner: capture.resultOwner?.receipt,
            status: capture.effectiveVisible ? "available" : "hidden",
            diagnostic: nil)
    }
}

private struct BoundaryMapRenderStyleFixture {
    let directory: URL
    let project: URL
    let visualization: URL
    let sourceA: URL
    let sourceB: URL
    let projectSessionID = UUID()
    let mapID = UUID().uuidString

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("boundary-map-render-style-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        project = directory.appendingPathComponent("Project.ras")
        visualization = directory.appendingPathComponent("Project.vis")
        sourceA = directory.appendingPathComponent("Boundary-A.h5")
        sourceB = directory.appendingPathComponent("Boundary-B.h5")
        try Data("project-sentinel".utf8).write(to: project)
        try Data("vis-sentinel".utf8).write(to: visualization)
        try Data("hdf-a-sentinel".utf8).write(to: sourceA)
        try Data("hdf-b-sentinel".utf8).write(to: sourceB)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func sha(_ character: Character) -> String { String(repeating: character, count: 64) }

    func directCapture(name: String, source: URL, nodePath: [Int], sourceRevision: String,
                       mapID: String? = nil) throws -> BoundaryMapCapture {
        let sourcePath = canonical(source)
        let node = CatalogTreeNodeLocator(rootName: "Boundary Conditions",
            nodeType: "BoundaryCondition", nodeName: name, nodePath: nodePath, assetID: sourcePath)
        return try BoundaryMapCapture(projectSessionID: projectSessionID,
            mapWorkflowIdentity: "project-map-\(mapID ?? self.mapID)",
            map: mapIdentity(mapID: mapID ?? self.mapID, visualizationRevision: sha("B")),
            boundaryNode: node, sourcePath: sourcePath, sourceRevision: sourceRevision,
            isChecked: true, effectiveVisible: true)
    }

    func resultCapture(source: URL, sourceRevision: String, visualizationRevision: String,
                       contextToken: String) throws -> BoundaryMapCapture {
        let sourcePath = canonical(source)
        let resultNode = CatalogTreeNodeLocator(rootName: "Results", nodeType: "Result",
            nodeName: "Shared result name", nodePath: [2, 0], assetID: sourcePath)
        let owner = try MapResultOwnerSelection(resultNode: resultNode,
            contextToken: contextToken, selectionOverrides: [], selectionIndex: 0,
            selectedResultPath: sourcePath, selectedResultRevision: sourceRevision)
        let boundaryNode = CatalogTreeNodeLocator(rootName: "Results",
            nodeType: "BoundaryCondition", nodeName: "Boundary", nodePath: [2, 0, 0],
            assetID: sourcePath, parentResultNodeType: "Result", parentResultAssetID: sourcePath,
            parentResultNodePath: [2, 0], parentResultNodeName: resultNode.nodeName,
            parentResultRevision: sourceRevision)
        return try BoundaryMapCapture(projectSessionID: projectSessionID,
            mapWorkflowIdentity: "project-map-\(mapID)",
            map: mapIdentity(mapID: mapID, visualizationRevision: visualizationRevision),
            boundaryNode: boundaryNode, sourcePath: sourcePath, sourceRevision: sourceRevision,
            resultOwner: owner, isChecked: true, effectiveVisible: true)
    }

    private func mapIdentity(mapID: String, visualizationRevision: String) -> MapTreeMapIdentity {
        MapTreeMapIdentity(projectPath: canonical(project), projectXml: "<Project />",
            projectXmlSHA: sha("A"), mapID: mapID, mapIndex: 0, mapName: "Saved map",
            mapType: "Project", expectedVisualizationRevision: visualizationRevision)
    }

    private func canonical(_ url: URL) -> String {
        SourceFilePaths.canonical(url)
    }
}
