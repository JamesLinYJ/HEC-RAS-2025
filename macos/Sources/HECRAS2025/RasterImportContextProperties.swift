import CryptoKit
import Foundation
import RASWorkspaceCore
import SwiftUI

struct RasterImportContextPropertiesRequest: Encodable, Sendable {
    let filePaths: [String]
    let compareProjectionWKT: String?
}

struct RasterImportContextInfo: Decodable, Equatable, Sendable {
    var fileName: String?
    var directory: String?
    var rasterProjection: String?
    var projectionFriendlyText: String?
    let overviewsCount: Double?
    let overviews: [String]?
    var cellSize: String?
    var size: String?
    var uncompressedSize: String?
    var compressionRatio: String?
    var driver: String?
    var bandCount: Int?
    var unitSystem: String?

    mutating func set(_ field: RasterImportContextPropertyField, to value: String) -> Bool {
        switch field {
        case .fileName: fileName = value
        case .directory: directory = value
        case .rasterProjection: rasterProjection = value
        case .projectionFriendlyText: projectionFriendlyText = value
        case .cellSize: cellSize = value
        case .size: size = value
        case .uncompressedSize: uncompressedSize = value
        case .compressionRatio: compressionRatio = value
        case .driver: driver = value
        case .unitSystem: unitSystem = value
        case .bandCount:
            guard let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
            bandCount = parsed
        case .min, .max, .mean, .standardDeviation:
            return false
        }
        return true
    }

    func value(for field: RasterImportContextPropertyField) -> String? {
        switch field {
        case .fileName: fileName
        case .directory: directory
        case .rasterProjection: rasterProjection
        case .projectionFriendlyText: projectionFriendlyText
        case .cellSize: cellSize
        case .size: size
        case .uncompressedSize: uncompressedSize
        case .compressionRatio: compressionRatio
        case .driver: driver
        case .unitSystem: unitSystem
        case .bandCount: bandCount.map(String.init)
        case .min, .max, .mean, .standardDeviation: nil
        }
    }
}

struct RasterImportContextStats: Decodable, Equatable, Sendable {
    var min: String
    var max: String
    var mean: String
    var standardDeviation: String

    mutating func set(_ field: RasterImportContextPropertyField, to value: String) -> Bool {
        guard let number = Self.parseNumber(value) else { return false }
        let formatted = Self.formatNumber(number)
        switch field {
        case .min: min = formatted
        case .max: max = formatted
        case .mean: mean = formatted
        case .standardDeviation: standardDeviation = formatted
        default: return false
        }
        return true
    }

    func value(for field: RasterImportContextPropertyField) -> String? {
        switch field {
        case .min: min
        case .max: max
        case .mean: mean
        case .standardDeviation: standardDeviation
        default: nil
        }
    }

    private static func parseNumber(_ source: String) -> Double? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if let invariant = Double(trimmed) { return invariant }
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        return formatter.number(from: trimmed)?.doubleValue
    }

    private static func formatNumber(_ value: Double) -> String {
        guard value.isFinite else { return value.description }
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 15
        return formatter.string(from: NSNumber(value: value)) ?? value.description
    }
}

struct RasterImportContextSource: Decodable, Equatable, Identifiable, Sendable {
    let path: String
    let revision: String
    var info: RasterImportContextInfo?
    var stats: RasterImportContextStats?
    let error: String?

    var id: String { Self.identity(path: path, revision: revision) }

    static func identity(path: String, revision: String) -> String {
        let canonical = SourceFilePaths.canonical(URL(fileURLWithPath: path))
        return "\(canonical.utf8.count):\(canonical)|\(revision.lowercased())"
    }
}

struct RasterImportContextPropertiesSnapshot: Decodable, Sendable {
    let sources: [RasterImportContextSource]
}

enum RasterImportContextPropertyGroup: String, CaseIterable, Identifiable, Sendable {
    case summary
    case file
    case statistics

