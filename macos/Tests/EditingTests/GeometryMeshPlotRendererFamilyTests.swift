import CoreGraphics
import XCTest
import RASWorkspaceCore
@testable import HECRAS2025

final class GeometryMeshPlotRendererFamilyTests: XCTestCase {
    func testEditorOwnerCountFailsClosedWhenOwnershipIsAmbiguous() {
        XCTAssertEqual(GeometryMeshPlotEditorOwnerPolicy.ownerMode(forEditorCount: 0), .savedSource)
        XCTAssertEqual(GeometryMeshPlotEditorOwnerPolicy.ownerMode(forEditorCount: 1), .parentDraft)
        XCTAssertNil(GeometryMeshPlotEditorOwnerPolicy.ownerMode(forEditorCount: 2),
            "Multiple registered editors must not select one draft or fall back to saved HDF.")
        XCTAssertNil(GeometryMeshPlotEditorOwnerPolicy.ownerMode(forEditorCount: -1),
            "Invalid editor counts must fail closed.")
    }

    func testGeometryPlotStylePacketIdentityTracksExactCanonicalStyles() {
        let meshStyle = VectorStyleValues(penColor: "#80402010", penWidth: 2.5,
            fillColor: "#80402010", pointSize: 7)
        let arcStyle = VectorStyleValues(penColor: "#80607080", penWidth: 1.25,
            fillColor: "#80607080", pointSize: 3)
        let first = GeometryMeshPlotStylePacket(scope: .localVis, revision: "vis-r1",
            globalRevision: 4, styles: ["Mesh_Line_Symbology": meshStyle,
                "Arc_Line_Symbology": arcStyle])
        let reordered = GeometryMeshPlotStylePacket(scope: .localVis, revision: "vis-r1",
            globalRevision: 4, styles: Dictionary(uniqueKeysWithValues: [
                ("Mesh_Line_Symbology", meshStyle), ("Arc_Line_Symbology", arcStyle)
            ].reversed()))
        let changedStyle = GeometryMeshPlotStylePacket(scope: .localVis, revision: "vis-r1",
            globalRevision: 4, styles: ["Mesh_Line_Symbology": VectorStyleValues(
                penColor: "#80402011", penWidth: 2.5, fillColor: "#80402010", pointSize: 7),
                "Arc_Line_Symbology": arcStyle])

        XCTAssertEqual(first.packetSHA256, reordered.packetSHA256)
        XCTAssertNotEqual(first.packetSHA256, changedStyle.packetSHA256)
        XCTAssertNotEqual(first.identity(sourceIdentity: "source", ownerIdentity: "owner", mapID: "map",
                mapContextToken: "context", geometryNodeIdentity: "node", projectRevision: "project",
                visualizationRevision: "vis", sourceRevision: "hdf"),
            changedStyle.identity(sourceIdentity: "source", ownerIdentity: "owner", mapID: "map",
                mapContextToken: "context", geometryNodeIdentity: "node", projectRevision: "project",
                visualizationRevision: "vis", sourceRevision: "hdf"))
    }

    func testRendererContractsIncludeInheritedNetworkAndTopologyTINOptions() {
        XCTAssertEqual(GeometryMeshPlotRendererFamily.mesh.sourceOptionNames, [
            "LabelCells", "LabelFaces", "LabelFacePoints", "RenderPerimeter", "RenderQuality"
        ])

        let inheritedNetworkOptions: Set<String> = [
            "ShowArcIndexing", "ShowDirectionArrows", "ShowArcVertices"
        ]
        XCTAssertTrue(inheritedNetworkOptions.isSubset(of:
            GeometryMeshPlotRendererFamily.conceptualMesh.sourceOptionNames))
        XCTAssertEqual(GeometryMeshPlotRendererFamily.conceptualMesh.sourceOptionNames.count, 9)
        XCTAssertEqual(GeometryMeshPlotRendererFamily.topologyTIN.sourceOptionNames, [
            "RenderEdges", "RenderPoints", "LabelTris", "LabelEdges", "LabelPoints"
        ])
        XCTAssertEqual(GeometryMeshPlotRendererFamily.topologyTIN.sourceOptionsWithoutDrawingImplementation,
            ["LabelPoints"])
    }

    func testAcceptedTransparentFrameSuppressesBaseAndReusesItsDecodedImage() {
        let transparentPixels = Data([0, 0, 0, 0])
        let viewport = GeometryMeshPlotViewport(minX: 0, minY: 0, maxX: 1, maxY: 1)
        let response = GeometryMeshPlotRenderResponse(
            sourceIdentity: "geometry-source",
            ownerIdentity: "geometry-owner",
            mapID: "map-id",
            mapContextToken: "map-context",
            geometryNodeIdentity: "geometry-node",
            projectRevision: "project-revision",
            visualizationRevision: "vis-revision",
            sourceRevision: "geometry-revision",
            meshDraftSHA256: "mesh-draft-sha",
            topologyDraftSHA256: "topology-draft-sha",
            ownerMode: GeometryMeshPlotOwnerMode.savedSource.rawValue,
            viewport: viewport,
            pixelWidth: 1,
            pixelHeight: 1,
            renderScale: 1,
            pixelSamplingScale: 1,
            sourceRenderScale: 1,
            stylePacketSHA256: GeometryMeshPlotStylePacket.sourceDefaults.packetSHA256,
            styleIdentity: "style-identity",
            appliedStyles: [:],
            rasterExtent: viewport,
            rendererFamily: GeometryMeshPlotRendererFamily.topologyTIN.rawValue,
            status: "rendered",
            paintedPixels: false,
            pixelsRGBA: transparentPixels.base64EncodedString(),
            labels: [],
            options: [])
        guard let image = GeometryMeshPlotImage.make(pixels: transparentPixels, width: 1, height: 1) else {
            XCTFail("A valid transparent RGBA frame must still decode to a CGImage.")
            return
        }
        let accepted = GeometryMeshPlotRenderedOutput(identity: "request-identity",
            response: response, image: image)
        var cache = GeometryMeshPlotOutputCache()
        cache.insert(accepted, for: .topologyTIN)

        let firstRead = cache.output(for: .topologyTIN, matching: "request-identity")
        let secondRead = cache.output(for: .topologyTIN, matching: "request-identity")
        XCTAssertNotNil(firstRead)
        XCTAssertNotNil(secondRead)
        XCTAssertFalse(response.paintedPixels)
        XCTAssertEqual(GeometryMeshPlotFramePolicy.familyToSuppressBaseLayer(
            output: firstRead, requestedIdentity: "request-identity", requestedFamily: .topologyTIN), .topologyTIN,
            "An accepted transparent source frame must suppress its sampled base layer.")
        XCTAssertNil(GeometryMeshPlotFramePolicy.familyToSuppressBaseLayer(
            output: firstRead, requestedIdentity: "stale-request", requestedFamily: .topologyTIN))
        XCTAssertNil(cache.output(for: .topologyTIN, matching: "stale-request"))
        guard let firstRead, let secondRead else {
            XCTFail("The exact accepted output must remain in the immutable frame cache.")
            return
        }
        XCTAssertTrue(firstRead.image === secondRead.image,
            "Repeated Canvas reads must reuse the one CGImage decoded when the frame was accepted.")
        XCTAssertNil(GeometryMeshPlotFramePolicy.familyToSuppressBaseLayer(
            output: firstRead, requestedIdentity: "request-identity", requestedFamily: .mesh),
            "A frame from a different source renderer cannot suppress this layer's base rendering.")
    }
}
