import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@Suite
struct ProjectGeometryMapProviderValidationTests {
    @Test @MainActor
    func acceptsEveryHiddenSparseSourceDefaultGeometryChild() throws {
        let fixture = makeFixture()
        let sourceDefaults = [
            ("ConceptualMesh", "Conceptual Mesh"),
            ("FlowAreaLayer", "Computational Mesh"),
            ("CulvertBarrelLayer", "Culvert Barrels")
        ]

        for (nodeType, nodeName) in sourceDefaults {
            let state = makeLayerState(fixture: fixture, nodeType: nodeType, nodeName: nodeName)
            try BackendProjectGeometryMapProvider.validateLayer(state,
                expectedNodeType: nodeType, geometryNode: fixture.geometryNode,
                geometryAssetPath: fixture.geometryAssetPath, geometryChecked: true)
        }
    }

    @Test @MainActor
    func rejectsForgedOrVisibleSparseDefaultChildren() throws {
        let fixture = makeFixture()

        let mismatchedOwner = makeLayerState(fixture: fixture, nodeType: "CulvertBarrelLayer",
            parentGeometryAssetID: "/tmp/geometry-other/Geometry B.hdf")
        #expect(throws: ProjectGeometryMapError.self) {
            try validate(mismatchedOwner, fixture: fixture, type: "CulvertBarrelLayer")
        }

        let mismatchedParentPath = makeLayerState(fixture: fixture, nodeType: "CulvertBarrelLayer",
            parentGeometryNodePath: [1, 9])
        #expect(throws: ProjectGeometryMapError.self) {
            try validate(mismatchedParentPath, fixture: fixture, type: "CulvertBarrelLayer")
        }

        let mismatchedParentName = makeLayerState(fixture: fixture, nodeType: "CulvertBarrelLayer",
            parentGeometryNodeName: "Other Geometry")
        #expect(throws: ProjectGeometryMapError.self) {
            try validate(mismatchedParentName, fixture: fixture, type: "CulvertBarrelLayer")
        }

        let mismatchedRoot = makeLayerState(fixture: fixture, nodeType: "CulvertBarrelLayer",
            rootName: "Other Geometries")
        #expect(throws: ProjectGeometryMapError.self) {
            try validate(mismatchedRoot, fixture: fixture, type: "CulvertBarrelLayer")
        }

        let wrongType = makeLayerState(fixture: fixture, nodeType: "OtherLayer")
        #expect(throws: ProjectGeometryMapError.self) {
            try validate(wrongType, fixture: fixture, type: "CulvertBarrelLayer")
        }

        let visibleDefault = makeLayerState(fixture: fixture, nodeType: "CulvertBarrelLayer",
            isChecked: true, effectiveVisible: true)
        #expect(throws: ProjectGeometryMapError.self) {
            try validate(visibleDefault, fixture: fixture, type: "CulvertBarrelLayer")
        }

        let checkedButHiddenDefault = makeLayerState(fixture: fixture, nodeType: "CulvertBarrelLayer",
            isChecked: true, effectiveVisible: false)
        #expect(throws: ProjectGeometryMapError.self) {
            try validate(checkedButHiddenDefault, fixture: fixture, type: "CulvertBarrelLayer")
        }
    }

    @Test @MainActor
    func persistedChildrenKeepDirectPathValidation() throws {
        let fixture = makeFixture()
        let parentPath = try #require(fixture.geometryNode.nodePath)
        let persisted = makeLayerState(fixture: fixture, nodeType: "CulvertBarrelLayer",
            nodePath: parentPath + [0], isChecked: true, effectiveVisible: true)

        try validate(persisted, fixture: fixture, type: "CulvertBarrelLayer")

        let persistedWithoutPath = makeLayerState(fixture: fixture, nodeType: "CulvertBarrelLayer",
            nodePath: nil, isChecked: true, effectiveVisible: false)
        #expect(throws: ProjectGeometryMapError.self) {
            try validate(persistedWithoutPath, fixture: fixture, type: "CulvertBarrelLayer")
        }

        let implicitUnknownLayer = makeLayerState(fixture: fixture, nodeType: "UnknownLayer")
        #expect(throws: ProjectGeometryMapError.self) {
            try validate(implicitUnknownLayer, fixture: fixture, type: "UnknownLayer")
        }

        let implicitTopologyWithDifferentExpectedType = makeLayerState(fixture: fixture,
            nodeType: "ConceptualMesh")
        #expect(throws: ProjectGeometryMapError.self) {
            try validate(implicitTopologyWithDifferentExpectedType,
                fixture: fixture, type: "FlowAreaLayer")
        }
    }

    @MainActor
    private func validate(_ state: MapGeometryLayerState, fixture: Fixture,
                          type: String) throws {
        try BackendProjectGeometryMapProvider.validateLayer(state,
            expectedNodeType: type, geometryNode: fixture.geometryNode,
            geometryAssetPath: fixture.geometryAssetPath, geometryChecked: true)
    }

    private func makeLayerState(fixture: Fixture, nodeType: String,
                                nodeName: String? = nil, nodePath: [Int]? = nil,
                                rootName: String? = nil,
                                parentGeometryAssetID: String? = nil,
                                parentGeometryNodePath: [Int]? = nil,
                                parentGeometryNodeName: String? = nil,
                                isChecked: Bool = false,
                                effectiveVisible: Bool = false) -> MapGeometryLayerState {
        let locator = CatalogTreeNodeLocator(
            rootName: rootName ?? fixture.geometryNode.rootName,
            nodeType: nodeType,
            nodeName: nodeName ?? "Source \(nodeType)",
            nodePath: nodePath,
            assetID: nil,
            parentGeometryAssetID: parentGeometryAssetID ?? fixture.geometryAssetPath,
            parentGeometryNodePath: parentGeometryNodePath ?? fixture.geometryNode.nodePath,
            parentGeometryNodeName: parentGeometryNodeName ?? fixture.geometryNode.nodeName)
        return MapGeometryLayerState(nodeID: "source-default-\(nodeType)", locator: locator,
            isChecked: isChecked, effectiveVisible: effectiveVisible,
            status: .available, diagnostic: nil)
    }

    private func makeFixture() -> Fixture {
        let geometryAssetPath = SourceFilePaths.canonical(
            URL(fileURLWithPath: "/tmp/geometry-owner/Geometry A.hdf"))
        let geometryNode = CatalogTreeNodeLocator(rootName: "Geometries",
            nodeType: "Geometry", nodeName: "Geometry A", nodePath: [1, 2],
            assetID: geometryAssetPath)
        return Fixture(geometryNode: geometryNode, geometryAssetPath: geometryAssetPath)
    }

    private struct Fixture {
        let geometryNode: CatalogTreeNodeLocator
        let geometryAssetPath: String
    }
}
