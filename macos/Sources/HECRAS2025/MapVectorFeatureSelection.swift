import Foundation
import RASWorkspaceCore

/// A source SelectedSet belongs to one render-layer instance. Feature IDs
/// alone cannot identify that owner when the same file is mounted twice.
struct MapVectorSelectionOwner: Equatable, Sendable {
    let layerID: String
    let sourcePath: String
    let sourceRevision: String?

    init(_ layer: MapVectorLayer) {
        layerID = layer.id
        sourcePath = SourceFilePaths.canonical(layer.url)
        sourceRevision = layer.sourceRevision
    }
}

enum MapVectorSelectionMode: Equatable, Sendable {
    case replace, toggle, ensureIncluded, range, extendRange

    static func pointer(modifiers: Set<MapInput.Modifier>) -> Self {
        // RenderLayerClickSelectionHandler maps source Ctrl to Toggle.
        // Command is its native macOS equivalent; Shift is not a marquee.
        modifiers.contains(.command) || modifiers.contains(.control) ? .toggle : .replace
    }

    static func list(modifiers: Set<MapInput.Modifier>) -> Self {
        let extends = modifiers.contains(.command) || modifiers.contains(.control)
        if modifiers.contains(.shift) { return extends ? .extendRange : .range }
        return extends ? .toggle : .replace
    }
}

struct MapVectorFeatureSelection: Equatable, Sendable {
    private(set) var identities: Set<String> = []
    private(set) var primary: String?
    private(set) var anchor: String?

    mutating func replaceLegacy(_ identity: String?) {
        identities = identity.map { [$0] } ?? []
        primary = identity
        anchor = identity
    }

    mutating func select(_ identity: String, mode: MapVectorSelectionMode,
                         available: [String], rangeOrder: [String]? = nil) {
        let counts = Dictionary(available.map { ($0, 1) }, uniquingKeysWith: +)
        let ordered = available.filter { counts[$0] == 1 }
        let valid = Set(ordered)
        reconcile(available: valid)
        guard valid.contains(identity) else { return }
        switch mode {
        case .replace:
            identities = [identity]
            anchor = identity
        case .toggle:
            if !identities.insert(identity).inserted { identities.remove(identity) }
            anchor = identity
        case .ensureIncluded:
            identities.insert(identity)
            if anchor == nil { anchor = identity }
        case .range, .extendRange:
            let rangeCandidates = rangeOrder ?? ordered
            let rangeCounts = Dictionary(rangeCandidates.map { ($0, 1) }, uniquingKeysWith: +)
            let visibleOrder = rangeCandidates.filter { valid.contains($0) && rangeCounts[$0] == 1 }
            if let anchor, let first = visibleOrder.firstIndex(of: anchor),
               let last = visibleOrder.firstIndex(of: identity) {
                let range = Set(visibleOrder[min(first, last)...max(first, last)])
                if case .extendRange = mode { identities.formUnion(range) }
                else { identities = range }
            } else {
                if case .extendRange = mode { identities.insert(identity) }
                else { identities = [identity] }
                anchor = identity
            }
        }
        primary = identities.contains(identity) ? identity : ordered.last(where: identities.contains)
    }

    mutating func reconcile(available: Set<String>) {
        identities.formIntersection(available)
        if let primary, !identities.contains(primary) { self.primary = identities.sorted().first }
        if let anchor, !available.contains(anchor) { self.anchor = nil }
    }
}
