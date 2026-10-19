import Foundation
import Testing
@testable import HECRAS2025

struct ProjectUMLInteractionStateTests {
    @Test
    func zoomKeepsTheCanvasPointUnderThePointerAndPanInvertsExactly() {
        var viewport = ProjectUMLViewportState()
        viewport.setOffset(CGSize(width: -120, height: 45))
        let pointer = CGPoint(x: 380, y: 260)
        let canvasPoint = viewport.canvasPoint(fromViewport: pointer)

        viewport.zoom(by: 2.5, anchoredAt: pointer)

        #expect(viewport.viewportPoint(fromCanvas: canvasPoint).x == pointer.x)
        #expect(viewport.viewportPoint(fromCanvas: canvasPoint).y == pointer.y)
        let mapped = viewport.viewportPoint(fromCanvas: CGPoint(x: 410, y: 220))
        #expect(viewport.canvasPoint(fromViewport: mapped) == CGPoint(x: 410, y: 220))
        viewport.zoom(by: 100, anchoredAt: pointer)
        #expect(viewport.zoom == ProjectUMLViewportState.maximumZoom)
        viewport.zoom(by: 0.0001, anchoredAt: pointer)
        #expect(viewport.zoom == ProjectUMLViewportState.minimumZoom)
    }

    @Test
    func fitCentersWholeNodeBoundsWithSourceMargin() {
        var viewport = ProjectUMLViewportState()
        let bounds = CGRect(x: 30, y: 80, width: 840, height: 420)
        let size = CGSize(width: 720, height: 520)

        viewport.fit(bounds: bounds, in: size)

        let topLeft = viewport.viewportPoint(fromCanvas: CGPoint(x: bounds.minX, y: bounds.minY))
        let bottomRight = viewport.viewportPoint(fromCanvas: CGPoint(x: bounds.maxX, y: bounds.maxY))
        #expect(abs((topLeft.x + bottomRight.x) / 2 - size.width / 2) < 0.001)
        #expect(abs((topLeft.y + bottomRight.y) / 2 - size.height / 2) < 0.001)
        #expect(topLeft.x >= 0 && bottomRight.x <= size.width)
        #expect(topLeft.y >= 0 && bottomRight.y <= size.height)
    }

    @Test
    func additiveSelectionKeepsGroupAndInspectorTracksTheActiveNode() {
        var selection = ProjectUMLSelectionState()
        selection.select("terrain", additive: false)
        selection.select("geometry", additive: true)

        #expect(selection.selectedNodeIDs == ["terrain", "geometry"])
        #expect(selection.inspectorNodeID == "geometry")
        selection.select("geometry", additive: true)
        #expect(selection.selectedNodeIDs == ["terrain", "geometry"],
            "The original modifier-click behavior adds; it does not toggle an existing selection off.")

