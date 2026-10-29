import Foundation
import Combine

struct RasterPalette: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let colors: [String]
    var values: [Double]? = nil
    var isCustom: Bool = false

    static let defaults: [Self] = {
        struct Catalog: Decodable { let palettes: [RasterPalette] }
        guard let url = Bundle.module.url(forResource: "color-palettes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else { return [] }
        return catalog.palettes
    }()

    // Missing values and custom flags are intentional for source color-only palettes.
    init(id: String, name: String, colors: [String], values: [Double]? = nil, isCustom: Bool = false) {
        self.id = id; self.name = name; self.colors = colors; self.values = values; self.isCustom = isCustom
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        colors = try container.decode([String].self, forKey: .colors)
        values = try container.decodeIfPresent([Double].self, forKey: .values)
        isCustom = try container.decodeIfPresent(Bool.self, forKey: .isCustom) ?? false
    }
}

enum RasterValueSource: String, CaseIterable, Codable, Sendable { case histogram = "Histogram", linear = "Linear", manual = "Manual" }
struct RasterColorStop: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var color: String
    var value: Double
    init(id: UUID = UUID(), color: String, value: Double) { self.id = id; self.color = color; self.value = value }
}
struct RasterSymbologyDraft: Codable, Sendable, Equatable {
    var paletteID: String?
    var name: String
    var stops: [RasterColorStop]
    var valueSource: RasterValueSource
    var grayscale: Bool
    var isEditing: Bool
    var updateHistogramWithView: Bool
    var canComputeHistogram: Bool

    func valueIsEditable(at index: Int) -> Bool {
        isEditing && (valueSource == .manual || valueSource == .linear && (index == 0 || index == stops.count - 1))
    }
    // Source ValidateValuesIncreasing marks each row independently; its aggregate
    // uses |= starting at true. Keep row diagnostics without inventing an Apply gate.
    func valueIsIncreasing(at index: Int) -> Bool {
        stops[index].value.isFinite && stops[index].value > (index == 0 ? -Double.greatestFiniteMagnitude : stops[index - 1].value)
    }
    mutating func interpolate() {
        guard valueSource == .linear, stops.count >= 2, let first = stops.first?.value, let last = stops.last?.value else { return }
        let denominator = Double(stops.count - 1)
        for index in stops.indices { stops[index].value = first + (last - first) * Double(index) / denominator }
    }
}

/// Read-only values copied from Geospatial.Rendering.InterpolatedSurfaceFill.ColorValues.
/// This must come from an actual interpolated surface-fill context, not a generic raster range.
struct InterpolatedSurfaceFillContext: Sendable, Equatable {
    let colorValues: [Double]
    var minValue: Double? { colorValues.first }
    var maxValue: Double? { colorValues.last }
}

struct RasterSymbologySnapshot: Sendable {
    let draft: RasterSymbologyDraft
    let palettes: [RasterPalette]
    let interpolatedSurfaceFillContext: InterpolatedSurfaceFillContext?
    let additionalOptions: [RasterPlotOption]

    init(
        draft: RasterSymbologyDraft,
        palettes: [RasterPalette],
        interpolatedSurfaceFillContext: InterpolatedSurfaceFillContext? = nil,
        additionalOptions: [RasterPlotOption] = []
    ) {
        self.draft = draft
        self.palettes = palettes
        self.interpolatedSurfaceFillContext = interpolatedSurfaceFillContext
        self.additionalOptions = additionalOptions
    }
}

struct RasterPlotOptionChoice: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
}

/// Runtime options reflected from the retained RasterRenderLayer. These are
/// transient renderer state; the palette editor does not serialize them into
/// the project's .vis RasterSymbology element.
struct RasterPlotOption: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let isBoolean: Bool
    var value: String
    let choices: [RasterPlotOptionChoice]
    let isEnabled: Bool
    let description: String?
}
struct RasterSymbologyContext: Hashable, Sendable {
    let projectSessionID: UUID
    let mapID: UUID
    let assetID: String?
    var sourceContextRevision: Int? = nil
}

