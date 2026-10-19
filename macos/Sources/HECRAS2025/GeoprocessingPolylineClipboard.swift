import Foundation
import RASWorkspaceCore

/// Typed app clipboard for the source's `IEnumerable<Polyline>` output. The
/// original handler copies geometry objects, not source feature attributes.
struct GeoprocessingPolylineClipboard: Codable, Sendable {
    static let type = "org.hecras2025.polylines"
    static let textType = "public.utf8-plain-text"

    let schema: String
    let coordinateProjectionWKT: String?
    let lines: [GeoprocessingClipboardPolyline]

    init(lines: [GeoprocessingClipboardPolyline], coordinateProjectionWKT: String?) {
        schema = "hecras-polylines-v1"
        self.coordinateProjectionWKT = coordinateProjectionWKT
        self.lines = lines
    }

    func validate() throws {
        guard schema == "hecras-polylines-v1", !lines.isEmpty else {
            throw ProjectFileError.invalid("The app clipboard has no copied polylines.")
        }
        for line in lines {
            guard line.vertices.count >= 2,
                  line.vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                  Self.hasNonzeroLength(line.vertices),
                  (line.hasZ ? line.vertices.allSatisfy({ $0.z != nil }) : line.vertices.allSatisfy({ $0.z == nil })),
                  (line.hasM ? line.vertices.allSatisfy({ $0.m != nil }) : line.vertices.allSatisfy({ $0.m == nil })),
                  line.vertices.allSatisfy({ vertex in
                      validOrdinate(vertex.z) && validOrdinate(vertex.m)
                  }) else {
                throw ProjectFileError.invalid("The copied polyline geometry or Z/M dimensions are invalid.")
            }
        }
    }

    @MainActor static func read(system: any WorkspaceSystemServices) throws -> Self {
        for item in system.readClipboard(types: [type]) {
            guard let data = item.representations[type] else { continue }
            let payload = try JSONDecoder().decode(Self.self, from: data)
            try payload.validate()
            return payload
        }
        throw ProjectFileError.invalid("The app clipboard does not contain copied polylines.")
    }

    private static func hasNonzeroLength(_ vertices: [GeoprocessingClipboardVertex]) -> Bool {
        vertices.indices.dropFirst().contains { index in
            vertices[index].x != vertices[index - 1].x || vertices[index].y != vertices[index - 1].y
        }
    }

    private func validOrdinate(_ value: String?) -> Bool {
        guard let value else { return true }
        return Double(value).map { !$0.isInfinite } ?? false
    }
}

struct GeoprocessingClipboardPolyline: Codable, Sendable {
    let hasZ: Bool
    let hasM: Bool
    let vertices: [GeoprocessingClipboardVertex]

    init(hasZ: Bool, hasM: Bool, vertices: [GeoprocessingClipboardVertex]) {
        self.hasZ = hasZ; self.hasM = hasM; self.vertices = vertices
    }

    init(_ output: GeoprocessingPolylineOutput) {
        hasZ = output.zValues != nil
        hasM = output.mValues != nil
        vertices = output.coordinates.indices.map { index in
            let point = output.coordinates[index]
            return GeoprocessingClipboardVertex(
                x: point[0], y: point[1],
                z: output.zValues?.indices.contains(index) == true ? output.zValues?[index] : nil,
                m: output.mValues?.indices.contains(index) == true ? output.mValues?[index] : nil
            )
        }
    }
}

struct GeoprocessingClipboardVertex: Codable, Sendable {
    let x: Double
    let y: Double
    /// Strings preserve IEEE NaN values that JSON numbers cannot encode.
    let z: String?
    let m: String?
}
