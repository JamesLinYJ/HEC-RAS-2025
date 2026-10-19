import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import RASWorkspaceCore
import XCTest

final class ProjectDocumentTests: XCTestCase {
    func testFileLinksRemainAssetsAndConnectionsWithoutFollowingDirectoryCycles() throws {
        // macOS exposes the same temporary parent through /var and
        // /private/var. Normalize the parent only: resolving the final file
        // link would hide a regression that replaced its presentation URL.
        func presentedFile(_ url: URL) -> URL {
            url.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(url.lastPathComponent)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let layers = folder.appendingPathComponent("Map Layers", isDirectory: true)
        try FileManager.default.createDirectory(at: layers, withIntermediateDirectories: true)
        let backing = folder.appendingPathComponent("backing.geojson")
        try Data("{\"type\":\"FeatureCollection\",\"features\":[]}".utf8).write(to: backing)
        let alias = layers.appendingPathComponent("linked.geojson")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: backing)
        try FileManager.default.createSymbolicLink(at: layers.appendingPathComponent("cycle"), withDestinationURL: layers)
        try FileManager.default.createSymbolicLink(at: layers.appendingPathComponent("missing.geojson"),
            withDestinationURL: folder.appendingPathComponent("does-not-exist.geojson"))
        let projectURL = folder.appendingPathComponent("Links.ras")
        try Data("<Project/>".utf8).write(to: projectURL)
        let document = try ProjectDocument(contentsOf: projectURL)
        XCTAssertEqual(document.assets.map { presentedFile($0.url) }, [presentedFile(alias)])
        try document.connectFiles([(name: "Linked file", target: alias)])
        try document.connectDirectory(layers, name: "Linked folder", searchPattern: "*.geojson", recurse: true)
        let connection = try XCTUnwrap(document.connections.first { $0.name == "Linked folder" })
        XCTAssertEqual(try connection.files(relativeTo: folder, mappings: []).map(presentedFile), [presentedFile(alias)])
        try document.save()
        let reopened = try ProjectDocument(contentsOf: projectURL)
        XCTAssertEqual(reopened.assets.map { presentedFile($0.url) }, [presentedFile(alias)])
        let resolved = try XCTUnwrap(reopened.connections.first { $0.name == "Linked file" }?.resolve(relativeTo: folder, mappings: []))
        XCTAssertEqual(presentedFile(resolved), presentedFile(alias))
        XCTAssertEqual(try Data(contentsOf: alias), try Data(contentsOf: backing))
    }