    var id: String { rawValue }
    var title: String {
        switch self {
        case .summary: "Raster Summary Properties"
        case .file: "Raster File Properties"
        case .statistics: "Raster Statistics"
        }
    }

    var fields: [RasterImportContextPropertyField] {
        switch self {
        case .summary: [.fileName, .projectionFriendlyText, .rasterProjection, .cellSize]
        case .file: [.fileName, .directory, .cellSize, .unitSystem, .size,
                     .uncompressedSize, .compressionRatio, .driver, .bandCount]
        case .statistics: [.min, .max, .mean, .standardDeviation]
        }
    }
}

enum RasterImportContextPropertyField: String, Identifiable, Sendable {
    case fileName, directory, rasterProjection, projectionFriendlyText, cellSize
    case size, uncompressedSize, compressionRatio, driver, bandCount, unitSystem
    case min, max, mean, standardDeviation

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fileName: "File Name"
        case .directory: "Directory"
        case .rasterProjection: "Raster Projection"
        case .projectionFriendlyText: "Projection"
        case .cellSize: "Cell Size"
        case .size: "Size on Disk"
        case .uncompressedSize: "Uncompressed Size"
        case .compressionRatio: "Compression Ratio"
        case .driver: "Driver"
        case .bandCount: "Band Count"
        case .unitSystem: "Unit System"
        case .min: "Minimum"
        case .max: "Maximum"
        case .mean: "Mean"
        case .standardDeviation: "Standard Deviation"
        }
    }
}

enum RasterImportContextAggregate: Equatable, Sendable {
    case unavailable
    case mixed
    case value(String)
}

@MainActor
protocol RasterImportContextPropertiesProvider {
    func inspect(filePaths: [String], compareProjectionWKT: String?) async throws
        -> RasterImportContextPropertiesSnapshot
}

@MainActor
final class BackendRasterImportContextPropertiesProvider: RasterImportContextPropertiesProvider {
    private let client: BackendProcessClient
    private let isCurrent: @MainActor () -> Bool

    init(client: BackendProcessClient? = nil,
         isCurrent: @escaping @MainActor () -> Bool = { true }) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
        self.isCurrent = isCurrent
    }

    func inspect(filePaths: [String], compareProjectionWKT: String?) async throws
        -> RasterImportContextPropertiesSnapshot {
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        let request = RasterImportContextPropertiesRequest(filePaths: filePaths,
            compareProjectionWKT: compareProjectionWKT)
        let snapshot: RasterImportContextPropertiesSnapshot = try await client.request(
            "raster.import.context.inspect", parameters: request,
            as: RasterImportContextPropertiesSnapshot.self)
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        guard snapshot.sources.count == filePaths.count,
              zip(snapshot.sources, filePaths).allSatisfy({ pair in
                  SourceFilePaths.canonical(URL(fileURLWithPath: pair.0.path))
                    == SourceFilePaths.canonical(URL(fileURLWithPath: pair.1))
              }),
              Set(snapshot.sources.map(\.id)).count == snapshot.sources.count,
              snapshot.sources.allSatisfy(Self.validSource) else {
            throw RasterImportContextPropertiesError.mismatchedReply
        }
        for source in snapshot.sources {
            let currentRevision = try await Self.sourceRevision(at: URL(fileURLWithPath: source.path))
            guard currentRevision.caseInsensitiveCompare(source.revision) == .orderedSame else {
                throw RasterImportContextPropertiesError.sourceChanged
            }
        }
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        return snapshot
    }

    private static func validSource(_ source: RasterImportContextSource) -> Bool {
        if source.revision == "missing" {
            return source.error != nil && source.info == nil && source.stats == nil
        }
        guard source.revision.count == 64, source.revision.allSatisfy(\.isHexDigit) else { return false }
        if source.error == nil {
            return source.info != nil && source.stats != nil
        }
        return true
    }

    private static func sourceRevision(at url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: url.path) else { return "missing" }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
        }.value
    }
}

