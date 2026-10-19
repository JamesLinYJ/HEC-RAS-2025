import Foundation
import RASWorkspaceCore

struct MapFileLoadResult: Sendable {
    let layers: [MapVectorLayer]
    let issues: [String]
}
enum MapFileLoader {
    static func load(files initial: [URL], connections: [ProjectConnection], directory: URL, mappings: [PathMapping]) throws -> MapFileLoadResult {
        var files = initial
        var issues: [String] = []
        for connection in connections {
            try Task.checkCancellation()
            do {
                files += try connection.files(relativeTo: directory, mappings: mappings)
                    .filter { ["json", "geojson"].contains($0.pathExtension.lowercased()) }
            } catch { issues.append(error.localizedDescription) }
        }
        var installed: Set<String> = []
        var layers: [MapVectorLayer] = []
        for file in files where installed.insert(file.standardizedFileURL.path).inserted {
            try Task.checkCancellation()
            do { layers.append(try MapVectorLayer(contentsOf: file)) }
            catch { issues.append(error.localizedDescription) }
        }
        try Task.checkCancellation()
        return MapFileLoadResult(layers: layers, issues: issues)
    }
}
