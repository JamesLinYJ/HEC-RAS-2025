import Combine
import Foundation
import RASWorkspaceCore

struct AttributeTableRoute: Codable, Hashable {
    var id = UUID()
    var path = ""
    /// Stable source row selected by a map feature context action, such as
    /// "feature/12" for source record ordinal 12.
    var focusRowID: String? = nil
}
struct AttributeColumn: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let type: String
    var readOnly = false
    var numeric: Bool { ["Int32", "Single", "Double"].contains(type) }
    var typeTitle: String {
        switch type { case "Int32": "Integer"; case "Single", "Double": "Numeric"; default: type }
    }
}
struct AttributeRow: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var values: [String: String?]
    func value(_ column: String) -> String? { values[column] ?? nil }
}
struct AttributeTableData: Codable, Equatable, Sendable {
    let sourcePath: String
    let shapeType: String
    var columns: [AttributeColumn]
    var rows: [AttributeRow]
    var initValueTypesToDefault = false
    func validate() throws {
        let keys = Set(columns.map(\.id))
        guard keys.count == columns.count, Set(rows.map(\.id)).count == rows.count,
              columns.allSatisfy({ !$0.id.isEmpty && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              rows.allSatisfy({ !$0.id.isEmpty && Set($0.values.keys) == keys }) else {
            throw BackendServiceError(code: "protocolFailure", message: "Invalid attribute table identities.")
        }
    }
    func text(rows selected: [AttributeRow], delimiter: String) -> String {
        func quoted(_ value: String) -> String {
            value.contains(delimiter) || value.contains("\"") || value.contains(where: \.isNewline)
                ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
        }
        return ([columns.map { quoted($0.name) }.joined(separator: delimiter)] + selected.map { row in
            columns.map { quoted(row.value($0.id) ?? "") }.joined(separator: delimiter)
        }).joined(separator: "\r\n") + "\r\n"
    }
}
struct AttributeCellEdit: Codable, Equatable, Sendable {
    let rowId: String
    let columnId: String
    let value: String?
}
struct AttributeMutation: Codable, Sendable {
    let operation: String
    var columnId: String? = nil
    var name: String? = nil
    var type: String? = nil
    var cells: [AttributeCellEdit]? = nil
}
@MainActor protocol AttributeTableProvider {
    func load(_ url: URL) async throws -> AttributeTableData
    func transform(_ table: AttributeTableData, mutation: AttributeMutation) async throws -> AttributeTableData
}
@MainActor final class BackendAttributeTableProvider: AttributeTableProvider {
    private let client: BackendProcessClient
    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }
    func load(_ url: URL) async throws -> AttributeTableData {
        try await client.request("attributeTable.load", parameters: Load(path: url.path), as: AttributeTableData.self)
    }
    func transform(_ table: AttributeTableData, mutation: AttributeMutation) async throws -> AttributeTableData {
        try await client.request("attributeTable.transform", parameters: Transform(table: table, mutation: mutation), as: AttributeTableData.self)
    }
    private struct Load: Encodable, Sendable { let path: String }
    private struct Transform: Encodable, Sendable { let table: AttributeTableData; let mutation: AttributeMutation }
}
struct AttributeCellKey: Hashable { let row: String; let column: String }
@MainActor final class AttributeTableSession: ObservableObject, Identifiable {
    private struct PasteResult: Sendable {
        let data: AttributeTableData
        let failedCellCount: Int
    }

