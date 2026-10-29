import Foundation
import RASWorkspaceCore

@MainActor
enum RasterCalculatorErrorPresentation {
    static func text(_ message: String) -> String {
        message.components(separatedBy: "\n").map(textLine).joined(separator: "\n")
    }

    private static func textLine(_ message: String) -> String {
        if let value = capture(message, prefix: "Failed to compile expression: ", suffix: "") {
            return L10n.format("Failed to compile expression: %@", value)
        }
        if let value = capture(message, prefix: "Key-frame input '", suffix: "' is not a temporal (dynamic) input.") {
            return L10n.format("Key-frame input '%@' is not a temporal (dynamic) input.", value)
        }
        if let value = capture(message, prefix: "Temporal input '", suffix: "' does not expose timesteps.") {
            return L10n.format("Temporal input '%@' does not expose timesteps.", value)
        }
        if let value = capture(message, prefix: "Temporal input '", suffix: "' does not expose timesteps and cannot be aligned to the key frame.") {
            return L10n.format("Temporal input '%@' does not expose timesteps and cannot be aligned to the key frame.", value)
        }
        if let parts = capture(message, prefix: "Temporal input '", firstSeparator: "' has ",
                               secondSeparator: " profiles but ", suffix: " timesteps."),
           let profiles = Int(parts[1]), let timesteps = Int(parts[2]) {
            return L10n.format("Temporal input '%@' has %d profiles but %d timesteps.",
                parts[0], profiles, timesteps)
        }
        if let value = capture(message, prefix: "Variable name '", suffix: "' is reserved. Choose a different name.") {
            return L10n.format("Variable name '%@' is reserved. Choose a different name.", value)
        }
        if let value = capture(message, prefix: "Constant name '", suffix: "' is reserved.") {
            return L10n.format("Constant name '%@' is reserved.", value)
        }
        if let value = capture(message, prefix: "Duplicate constant name '", suffix: "'.") {
            return L10n.format("Duplicate constant name '%@'.", value)
        }
        if let value = capture(message, prefix: "Constant '", separator: "' collides with an input variable name.") {
            return L10n.format("Constant '%@' collides with an input variable name.", value)
        }
        if let parts = capture(message, prefix: "Constant '", separator: "' has an invalid numeric value '", suffix: "'.") {
            return L10n.format("Constant '%@' has an invalid numeric value '%@'.", parts.first ?? "", parts.last ?? "")
        }
        return L10n.text(message)
    }

    private static func capture(_ value: String, prefix: String, suffix: String) -> String? {
        guard value.hasPrefix(prefix), value.hasSuffix(suffix), value.count >= prefix.count + suffix.count else { return nil }
        let start = value.index(value.startIndex, offsetBy: prefix.count)
        let end = value.index(value.endIndex, offsetBy: -suffix.count)
        return String(value[start..<end])
    }

    private static func capture(_ value: String, prefix: String, separator: String) -> String? {
        guard value.hasPrefix(prefix), let range = value.range(of: separator, options: .backwards) else { return nil }
        let start = value.index(value.startIndex, offsetBy: prefix.count)
        guard start <= range.lowerBound else { return nil }
        return String(value[start..<range.lowerBound])
    }

    private static func capture(_ value: String, prefix: String, separator: String, suffix: String) -> [String]? {
        guard value.hasPrefix(prefix), value.hasSuffix(suffix),
              let range = value.range(of: separator, options: .backwards) else { return nil }
        let firstStart = value.index(value.startIndex, offsetBy: prefix.count)
        let secondStart = range.upperBound
        let secondEnd = value.index(value.endIndex, offsetBy: -suffix.count)
        guard firstStart <= range.lowerBound, secondStart <= secondEnd else { return nil }
        return [String(value[firstStart..<range.lowerBound]), String(value[secondStart..<secondEnd])]
    }

    private static func capture(_ value: String, prefix: String, firstSeparator: String,
                                secondSeparator: String, suffix: String) -> [String]? {
        guard value.hasPrefix(prefix), value.hasSuffix(suffix),
              let first = value.range(of: firstSeparator),
              let second = value.range(of: secondSeparator, range: first.upperBound..<value.endIndex) else {
            return nil
        }
        let firstStart = value.index(value.startIndex, offsetBy: prefix.count)
        let end = value.index(value.endIndex, offsetBy: -suffix.count)
        guard firstStart <= first.lowerBound, first.upperBound <= second.lowerBound,
              second.upperBound <= end else { return nil }
        return [String(value[firstStart..<first.lowerBound]),
                String(value[first.upperBound..<second.lowerBound]),
                String(value[second.upperBound..<end])]
    }
}

struct RasterCalculatorSourceFile: Codable, Hashable, Sendable {
    let path: String
    let role: String
    let exists: Bool
    let revision: String?
}

struct RasterCalculatorSourceChoice: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let kind: String
    let name: String
    let assetPath: String
    let revision: String
    let files: [RasterCalculatorSourceFile]
    let isAvailable: Bool
    let unavailableReason: String?
    let mapTypes: [String]
    let profileCount: Int
    let profileTimes: [String]
    let noDataValue: Double?
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double
}

