import Foundation
import RASWorkspaceCore
import SwiftUI

struct ProjectionDefinitionDraft: Codable, Hashable, Sendable {
    var type: String = "EPSG"
    var value: String = ""
    static func canonicalType(_ type: String) -> String {
        if type.caseInsensitiveCompare("None") == .orderedSame { return "Local" }
        return ["Local", "EPSG", "Proj", "WKT", "ESRI"].first { $0.caseInsensitiveCompare(type) == .orderedSame } ?? type
    }
    mutating func selectType(_ type: String) {
        guard self.type != type else { return }
        self.type = type; value = type == "Local" ? "SI" : ""
    }
}
struct ProjectionEvaluation: Codable, Sendable {
    let isValid: Bool
    let name: String
    let units: String?
    let unitName: String?
    let epsgCode: Int?
    let utmZone: Int?
    let wkt: String?
    let error: String?
    let normalizedType: String
    let normalizedValue: String
    var validity: String? = nil
    var isVertical: Bool? = nil
    var isProjected: Bool? = nil
    var areaOfUse: ProjectionAreaOfUse? = nil
    var normalizedDefinition: ProjectionDefinitionDraft { .init(type: normalizedType, value: normalizedValue) }
}

struct ProjectionAreaBounds: Codable, Equatable, Sendable {
    let left: Double
    let right: Double
    let bottom: Double
    let top: Double
}

struct ProjectionAreaOfUse: Codable, Equatable, Sendable {
    let geographic: ProjectionAreaBounds
    let projected: ProjectionAreaBounds
}

struct ProjectionSearchQuery: Encodable, Hashable, Sendable {
    var query: String? = nil
    var longitude: Double? = nil
    var latitude: Double? = nil
    var limit = 30
    var isLocation: Bool { longitude != nil || latitude != nil }
    var validLocation: Bool {
        guard let longitude, let latitude else { return false }
        return longitude.isFinite && latitude.isFinite && (-180...180).contains(longitude) && (-90...90).contains(latitude)
    }
}
struct ProjectionMatch: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let code: Int
    let authority: String
    var area: String? = nil
}
@MainActor
protocol ProjectionProvider {
    func evaluate(_ definition: ProjectionDefinitionDraft) async throws -> ProjectionEvaluation
    func search(_ query: ProjectionSearchQuery) async throws -> [ProjectionMatch]
}
@MainActor
final class BackendProjectionProvider: ProjectionProvider {
    private let client: BackendProcessClient
    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }
    func evaluate(_ definition: ProjectionDefinitionDraft) async throws -> ProjectionEvaluation {
        try await client.request("projection.evaluate", parameters: definition, as: ProjectionEvaluation.self)
    }
    func search(_ query: ProjectionSearchQuery) async throws -> [ProjectionMatch] {
        try await client.request("projection.search", parameters: query, as: [ProjectionMatch].self)
    }
}

@MainActor
final class ProjectProjectionSession: ObservableObject {
    @Published private(set) var evaluation: ProjectionEvaluation?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var input: ProjectionDefinitionDraft?
    private var revision = 0
    func current(_ definition: ProjectionDefinitionDraft) -> ProjectionEvaluation? { input == definition ? evaluation : nil }
    func accepted(_ definition: ProjectionDefinitionDraft) -> ProjectionEvaluation? {
        guard let result = current(definition), result.isValid else { return nil }
        return result
    }
    func evaluate(_ definition: ProjectionDefinitionDraft, provider: (any ProjectionProvider)?, debounce: Duration = .milliseconds(250)) async {
        revision += 1; let request = revision
        input = definition; evaluation = nil; error = nil; loading = false
        guard !definition.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let provider else { error = L10n.text("The projection service is unavailable."); return }
        loading = true
        defer { if request == revision { loading = false } }
        do {
            try await Task.sleep(for: debounce)
            let result = try await provider.evaluate(definition)
            guard !Task.isCancelled, request == revision else { return }
            guard !result.isValid || ["Local", "EPSG", "Proj", "WKT"].contains(result.normalizedType),
                  !result.isValid || ["SI", "USC"].contains(result.units ?? ""),
                  !result.isValid || !result.normalizedValue.isEmpty else {
                throw ProjectFileError.invalid("The projection service returned an invalid definition.")
            }
            evaluation = result
        } catch {
            guard !Task.isCancelled, request == revision else { return }
            self.error = L10n.text(error.localizedDescription)
        }
    }
    func invalidate() { revision += 1; input = nil; evaluation = nil; loading = false; error = nil }
}

@MainActor
final class ProjectionSearchSession: ObservableObject {
    @Published private(set) var matches: [ProjectionMatch] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var revision = 0
    private var input: ProjectionSearchQuery?
    func results(for query: ProjectionSearchQuery?) -> [ProjectionMatch] { input == query ? matches : [] }
    func search(_ query: ProjectionSearchQuery?, provider: (any ProjectionProvider)?, debounce: Duration = .milliseconds(250)) async {
        revision += 1; let request = revision
        input = query
        matches = []; error = nil; loading = false
        guard let query else { return }
        guard query.isLocation || query.query?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return }
        guard !query.isLocation || query.validLocation else { error = L10n.text("Enter valid longitude and latitude."); return }
        guard let provider else { error = L10n.text("The projection service is unavailable."); return }
        loading = true
        defer { if request == revision { loading = false } }
        do {
            try await Task.sleep(for: debounce)
            let results = try await provider.search(query)
            guard !Task.isCancelled, request == revision else { return }
            guard Set(results.map(\.id)).count == results.count,
                  results.allSatisfy({ $0.authority == "EPSG" && $0.code > 0 && $0.id == "EPSG:" + String($0.code) }) else {
                throw ProjectFileError.invalid("The projection service returned invalid coordinate system identities.")
            }
            matches = results
        } catch {
            guard !Task.isCancelled, request == revision else { return }
            self.error = L10n.text(error.localizedDescription)
        }
    }
    func invalidate() { revision += 1; input = nil; matches = []; loading = false; error = nil }
}