    let id = UUID()
    @Published private(set) var data: AttributeTableData?
    @Published private(set) var busy = false
    @Published var error: String?
    @Published private(set) var drafts: [AttributeCellKey: String?] = [:]
    @Published private(set) var exporting = false
    var isBusy: Bool { busy || exporting }
    @Published private(set) var exportedURL: URL?
    private var baseline: AttributeTableData?
    private var generation = UUID()
    private var work: Task<AttributeTableData, any Error>?
    private var pasteWork: Task<PasteResult, any Error>?
    private let provider: (any AttributeTableProvider)?
    init(provider: (any AttributeTableProvider)?) { self.provider = provider }
    var name: String { data.map { URL(filePath: $0.sourcePath).lastPathComponent } ?? L10n.text("Attribute Table") }
    var modified: Bool { data != baseline || !drafts.isEmpty }
    func nameIsValid(_ name: String, excluding id: String? = nil) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && data?.columns.contains { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame } != true
    }
    func load(_ url: URL) async {
        guard !exporting else { return }
        work?.cancel(); pasteWork?.cancel(); work = nil; pasteWork = nil
        let generation = UUID(); self.generation = generation; busy = true; error = nil
        defer { if self.generation == generation { busy = false; work = nil; pasteWork = nil } }
        guard let provider else { error = L10n.text("The attribute table service is unavailable."); return }
        let task = Task { try await provider.load(url) }; work = task
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try result.validate()
            guard self.generation == generation, !Task.isCancelled else { return }
            data = result; baseline = result; drafts = [:]; exportedURL = nil
        } catch { if self.generation == generation, !Task.isCancelled { self.error = L10n.text(error.localizedDescription) } }
    }
    func setDraft(row: String, column: String, value: String?) {
        guard !isBusy, let definition = data?.columns.first(where: { $0.id == column }), !definition.readOnly,
              let source = data?.rows.first(where: { $0.id == row }) else { return }
        let key = AttributeCellKey(row: row, column: column)
        if source.value(column) == value { drafts.removeValue(forKey: key) } else { drafts.updateValue(value, forKey: key) }
    }
    func value(row: AttributeRow, column: AttributeColumn) -> String? {
        if let draft = drafts[.init(row: row.id, column: column.id)] { return draft }
        return row.value(column.id)
    }
    func text(row: AttributeRow, column: AttributeColumn) -> String { value(row: row, column: column) ?? "" }
    func clearDraft(row: String, column: String) { guard !isBusy else { return }; drafts.removeValue(forKey: .init(row: row, column: column)) }
    @discardableResult func applyPaste(_ edits: [NativeDataGridPasteCell]) async -> Int? {
        guard !busy, !exporting, !edits.isEmpty else { return nil }
        guard await flushDrafts(), !busy, !exporting, let original = data, let provider else { return nil }
        let generation = self.generation
        busy = true
        error = nil
        defer {
            if self.generation == generation {
                busy = false
                work = nil
                pasteWork = nil
            }
        }

        let task = Task { () throws -> PasteResult in
            var working = original
            var failedCellCount = 0
            @MainActor func apply(_ batch: [NativeDataGridPasteCell]) async throws {
                try Task.checkCancellation()
                do {
                    let candidate = try await provider.transform(working, mutation: .init(
                        operation: "setCells",
                        cells: batch.map { .init(rowId: $0.rowID, columnId: $0.columnID, value: $0.value) }
                    ))
                    try candidate.validate()
                    guard candidate.sourcePath == original.sourcePath,
                          candidate.shapeType == original.shapeType,
                          candidate.rows.map(\.id) == original.rows.map(\.id) else {
                        throw BackendServiceError(code: "protocolFailure", message: "The attribute table response changed its source identity.")
                    }
                    working = candidate
                } catch is CancellationError {
                    throw CancellationError()
                } catch let serviceError as BackendServiceError where serviceError.code == "invalidInput" {
                    guard batch.count > 1 else {
                        failedCellCount += 1
                        return
                    }
                    let split = batch.count / 2
                    try await apply(Array(batch[..<split]))
                    try await apply(Array(batch[split...]))
                } catch {
                    throw error
                }
            }
            try await apply(edits)
            return PasteResult(data: working, failedCellCount: failedCellCount)
        }
        pasteWork = task
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard self.generation == generation, !Task.isCancelled else { return nil }
            data = result.data
            if result.failedCellCount > 0 {
                error = L10n.format("Failed to paste %d cells due to invalid format or type.", result.failedCellCount)
            }
            return result.failedCellCount
        } catch {
            if self.generation == generation, !Task.isCancelled { self.error = L10n.text(error.localizedDescription) }
            return nil
        }
    }
    @discardableResult func flushDrafts(allowExport: Bool = false) async -> Bool {
        guard !busy, !exporting || allowExport else { return false }
        guard !drafts.isEmpty else { return true }
        let edits = drafts.map { AttributeCellEdit(rowId: $0.key.row, columnId: $0.key.column, value: $0.value) }
        return await perform(.init(operation: "setCells", cells: edits), allowExport: allowExport)
    }
    @discardableResult func perform(_ mutation: AttributeMutation, allowExport: Bool = false) async -> Bool {
        guard !busy, !exporting || allowExport, let data, let provider else { return false }
        let generation = self.generation; busy = true; error = nil
        defer { if self.generation == generation { busy = false; work = nil } }
        let task = Task { try await provider.transform(data, mutation: mutation) }; work = task
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try result.validate()
            guard self.generation == generation, !Task.isCancelled else { return false }
            guard result.sourcePath == data.sourcePath, result.shapeType == data.shapeType, result.rows.map(\.id) == data.rows.map(\.id) else {
                throw BackendServiceError(code: "protocolFailure", message: "The attribute table response changed its source identity.")
            }
            self.data = result
            if mutation.operation == "setCells" {
                for cell in mutation.cells ?? [] {
                    let key = AttributeCellKey(row: cell.rowId, column: cell.columnId)
                    if let requested = drafts[key], requested == cell.value { drafts.removeValue(forKey: key) }
                }
            }
            let ids = Set(result.columns.map(\.id)); drafts = drafts.filter { ids.contains($0.key.column) }
            return true
        } catch {
            if self.generation == generation, !Task.isCancelled { self.error = L10n.text(error.localizedDescription) }
            return false
        }
    }
    @discardableResult func export(using system: any WorkspaceSystemServices) async -> Bool {
        guard !isBusy else { return false }
        exporting = true; defer { exporting = false }
        guard await flushDrafts(allowExport: true), let data else { return false }
        guard let destination = system.chooseExportDestination(name: URL(filePath: data.sourcePath).deletingPathExtension().lastPathComponent + ".csv", extensions: ["csv"], title: L10n.text("Export Attribute Table")) else { return false }
        do {
            guard destination.pathExtension.lowercased() == "csv", destination.standardizedFileURL.path != URL(filePath: data.sourcePath).standardizedFileURL.path else {
                throw BackendServiceError(code: "invalidInput", message: "Choose a CSV file for the exported table.")
            }
            try Data(data.text(rows: data.rows, delimiter: ",").utf8).write(to: destination, options: .atomic)
            baseline = data; exportedURL = destination; return true
        } catch { self.error = L10n.text(error.localizedDescription); return false }
    }
    func confirmClose(using system: any WorkspaceSystemServices) async -> Bool {
        guard !exporting else { return false }
        if busy { cancelCurrentWork() }
        guard modified else { return true }
        switch system.confirmAttributeTableClose(name: name) {
        case .cancel: return false
        case .export: return await export(using: system)
        case .discard: drafts = [:]; data = baseline; return true
        }
    }
    func cancelCurrentWork() { work?.cancel(); pasteWork?.cancel(); work = nil; pasteWork = nil; generation = UUID(); busy = false; error = nil }
    func invalidate() { cancelCurrentWork() }
}