struct RasterCalculatorInspectRequest: Encodable, Sendable {
    let map: MapTreeMapIdentity
}

struct RasterCalculatorInspectResult: Decodable, Sendable {
    let projectPath: String
    let projectRevision: String
    let projectXmlSHA: String
    let visualizationRevision: String
    let mapID: String
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let contextToken: String
    let defaultNoDataBehavior: String
    let noDataBehaviors: [String]
    let reservedConstants: [String]
    let sources: [RasterCalculatorSourceChoice]

    func validate(matching map: MapTreeMapIdentity) throws {
        guard Self.canonical(projectPath) == Self.canonical(map.projectPath),
              projectXmlSHA.caseInsensitiveCompare(map.projectXmlSHA) == .orderedSame,
              visualizationRevision.caseInsensitiveCompare(map.expectedVisualizationRevision) == .orderedSame,
              mapID.caseInsensitiveCompare(map.mapID) == .orderedSame,
              mapIndex == map.mapIndex, mapName == map.mapName, mapType == map.mapType,
              projectRevision.count == 64, contextToken.count == 64,
              noDataBehaviors.contains(defaultNoDataBehavior),
              Set(sources.map(\.id)).count == sources.count,
              sources.allSatisfy({ !$0.id.isEmpty && !$0.assetPath.isEmpty && $0.revision.count == 64 }) else {
            throw BackendServiceError(code: "sourceChanged",
                message: "The Raster Calculator source list no longer matches the selected map.")
        }
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

struct RasterCalculatorInput: Codable, Hashable, Sendable, Identifiable {
    var variableName: String
    var sourceID: String
    var sourceRevision: String
    var kind: String
    var mapType: String?
    var forceHorizontal: Bool
    var isKeyFrame: Bool
    var id: UUID

    init(variableName: String = "", sourceID: String = "", sourceRevision: String = "",
         kind: String = "terrain", mapType: String? = nil, forceHorizontal: Bool = false,
         isKeyFrame: Bool = false, id: UUID = UUID()) {
        self.variableName = variableName
        self.sourceID = sourceID
        self.sourceRevision = sourceRevision
        self.kind = kind
        self.mapType = mapType
        self.forceHorizontal = forceHorizontal
        self.isKeyFrame = isKeyFrame
        self.id = id
    }

    private enum CodingKeys: String, CodingKey {
        case variableName, sourceID, sourceRevision, kind, mapType, forceHorizontal, isKeyFrame
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        variableName = try container.decode(String.self, forKey: .variableName)
        sourceID = try container.decode(String.self, forKey: .sourceID)
        sourceRevision = try container.decode(String.self, forKey: .sourceRevision)
        kind = try container.decode(String.self, forKey: .kind)
        mapType = try container.decodeIfPresent(String.self, forKey: .mapType)
        forceHorizontal = try container.decode(Bool.self, forKey: .forceHorizontal)
        isKeyFrame = try container.decode(Bool.self, forKey: .isKeyFrame)
        id = UUID()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(variableName, forKey: .variableName)
        try container.encode(sourceID, forKey: .sourceID)
        try container.encode(sourceRevision, forKey: .sourceRevision)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(mapType, forKey: .mapType)
        try container.encode(forceHorizontal, forKey: .forceHorizontal)
        try container.encode(isKeyFrame, forKey: .isKeyFrame)
    }
}

struct RasterCalculatorConstant: Codable, Hashable, Sendable, Identifiable {
    var name: String
    var value: String
    var id: UUID

    init(name: String = "", value: String = "", id: UUID = UUID()) {
        self.name = name
        self.value = value
        self.id = id
    }

    private enum CodingKeys: String, CodingKey { case name, value }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        value = try container.decode(String.self, forKey: .value)
        id = UUID()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(value, forKey: .value)
    }
}

struct RasterCalculatorRecipe: Codable, Hashable, Sendable {
    var expression: String
    var noDataBehavior: String
    var keyFrameVariableName: String?
    var inputs: [RasterCalculatorInput]
    var constants: [RasterCalculatorConstant]

    init(expression: String = "", noDataBehavior: String = "WriteNDV",
         keyFrameVariableName: String? = nil, inputs: [RasterCalculatorInput] = [],
         constants: [RasterCalculatorConstant] = []) {
        self.expression = expression
        self.noDataBehavior = noDataBehavior
        self.keyFrameVariableName = keyFrameVariableName
        self.inputs = inputs
        self.constants = constants
    }
}

struct RasterCalculatorEvaluateRequest: Encodable, Sendable {
    let map: MapTreeMapIdentity
    let expectedContextToken: String
    let recipe: RasterCalculatorRecipe
    let layerID: String
    let layerName: String
    let profileIndex: Int
    let viewport: RasterMapViewExtent
}

struct RasterCalculatorProfile: Codable, Hashable, Sendable, Identifiable {
    let index: Int
    let time: String
    var id: Int { index }
}

struct RasterCalculatorLayerPayload: Decodable, Sendable {
    let id: String
    let mapID: String
    let name: String
    let width: Int
    let height: Int
    let rgba: Data
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double

