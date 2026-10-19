import CryptoKit
import Foundation

/// A loss-preserving editor model for GeoJSON line features. The ordered JSON
/// tree keeps unknown members, typed properties, nulls and extra ordinates
/// intact; only the selected line coordinates are replaced.
public struct GeoJSONPolylineDocument: Sendable {
    private indirect enum Value: Sendable {
        case object([(String, Value)])
        case array([Value])
        case string(String)
        case number(String)
        case bool(Bool)
        case null

        var objectMembers: [(String, Value)]? { if case .object(let value) = self { value } else { nil } }
        var arrayValues: [Value]? { if case .array(let value) = self { value } else { nil } }
        var stringValue: String? { if case .string(let value) = self { value } else { nil } }

        func value(for key: String) -> Value? { objectMembers?.first { $0.0 == key }?.1 }

        mutating func set(_ value: Value, for key: String) {
            guard case .object(var members) = self else { return }
            if let index = members.firstIndex(where: { $0.0 == key }) { members[index].1 = value }
            else { members.append((key, value)) }
            self = .object(members)
        }

        func jsonData() throws -> Data {
            var output = Data()
            try write(to: &output)
            return output
        }

        private func write(to output: inout Data) throws {
            switch self {
            case .object(let members):
                output.append(123)
                for index in members.indices {
                    if index > 0 { output.append(44) }
                    output.append(try JSONEncoder().encode(members[index].0))
                    output.append(58)
                    try members[index].1.write(to: &output)
                }
                output.append(125)
            case .array(let values):
                output.append(91)
                for index in values.indices {
                    if index > 0 { output.append(44) }
                    try values[index].write(to: &output)
                }
                output.append(93)
            case .string(let value): output.append(try JSONEncoder().encode(value))
            case .number(let raw): output.append(contentsOf: raw.utf8)
            case .bool(let value): output.append(contentsOf: (value ? "true" : "false").utf8)
            case .null: output.append(contentsOf: "null".utf8)
            }
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        var offset = 0

        init(_ data: Data) { bytes = Array(data) }

        mutating func parse() throws -> Value {
            // Retained source GeoJSON writers can emit a UTF-8 BOM. Accept
            // it only at the document boundary, matching the source reader.
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { offset = 3 }
            skipWhitespace()
            let value = try parseValue()
            skipWhitespace()
            guard offset == bytes.count else { throw ProjectFileError.invalid("The GeoJSON document has trailing data.") }
            return value
        }

        private mutating func parseValue() throws -> Value {
            skipWhitespace()
            guard offset < bytes.count else { throw ProjectFileError.invalid("The GeoJSON document is incomplete.") }
            switch bytes[offset] {
            case 123: return try parseObject()
            case 91: return try parseArray()
            case 34: return .string(try parseString())
            case 116: try consume("true"); return .bool(true)
            case 102: try consume("false"); return .bool(false)
            case 110: try consume("null"); return .null
            case 45, 48...57: return .number(try parseNumber())
            default: throw ProjectFileError.invalid("The GeoJSON document contains an invalid JSON value.")
            }
        }

        private mutating func parseObject() throws -> Value {
            offset += 1; skipWhitespace()
            var members: [(String, Value)] = []
            if take(125) { return .object(members) }
            while true {
                skipWhitespace()
                guard offset < bytes.count, bytes[offset] == 34 else { throw ProjectFileError.invalid("The GeoJSON document contains an invalid object key.") }
                let key = try parseString()
                skipWhitespace()
                guard take(58) else { throw ProjectFileError.invalid("The GeoJSON document contains an invalid object.") }
                members.append((key, try parseValue()))
                skipWhitespace()
                if take(125) { return .object(members) }
                guard take(44) else { throw ProjectFileError.invalid("The GeoJSON document contains an invalid object separator.") }
            }
        }

        private mutating func parseArray() throws -> Value {
            offset += 1; skipWhitespace()
            var values: [Value] = []
            if take(93) { return .array(values) }
            while true {
                values.append(try parseValue())
                skipWhitespace()
                if take(93) { return .array(values) }
                guard take(44) else { throw ProjectFileError.invalid("The GeoJSON document contains an invalid array separator.") }
            }
        }

        private mutating func parseString() throws -> String {
            let start = offset
            offset += 1
            var escaped = false
            while offset < bytes.count {
                let byte = bytes[offset]; offset += 1
                if escaped { escaped = false; continue }
                if byte == 92 { escaped = true; continue }
                if byte == 34 {
                    let token = Data(bytes[start..<offset])
                    guard let decoded = try? JSONDecoder().decode(String.self, from: token) else {
                        throw ProjectFileError.invalid("The GeoJSON document contains an invalid string.")
                    }
                    return decoded
                }
            }
            throw ProjectFileError.invalid("The GeoJSON document contains an unterminated string.")
        }

        private mutating func parseNumber() throws -> String {
            let start = offset
            if take(45) {}
            if take(48) {} else {
                guard takeDigit(nonZero: true) else { throw ProjectFileError.invalid("The GeoJSON document contains an invalid number.") }
                while takeDigit(nonZero: false) {}
            }
            if take(46) {
                guard takeDigit(nonZero: false) else { throw ProjectFileError.invalid("The GeoJSON document contains an invalid number.") }
                while takeDigit(nonZero: false) {}
            }
            if offset < bytes.count, (bytes[offset] == 101 || bytes[offset] == 69) {
                offset += 1
                if !take(43) { _ = take(45) }
                guard takeDigit(nonZero: false) else { throw ProjectFileError.invalid("The GeoJSON document contains an invalid exponent.") }
                while takeDigit(nonZero: false) {}
            }
            return String(decoding: bytes[start..<offset], as: UTF8.self)
        }

        private mutating func consume(_ token: String) throws {
            let expected = Array(token.utf8)
            guard offset + expected.count <= bytes.count, Array(bytes[offset..<(offset + expected.count)]) == expected else {
                throw ProjectFileError.invalid("The GeoJSON document contains an invalid literal.")
            }
            offset += expected.count
        }
        private mutating func takeDigit(nonZero: Bool) -> Bool {
            guard offset < bytes.count else { return false }
            let byte = bytes[offset]
            guard byte >= (nonZero ? 49 : 48), byte <= 57 else { return false }
            offset += 1; return true
        }
        private mutating func take(_ byte: UInt8) -> Bool {
            guard offset < bytes.count, bytes[offset] == byte else { return false }
            offset += 1; return true
        }
        private mutating func skipWhitespace() {
            while offset < bytes.count, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
        }
    }

    private struct LineAddress: Sendable {
        let featureIndex: Int
        let componentIndex: Int?
        let featureIdentity: String
        let componentIdentity: String
        let editable: Bool
    }

    private struct MergeChain {
        let coordinates: [Value]
        let sourceIndices: [Int]
    }

    public let sourceURL: URL
    public private(set) var sourceRevision: String
    private var root: Value
    private var featureIdentities: [Int: String] = [:]
    private var componentIdentities: [Int: [Int: String]] = [:]
    private var ambiguousFeatureIndices: Set<Int> = []

    public init(data: Data, sourceURL: URL) throws {
        var parser = Parser(data)
        let root = try parser.parse()
        guard case .object = root, let type = root.value(for: "type")?.stringValue else {
            throw ProjectFileError.invalid("The GeoJSON document must have a named root geometry type.")
        }
        guard type == "FeatureCollection" || type == "Feature" else {
            throw ProjectFileError.invalid("Editing requires a GeoJSON Feature or FeatureCollection.")
        }
        self.root = root
        self.sourceURL = sourceURL
        self.sourceRevision = Self.digest(data)
        try rebuildIdentities()
    }

    public var supportsAddingLines: Bool { root.value(for: "type")?.stringValue == "FeatureCollection" }
    public var isFeatureCollection: Bool { supportsAddingLines }

    public var lines: [GeoJSONPolylineLine] {
        guard let features = featureValues else { return [] }
        var result: [GeoJSONPolylineLine] = []
        for index in features.indices {
            guard case .object = features[index], let geometry = features[index].value(for: "geometry"),
                  case .object = geometry,
                  let type = geometry.value(for: "type")?.stringValue,
                  type == "LineString" || type == "MultiLineString",
                  let coordinates = geometry.value(for: "coordinates") else { continue }
            let components: [Value]
            if type == "LineString" { components = [coordinates] }
            else { components = coordinates.arrayValues ?? [] }
            let featureIdentity = featureIdentities[index] ?? Self.identity(for: features[index])
            let name = Self.featureName(features[index], fallback: featureIdentity)
            for componentIndex in components.indices {
                let pathValues = components[componentIndex].arrayValues ?? []
                let points = pathValues.compactMap(Self.mapPoint)
                let keyIndex = type == "LineString" ? 0 : componentIndex
                let componentIdentity = componentIdentities[index]?[keyIndex] ?? "geometry.coordinates[\(keyIndex)]"
                let id = Self.lineID(featureIdentity: featureIdentity, componentIdentity: componentIdentity)
                result.append(GeoJSONPolylineLine(id: id, sourceFeatureIdentity: featureIdentity,
                    sourceFeatureOrdinal: index, componentOrdinal: componentIndex,
                    name: name, points: points, geometryPath: "geometry",
                    canEdit: !ambiguousFeatureIndices.contains(index) && points.count == pathValues.count && points.count >= 2))
            }
        }
        return result
    }

    public func encoded() throws -> Data { try root.jsonData() }

    /// Returns the exact two-dimensional tuples accepted by the retained
    /// Douglas-Peucker and moving-average algorithms. This deliberately refuses
    /// Z/M coordinates because those source algorithms rebuild XY-only points.
    public func xyCoordinates(lineID: String) throws -> [[Double]] {
        let address = try lineAddress(lineID)
        guard address.editable else { throw ProjectFileError.invalid("This line identity is ambiguous and cannot be edited safely.") }
        let positions = try coordinateValues(at: address)
        guard positions.count >= 2 else { throw ProjectFileError.invalid("Polyline operations require a nonzero line with at least two vertices.") }
        let coordinates = try positions.map { value -> [Double] in
            guard let ordinates = value.arrayValues, ordinates.count == 2,
                  case .number(let xText) = ordinates[0], case .number(let yText) = ordinates[1],
                  let x = Double(xText), let y = Double(yText), x.isFinite, y.isFinite else {
                throw ProjectFileError.invalid("Polyline filter and smooth require two-dimensional coordinates. Z/M coordinates remain unchanged.")
            }
            return [x, y]
        }
        try Self.validateNonzeroLine(coordinates)
        return coordinates
    }

    /// Replaces only a line's coordinate tuples. All feature properties,
    /// identities, foreign members, and neighboring components remain in the
    /// original ordered GeoJSON tree.
    public mutating func replaceXYCoordinates(lineID: String, coordinates: [[Double]]) throws {
        guard coordinates.count >= 2, coordinates.allSatisfy({
            $0.count == 2 && $0.allSatisfy(\.isFinite)
        }) else {
            throw ProjectFileError.invalid("The geometry operation produced an invalid line.")
        }
        try Self.validateNonzeroLine(coordinates)
        let address = try lineAddress(lineID)
        guard address.editable else { throw ProjectFileError.invalid("This line identity is ambiguous and cannot be edited safely.") }
        let original = try coordinateValues(at: address)
        guard coordinates.count <= original.count else {
            throw ProjectFileError.invalid("The geometry operation returned more vertices than the selected line.")
        }
        guard original.allSatisfy({ $0.arrayValues?.count == 2 }) else {
            throw ProjectFileError.invalid("Polyline filter and smooth require two-dimensional coordinates. Z/M coordinates remain unchanged.")
        }
        let values = try coordinates.map { coordinate in
            Value.array(try coordinate.map { .number(try Self.numberString($0)) })
        }
        try setCoordinateValues(values, at: address)
    }

    /// Applies a source-style In Place replacement to the exact captured line
    /// components. A one-for-one result keeps each feature/component identity;
    /// a cardinality change removes the captured components and inserts fresh
    /// LineString features at the first captured feature position, matching the
    /// source ReplacePolylines identity rule while retaining GeoJSON metadata.
    /// One document mutation makes the whole replacement a single undo unit.
    @discardableResult
    public mutating func replacePolylines(lineIDs: [String],
                                          with replacements: [GeoJSONPolylineReplacement]) throws -> [String] {
        guard !lineIDs.isEmpty, Set(lineIDs).count == lineIDs.count else {
            throw ProjectFileError.invalid("The captured line selection is empty or contains duplicate identities.")
        }
        guard let originalFeatures = featureValues else {
            throw ProjectFileError.invalid("The captured GeoJSON features are unavailable.")
        }
        let addresses = try lineIDs.map(lineAddress)
        guard addresses.allSatisfy(\.editable) else {
            throw ProjectFileError.invalid("An ambiguous line identity cannot be replaced safely.")
        }
        for replacement in replacements {
            try Self.validateReplacement(replacement)
        }

        if replacements.count == addresses.count {
            var changed = self
            var ids: [String] = []
            for (address, replacement) in zip(addresses, replacements) {
                let oldCoordinates = try changed.coordinateValues(at: address)
                let values = try Self.replacementValues(replacement, preserving: oldCoordinates)
                try changed.setCoordinateValues(values, at: address)
                ids.append(Self.lineID(featureIdentity: address.featureIdentity,
                                       componentIdentity: address.componentIdentity))
            }
            self = changed
            return ids
        }
        guard supportsAddingLines else {
            throw ProjectFileError.invalid("Changing line count in place requires a GeoJSON FeatureCollection.")
        }

        struct FeatureEntry {
            var value: Value
            let identity: String
            var componentIdentities: [Int: String]
            let ambiguous: Bool
        }

        let selectedByFeature = Dictionary(grouping: addresses, by: \.featureIndex)
        let firstAddress = addresses.min {
            if $0.featureIndex != $1.featureIndex { return $0.featureIndex < $1.featureIndex }
            return ($0.componentIndex ?? 0) < ($1.componentIndex ?? 0)
        }!
        let firstSelectedComponent = firstAddress.componentIndex ?? 0
        let selectedFeatureIndices = Set(selectedByFeature.keys)
        var entries: [FeatureEntry] = []
        var insertedOutputs = false
        var insertedOutputIDs: [String] = []

        func outputEntries() throws -> [FeatureEntry] {
            let sourceFeatures = addresses.map { originalFeatures[$0.featureIndex] }
            let template = sourceFeatures.first ?? originalFeatures[firstAddress.featureIndex]
            var result: [FeatureEntry] = []
            for (index, replacement) in replacements.enumerated() {
                var feature = sourceFeatures.indices.contains(index) ? sourceFeatures[index] : template
                let featureID = Self.uniqueFeatureID(in: originalFeatures + result.map(\.value))
                feature.set(.string(featureID), for: "id")
                feature.set(.string("Feature"), for: "type")
                let coordinateValues = try Self.replacementValues(replacement, preserving: nil)
                var geometry = feature.value(for: "geometry") ?? .object([])
                geometry.set(.string("LineString"), for: "type")
                geometry.set(.array(coordinateValues), for: "coordinates")
                feature.set(geometry, for: "geometry")
                let identity = Self.identity(for: feature)
                insertedOutputIDs.append(Self.lineID(featureIdentity: identity,
                    componentIdentity: "geometry.coordinates[0]"))
                result.append(FeatureEntry(value: feature, identity: identity,
                    componentIdentities: [0: "geometry.coordinates[0]"], ambiguous: false))
            }
            return result
        }

        for featureIndex in originalFeatures.indices {
            let originalFeature = originalFeatures[featureIndex]
            guard selectedFeatureIndices.contains(featureIndex) else {
                let identity = featureIdentities[featureIndex] ?? Self.identity(for: originalFeature)
                let components = componentIdentities[featureIndex] ?? [:]
                entries.append(FeatureEntry(value: originalFeature, identity: identity,
                    componentIdentities: components, ambiguous: ambiguousFeatureIndices.contains(featureIndex)))
                continue
            }

            guard let geometry = originalFeature.value(for: "geometry"),
                  let geometryType = geometry.value(for: "type")?.stringValue,
                  let coordinateValue = geometry.value(for: "coordinates") else {
                throw ProjectFileError.invalid("The captured line geometry is no longer available.")
            }
            let removedComponents = Set((selectedByFeature[featureIndex] ?? []).compactMap(\.componentIndex))
            let isWholeLineStringSelected = geometryType == "LineString"
                && (selectedByFeature[featureIndex] ?? []).contains(where: { $0.componentIndex == nil })
            var retainedComponentIndexes: [Int] = []
            var retainedCoordinates: [Value] = []
            if geometryType == "MultiLineString" {
                guard let components = coordinateValue.arrayValues else {
                    throw ProjectFileError.invalid("The captured MultiLineString coordinates are invalid.")
                }
                for componentIndex in components.indices where !removedComponents.contains(componentIndex) {
                    retainedComponentIndexes.append(componentIndex)
                    retainedCoordinates.append(components[componentIndex])
                }
            }

            let featureIdentity = featureIdentities[featureIndex] ?? Self.identity(for: originalFeature)
            if !isWholeLineStringSelected, !retainedCoordinates.isEmpty {
                var retainedGeometry = geometry
                retainedGeometry.set(.array(retainedCoordinates), for: "coordinates")
                var retainedFeature = originalFeature
                retainedFeature.set(retainedGeometry, for: "geometry")
                let oldComponents = componentIdentities[featureIndex] ?? [:]
                let identities = Dictionary(uniqueKeysWithValues: retainedComponentIndexes.enumerated().map { newIndex, oldIndex in
                    (newIndex, oldComponents[oldIndex] ?? "geometry.coordinates[\(oldIndex)]")
                })
                let retainedEntry = FeatureEntry(value: retainedFeature, identity: featureIdentity,
                    componentIdentities: identities, ambiguous: ambiguousFeatureIndices.contains(featureIndex))
                if featureIndex == firstAddress.featureIndex && firstSelectedComponent == 0 {
                    entries.append(contentsOf: try outputEntries())
                    insertedOutputs = true
                }
                entries.append(retainedEntry)
                if featureIndex == firstAddress.featureIndex && !insertedOutputs {
                    entries.append(contentsOf: try outputEntries())
                    insertedOutputs = true
                }
            } else if featureIndex == firstAddress.featureIndex {
                entries.append(contentsOf: try outputEntries())
                insertedOutputs = true
            }
        }

        if !insertedOutputs { entries.append(contentsOf: try outputEntries()) }
        let nextFeatures = entries.map(\.value)
        setFeatureValues(nextFeatures)
        featureIdentities = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.offset, $0.element.identity) })
        componentIdentities = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.offset, $0.element.componentIdentities) })
        ambiguousFeatureIndices = Set(entries.enumerated().compactMap { $0.element.ambiguous ? $0.offset : nil })

        return insertedOutputIDs
    }

    public mutating func moveVertex(lineID: String, vertexIndex: Int, to point: MapPoint) throws {
        guard point.x.isFinite, point.y.isFinite else { throw ProjectFileError.invalid("Enter finite line coordinates.") }
        let address = try lineAddress(lineID)
        guard address.editable else { throw ProjectFileError.invalid("This line identity is ambiguous and cannot be edited safely.") }
        var positions = try coordinateValues(at: address)
        guard positions.indices.contains(vertexIndex), var ordinates = positions[vertexIndex].arrayValues, ordinates.count >= 2 else {
            throw ProjectFileError.invalid("The selected line vertex is unavailable.")
        }
        ordinates[0] = .number(try Self.numberString(point.x)); ordinates[1] = .number(try Self.numberString(point.y))
        positions[vertexIndex] = .array(ordinates)
        try setCoordinateValues(positions, at: address)
    }

    /// Moves the source-selected point set by one shared XY delta, matching
    /// TranslatePointOperation. Extra ordinates remain attached to their source
    /// coordinates. When a moved point lands within the renderer's duplicate
    /// tolerance of an unselected adjacent point, the source removes the moved
    /// point; the native editor does the same while preserving the surrounding
    /// GeoJSON AST.
    @discardableResult
    public mutating func moveVertices(lineID: String, vertexIndices: Set<Int>, by delta: MapPoint,
                                      duplicateTolerance: Double, interactionPoint: MapPoint? = nil) throws -> [Int] {
        guard delta.x.isFinite, delta.y.isFinite, duplicateTolerance.isFinite, duplicateTolerance >= 0,
              interactionPoint.map({ $0.x.isFinite && $0.y.isFinite }) ?? true else {
            throw ProjectFileError.invalid("Enter finite line coordinates.")
        }
        let address = try lineAddress(lineID)
        guard address.editable else { throw ProjectFileError.invalid("This line identity is ambiguous and cannot be edited safely.") }
        var positions = try coordinateValues(at: address)
        guard !vertexIndices.isEmpty, vertexIndices.allSatisfy({ positions.indices.contains($0) }) else {
            throw ProjectFileError.invalid("The selected line vertices are unavailable.")
        }

        let original = positions
        for index in vertexIndices {
            guard var ordinates = positions[index].arrayValues, ordinates.count >= 2,
                  let point = Self.mapPoint(positions[index]) else {
                throw ProjectFileError.invalid("The selected line vertex is invalid.")
            }
            let x = point.x + delta.x, y = point.y + delta.y
            guard x.isFinite, y.isFinite else { throw ProjectFileError.invalid("Enter finite line coordinates.") }
            ordinates[0] = .number(try Self.numberString(x)); ordinates[1] = .number(try Self.numberString(y))
            positions[index] = .array(ordinates)
        }

        // GenericEditableLine.ValidateMoveSelectedPoints rejects a cursor that
        // would collapse a selected point against the point two places away.
        if duplicateTolerance > 0, let interactionPoint {
            for index in vertexIndices {
                for neighbor in [index - 2, index + 2] where original.indices.contains(neighbor) {
                    guard let point = Self.mapPoint(original[neighbor]),
                          Self.distance(from: interactionPoint, to: point) >= duplicateTolerance else {
                        throw ProjectFileError.invalid("Moving the selected points would collapse a neighboring line segment.")
                    }
                }
            }
        }

        var removedAny = false
        if duplicateTolerance > 0 {
            for index in vertexIndices.sorted(by: >) {
                guard positions.indices.contains(index), let moved = Self.mapPoint(positions[index]) else {
                    throw ProjectFileError.invalid("The selected line vertex is unavailable.")
                }
                let previousIsUnselected = !vertexIndices.contains(index - 1)
                let nextIsUnselected = !vertexIndices.contains(index + 1)
                let joinsPrevious = previousIsUnselected && index > 0 &&
                    (Self.mapPoint(positions[index - 1]).map { Self.distance(from: moved, to: $0) < duplicateTolerance } ?? false)
                let joinsNext = nextIsUnselected && index + 1 < positions.count &&
                    (Self.mapPoint(positions[index + 1]).map { Self.distance(from: moved, to: $0) < duplicateTolerance } ?? false)
                if joinsPrevious || joinsNext {
                    positions.remove(at: index)
                    removedAny = true
                }
            }
        }
        guard positions.count >= 2 else {
            throw ProjectFileError.invalid("Moving these points would leave fewer than two line vertices.")
        }
        try setCoordinateValues(positions, at: address)
        return removedAny ? [] : vertexIndices.sorted()
    }

    public mutating func insertVertex(lineID: String, after vertexIndex: Int, at point: MapPoint) throws {
        guard point.x.isFinite, point.y.isFinite else { throw ProjectFileError.invalid("Enter finite line coordinates.") }
        let address = try lineAddress(lineID)
        guard address.editable else { throw ProjectFileError.invalid("This line identity is ambiguous and cannot be edited safely.") }
        var positions = try coordinateValues(at: address)
        guard vertexIndex >= 0, vertexIndex + 1 < positions.count,
              let left = positions[vertexIndex].arrayValues, let right = positions[vertexIndex + 1].arrayValues,
              left.count == right.count, left.count >= 2 else {
            throw ProjectFileError.invalid("The selected line segment does not support a safe vertex insertion.")
        }
        var inserted: [Value] = [.number(try Self.numberString(point.x)), .number(try Self.numberString(point.y))]
        for dimension in 2..<left.count {
            guard case .number(let leftRaw) = left[dimension], case .number(let rightRaw) = right[dimension],
                  let leftValue = Double(leftRaw), let rightValue = Double(rightRaw) else {
                throw ProjectFileError.invalid("Extra coordinate dimensions cannot be interpolated safely.")
            }
            inserted.append(.number(try Self.numberString(leftValue / 2 + rightValue / 2)))
        }
        positions.insert(.array(inserted), at: vertexIndex + 1)
        try setCoordinateValues(positions, at: address)
    }

    public mutating func deleteVertex(lineID: String, vertexIndex: Int) throws {
        let address = try lineAddress(lineID)
        guard address.editable else { throw ProjectFileError.invalid("This line identity is ambiguous and cannot be edited safely.") }
        var positions = try coordinateValues(at: address)
        guard positions.indices.contains(vertexIndex), positions.count > 2 else {
            throw ProjectFileError.invalid("A line must retain at least two vertices.")
        }
        positions.remove(at: vertexIndex)
        try setCoordinateValues(positions, at: address)
    }

    /// Deletes the selected source vertices in descending index order. The
    /// source removes the whole editable line when every point is selected;
    /// otherwise this method keeps the GeoJSON LineString validity invariant.
    @discardableResult
    public mutating func deleteVertices(lineID: String, vertexIndices: Set<Int>) throws -> GeoJSONPolylinePointDeletion {
        let address = try lineAddress(lineID)
        guard address.editable else { throw ProjectFileError.invalid("This line identity is ambiguous and cannot be edited safely.") }
        let positions = try coordinateValues(at: address)
        guard !vertexIndices.isEmpty, vertexIndices.allSatisfy({ positions.indices.contains($0) }) else {
            throw ProjectFileError.invalid("The selected line vertices are unavailable.")
        }
        if vertexIndices.count == positions.count {
            try deleteLine(lineID: lineID)
            return GeoJSONPolylinePointDeletion(lineDeleted: true, selectedVertexIndex: nil)
        }
        guard positions.count - vertexIndices.count >= 2 else {
            throw ProjectFileError.invalid("A GeoJSON line must retain at least two vertices.")
        }
        var remaining = positions
        for index in vertexIndices.sorted(by: >) { remaining.remove(at: index) }
        try setCoordinateValues(remaining, at: address)
        let nextSelection = remaining.count > 2 ? min(vertexIndices.min() ?? 0, remaining.count - 1) : nil
        return GeoJSONPolylinePointDeletion(lineDeleted: false, selectedVertexIndex: nextSelection)
    }

    public mutating func reverse(lineID: String) throws {
        let address = try lineAddress(lineID)
        guard address.editable else { throw ProjectFileError.invalid("This line identity is ambiguous and cannot be edited safely.") }
        let positions = try coordinateValues(at: address)
        try setCoordinateValues(Array(positions.reversed()), at: address)
    }

    /// Splits one line at the closest interior point. The first output keeps the
    /// original component identity; the second receives a new stable identity.
    /// For a LineString feature in a FeatureCollection, the second line is a
    /// sibling Feature carrying the original feature metadata and a fresh id.
    @discardableResult
    public mutating func split(lineID: String, near point: MapPoint,
                               mode: GeoJSONPolylineSplitMode = .anywhere,
                               maximumDistance: Double) throws -> [String] {
        guard point.x.isFinite, point.y.isFinite, maximumDistance.isFinite, maximumDistance >= 0 else {
            throw ProjectFileError.invalid("Choose a finite point within the line split tolerance.")
        }
        let address = try lineAddress(lineID)
        guard address.editable else { throw ProjectFileError.invalid("This line identity is ambiguous and cannot be edited safely.") }
        let positions = try coordinateValues(at: address)
        guard positions.count >= 2 else { throw ProjectFileError.invalid("A split needs at least one interior line segment.") }

        let split: (index: Int, coordinate: Value, existingVertex: Bool)
        switch mode {
        case .atVertex:
            let candidates = (1..<(positions.count - 1)).compactMap { index -> (Int, Double)? in
                guard let vertex = Self.mapPoint(positions[index]) else { return nil }
                return (index, Self.distance(from: vertex, to: point))
            }
            guard let candidate = candidates.min(by: { $0.1 < $1.1 }), candidate.1 <= maximumDistance else {
                throw ProjectFileError.invalid("Click near an interior vertex to split at a vertex.")
            }
            split = (candidate.0, positions[candidate.0], true)
        case .anywhere:
            var closest: (segment: Int, fraction: Double, distance: Double, projected: MapPoint)?
            for segment in 0..<(positions.count - 1) {
                guard let start = Self.mapPoint(positions[segment]), let end = Self.mapPoint(positions[segment + 1]) else {
                    throw ProjectFileError.invalid("The selected line contains coordinates that cannot be split safely.")
                }
                let dx = end.x - start.x, dy = end.y - start.y
                let lengthSquared = dx * dx + dy * dy
                let fraction = lengthSquared > 0
                    ? min(max(((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared, 0), 1)
                    : 0
                let projected = MapPoint(x: start.x + fraction * dx, y: start.y + fraction * dy)
                let distance = Self.distance(from: projected, to: point)
                if closest == nil || distance < closest!.distance {
                    closest = (segment, fraction, distance, projected)
                }
            }
            guard let closest, closest.distance <= maximumDistance else {
                throw ProjectFileError.invalid("Click close to a line segment to split it.")
            }
            if closest.fraction <= 1e-12 {
                split = (closest.segment, positions[closest.segment], true)
            } else if closest.fraction >= 1 - 1e-12 {
                split = (closest.segment + 1, positions[closest.segment + 1], true)
            } else {
                let coordinate = try Self.interpolatePosition(positions[closest.segment], positions[closest.segment + 1],
                    fraction: closest.fraction, projectedXY: closest.projected)
                split = (closest.segment + 1, coordinate, false)
            }
        }
        let splitIsInterior = split.existingVertex
            ? split.index > 0 && split.index < positions.count - 1
            : split.index > 0 && split.index < positions.count
        guard splitIsInterior else {
            throw ProjectFileError.invalid("A line cannot be split at either endpoint.")
        }

        let left: [Value]
        let right: [Value]
        if split.existingVertex {
            left = Array(positions.prefix(through: split.index))
            right = Array(positions.suffix(from: split.index))
        } else {
            left = Array(positions.prefix(split.index)) + [split.coordinate]
            right = [split.coordinate] + Array(positions.suffix(from: split.index))
        }
        guard left.count >= 2, right.count >= 2 else {
            throw ProjectFileError.invalid("A split must leave at least two vertices on both resulting lines.")
        }

        let newComponentIdentity = "geometry.coordinates.split:" + UUID().uuidString
        guard var features = featureValues else { throw ProjectFileError.invalid("The selected GeoJSON feature is unavailable.") }
        let featureIndex = address.featureIndex
        guard features.indices.contains(featureIndex), var geometry = features[featureIndex].value(for: "geometry"),
              let geometryType = geometry.value(for: "type")?.stringValue,
              let coordinates = geometry.value(for: "coordinates") else {
            throw ProjectFileError.invalid("The selected line geometry is unavailable.")
        }

        if geometryType == "MultiLineString", let componentIndex = address.componentIndex,
           var components = coordinates.arrayValues, components.indices.contains(componentIndex) {
            components[componentIndex] = .array(left)
            components.insert(.array(right), at: componentIndex + 1)
            geometry.set(.array(components), for: "coordinates")
            var feature = features[featureIndex]; feature.set(geometry, for: "geometry")
            features[featureIndex] = feature; setFeatureValues(features)
            var identities = componentIdentities[featureIndex] ?? [:]
            identities = Dictionary(uniqueKeysWithValues: identities.map { index, identity in
                (index > componentIndex ? index + 1 : index, identity)
            })
            identities[componentIndex] = address.componentIdentity
            identities[componentIndex + 1] = newComponentIdentity
            componentIdentities[featureIndex] = identities
            let featureIdentity = featureIdentities[featureIndex] ?? address.featureIdentity
            return [Self.lineID(featureIdentity: featureIdentity, componentIdentity: address.componentIdentity),
                    Self.lineID(featureIdentity: featureIdentity, componentIdentity: newComponentIdentity)]
        }

        guard geometryType == "LineString", supportsAddingLines else {
            throw ProjectFileError.invalid("Splitting a LineString feature requires a GeoJSON FeatureCollection.")
        }
        let originalFeature = features[featureIndex]
        var firstGeometry = geometry; firstGeometry.set(.array(left), for: "coordinates")
        var firstFeature = originalFeature; firstFeature.set(firstGeometry, for: "geometry")
        var secondGeometry = geometry; secondGeometry.set(.array(right), for: "coordinates")
        var secondFeature = originalFeature; secondFeature.set(secondGeometry, for: "geometry")
        secondFeature.set(.string(Self.uniqueFeatureID(in: features)), for: "id")
        features[featureIndex] = firstFeature
        features.insert(secondFeature, at: featureIndex + 1)
        shiftFeatureIdentityIndexes(forInsertionAt: featureIndex + 1)
        setFeatureValues(features)
        let secondFeatureIdentity = Self.identity(for: secondFeature)
        featureIdentities[featureIndex] = address.featureIdentity
        componentIdentities[featureIndex] = [0: address.componentIdentity]
        featureIdentities[featureIndex + 1] = secondFeatureIdentity
        componentIdentities[featureIndex + 1] = [0: newComponentIdentity]
        ambiguousFeatureIndices.remove(featureIndex + 1)
        return [Self.lineID(featureIdentity: address.featureIdentity, componentIdentity: address.componentIdentity),
                Self.lineID(featureIdentity: secondFeatureIdentity, componentIdentity: newComponentIdentity)]
    }

    /// Source MergePolylineOperation joins endpoint-connected chains using the
    /// nearest available connection (the source's PreferClosest mode). This
    /// GeoJSON editor limits a merge to components of the same MultiLineString
    /// so no Feature-level id or property object has to be discarded.
    @discardableResult
    public mutating func merge(lineIDs: [String], tolerance: Double = 5.0) throws -> [String] {
        guard tolerance.isFinite, tolerance >= 0 else { throw ProjectFileError.invalid("Merge tolerance must be finite and non-negative.") }
        var seenIDs = Set<String>()
        let uniqueIDs = lineIDs.filter { seenIDs.insert($0).inserted }
        guard uniqueIDs.count >= 2 else { throw ProjectFileError.invalid("Select at least two line components to merge.") }
        let addresses = try uniqueIDs.map(lineAddress)
        guard addresses.allSatisfy(\.editable) else { throw ProjectFileError.invalid("An ambiguous line identity cannot be merged safely.") }
        guard Set(addresses.map(\.featureIndex)).count == 1,
              let featureIndex = addresses.first?.featureIndex,
              addresses.allSatisfy({ $0.componentIndex != nil }) else {
            throw ProjectFileError.invalid("Merging separate GeoJSON Features cannot preserve both Features' properties and ids safely.")
        }
        guard let features = featureValues, features.indices.contains(featureIndex),
              let geometry = features[featureIndex].value(for: "geometry"),
              geometry.value(for: "type")?.stringValue == "MultiLineString",
              let allComponents = geometry.value(for: "coordinates")?.arrayValues else {
            throw ProjectFileError.invalid("Safe merging requires components of one GeoJSON MultiLineString Feature.")
        }
        let orderedAddresses = addresses.sorted { $0.componentIndex! < $1.componentIndex! }
        let selectedOrdinals = orderedAddresses.map { $0.componentIndex! }
        let components = try orderedAddresses.map { address -> [Value] in
            guard allComponents.indices.contains(address.componentIndex!) else {
                throw ProjectFileError.invalid("A selected MultiLineString component is unavailable.")
            }
            return allComponents[address.componentIndex!].arrayValues ?? []
        }
        guard components.allSatisfy({ $0.count >= 2 }),
              let dimensionCount = components.first?.first?.arrayValues?.count, dimensionCount >= 2,
              components.flatMap({ $0 }).allSatisfy({
                  $0.arrayValues?.count == dimensionCount && Self.mapPoint($0) != nil
              }) else {
            throw ProjectFileError.invalid("Selected lines need consistent coordinate dimensions to merge safely.")
        }

        let merged = Self.mergeComponents(components, tolerance: tolerance)
        guard !merged.chains.isEmpty else { throw ProjectFileError.invalid("No selected line endpoints are within the merge tolerance.") }
        var replacements: [(coordinates: [Value], identity: String)] = []
        var mergedIdentities: [String] = []
        for chain in merged.chains {
            guard let owner = chain.sourceIndices.min() else { continue }
            let identity = orderedAddresses[owner].componentIdentity
            replacements.append((chain.coordinates, identity))
            mergedIdentities.append(identity)
        }
        for index in merged.unmergedIndices {
            replacements.append((components[index], orderedAddresses[index].componentIdentity))
        }
        var changed = allComponents
        for ordinal in selectedOrdinals.sorted(by: >) { changed.remove(at: ordinal) }
        let insertionIndex = selectedOrdinals.min() ?? changed.count
        for (offset, replacement) in replacements.enumerated() {
            changed.insert(.array(replacement.coordinates), at: insertionIndex + offset)
        }
        var updatedGeometry = geometry; updatedGeometry.set(.array(changed), for: "coordinates")
        var updatedFeature = features[featureIndex]; updatedFeature.set(updatedGeometry, for: "geometry")
        var updatedFeatures = features; updatedFeatures[featureIndex] = updatedFeature
        setFeatureValues(updatedFeatures)

        let removedOrdinals = Set(selectedOrdinals)
        let oldIdentities = componentIdentities[featureIndex] ?? [:]
        var nextIdentities: [Int: String] = [:]
        var outputOrdinal = 0
        for oldOrdinal in allComponents.indices where !removedOrdinals.contains(oldOrdinal) {
            if oldOrdinal < insertionIndex { nextIdentities[outputOrdinal] = oldIdentities[oldOrdinal] ?? "geometry.coordinates[\(oldOrdinal)]"; outputOrdinal += 1 }
        }
        for replacement in replacements { nextIdentities[outputOrdinal] = replacement.identity; outputOrdinal += 1 }
        for oldOrdinal in allComponents.indices where !removedOrdinals.contains(oldOrdinal) && oldOrdinal >= insertionIndex {
            nextIdentities[outputOrdinal] = oldIdentities[oldOrdinal] ?? "geometry.coordinates[\(oldOrdinal)]"; outputOrdinal += 1
        }
        componentIdentities[featureIndex] = nextIdentities
        let featureIdentity = featureIdentities[featureIndex] ?? orderedAddresses[0].featureIdentity
        return mergedIdentities.map { Self.lineID(featureIdentity: featureIdentity, componentIdentity: $0) }
    }

    /// Adds the clicked point at the nearer end, matching the source endpoint
    /// attach gesture. Extra ordinates are copied from that endpoint.
    @discardableResult
    public mutating func attachEndpoint(lineID: String, at point: MapPoint, near anchor: MapPoint? = nil,
                                        maximumDistance: Double) throws -> Int {
        guard point.x.isFinite, point.y.isFinite, maximumDistance.isFinite, maximumDistance >= 0,
              anchor.map({ $0.x.isFinite && $0.y.isFinite }) ?? true else {
            throw ProjectFileError.invalid("Choose a finite point within the endpoint attach tolerance.")
        }
        let address = try lineAddress(lineID)
        guard address.editable else { throw ProjectFileError.invalid("This line identity is ambiguous and cannot be edited safely.") }
        var positions = try coordinateValues(at: address)
        guard let first = positions.first.flatMap(Self.mapPoint), let last = positions.last.flatMap(Self.mapPoint), positions.count >= 2 else {
            throw ProjectFileError.invalid("The selected line has no attachable endpoint.")
        }
        let target = anchor ?? point
        let prepend = Self.distance(from: first, to: target) <= Self.distance(from: last, to: target)
        let endpoint = prepend ? positions[0] : positions[positions.count - 1]
        guard let ordinates = endpoint.arrayValues, ordinates.count >= 2 else {
            throw ProjectFileError.invalid("The selected line endpoint is invalid.")
        }
        guard Self.distance(from: prepend ? first : last, to: target) <= maximumDistance else {
            throw ProjectFileError.invalid("Click within the endpoint attach tolerance.")
        }
        var attached = ordinates
        attached[0] = .number(try Self.numberString(point.x)); attached[1] = .number(try Self.numberString(point.y))
        if prepend { positions.insert(.array(attached), at: 0) } else { positions.append(.array(attached)) }
        try setCoordinateValues(positions, at: address)
        return prepend ? 0 : positions.count - 1
    }

    public mutating func deleteLine(lineID: String) throws {
        let address = try lineAddress(lineID)
        guard address.editable else { throw ProjectFileError.invalid("This line identity is ambiguous and cannot be edited safely.") }
        guard supportsAddingLines, var features = featureValues else {
            throw ProjectFileError.invalid("Only a line in a FeatureCollection can be deleted safely.")
        }
        if let componentIndex = address.componentIndex,
           let coordinates = features[address.featureIndex].value(for: "geometry")?.value(for: "coordinates")?.arrayValues,
           coordinates.count > 1 {
            var geometry = features[address.featureIndex].value(for: "geometry")!
            var remaining = coordinates; remaining.remove(at: componentIndex)
            geometry.set(.array(remaining), for: "coordinates")
            var feature = features[address.featureIndex]; feature.set(geometry, for: "geometry")
            features[address.featureIndex] = feature
            setFeatureValues(features)
            if var keys = componentIdentities[address.featureIndex] {
                keys.removeValue(forKey: componentIndex)
                componentIdentities[address.featureIndex] = Dictionary(uniqueKeysWithValues: keys.sorted { $0.key < $1.key }.enumerated().map { ($0.offset, $0.element.value) })
            }
            return
        }
        features.remove(at: address.featureIndex)
        setFeatureValues(features)
        shiftFeatureIdentityIndexes(afterRemoving: address.featureIndex)
    }

    @discardableResult
    public mutating func addLine(points: [MapPoint], name: String? = nil) throws -> String {
        guard supportsAddingLines, var features = featureValues else {
            throw ProjectFileError.invalid("Adding a line requires a GeoJSON FeatureCollection.")
        }
        guard points.count >= 2, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw ProjectFileError.invalid("A new line needs at least two finite coordinates.")
        }
        let identifier = UUID().uuidString
        var properties: [(String, Value)] = []
        if let name { properties.append(("name", .string(name))) }
        let coordinates = try points.map { point -> Value in
            .array([.number(try Self.numberString(point.x)), .number(try Self.numberString(point.y))])
        }
        let feature = Value.object([
            ("type", .string("Feature")), ("id", .string(identifier)),
            ("properties", .object(properties)),
            ("geometry", .object([("type", .string("LineString")), ("coordinates", .array(coordinates))]))
        ])
        let index = features.count
        features.append(feature); setFeatureValues(features)
        let featureIdentity = Self.identity(for: feature)
        featureIdentities[index] = featureIdentity
        componentIdentities[index] = [0: "geometry.coordinates[0]"]
        return Self.lineID(featureIdentity: featureIdentity, componentIdentity: componentIdentities[index]![0]!)
    }

    /// Adds clipboard geometry without dropping source Z/M dimensions. GeoJSON
    /// positions can represent XY, XYZ, and XYZM; an M-only shape is refused
    /// because assigning its M value to the third ordinate would change its
    /// meaning to Z.
    @discardableResult
    public mutating func addLine(sourceCoordinates: [MapSourceCoordinate], hasZ: Bool,
                                 hasM: Bool, name: String? = nil) throws -> String {
        guard supportsAddingLines, var features = featureValues else {
            throw ProjectFileError.invalid("Adding a line requires a GeoJSON FeatureCollection.")
        }
        guard sourceCoordinates.count >= 2,
              sourceCoordinates.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw ProjectFileError.invalid("A new line needs at least two finite coordinates.")
        }
        guard !hasM || hasZ else {
            throw ProjectFileError.invalid("This GeoJSON editor cannot represent M-only polyline coordinates.")
        }
        guard sourceCoordinates.allSatisfy({ coordinate in
            if hasZ {
                guard let z = coordinate.z, z.isFinite else { return false }
            } else if coordinate.z != nil { return false }
            if hasM {
                guard let m = coordinate.m, m.isFinite else { return false }
            } else if coordinate.m != nil { return false }
            return true
        }) else {
            throw ProjectFileError.invalid("The copied polyline dimensions do not match its coordinates.")
        }

        let identifier = UUID().uuidString
        var properties: [(String, Value)] = []
        if let name { properties.append(("name", .string(name))) }
        let coordinates = try sourceCoordinates.map { coordinate -> Value in
            var ordinates: [Value] = [
                .number(try Self.numberString(coordinate.x)),
                .number(try Self.numberString(coordinate.y))
            ]
            if hasZ, let z = coordinate.z { ordinates.append(.number(try Self.numberString(z))) }
            if hasM, let m = coordinate.m { ordinates.append(.number(try Self.numberString(m))) }
            return .array(ordinates)
        }
        let feature = Value.object([
            ("type", .string("Feature")), ("id", .string(identifier)),
            ("properties", .object(properties)),
            ("geometry", .object([("type", .string("LineString")), ("coordinates", .array(coordinates))]))
        ])
        let index = features.count
        features.append(feature); setFeatureValues(features)
        let featureIdentity = Self.identity(for: feature)
        featureIdentities[index] = featureIdentity
        componentIdentities[index] = [0: "geometry.coordinates[0]"]
        return Self.lineID(featureIdentity: featureIdentity, componentIdentity: componentIdentities[index]![0]!)
    }

    /// Set the post-save byte baseline without discarding in-session line identities.
    public mutating func acceptSavedRevision(_ revision: String) {
        sourceRevision = revision
    }

    private var featureValues: [Value]? {
        if root.value(for: "type")?.stringValue == "Feature" { return [root] }
        return root.value(for: "features")?.arrayValues
    }

    private mutating func setFeatureValues(_ features: [Value]) {
        if root.value(for: "type")?.stringValue == "Feature" {
            if let feature = features.first { root = feature }
        } else { root.set(.array(features), for: "features") }
    }

    private mutating func rebuildIdentities() throws {
        guard let features = featureValues else { throw ProjectFileError.invalid("The GeoJSON FeatureCollection has no feature array.") }
        var counts: [String: Int] = [:]
        var identities: [Int: String] = [:]
        for index in features.indices {
            guard case .object = features[index] else { throw ProjectFileError.invalid("The GeoJSON FeatureCollection contains an invalid feature.") }
            let identity = Self.identity(for: features[index])
            identities[index] = identity; counts[identity, default: 0] += 1
        }
        featureIdentities = identities
        ambiguousFeatureIndices = Set(identities.compactMap { counts[$0.value, default: 0] > 1 ? $0.key : nil })
        for index in features.indices {
            guard let geometry = features[index].value(for: "geometry"), let type = geometry.value(for: "type")?.stringValue else { continue }
            let count: Int
            if type == "LineString" { count = 1 }
            else if type == "MultiLineString" { count = geometry.value(for: "coordinates")?.arrayValues?.count ?? 0 }
            else { continue }
            componentIdentities[index] = Dictionary(uniqueKeysWithValues: (0..<count).map { ($0, "geometry.coordinates[\($0)]") })
        }
    }

    private func lineAddress(_ id: String) throws -> LineAddress {
        guard let features = featureValues else { throw ProjectFileError.invalid("The GeoJSON line no longer exists.") }
        for index in features.indices {
            guard let geometry = features[index].value(for: "geometry"), let type = geometry.value(for: "type")?.stringValue else { continue }
            guard type == "LineString" || type == "MultiLineString" else { continue }
            let count = type == "LineString" ? 1 : geometry.value(for: "coordinates")?.arrayValues?.count ?? 0
            for component in 0..<count {
                let keyIndex = type == "LineString" ? 0 : component
                let featureIdentity = featureIdentities[index] ?? Self.identity(for: features[index])
                let componentIdentity = componentIdentities[index]?[keyIndex] ?? "geometry.coordinates[\(keyIndex)]"
                guard Self.lineID(featureIdentity: featureIdentity, componentIdentity: componentIdentity) == id else { continue }
                return LineAddress(featureIndex: index, componentIndex: type == "MultiLineString" ? component : nil,
                    featureIdentity: featureIdentity, componentIdentity: componentIdentity,
                    editable: !ambiguousFeatureIndices.contains(index))
            }
        }
        throw ProjectFileError.invalid("The selected GeoJSON line is no longer available.")
    }

    private func coordinateValues(at address: LineAddress) throws -> [Value] {
        guard let features = featureValues,
              let geometry = features.indices.contains(address.featureIndex) ? features[address.featureIndex].value(for: "geometry") : nil,
              let coordinates = geometry.value(for: "coordinates") else { throw ProjectFileError.invalid("The selected line coordinates are unavailable.") }
        if let componentIndex = address.componentIndex {
            guard let parts = coordinates.arrayValues, parts.indices.contains(componentIndex), let values = parts[componentIndex].arrayValues else {
                throw ProjectFileError.invalid("The selected MultiLineString component is unavailable.")
            }
            return values
        }
        guard let values = coordinates.arrayValues else { throw ProjectFileError.invalid("The selected line coordinates are invalid.") }
        return values
    }

    private mutating func setCoordinateValues(_ values: [Value], at address: LineAddress) throws {
        guard var features = featureValues, features.indices.contains(address.featureIndex),
              var geometry = features[address.featureIndex].value(for: "geometry"),
              let current = geometry.value(for: "coordinates") else { throw ProjectFileError.invalid("The selected line coordinates are unavailable.") }
        if let componentIndex = address.componentIndex {
            guard var parts = current.arrayValues, parts.indices.contains(componentIndex) else { throw ProjectFileError.invalid("The selected MultiLineString component is unavailable.") }
            parts[componentIndex] = .array(values); geometry.set(.array(parts), for: "coordinates")
        } else { geometry.set(.array(values), for: "coordinates") }
        var feature = features[address.featureIndex]; feature.set(geometry, for: "geometry"); features[address.featureIndex] = feature
        setFeatureValues(features)
    }

    private mutating func shiftFeatureIdentityIndexes(afterRemoving removed: Int) {
        featureIdentities = Dictionary(uniqueKeysWithValues: featureIdentities.compactMap { index, value in
            if index == removed { return nil }
            return (index > removed ? index - 1 : index, value)
        })
        componentIdentities = Dictionary(uniqueKeysWithValues: componentIdentities.compactMap { index, value in
            if index == removed { return nil }
            return (index > removed ? index - 1 : index, value)
        })
        ambiguousFeatureIndices = Set(ambiguousFeatureIndices.compactMap { index in
            if index == removed { return nil }
            return index > removed ? index - 1 : index
        })
    }

    private mutating func shiftFeatureIdentityIndexes(forInsertionAt inserted: Int) {
        featureIdentities = Dictionary(uniqueKeysWithValues: featureIdentities.map { index, value in
            (index >= inserted ? index + 1 : index, value)
        })
        componentIdentities = Dictionary(uniqueKeysWithValues: componentIdentities.map { index, value in
            (index >= inserted ? index + 1 : index, value)
        })
        ambiguousFeatureIndices = Set(ambiguousFeatureIndices.map { index in index >= inserted ? index + 1 : index })
    }

    private struct EndpointConnection {
        let indexA: Int
        let isStartA: Bool
        let indexB: Int
        let isStartB: Bool
        let distance: Double
    }

    /// Mirrors PolylineMergeHelpers.MergePolylines with PreferClosest: build
    /// endpoint-connected groups, walk the closest unvisited connection, and
    /// leave branches that cannot be consumed in a single chain as separate
    /// components. Input order breaks equal-distance ties deterministically.
    private static func mergeComponents(_ components: [[Value]], tolerance: Double) -> (chains: [MergeChain], unmergedIndices: [Int]) {
        var connections: [EndpointConnection] = []
        if components.count > 1 {
            for first in 0..<(components.count - 1) {
                guard let firstStart = components[first].first.flatMap(mapPoint),
                      let firstEnd = components[first].last.flatMap(mapPoint) else { continue }
                for second in (first + 1)..<components.count {
                    guard let secondStart = components[second].first.flatMap(mapPoint),
                          let secondEnd = components[second].last.flatMap(mapPoint) else { continue }
                    let pairs: [(Bool, Bool, MapPoint, MapPoint)] = [
                        (true, true, firstStart, secondStart),
                        (true, false, firstStart, secondEnd),
                        (false, true, firstEnd, secondStart),
                        (false, false, firstEnd, secondEnd)
                    ]
                    for (firstIsStart, secondIsStart, a, b) in pairs {
                        let distance = hypot(a.x - b.x, a.y - b.y)
                        if distance.isFinite && distance <= tolerance {
                            connections.append(EndpointConnection(indexA: first, isStartA: firstIsStart,
                                indexB: second, isStartB: secondIsStart, distance: distance))
                        }
                    }
                }
            }
        }

        var adjacency = Array(repeating: Set<Int>(), count: components.count)
        for connection in connections {
            adjacency[connection.indexA].insert(connection.indexB)
            adjacency[connection.indexB].insert(connection.indexA)
        }
        var groups: [[Int]] = []
        var visited = Set<Int>()
        for index in components.indices where !visited.contains(index) {
            var queue = [index]
            visited.insert(index)
            var group: [Int] = []
            while let next = queue.first {
                queue.removeFirst(); group.append(next)
                for neighbor in adjacency[next].sorted() where visited.insert(neighbor).inserted { queue.append(neighbor) }
            }
            groups.append(group.sorted())
        }

        var chains: [MergeChain] = []
        var unmerged: [Int] = []
        for group in groups {
            guard group.count > 1 else { unmerged.append(contentsOf: group); continue }
            var remaining = Set(group)
            while remaining.count > 1 {
                var firstNode: Int?
                var forwardFromStart = true
                for index in group where remaining.contains(index) {
                    let startHasConnection = connections.contains { connection in
                        (connection.indexA == index && connection.isStartA && remaining.contains(connection.indexB)) ||
                        (connection.indexB == index && connection.isStartB && remaining.contains(connection.indexA))
                    }
                    let endHasConnection = connections.contains { connection in
                        (connection.indexA == index && !connection.isStartA && remaining.contains(connection.indexB)) ||
                        (connection.indexB == index && !connection.isStartB && remaining.contains(connection.indexA))
                    }
                    if !startHasConnection { firstNode = index; forwardFromStart = true; break }
                    if !endHasConnection { firstNode = index; forwardFromStart = false; break }
                }
                if firstNode == nil { firstNode = remaining.min(); forwardFromStart = true }
                guard let initial = firstNode else { break }

                var chainCoordinates: [Value] = []
                var chainIndices: [Int] = []
                var current = initial
                var entersAtStart = forwardFromStart
                while remaining.contains(current) {
                    remaining.remove(current)
                    chainIndices.append(current)
                    var path = components[current]
                    if !entersAtStart { path.reverse() }
                    if chainCoordinates.isEmpty { chainCoordinates = path }
                    else if !path.isEmpty {
                        // Polyline.Concatenate discards the previous line's
                        // terminal coordinate and keeps the next line's start.
                        chainCoordinates.removeLast()
                        chainCoordinates.append(contentsOf: path)
                    }
                    let exitsAtStart = entersAtStart == false
                    let options = connections.compactMap { connection -> (EndpointConnection, Int, Bool)? in
                        if connection.indexA == current && connection.isStartA == exitsAtStart && remaining.contains(connection.indexB) {
                            return (connection, connection.indexB, connection.isStartB)
                        }
                        if connection.indexB == current && connection.isStartB == exitsAtStart && remaining.contains(connection.indexA) {
                            return (connection, connection.indexA, connection.isStartA)
                        }
                        return nil
                    }
                    guard let next = options.min(by: { $0.0.distance < $1.0.distance }) else { break }
                    current = next.1
                    entersAtStart = next.2
                }
                if chainIndices.count >= 2 {
                    chains.append(MergeChain(coordinates: chainCoordinates, sourceIndices: chainIndices))
                } else {
                    remaining.formUnion(chainIndices)
                    break
                }
            }
            unmerged.append(contentsOf: remaining.sorted())
        }
        return (chains, unmerged.sorted())
    }

    private static func interpolatePosition(_ left: Value, _ right: Value,
                                            fraction: Double, projectedXY: MapPoint) throws -> Value {
        guard fraction.isFinite, let leftValues = left.arrayValues, let rightValues = right.arrayValues,
              leftValues.count == rightValues.count, leftValues.count >= 2 else {
            throw ProjectFileError.invalid("Extra coordinate dimensions cannot be interpolated safely.")
        }
        var values: [Value] = [
            .number(try numberString(projectedXY.x)),
            .number(try numberString(projectedXY.y))
        ]
        for dimension in 2..<leftValues.count {
            guard case .number(let leftRaw) = leftValues[dimension], case .number(let rightRaw) = rightValues[dimension],
                  let leftNumber = Double(leftRaw), let rightNumber = Double(rightRaw),
                  leftNumber.isFinite, rightNumber.isFinite else {
                throw ProjectFileError.invalid("Extra coordinate dimensions cannot be interpolated safely.")
            }
            let interpolated = leftNumber * (1 - fraction) + rightNumber * fraction
            guard interpolated.isFinite else { throw ProjectFileError.invalid("Extra coordinate dimensions cannot be interpolated safely.") }
            values.append(.number(try numberString(interpolated)))
        }
        return .array(values)
    }

    private static func uniqueFeatureID(in features: [Value]) -> String {
        var identifier = UUID().uuidString
        let used = Set(features.compactMap { $0.value(for: "id")?.stringValue })
        while used.contains(identifier) { identifier = UUID().uuidString }
        return identifier
    }

    private static func distance(from first: MapPoint, to second: MapPoint) -> Double {
        hypot(first.x - second.x, first.y - second.y)
    }

    private static func validateNonzeroLine(_ coordinates: [[Double]]) throws {
        guard coordinates.count >= 2,
              coordinates.indices.dropFirst().contains(where: { index in
                  coordinates[index][0] != coordinates[index - 1][0] || coordinates[index][1] != coordinates[index - 1][1]
              }) else {
            throw ProjectFileError.invalid("Polyline operations require a nonzero line with at least two vertices.")
        }
    }

    private static func validateReplacement(_ replacement: GeoJSONPolylineReplacement) throws {
        guard !replacement.hasM || replacement.hasZ else {
            throw ProjectFileError.invalid("GeoJSON cannot preserve M-only polyline coordinates.")
        }
        guard replacement.coordinates.count >= 2,
              replacement.coordinates.allSatisfy({ coordinate in
                  coordinate.x.isFinite && coordinate.y.isFinite
                      && (!replacement.hasZ || coordinate.z?.isFinite == true)
                      && (!replacement.hasM || coordinate.m?.isFinite == true)
                      && (replacement.hasZ || coordinate.z == nil)
                      && (replacement.hasM || coordinate.m == nil)
              }) else {
            throw ProjectFileError.invalid("The geometry operation returned invalid coordinates or dimensions.")
        }
        try validateNonzeroLine(replacement.coordinates.map { [$0.x, $0.y] })
    }

    private static func replacementValues(_ replacement: GeoJSONPolylineReplacement,
                                          preserving original: [Value]?) throws -> [Value] {
        try validateReplacement(replacement)
        let outputDimensionCount = 2 + (replacement.hasZ ? 1 : 0) + (replacement.hasM ? 1 : 0)
        if let original,
           original.contains(where: { ($0.arrayValues?.count ?? 0) > outputDimensionCount }) {
            guard original.count == replacement.coordinates.count,
                  original.allSatisfy({ ($0.arrayValues?.count ?? 0) >= outputDimensionCount }) else {
                throw ProjectFileError.invalid("The operation changed vertex count and omitted source coordinate dimensions.")
            }
            return try zip(replacement.coordinates, original).map { pair in
                let (coordinate, source) = pair
                guard var ordinates = source.arrayValues else {
                    throw ProjectFileError.invalid("The source coordinate dimensions are invalid.")
                }
                ordinates[0] = .number(try numberString(coordinate.x))
                ordinates[1] = .number(try numberString(coordinate.y))
                if replacement.hasZ { ordinates[2] = .number(try numberString(coordinate.z!)) }
                if replacement.hasM { ordinates[3] = .number(try numberString(coordinate.m!)) }
                return .array(ordinates)
            }
        }
        return try replacement.coordinates.map { coordinate in
            var ordinates: [Value] = [
                .number(try numberString(coordinate.x)),
                .number(try numberString(coordinate.y))
            ]
            if replacement.hasZ, let z = coordinate.z { ordinates.append(.number(try numberString(z))) }
            if replacement.hasM, let m = coordinate.m { ordinates.append(.number(try numberString(m))) }
            return .array(ordinates)
        }
    }

    private static func identity(for feature: Value) -> String {
        if let id = feature.value(for: "id") {
            switch id {
            case .string(let text): return "geojson-id:string:" + digest(Data(text.utf8))
            case .number(let number): return "geojson-id:number:" + digest(Data(number.utf8))
            default: break
            }
        }
        return "geojson-content:" + ((try? feature.jsonData()).map(digest) ?? "invalid")
    }

    private static func featureName(_ feature: Value, fallback: String) -> String {
        if let properties = feature.value(for: "properties"), let name = properties.value(for: "name")?.stringValue,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
        if let id = feature.value(for: "id")?.stringValue { return id }
        return String(fallback.suffix(12))
    }

    private static func mapPoint(_ value: Value) -> MapPoint? {
        guard let coordinates = value.arrayValues, coordinates.count >= 2,
              case .number(let xRaw) = coordinates[0], case .number(let yRaw) = coordinates[1],
              let x = Double(xRaw), let y = Double(yRaw), x.isFinite, y.isFinite else { return nil }
        return MapPoint(x: x, y: y)
    }

    private static func lineID(featureIdentity: String, componentIdentity: String) -> String {
        "polyline:" + digest(Data((featureIdentity + "|" + componentIdentity).utf8))
    }
    private static func numberString(_ value: Double) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}

public enum GeoJSONPolylineSplitMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    case anywhere
    case atVertex
    public var id: String { rawValue }
}

public struct GeoJSONPolylinePointDeletion: Equatable, Sendable {
    public let lineDeleted: Bool
    public let selectedVertexIndex: Int?
}

public struct GeoJSONPolylineLine: Identifiable, Equatable, Sendable {
    public let id: String
    public let sourceFeatureIdentity: String
    /// Position in the GeoJSON FeatureCollection. This is a correlation hint for
    /// projecting the parsed map geometry, never part of the stable identity.
    public let sourceFeatureOrdinal: Int
    /// LineString is component 0; MultiLineString components remain separate.
    public let componentOrdinal: Int
    public let name: String
    public let points: [MapPoint]
    public let geometryPath: String
    public let canEdit: Bool

    public init(id: String, sourceFeatureIdentity: String, sourceFeatureOrdinal: Int,
                componentOrdinal: Int, name: String, points: [MapPoint],
                geometryPath: String, canEdit: Bool) {
        self.id = id
        self.sourceFeatureIdentity = sourceFeatureIdentity
        self.sourceFeatureOrdinal = sourceFeatureOrdinal
        self.componentOrdinal = componentOrdinal
        self.name = name
        self.points = points
        self.geometryPath = geometryPath
        self.canEdit = canEdit
    }
}

public struct GeoJSONPolylineReplacement: Sendable {
    public let coordinates: [MapSourceCoordinate]
    public let hasZ: Bool
    public let hasM: Bool

    public init(coordinates: [MapSourceCoordinate], hasZ: Bool, hasM: Bool) {
        self.coordinates = coordinates
        self.hasZ = hasZ
        self.hasM = hasM
    }
}
