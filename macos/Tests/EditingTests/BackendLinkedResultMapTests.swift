import CryptoKit
import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendLinkedResultMapTests {
    private struct Fixture: Decodable {
        let project: String
        let anchor: String
        let candidatePlan: String
        let profileIndex: Int
        let mapType: String
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_LINKED_RESULT_MAP_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func actualLinkedResultSourcesRenderOneSharedRasterThroughTheProductionProvider() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixtureDirectory = URL(fileURLWithPath: try #require(environment["HECRAS_LINKED_RESULT_MAP_ACCEPTANCE_DIRECTORY"]))
        let executable = URL(fileURLWithPath: try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"]))
        let workingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("linked-result-map-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: fixtureDirectory, to: workingRoot)
        defer { try? FileManager.default.removeItem(at: workingRoot) }

        let fixture = try JSONDecoder().decode(Fixture.self,
            from: Data(contentsOf: workingRoot.appendingPathComponent("LINKED_RESULT_MAP_FIXTURE.json")))
        let project = workingRoot.appendingPathComponent(fixture.project)
        let anchor = workingRoot.appendingPathComponent(fixture.anchor)
        let originalBytes = try LinkedMapSourceByteSnapshot(root: workingRoot)
        #expect(originalBytes.containsHDF)
        let projectBytes = try Data(contentsOf: project)
        let anchorBytes = try Data(contentsOf: anchor)
        let xml = try #require(String(data: projectBytes, encoding: .utf8))
        let revision = SHA256.hash(data: anchorBytes).map { String(format: "%02X", $0) }.joined()
        let client = BackendProcessClient(executableURL: executable)
        let context = try await client.request("result.planContext",
            parameters: ResultPlanContextRequest(projectPath: project.path, projectXml: xml,
                resultPath: anchor.path, revision: revision), as: ResultPlanContextSnapshot.self)
        let selectedGroup = try #require(context.candidateGroups.first { $0.planName == fixture.candidatePlan })
        let selection = LinkedResultSelection(projectPath: context.projectPath,
            projectRevision: context.projectRevision, anchor: context.anchor,
            selectedGroups: [selectedGroup])
        let mapType = try #require(LinkedResultMapType(rawValue: fixture.mapType))
        let session = LinkedResultMapSession(client: client)
        let viewport = RasterMapViewExtent(minX: 0, minY: 0, maxX: 1, maxY: 1,
            pixelWidth: 32, pixelHeight: 32)

        await session.render(selection, projectXML: xml, profileIndex: fixture.profileIndex,
            mapType: mapType, frameMode: .profile, viewport: viewport)
        let profile = try #require(session.snapshot)
        #expect(session.errorCode == nil && !session.isLoading)
        #expect(profile.sources.count == 2 && profile.layers.count == 2 && session.rasters.count == 2)
        #expect(profile.layers.allSatisfy { $0.width == viewport.pixelWidth &&
            $0.height == viewport.pixelHeight && $0.rgba.count == viewport.pixelWidth * viewport.pixelHeight * 4 })
        #expect(profile.layers.map(\.profileIndex).sorted() == [0, fixture.profileIndex])
        #expect(profile.layers.map(\.time).uniqued().count == 1)
        #expect(profile.layers[0].rgba != profile.layers[1].rgba)
        #expect(!profile.minimumAvailable && !profile.maximumAvailable)

        await session.render(selection, projectXML: xml, profileIndex: fixture.profileIndex,
            mapType: mapType, frameMode: .maximum, viewport: viewport)
        let maximum = try #require(session.snapshot)
        #expect(maximum.layers.isEmpty && !maximum.maximumAvailable)
        #expect(maximum.unavailableReason == "maximumUnavailable")

        await session.render(selection, projectXML: xml, profileIndex: fixture.profileIndex,
            mapType: mapType, frameMode: .minimum, viewport: viewport)
        let minimum = try #require(session.snapshot)
        #expect(minimum.layers.isEmpty && !minimum.minimumAvailable)
        #expect(minimum.unavailableReason == "minimumUnavailable")
        #expect(try originalBytes.matches(root: workingRoot))
        session.cancel()
        #expect(session.snapshot == nil && session.rasters.isEmpty && !session.isLoading)
    }
}

private struct LinkedMapSourceByteSnapshot {
    private let files: [String: String]
    var containsHDF: Bool {
        files.keys.contains { ["h5", "hdf"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
    }

    init(root: URL) throws {
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey]) else { throw CocoaError(.fileReadUnknown) }
        var snapshot: [String: String] = [:]
        for case let file as URL in enumerator {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let relativePath = String(file.path.dropFirst(root.path.count + 1))
            snapshot[relativePath] = SHA256.hash(data: try Data(contentsOf: file))
                .map { String(format: "%02X", $0) }.joined()
        }
        files = snapshot
    }

    func matches(root: URL) throws -> Bool {
        guard !files.isEmpty else { return false }
        let current = try LinkedMapSourceByteSnapshot(root: root)
        return files == current.files
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] { Array(Set(self)) }
}