    func makeLayer(expectedID: String, expectedMapID: UUID) throws -> MapRasterLayer {
        guard id == expectedID, UUID(uuidString: mapID) == expectedMapID else {
            throw BackendServiceError(code: "sourceChanged",
                message: "The Raster Calculator image belongs to a different map.")
        }
        return try MapRasterLayer(id: id, name: name, width: width, height: height,
            rgba: rgba, lowerLeft: MapPoint(x: minX, y: minY),
            upperRight: MapPoint(x: maxX, y: maxY), sourceMapID: expectedMapID)
    }
}

struct RasterCalculatorEvaluateResult: Decodable, Sendable {
    let projectPath: String
    let projectRevision: String
    let projectXmlSHA: String
    let visualizationRevision: String
    let mapID: String
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let contextToken: String
    let layerID: String
    let layerName: String
    let recipe: RasterCalculatorRecipe
    let isDynamic: Bool
    let profileCount: Int
    let selectedProfileIndex: Int
    let selectedProfileTime: String?
    let profiles: [RasterCalculatorProfile]
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double
    let layer: RasterCalculatorLayerPayload
    let sources: [RasterCalculatorSourceChoice]

    func makeLayer(matching map: MapTreeMapIdentity, expectedToken: String,
                   expectedLayerID: String, expectedLayerName: String, expectedRecipe: RasterCalculatorRecipe,
                   expectedProfileIndex: Int,
                   expectedSources: [RasterCalculatorSourceChoice]) throws -> MapRasterLayer {
        let dynamicInputs = expectedRecipe.inputs.filter { $0.kind == "resultMap" }
        let isExpectedDynamic = !dynamicInputs.isEmpty
        let keyFrameName = expectedRecipe.inputs.first(where: \.isKeyFrame)?.variableName
            ?? expectedRecipe.keyFrameVariableName ?? dynamicInputs.first?.variableName
        let expectedKeyFrame = keyFrameName.flatMap { name in
            expectedRecipe.inputs.first { $0.variableName.caseInsensitiveCompare(name) == .orderedSame }
        }
        let expectedTimes = expectedKeyFrame.flatMap { input in
            expectedSources.first(where: { $0.id == input.sourceID })?.profileTimes
        } ?? []
        guard Self.canonical(projectPath) == Self.canonical(map.projectPath),
              projectXmlSHA.caseInsensitiveCompare(map.projectXmlSHA) == .orderedSame,
              visualizationRevision.caseInsensitiveCompare(map.expectedVisualizationRevision) == .orderedSame,
              mapID.caseInsensitiveCompare(map.mapID) == .orderedSame,
              mapIndex == map.mapIndex, mapName == map.mapName, mapType == map.mapType,
              contextToken == expectedToken, layerID == expectedLayerID,
              layerName == expectedLayerName, layer.name == expectedLayerName,
              recipe.wireEquivalent(to: expectedRecipe), selectedProfileIndex == expectedProfileIndex,
              isDynamic == isExpectedDynamic, profileCount > 0,
              profileCount == (isExpectedDynamic ? expectedTimes.count : 1),
              profiles.count == profileCount,
              profiles.enumerated().allSatisfy({ $0.offset == $0.element.index }),
              profiles.indices.contains(selectedProfileIndex),
              (isExpectedDynamic
                  ? selectedProfileTime == profiles[selectedProfileIndex].time
                  : selectedProfileTime == nil),
              !isExpectedDynamic || profiles.map(\.time) == expectedTimes,
              sources == expectedSources else {
            throw BackendServiceError(code: "sourceChanged",
                message: "The Raster Calculator result no longer matches the current inputs.")
        }
        guard let expectedMapID = UUID(uuidString: map.mapID) else {
            throw BackendServiceError(code: "sourceChanged",
                message: "The Raster Calculator result no longer matches the current inputs.")
        }
        return try layer.makeLayer(expectedID: expectedLayerID, expectedMapID: expectedMapID)
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

private extension RasterCalculatorRecipe {
    func wireEquivalent(to other: RasterCalculatorRecipe) -> Bool {
        expression == other.expression
            && noDataBehavior == other.noDataBehavior
            && keyFrameVariableName == other.keyFrameVariableName
            && inputs.map(\.wireValue) == other.inputs.map(\.wireValue)
            && constants.map { $0.name + "\u{1f}" + $0.value }
                == other.constants.map { $0.name + "\u{1f}" + $0.value }
    }
}

private extension RasterCalculatorInput {
    var wireValue: String {
        [variableName, sourceID, sourceRevision, kind, mapType ?? "",
         String(forceHorizontal), String(isKeyFrame)].joined(separator: "\u{1f}")
    }
}
