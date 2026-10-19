import Foundation
import Testing
@testable import HECRAS2025

struct CatalogLayerDiagnosticsContractTests {
    @Test
    func olderTreePayloadsKeepMissingDiagnosticsUnknown() throws {
        let data = Data(#"{"roots":[{"id":"asset:/model.g01","sourceClass":"ObservableGeometry","name":"Geometry"}]}"#.utf8)
        let response = try JSONDecoder().decode(CatalogTreeSnapshotResponse.self, from: data)
        let node = try #require(response.roots.first?.layerTreeNode)

        #expect(response.roots[0].layerErrors == nil)
        #expect(response.roots[0].diagnosticStatus == nil)
        #expect(node.layerErrors == nil)
        #expect(CatalogLayerDiagnosticsProjection.state(for: node) == .notLoaded)
    }

    @Test
    func loadedEmptyDiagnosticsDifferFromUnavailableAndChangedSources() throws {
        let data = Data(#"{"roots":[{"id":"empty","sourceClass":"ObservableTerrain","name":"Terrain","diagnosticStatus":"loaded","diagnosticSourceIdentity":"/task/model.terrain.hdf","diagnosticSourceRevision":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","layerErrors":[]},{"id":"unavailable","sourceClass":"ObservableTerrain","name":"Terrain","diagnosticStatus":"unavailable","layerErrors":null},{"id":"changed","sourceClass":"ObservableTerrain","name":"Terrain","diagnosticStatus":"sourceChanged","layerErrors":[{"code":"STALE","severity":"Error","evaluatedMessage":"Must be suppressed","logData":[]}]}]}"#.utf8)
        let response = try JSONDecoder().decode(CatalogTreeSnapshotResponse.self, from: data)
        let empty = try #require(response.roots.first?.layerTreeNode)
        let unavailable = try #require(response.roots.dropFirst().first?.layerTreeNode)
        let changed = try #require(response.roots.dropFirst(2).first?.layerTreeNode)

        #expect(empty.layerErrors?.isEmpty == true)
        #expect(empty.diagnosticSourceIdentity == "/task/model.terrain.hdf")
        #expect(empty.diagnosticSourceRevision == String(repeating: "A", count: 64))
        #expect(CatalogLayerDiagnosticsProjection.state(for: empty) == .noIssues)
        #expect(CatalogLayerDiagnosticsProjection.state(for: unavailable) == .unavailable)
        #expect(CatalogLayerDiagnosticsProjection.state(for: changed) == .sourceChanged)
    }

    @Test
    func diagnosticsRemainBoundToNodeIdentityWhenNamesMatch() throws {
        let data = Data(#"{"roots":[{"id":"asset:/task/a.g01","sourceClass":"ObservableGeometry","name":"Geometry","assetID":"/task/a.g01","diagnosticStatus":"loaded","diagnosticSourceIdentity":"/task/a.g01","diagnosticSourceRevision":"1111111111111111111111111111111111111111111111111111111111111111","layerErrors":[{"code":"GEO_A","severity":"Warning","evaluatedMessage":"First source warning","logData":[{"key":"Asset","value":"/task/a.g01"}]}]},{"id":"asset:/task/b.g01","sourceClass":"ObservableGeometry","name":"Geometry","assetID":"/task/b.g01","diagnosticStatus":"loaded","diagnosticSourceIdentity":"/task/b.g01","diagnosticSourceRevision":"2222222222222222222222222222222222222222222222222222222222222222","layerErrors":[{"code":"GEO_B","severity":"Error","evaluatedMessage":"Second source error","logData":[{"key":"Asset","value":"/task/b.g01"}]}]}]}"#.utf8)
        let response = try JSONDecoder().decode(CatalogTreeSnapshotResponse.self, from: data)
        let nodes = response.roots.map(\.layerTreeNode)

        #expect(nodes.map(\.name) == ["Geometry", "Geometry"])
        #expect(nodes.map(\.id) == ["asset:/task/a.g01", "asset:/task/b.g01"])
        #expect(nodes.compactMap(\.assetID) == ["/task/a.g01", "/task/b.g01"])
        #expect(nodes[0].layerErrors?.first?.evaluatedMessage == "First source warning")
        #expect(nodes[1].layerErrors?.first?.evaluatedMessage == "Second source error")
        #expect(nodes[0].diagnosticSourceRevision != nodes[1].diagnosticSourceRevision)
    }

    @Test
    func sourceSeverityOrderMatchesMessageSeverityEnum() {
        let diagnostics = ["Information", "Trace", "Debug", "Warning", "Error"].map { severity in
            CatalogLayerDiagnostic(code: severity, severity: severity,
                evaluatedMessage: severity, logData: [])
        }

        #expect(CatalogLayerDiagnosticsProjection.highestSeverity(in: diagnostics) == .error)
        #expect(CatalogLayerDiagnosticsProjection.highestSeverity(in: Array(diagnostics.prefix(1))) == .information)
        #expect(CatalogLayerDiagnosticsProjection.highestSeverity(in: [
            CatalogLayerDiagnostic(code: "future", severity: "FutureSeverity",
                evaluatedMessage: "Retain raw value", logData: [])
        ]) == .unknown)
    }

    @Test
    func failedDiagnosticReadCarriesItsFailureOutsideSourceMessages() throws {
        let data = Data(#"{"roots":[{"id":"asset:/task/nvalue.hdf","sourceClass":"ObservableNValueLayer","name":"N-Value","diagnosticStatus":"readFailed","diagnosticReadError":"The source file could not be read.","diagnosticSourceIdentity":"/task/nvalue.hdf","layerErrors":null}]}"#.utf8)
        let response = try JSONDecoder().decode(CatalogTreeSnapshotResponse.self, from: data)
        let node = try #require(response.roots.first?.layerTreeNode)

        #expect(node.layerErrors == nil)
        #expect(CatalogLayerDiagnosticsProjection.state(for: node) == .readFailed("The source file could not be read."))
    }

    @Test
    func unknownStatusAndMultiResultGroupNeverInferCleanStateFromChildData() {
        let unknown = LayerTreeNode(id: "asset:/task/terrain.hdf", sourceClass: "ObservableTerrain",
            name: "Terrain", layerErrors: [], diagnosticStatus: "futureStatus")
        let result = LayerTreeNode(id: "result:/task/result.hdf", sourceClass: "ObservableResult",
            name: "Result", assetID: "/task/result.hdf", layerErrors: [
                CatalogLayerDiagnostic(code: "R", severity: "Error", evaluatedMessage: "Selected result error", logData: [])
            ], diagnosticStatus: "loaded")
        let group = LayerTreeNode(id: "group:plan", sourceClass: "MultiResultNodeVM",
            name: "Plan results", children: [result])

        #expect(CatalogLayerDiagnosticsProjection.state(for: unknown) == .notLoaded)
        #expect(CatalogLayerDiagnosticsProjection.state(for: result) == .issues(result.layerErrors!))
        #expect(CatalogLayerDiagnosticsProjection.state(for: group) == .resultSelectionRequired)
    }
}
