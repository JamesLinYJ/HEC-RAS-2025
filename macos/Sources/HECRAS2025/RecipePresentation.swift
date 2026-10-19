import Foundation
import RASWorkspaceCore

struct RecipeParameterPresentation: Decodable, Identifiable, Sendable {
    let id: String
    let title: String
    let description: String
    let minimum: Double?
    let maximum: Double?
    let recommendedMinimum: Double?
    let recommendedMaximum: Double?
    init(id: String, title: String, description: String, minimum: Double? = nil, maximum: Double? = nil, recommendedMinimum: Double? = nil, recommendedMaximum: Double? = nil) {
        self.id = id; self.title = title; self.description = description
        self.minimum = minimum; self.maximum = maximum
        self.recommendedMinimum = recommendedMinimum; self.recommendedMaximum = recommendedMaximum
    }
    func isOutsideBounds(_ raw: String) -> Bool {
        guard let value = Double(raw), value.isFinite else { return false }
        return minimum.map { value < $0 } == true || maximum.map { value > $0 } == true
    }
    func isOutsideRecommendedBounds(_ raw: String) -> Bool {
        guard let value = Double(raw), value.isFinite else { return false }
        return recommendedMinimum.map { value < $0 } == true || recommendedMaximum.map { value > $0 } == true
    }
    var wireKey: String { id == "DeltaThreshold" ? "deltaCost" : id.prefix(1).lowercased() + id.dropFirst() }
    func wireKey(in step: RecipeStep) -> String {
        step.values.keys.first { $0.caseInsensitiveCompare(wireKey) == .orderedSame } ?? wireKey
    }
}

struct RecipePresentation: Decodable, Identifiable, Sendable {
    let id: String
    let description: String
    let paletteDescription: String
    let sourceIcon: String
    let parameters: [RecipeParameterPresentation]
    var symbol: String {
        switch sourceIcon {
        case "GridClosed": "square.grid.3x3"
        case "Topo": "point.3.connected.trianglepath.dotted"
        case "Cube": "cube"
        case "SquareAndTriangle": "square.on.square"
        case "Mesh": "square.grid.3x3.middle.filled"
        case "Compass": "location.north.line"
        case "Smooth": "water.waves"
        case "Split": "arrow.triangle.branch"
        case "Synchronize": "arrow.triangle.2.circlepath"
        default: "square.dashed"
        }
    }
}

enum RecipePresentationLibrary {
    private struct Resource: Decodable { let commands: [RecipePresentation] }
    static let commands: [RecipePresentation] = {
        guard let url = Bundle.module.url(forResource: "recipe-presentation", withExtension: "json"),
              let data = try? Data(contentsOf: url), let resource = try? JSONDecoder().decode(Resource.self, from: data) else {
            preconditionFailure("Missing original recipe card presentations")
        }
        return resource.commands
    }()
    static func presentation(_ id: String) -> RecipePresentation? { commands.first { $0.id == id } }
}

// Match the original Ingredient display units and ToString conversion. Extra
// wire parameters remain in RecipeStep even when the source card hides them.
enum RecipeParameterEditing {
    static func display(_ parameter: RecipeParameterPresentation, in step: RecipeStep) -> String {
        let raw = step.values[parameter.wireKey(in: step)] ?? ""
        guard let value = Double(raw), value.isFinite else { return raw }
        if parameter.id == "Threshold" { return String(value * 100) }
        if parameter.id == "DeltaThreshold", let threshold = Double(step.values["threshold"] ?? ""), threshold != 0 {
            return String(value / threshold)
        }
        return raw
    }
    static func set(_ raw: String, parameter: RecipeParameterPresentation, in step: inout RecipeStep, deltaThreshold: String? = nil) {
        let wireKey = parameter.wireKey(in: step)
        guard let number = Double(raw), number.isFinite else { step.values[wireKey] = raw; return }
        if parameter.id == "Threshold" {
            let oldThreshold = Double(step.values["threshold"] ?? "")
            let oldDelta = Double(step.values["deltaCost"] ?? "")
            let threshold = number / 100
            step.values["threshold"] = String(threshold)
            if step.command == "OptTopology", let oldThreshold, oldThreshold != 0, let oldDelta {
                step.values["deltaCost"] = String(threshold * (oldDelta / oldThreshold))
            } else if step.command == "OptTopology", let deltaThreshold, let ratio = Double(deltaThreshold), ratio.isFinite {
                step.values["deltaCost"] = String(threshold * ratio)
            }
        } else if parameter.id == "DeltaThreshold", let threshold = Double(step.values["threshold"] ?? "") {
            step.values["deltaCost"] = String(threshold * number)
        } else { step.values[wireKey] = raw }
    }
}
