import Foundation

/// Identity and display state for one persisted vector node that references a
/// shared source file. `sourcePath` is the physical canonical source path used
/// to bind this node to the loaded bytes; `id` remains the node identity.
public struct MapVectorInstanceBinding: Identifiable, Equatable, Sendable {
    public let id: String
    public let sourcePath: String
    public let name: String
    public let kind: MapFeature.Kind
    public let isVisible: Bool

    public init(id: String, sourcePath: String, name: String, kind: MapFeature.Kind, isVisible: Bool) {
        self.id = id
        self.sourcePath = sourcePath
        self.name = name
        self.kind = kind
        self.isVisible = isVisible
    }
}