@MainActor
final class RasterImportContextPropertiesSession: ObservableObject {
    @Published private(set) var sources: [RasterImportContextSource] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let provider: any RasterImportContextPropertiesProvider
    private var generation: UInt64 = 0
    private var cachedSources: [String: RasterImportContextSource] = [:]
    private var comparisonProjectionIdentity = ""

    init(provider: any RasterImportContextPropertiesProvider = BackendRasterImportContextPropertiesProvider()) {
        self.provider = provider
    }

    func select(filePaths: [String], compareProjectionWKT: String? = nil) async {
        generation &+= 1
        let requestGeneration = generation
        guard !filePaths.isEmpty else {
            sources = []
            errorMessage = nil
            isLoading = false
            return
        }
        guard filePaths.count <= 256, filePaths.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            sources = []
            errorMessage = L10n.text("Choose between one and 256 raster files.")
            isLoading = false
            return
        }
        guard Set(filePaths.map { SourceFilePaths.canonical(URL(fileURLWithPath: $0)) }).count == filePaths.count else {
            sources = []
            errorMessage = L10n.text("The selected raster files contain duplicate paths.")
            isLoading = false
            return
        }

        sources = []
        isLoading = true
        errorMessage = nil
        comparisonProjectionIdentity = compareProjectionWKT.map {
            SHA256.hash(data: Data($0.utf8)).map { String(format: "%02X", $0) }.joined()
        } ?? ""
        do {
            let snapshot = try await provider.inspect(filePaths: filePaths,
                compareProjectionWKT: compareProjectionWKT)
            guard generation == requestGeneration, !Task.isCancelled else { return }
            sources = snapshot.sources.map { source in
                let key = cacheKey(for: source)
                if let previous = cachedSources[key] { return previous }
                cachedSources[key] = source
                return source
            }
            isLoading = false
        } catch is CancellationError {
            guard generation == requestGeneration else { return }
            isLoading = false
        } catch {
            guard generation == requestGeneration else { return }
            sources = []
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    func cancel() {
        generation &+= 1
        isLoading = false
    }

    func aggregate(_ group: RasterImportContextPropertyGroup,
                   field: RasterImportContextPropertyField) -> RasterImportContextAggregate {
        guard !sources.isEmpty else { return .unavailable }
        let values = sources.compactMap { source -> String? in
            switch group {
            case .summary, .file: source.info?.value(for: field)
            case .statistics: source.stats?.value(for: field)
            }
        }
        guard values.count == sources.count, let first = values.first else { return .unavailable }
        return values.allSatisfy { $0 == first } ? .value(first) : .mixed
    }

    @discardableResult
    func forceSet(_ group: RasterImportContextPropertyGroup,
                  field: RasterImportContextPropertyField,
                  value: String) -> Bool {
        guard !sources.isEmpty else { return false }
        var updates: [RasterImportContextSource] = []
        for var source in sources {
            switch group {
            case .summary, .file:
                guard var info = source.info, info.set(field, to: value) else { return false }
                source.info = info
            case .statistics:
                guard var stats = source.stats, stats.set(field, to: value) else { return false }
                source.stats = stats
            }
            updates.append(source)
        }
        sources = updates
        for source in updates { cachedSources[cacheKey(for: source)] = source }
        return true
    }

    func close() {
        generation &+= 1
        sources = []
        cachedSources.removeAll(keepingCapacity: false)
        comparisonProjectionIdentity = ""
        isLoading = false
        errorMessage = nil
    }

    private func cacheKey(for source: RasterImportContextSource) -> String {
        "\(source.id.utf8.count):\(source.id)|\(comparisonProjectionIdentity)"
    }
}

struct RasterImportContextPropertiesView: View {
    @ObservedObject var session: RasterImportContextPropertiesSession
    let filePaths: [String]
    let compareProjectionWKT: String?
    @State private var inputValues: [String: String] = [:]