@MainActor
protocol RasterSymbologyProvider {
    func snapshot(_ context: RasterSymbologyContext) async throws -> RasterSymbologySnapshot?
    func selectPalette(_ id: String, draft: RasterSymbologyDraft, context: RasterSymbologyContext) async throws -> RasterSymbologyDraft
    func histogram(count: Int, forView: Bool, context: RasterSymbologyContext) async throws -> [Double]
    func apply(_ draft: RasterSymbologyDraft, additionalOptions: [RasterPlotOption], context: RasterSymbologyContext) async throws
    func reset(_ context: RasterSymbologyContext) async throws -> RasterSymbologySnapshot
    func savePalette(_ draft: RasterSymbologyDraft, name: String, context: RasterSymbologyContext) async throws -> [RasterPalette]
    func deletePalette(_ id: String, context: RasterSymbologyContext) async throws -> [RasterPalette]
}

@MainActor
final class RasterSymbologySession: ObservableObject {
    @Published private(set) var draft: RasterSymbologyDraft?
    @Published private(set) var palettes = RasterPalette.defaults
    @Published private(set) var interpolatedSurfaceFillContext: InterpolatedSurfaceFillContext?
    @Published private(set) var additionalOptions: [RasterPlotOption] = []
    @Published var selectedPaletteID: String?
    @Published private(set) var busy = false
    @Published var error: String?
    private var revision = 0
    private var context: RasterSymbologyContext?
    var previewColors: [String] {
        if let draft, draft.paletteID == selectedPaletteID { return draft.stops.map(\.color) }
        return palettes.first { $0.id == selectedPaletteID }?.colors ?? draft?.stops.map(\.color) ?? []
    }

