import Foundation
import Testing
@testable import HECRAS2025

@Suite("Feature query backend ownership")
@MainActor
struct FeatureQueryBackendIdentityTests {
    private let projectSHA = String(repeating: "A", count: 64)
    private let xmlSHA = String(repeating: "B", count: 64)
    private let visSHA = String(repeating: "C", count: 64)
    private let otherSHA = String(repeating: "D", count: 64)

    @Test func sameNamedMapsCannotAcceptEachOthersResults() {
        let map = request()
        #expect(BackendFeatureQueryProvider.matches(reply(map), map: map, projectRevision: projectSHA))
        #expect(!BackendFeatureQueryProvider.matches(reply(map, mapID: UUID().uuidString), map: map, projectRevision: projectSHA))
        #expect(!BackendFeatureQueryProvider.matches(reply(map, index: 2), map: map, projectRevision: projectSHA))
        #expect(!BackendFeatureQueryProvider.matches(reply(map, mapType: "Plan"), map: map, projectRevision: projectSHA))
        #expect(!BackendFeatureQueryProvider.matches(reply(map, persisted: false), map: map, projectRevision: projectSHA))
    }

    @Test func projectAndMapRevisionsBindPreviewAndExportToCapturedBytes() {
        let map = request()
        #expect(!BackendFeatureQueryProvider.matches(reply(map, projectRevision: otherSHA), map: map, projectRevision: projectSHA))
        #expect(!BackendFeatureQueryProvider.matches(reply(map, xmlSHA: otherSHA), map: map, projectRevision: projectSHA))
        #expect(!BackendFeatureQueryProvider.matches(reply(map, visSHA: otherSHA), map: map, projectRevision: projectSHA))
        #expect(!BackendFeatureQueryProvider.matches(reply(map, projectPath: "/tmp/other/project.ras"), map: map, projectRevision: projectSHA))
    }

    private func request() -> MapTreeMapIdentity {
        .init(projectPath: "/tmp/feature-query/project.ras", projectXml: "<Project/>", projectXmlSHA: xmlSHA,
              mapID: "5D552ACF-AB55-4337-8209-84422C79FCC4", mapIndex: 1,
              mapName: "Map", mapType: "Project", expectedVisualizationRevision: visSHA)
    }

    private func reply(_ map: MapTreeMapIdentity, mapID: String? = nil, index: Int? = nil,
                       mapType: String? = nil, persisted: Bool = true, projectRevision: String? = nil,
                       xmlSHA: String? = nil, visSHA: String? = nil, projectPath: String? = nil) -> MapSourceMapCapture {
        .init(projectPath: projectPath ?? map.projectPath, projectRevision: projectRevision ?? self.projectSHA,
              projectXmlSHA: xmlSHA ?? self.xmlSHA, visualizationPath: "/tmp/feature-query/project.vis",
              visualizationRevision: visSHA ?? self.visSHA, mapID: mapID ?? map.mapID,
              mapIndex: index ?? map.mapIndex, mapName: map.mapName, mapType: mapType ?? map.mapType,
              isPersisted: persisted)
    }
}