    func testBackingInputsRemainBrowsableWithoutBecomingModelAssociationRows() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        for section in ["Geometries", "Terrains"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(section), withIntermediateDirectories: true)
        }
        for path in ["Geometries/Geometry.h5", "Geometries/arcs.geojson", "Terrains/Terrain.h5", "Terrains/flat.tif"] {
            try Data().write(to: folder.appendingPathComponent(path))
        }
        let projectURL = folder.appendingPathComponent("Catalog.ras")
        let bytes = Data("<Project><GeometryAssociations><GeometryAssociation Geometry='Missing' Terrain='Missing terrain' Extra='keep'/></GeometryAssociations></Project>".utf8)
        try bytes.write(to: projectURL)

        let document = try ProjectDocument(contentsOf: projectURL)

        XCTAssertEqual(Set(document.assets.map(\.name)), ["Geometry", "arcs", "Terrain", "flat"])
        XCTAssertEqual(Set(document.assets.filter(\.isModelFile).map(\.name)), ["Geometry", "Terrain"])
        XCTAssertEqual(Set(document.associationRows(group: "GeometryAssociations").map(\.name)), ["Geometry", "Missing"])
        XCTAssertEqual(document.associations.first?.fields["Extra"], "keep")
        XCTAssertEqual(try Data(contentsOf: projectURL), bytes)
    }

    func testDirectoryConnectionPreservesPatternAndRecursionAcrossRelocation() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("图层", isDirectory: true)
        let nested = folder.appendingPathComponent("子目录", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let top = folder.appendingPathComponent("河道.geojson")
        let child = nested.appendingPathComponent("断面.GEOJSON")
        let ignored = folder.appendingPathComponent("说明.txt")
        for file in [top, child, ignored] { try Data("test".utf8).write(to: file) }
        let url = base.appendingPathComponent("中文项目.ras")
        try Data("<Project><Unknown Keep='yes'/></Project>".utf8).write(to: url)
        let document = try ProjectDocument(contentsOf: url)
        try document.connectDirectory(folder, name: "本机图层", searchPattern: "*.geojson", recurse: true)
        try document.save()
        let reopened = try ProjectDocument(contentsOf: url)
        let connection = try XCTUnwrap(reopened.connections.first)
        XCTAssertEqual(connection.type, "Directory")
        XCTAssertEqual(connection.relativePath, "图层")
        XCTAssertEqual(connection.searchPattern, "*.geojson")
        XCTAssertTrue(connection.recurse)
        XCTAssertEqual(Set(try connection.files(relativeTo: base, mappings: []).map { $0.resolvingSymlinksInPath() }), Set([top, child].map { $0.resolvingSymlinksInPath() }))
        let flat = ProjectConnection(id: "0", name: "Flat", type: "Directory", relativePath: "图层", absolutePath: "C:\\Old\\图层", searchPattern: "*.geojson")
        XCTAssertEqual(try flat.files(relativeTo: base, mappings: []).map { $0.resolvingSymlinksInPath() }, [top.resolvingSymlinksInPath()])
        let restored = try XMLDocument(data: Data(contentsOf: url))
        XCTAssertEqual(restored.rootElement()?.elements(forName: "Unknown").first?.attribute(forName: "Keep")?.stringValue, "yes")
    }

    func testRemovingConnectionKeepsFilesAndOtherXML() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let result = base.appendingPathComponent("结果.h5")
        try Data("task fixture".utf8).write(to: result)
        let project = base.appendingPathComponent("项目.ras")
        try Data("<Project><Unknown/><Connections><Connection Name='Result' Type='File'><RelativePath>结果.h5</RelativePath><Custom>Keep</Custom></Connection><Connection Name='Other' Type='File'><AbsolutePath>/missing</AbsolutePath></Connection></Connections></Project>".utf8).write(to: project)
        let document = try ProjectDocument(contentsOf: project)
        try document.removeConnection(id: XCTUnwrap(document.connections.first).id); try document.save()
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        XCTAssertEqual(try ProjectDocument(contentsOf: project).connections.map(\.name), ["Other"])
        XCTAssertTrue(String(data: try Data(contentsOf: project), encoding: .utf8)!.contains("<Unknown"))
    }

    func testRenamingConnectionPreservesNodeIdentityAndUnknownXMLAcrossSave() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appendingPathComponent("Rename.ras")
        let source = """
        <Project Vendor="preserve">
          <Connections>
            <Connection Name="Original" Type="Directory" VendorConnection="preserve">
              <Source VendorSource="preserve"><RelativePath>inputs</RelativePath><Unknown>Keep child</Unknown></Source>
              <Description>Keep description</Description><Custom>Keep connection data</Custom>
            </Connection>
            <Connection Name="Other" Type="File"><AbsolutePath>/missing</AbsolutePath></Connection>
          </Connections>
          <UnknownProjectData>Keep project data</UnknownProjectData>
        </Project>
        """
        try Data(source.utf8).write(to: project)

        let document = try ProjectDocument(contentsOf: project)
        let original = try XCTUnwrap(document.connections.first { $0.name == "Original" })
        XCTAssertThrowsError(try document.renameConnection(original, to: "Other"))
        XCTAssertThrowsError(try document.renameConnection(original, to: "  \n"))
        try document.renameConnection(original, to: "Renamed")

        let renamed = try XCTUnwrap(document.connections.first { $0.name == "Renamed" })
        XCTAssertEqual(renamed.id, original.id)
        XCTAssertEqual(renamed.relativePath, "inputs")
        XCTAssertThrowsError(try document.renameConnection(original, to: "Stale snapshot"))
        try document.save()

        let reopened = try ProjectDocument(contentsOf: project)
        XCTAssertEqual(reopened.connections.map(\.name), ["Renamed", "Other"])
        XCTAssertEqual(reopened.connections.first?.relativePath, "inputs")
        let xml = try XMLDocument(data: Data(contentsOf: project))
        let root = try XCTUnwrap(xml.rootElement())
        let connection = try XCTUnwrap(root.elements(forName: "Connections").first?.elements(forName: "Connection").first)
        XCTAssertEqual(root.attribute(forName: "Vendor")?.stringValue, "preserve")
        XCTAssertEqual(connection.attribute(forName: "VendorConnection")?.stringValue, "preserve")
        XCTAssertEqual(connection.elements(forName: "Source").first?.attribute(forName: "VendorSource")?.stringValue, "preserve")
        XCTAssertEqual(connection.elements(forName: "Source").first?.elements(forName: "Unknown").first?.stringValue, "Keep child")
        XCTAssertEqual(connection.elements(forName: "Description").first?.stringValue, "Keep description")
        XCTAssertEqual(connection.elements(forName: "Custom").first?.stringValue, "Keep connection data")
        XCTAssertEqual(root.elements(forName: "UnknownProjectData").first?.stringValue, "Keep project data")
    }

    func testDirectoryConnectionRejectsAFileAtTheRelativeLocation() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = base.appendingPathComponent("actual", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("not a directory".utf8).write(to: base.appendingPathComponent("relative"))
        let connection = ProjectConnection(id: "0", name: "Directory", type: "Directory", relativePath: "relative", absolutePath: folder.path)
        XCTAssertEqual(try connection.resolve(relativeTo: base, mappings: []), folder)
        XCTAssertThrowsError(try ProjectConnection(id: "0", name: "D", type: "Directory", relativePath: "actual", absolutePath: "", searchPattern: "../*").files(relativeTo: base, mappings: []))
    }

    func testWindowsFileURIsRequireTheSameExplicitMapping() throws {
        let base = URL(fileURLWithPath: "/project")
        let mappings = [PathMapping(sourceRoot: "C:\\Data", destination: URL(fileURLWithPath: "/local")), PathMapping(sourceRoot: "\\\\server\\share", destination: URL(fileURLWithPath: "/network"))]
        XCTAssertThrowsError(try PlatformPaths.resolve("file:///C:/Data/%E6%B2%B3%E9%81%93.h5", relativeTo: base))
        XCTAssertEqual(try PlatformPaths.resolve("file:///C:/Data/%E6%B2%B3%E9%81%93.h5", relativeTo: base, mappings: mappings).path, "/local/河道.h5")
        XCTAssertEqual(try PlatformPaths.resolve("file://server/share/river.h5", relativeTo: base, mappings: mappings).path, "/network/river.h5")
        XCTAssertThrowsError(try PlatformPaths.resolve("C:river.h5", relativeTo: base))
        XCTAssertThrowsError(try PlatformPaths.resolve("\\river.h5", relativeTo: base))
    }

    func testPresentationPathResolutionLexicallyNormalizesWithoutFollowingFinalSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = root.appendingPathComponent("Project", isDirectory: true)
        let external = root.appendingPathComponent("External", isDirectory: true)
        let intermediate = external.appendingPathComponent("subdir", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: intermediate, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let target = external.appendingPathComponent("Channel.data")
        let alias = external.appendingPathComponent("Channel.geojson")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)

        let relative = try PlatformPaths.resolvePresentationPath(
            "../External/subdir/../Channel.geojson", relativeTo: project)
        XCTAssertEqual(relative.pathExtension, "geojson")
        XCTAssertEqual(relative.path, alias.path)
        XCTAssertEqual(SourceFilePaths.canonical(relative), SourceFilePaths.canonical(target))

        let mapped = try PlatformPaths.resolvePresentationPath("C:\\Data\\subdir\\..\\Channel.geojson",
            relativeTo: project, mappings: [PathMapping(sourceRoot: "C:\\Data", destination: external)])
        XCTAssertEqual(mapped.pathExtension, "geojson")
        XCTAssertEqual(mapped.path, alias.path)
        XCTAssertEqual(SourceFilePaths.canonical(mapped), SourceFilePaths.canonical(target))

        let fileReference = "file://" + external.path + "/subdir/../Channel.geojson"
        let fileURL = try PlatformPaths.resolvePresentationPath(fileReference, relativeTo: project)
        XCTAssertEqual(fileURL.pathExtension, "geojson")
        XCTAssertEqual(fileURL.path, alias.path)
        XCTAssertEqual(SourceFilePaths.canonical(fileURL), SourceFilePaths.canonical(target))
    }

    func testUTF16ChineseProjectRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ras")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = "<?xml version='1.0' encoding='UTF-16'?><Project><Description>中文项目说明</Description><Extra>保留</Extra></Project>"
        try XCTUnwrap(text.data(using: .utf16)).write(to: url)
        let document = try ProjectDocument(contentsOf: url)
        XCTAssertEqual(document.description, "中文项目说明")
        document.description = "更新后的中文说明"; try document.save()
        XCTAssertEqual(try ProjectDocument(contentsOf: url).description, "更新后的中文说明")
        let restored = try XMLDocument(data: Data(contentsOf: url))
        XCTAssertEqual(restored.rootElement()?.elements(forName: "Extra").first?.stringValue, "保留")
    }

    func testConnectionPrefersRelocatedRelativePath() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let layer = folder.appendingPathComponent("layer.geojson")
        try Data("{\"type\":\"FeatureCollection\",\"features\":[]}".utf8).write(to: layer)
        let url = folder.appendingPathComponent("P.ras")
        try Data("<Project><Connections><Connection Name='L' Type='File'><RelativePath>layer.geojson</RelativePath><AbsolutePath>C:\\Old\\layer.geojson</AbsolutePath></Connection></Connections></Project>".utf8).write(to: url)
        let document = try ProjectDocument(contentsOf: url)
        let connection = try XCTUnwrap(document.connections.first)
        XCTAssertEqual(try connection.resolve(relativeTo: folder, mappings: []), layer)
    }

    func testGeoJSONKeepsPolygonHolesAndAttributes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".geojson")
        defer { try? FileManager.default.removeItem(at: url) }
        let json = """
        {"type":"Feature","properties":{"名称":"合成图层","value":7},"geometry":{"type":"Polygon","coordinates":[[[0,0],[10,0],[10,10],[0,10],[0,0]],[[2,2],[4,2],[4,4],[2,4],[2,2]]]}}
        """
        try Data(json.utf8).write(to: url)
        let layer = try MapVectorLayer(contentsOf: url)
        XCTAssertEqual(layer.features.count, 1)
        XCTAssertEqual(layer.features[0].paths.count, 2)
        XCTAssertEqual(layer.features[0].attributes["名称"], "合成图层")
        XCTAssertEqual(layer.features[0].attributes["value"], "7")
        XCTAssertEqual(layer.features[0].paths[1].count, 5)
    }

    func testPreservesUnknownXMLAndAssociationFields() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("测试项目.ras")
        let xml = """
        <Project Custom="retain"><Projection Type="Local">SI</Projection><Description>old</Description><Unknown Future="yes">中文 &amp; 保留</Unknown><PlanAssociations><PlanAssociation Plan="P" Geometry="G" BoundaryCondition="B" Extra="keep"/></PlanAssociations></Project>
        """
        try Data(xml.utf8).write(to: url)
        let document = try ProjectDocument(contentsOf: url)
        XCTAssertEqual(document.name, "测试项目")
        document.description = "new <文字> & data"
        try document.setAssociation(XCTUnwrap(document.associations.first), field: "Geometry", value: "G2")
        try document.save()
        let reopened = try ProjectDocument(contentsOf: url)
        XCTAssertEqual(reopened.description, "new <文字> & data")
        XCTAssertEqual(reopened.attributes["Custom"], "retain")
        XCTAssertEqual(reopened.associations.first?.fields["Geometry"], "G2")
        XCTAssertEqual(reopened.associations.first?.fields["Extra"], "keep")
        let restored = try XMLDocument(data: Data(contentsOf: url))
        XCTAssertEqual(restored.rootElement()?.elements(forName: "Unknown").first?.stringValue, "中文 & 保留")
    }

    func testRejectsOverwriteAfterExternalEdit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ras")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("<Project><Description>A</Description></Project>".utf8).write(to: url)
        let document = try ProjectDocument(contentsOf: url)
        let changed = Data("<Project><Description>B</Description></Project>".utf8)
        try changed.write(to: url)
        document.description = "C"
        XCTAssertThrowsError(try document.save())
        XCTAssertEqual(try Data(contentsOf: url), changed)
    }

    func testWindowsRelativeAndMappedAbsolutePaths() throws {
        let base = URL(fileURLWithPath: "/project")
        XCTAssertEqual(try PlatformPaths.resolve("Geometries\\河道.h5", relativeTo: base).path, "/project/Geometries/河道.h5")
        XCTAssertThrowsError(try PlatformPaths.resolve("C:\\Project\\河道.h5", relativeTo: base))
        let mapping = PathMapping(sourceRoot: "C:\\Project", destination: URL(fileURLWithPath: "/local"))
        XCTAssertEqual(try PlatformPaths.resolve("c:\\Project\\河道.h5", relativeTo: base, mappings: [mapping]).path, "/local/河道.h5")
        XCTAssertThrowsError(try PlatformPaths.resolve("C:\\ProjectOther\\file.h5", relativeTo: base, mappings: [mapping]))
    }

    func testRejectsExternalEntities() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ras")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("<!DOCTYPE Project [<!ENTITY leak SYSTEM 'file:///etc/passwd'>]><Project><Description>&leak;</Description></Project>".utf8).write(to: url)
        XCTAssertThrowsError(try ProjectDocument(contentsOf: url))
    }
}