    func load(context: RasterSymbologyContext, provider: (any RasterSymbologyProvider)?) async {
        revision += 1; let captured = revision; self.context = context
        draft = nil; palettes = RasterPalette.defaults; interpolatedSurfaceFillContext = nil; additionalOptions = []
        selectedPaletteID = nil; error = nil; busy = false
        guard let provider else { return }
        busy = true
        do {
            let snapshot = try await provider.snapshot(context)
            guard captured == revision, !Task.isCancelled else { return }
            if let snapshot { install(snapshot) }
        } catch { if captured == revision, !Task.isCancelled { self.error = error.localizedDescription } }
        if captured == revision { busy = false }
    }
    func invalidate() { revision += 1; busy = false }
    func edit(_ operation: (inout RasterSymbologyDraft) -> Void) {
        guard !busy, var value = draft else { return }
        operation(&value); value.interpolate(); draft = value; revision += 1
    }
    func setAdditional(_ id: String, value: String) {
        guard !busy, let index = additionalOptions.firstIndex(where: { $0.id == id && $0.isEnabled }) else { return }
        guard additionalOptions[index].value != value else { return }
        additionalOptions[index].value = value
        revision += 1
    }
    func choose(_ id: String, provider: (any RasterSymbologyProvider)?) async {
        guard !busy else { return }
        let previous = selectedPaletteID; let captured = revision
        selectedPaletteID = id
        guard let provider, let draft else { return }
        let succeeded = await run({ try await provider.selectPalette(id, draft: draft, context: $0) }, commit: { self.draft = $0 })
        if !succeeded, captured == revision { selectedPaletteID = previous }
    }
    func setSource(_ mode: RasterValueSource, provider: (any RasterSymbologyProvider)?) async {
        guard var value = draft, !busy else { return }
        if mode == .histogram {
            guard value.canComputeHistogram, let provider else { return }
            await run({ context in
                let values = try await provider.histogram(count: value.stops.count, forView: false, context: context)
                try self.assign(values, to: &value)
                value.valueSource = mode; return value
            }, commit: { self.draft = $0 })
        } else { edit { $0.valueSource = mode } }
    }
    func changeRows(at id: UUID, adding: Bool, provider: (any RasterSymbologyProvider)?) async {
        guard !busy, var value = draft, value.isEditing, let index = value.stops.firstIndex(where: { $0.id == id }) else { return }
        if adding { value.stops.insert(.init(color: value.stops[index].color, value: value.stops[index].value), at: index + 1) }
        else { guard value.stops.count > 1 else { return }; value.stops.remove(at: index) }
        if value.valueSource == .histogram {
            guard value.canComputeHistogram, let provider else { return }
            await run({ context in
                try self.assign(try await provider.histogram(count: value.stops.count, forView: false, context: context), to: &value)
                return value
            }, commit: { self.draft = $0 })
        } else { value.interpolate(); draft = value; revision += 1 }
    }
    func refreshHistogram(provider: (any RasterSymbologyProvider)?) async {
        guard var value = draft, value.canComputeHistogram, let provider else { return }
        await run({ context in
            try self.assign(try await provider.histogram(count: value.stops.count, forView: true, context: context), to: &value)
            return value
        }, commit: { self.draft = $0 })
    }
    func apply(provider: (any RasterSymbologyProvider)?) async -> Bool {
        guard let draft, let provider, !busy else { return false }
        return await run { try await provider.apply(draft, additionalOptions: additionalOptions, context: $0) }
    }
    func reset(provider: (any RasterSymbologyProvider)?) async {
        guard let provider else { return }
        await run({ try await provider.reset($0) }, commit: install)
    }
    func save(name: String, provider: (any RasterSymbologyProvider)?) async -> Bool {
        guard let draft, let provider else { return false }
        return await run({ try await provider.savePalette(draft, name: name, context: $0) }, commit: { self.palettes = $0 })
    }
    func delete(_ id: String, provider: (any RasterSymbologyProvider)?) async {
        guard let provider, palettes.contains(where: { $0.id == id && $0.isCustom }) else { return }
        await run({ try await provider.deletePalette(id, context: $0) }, commit: {
            self.palettes = $0
            if self.selectedPaletteID == id { self.selectedPaletteID = self.draft?.paletteID }
        })
    }
    var uniqueCustomName: String {
        var name = "Custom"; var number = 1
        while palettes.contains(where: { $0.name == name }) { name = "Custom \(number)"; number += 1 }
        return name
    }
    func nameIsValid(_ name: String) -> Bool { !name.isEmpty && name != "__" && !palettes.contains { !$0.isCustom && $0.name == name } }
    func overwritesCustom(_ name: String) -> Bool { palettes.contains { $0.isCustom && $0.name == name } }
    private func install(_ snapshot: RasterSymbologySnapshot) {
        draft = snapshot.draft; palettes = snapshot.palettes
        interpolatedSurfaceFillContext = snapshot.interpolatedSurfaceFillContext
        additionalOptions = snapshot.additionalOptions
        selectedPaletteID = snapshot.draft.paletteID
    }
    private func assign(_ values: [Double], to draft: inout RasterSymbologyDraft) throws {
        guard values.count == draft.stops.count, values.allSatisfy(\.isFinite) else { throw CocoaError(.coderInvalidValue) }
        for index in values.indices { draft.stops[index].value = values[index] }
    }
    @discardableResult
    private func run<Value>(_ operation: (RasterSymbologyContext) async throws -> Value, commit: (Value) -> Void = { _ in }) async -> Bool {
        guard !busy, let context else { return false }
        busy = true; error = nil; let captured = revision
        do {
            let result = try await operation(context)
            guard captured == revision, !Task.isCancelled else { return false }
            commit(result); busy = false; return true
        } catch {
            if captured == revision, !Task.isCancelled {
                self.error = error.localizedDescription; busy = false
            }
            return false
        }
    }
}