        selection.select("plan", additive: false)
        #expect(selection.selectedNodeIDs == ["plan"])
        #expect(selection.inspectorNodeID == "plan")
    }

    @Test
    func additiveBoxSelectionPreservesPriorNodesAndReconcilesTheInspector() {
        var selection = ProjectUMLSelectionState()
        selection.select("geometry", additive: false)
        selection.selectBox(["terrain", "plan"], additive: true,
            orderedIDs: ["terrain", "geometry", "plan"])
        #expect(selection.selectedNodeIDs == ["terrain", "geometry", "plan"])
        #expect(selection.inspectorNodeID == "geometry")

        selection.selectBox(["plan"], additive: false,
            orderedIDs: ["terrain", "geometry", "plan"])
        #expect(selection.selectedNodeIDs == ["plan"])
        #expect(selection.inspectorNodeID == "plan")

        selection.reconcile(orderedIDs: ["terrain", "geometry"])
        #expect(selection.selectedNodeIDs.isEmpty)
        #expect(selection.inspectorNodeID == nil)
    }

    @Test
    func boxSelectionUsesRectangleIntersectionLikeTheOriginalNodeBoundsCheck() {
        let node = CGRect(x: 100, y: 80, width: 200, height: 120)
        #expect(ProjectUMLCanvasGeometry.intersects(node, CGRect(x: 280, y: 190, width: 30, height: 30)))
        #expect(ProjectUMLCanvasGeometry.intersects(node, CGRect(x: 300, y: 200, width: -30, height: -30)))
        #expect(!ProjectUMLCanvasGeometry.intersects(node, CGRect(x: 320, y: 210, width: 20, height: 20)))
    }

    @Test
    func linkAnchorsStayInTheSameTransformedCanvasAsTheirNodeCards() {
        let outputOrigin = CGPoint(x: 40, y: 90)
        let inputOrigin = CGPoint(x: 510, y: 230)
        let output = ProjectUMLCanvasGeometry.outputAnchor(origin: outputOrigin,
            width: 200, height: ProjectUMLCanvasGeometry.nodeHeight(inputCount: 2,
                headerHeight: 28, inputRowHeight: 30))
        let input = ProjectUMLCanvasGeometry.inputAnchor(origin: inputOrigin,
            headerHeight: 28, inputRowHeight: 30, inputIndex: 1)
        var viewport = ProjectUMLViewportState()
        viewport.setOffset(CGSize(width: -170, height: 65))
        viewport.zoom(by: 1.8, anchoredAt: CGPoint(x: 350, y: 240))

        #expect(viewport.canvasPoint(fromViewport: viewport.viewportPoint(fromCanvas: output)) == output)
        #expect(viewport.canvasPoint(fromViewport: viewport.viewportPoint(fromCanvas: input)) == input)
        #expect(viewport.viewportPoint(fromCanvas: output).x == output.x * viewport.zoom + viewport.offset.width)
        #expect(viewport.viewportPoint(fromCanvas: input).y == input.y * viewport.zoom + viewport.offset.height)
    }

    @Test
    func projectLinkEndpointOverridesReplaceOnlyTheirOwnPortAndRemainCanvasCoordinates() {
        let outputOrigin = CGPoint(x: 40, y: 90)
        let inputOrigin = CGPoint(x: 510, y: 230)
        let outputOverride = CGPoint(x: 280, y: 180)
        let inputOverride = CGPoint(x: 510, y: 310)
        let endpoints = ProjectUMLCanvasGeometry.linkEndpoints(outputOrigin: outputOrigin,
            inputOrigin: inputOrigin, nodeWidth: 200, outputHeight: 90,
            headerHeight: 28, inputRowHeight: 30, inputIndex: 1,
            overrideOutput: outputOverride, overrideInput: inputOverride)
        #expect(endpoints.output == outputOverride)
        #expect(endpoints.input == inputOverride)

        let partiallyOverridden = ProjectUMLCanvasGeometry.linkEndpoints(outputOrigin: outputOrigin,
            inputOrigin: inputOrigin, nodeWidth: 200, outputHeight: 90,
            headerHeight: 28, inputRowHeight: 30, inputIndex: 1,
            overrideOutput: outputOverride)
        #expect(partiallyOverridden.output == outputOverride)
        #expect(partiallyOverridden.input == ProjectUMLCanvasGeometry.inputAnchor(
            origin: inputOrigin, headerHeight: 28, inputRowHeight: 30, inputIndex: 1))
    }

    @Test
    func linkDraftTracksCanvasCursorAndUsesTheSourceTwentyPointApplyThreshold() {
        var draft = ProjectUMLLinkDraft(source: .input(nodeID: "geometry", index: 0, typeID: "terrain"),
            anchor: CGPoint(x: 100, y: 140))
        draft.moveCursor(to: CGPoint(x: 115, y: 140))
        #expect(!draft.hasMovedBeyondSourceThreshold)
        draft.moveCursor(to: CGPoint(x: 121, y: 140))
        #expect(draft.hasMovedBeyondSourceThreshold)
        #expect(draft.source == .input(nodeID: "geometry", index: 0, typeID: "terrain"))
    }

    @Test
    func portHitTestingPreservesNodeAndInputTypeIdentity() {
        let nodes = [
            ProjectUMLPortLayoutNode(id: "terrain-file", typeID: "terrain", x: 40, y: 50,
                inputTypeIDs: []),
            ProjectUMLPortLayoutNode(id: "geometry-file", typeID: "geometry", x: 420, y: 70,
                inputTypeIDs: ["terrain", "nValue"])
        ]
        let inputAnchor = ProjectUMLCanvasGeometry.inputAnchor(origin: CGPoint(x: 420, y: 70),
            headerHeight: 28, inputRowHeight: 30, inputIndex: 1)
        let hit = ProjectUMLPortHitTesting.nearestPort(to: inputAnchor, nodes: nodes,
            nodeWidth: 200, nodeHeight: { node in
                ProjectUMLCanvasGeometry.nodeHeight(inputCount: node.inputTypeIDs.count,
                    headerHeight: 28, inputRowHeight: 30)
            }, headerHeight: 28, inputRowHeight: 30)

        #expect(hit == .input(nodeID: "geometry-file", index: 1, typeID: "nValue"))
        let outputAnchor = ProjectUMLCanvasGeometry.outputAnchor(origin: CGPoint(x: 40, y: 50),
            width: 200, height: 90)
        #expect(ProjectUMLPortHitTesting.nearestPort(to: outputAnchor, nodes: nodes,
            nodeWidth: 200, nodeHeight: { _ in 90 }, headerHeight: 28, inputRowHeight: 30)
            == .output(nodeID: "terrain-file", typeID: "terrain"))
    }

    @Test
    func negativeDiagramShiftKeepsTheCameraContentStationaryAndMovesEveryNodeTogether() {
        let positions = [
            "terrain": CGPoint(x: -20, y: -10),
            "geometry": CGPoint(x: 480, y: 210)
        ]
        let normalization = ProjectUMLCanvasGeometry.shiftNegativeDiagramBounds(positions)
        #expect(normalization.shift == CGSize(width: 1_020, height: 1_010))
        #expect(normalization.positions["terrain"] == CGPoint(x: 1_000, y: 1_000))
        #expect(normalization.positions["geometry"] == CGPoint(x: 1_500, y: 1_220))

        var viewport = ProjectUMLViewportState()
        viewport.setOffset(CGSize(width: 125, height: -40))
        viewport.setZoom(2, anchoredAt: .zero)
        let before = viewport.viewportPoint(fromCanvas: positions["terrain"]!)
        viewport.pan(by: CGSize(width: -normalization.shift.width * viewport.zoom,
            height: -normalization.shift.height * viewport.zoom))
        let after = viewport.viewportPoint(fromCanvas: normalization.positions["terrain"]!)
        #expect(before == after)
    }
}