    private var loadIdentity: String {
        (filePaths.map { SourceFilePaths.canonical(URL(fileURLWithPath: $0)) } +
            [compareProjectionWKT ?? ""]).map { "\($0.utf8.count):\($0)" }.joined()
    }

    var body: some View {
        Group {
            if session.isLoading {
                ProgressView().controlSize(.small)
            } else if let error = session.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else if session.sources.isEmpty {
                Text(L10n.text("Select raster files to inspect their properties."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(RasterImportContextPropertyGroup.allCases) { group in
                    DisclosureGroup(L10n.text(group.title)) {
                        ForEach(group.fields) { field in
                            propertyRow(group, field: field)
                        }
                        if group == .file {
                            ForEach(session.sources) { source in
                                if let count = source.info?.overviewsCount,
                                   let overviews = source.info?.overviews {
                                    DisclosureGroup(source.info?.fileName ?? source.path) {
                                        LabeledContent(L10n.text("Overviews"), value: "\(Int(count))")
                                        ForEach(Array(overviews.enumerated()), id: \.offset) { _, overview in
                                            LabeledContent("", value: overview)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                ForEach(session.sources.filter { $0.error != nil }) { source in
                    Label(source.error ?? "", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: loadIdentity) {
            inputValues.removeAll(keepingCapacity: false)
            await session.select(filePaths: filePaths, compareProjectionWKT: compareProjectionWKT)
        }
    }

    @ViewBuilder
    private func propertyRow(_ group: RasterImportContextPropertyGroup,
                            field: RasterImportContextPropertyField) -> some View {
        let aggregate = session.aggregate(group, field: field)
        HStack(alignment: .center) {
            Text(L10n.text(field.title))
            Spacer(minLength: 10)
            switch aggregate {
            case .value:
                TextField("", text: binding(group, field: field, aggregate: aggregate))
                    .textSelection(.enabled).lineLimit(2).frame(maxWidth: 280)
            case .mixed:
                TextField(L10n.text("Multiple values"), text: binding(group, field: field, aggregate: aggregate))
                    .frame(maxWidth: 280)
            case .unavailable:
                Text("—").foregroundStyle(.secondary)
            }
            if aggregate != .unavailable {
                Button(L10n.text("Force Set")) {
                    let value = inputValues[key(group, field)] ?? ""
                    if session.forceSet(group, field: field, value: value) {
                        inputValues[key(group, field)] = value
                    }
                }
                .disabled(!canForceSet(field, value: inputValues[key(group, field)] ?? "") ||
                    (ifUniformValue(aggregate, matches: inputValues[key(group, field)] ?? "")))
            }
        }
    }

    private func binding(_ group: RasterImportContextPropertyGroup,
                         field: RasterImportContextPropertyField,
                         aggregate: RasterImportContextAggregate) -> Binding<String> {
        Binding(get: {
            if let value = inputValues[key(group, field)] { return value }
            if case .value(let value) = aggregate { return value }
            return ""
        }, set: { inputValues[key(group, field)] = $0 })
    }

    private func ifUniformValue(_ aggregate: RasterImportContextAggregate, matches value: String) -> Bool {
        if case .value(let current) = aggregate { return current == value }
        return false
    }

    private func key(_ group: RasterImportContextPropertyGroup,
                     _ field: RasterImportContextPropertyField) -> String { "\(group.rawValue)|\(field.rawValue)" }

    private func canForceSet(_ field: RasterImportContextPropertyField, value: String) -> Bool {
        switch field {
        case .min, .max, .mean, .standardDeviation:
            return Double(value) != nil || NumberFormatter().number(from: value) != nil
        case .bandCount:
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        default:
            return true
        }
    }
}

enum RasterImportContextPropertiesError: Error, LocalizedError {
    case mismatchedReply
    case sourceChanged

    var errorDescription: String? {
        switch self {
        case .mismatchedReply: "The raster property reply does not match the selected source files."
        case .sourceChanged: "A selected raster file changed while its properties were loading. Refresh the properties."
        }
    }
}
