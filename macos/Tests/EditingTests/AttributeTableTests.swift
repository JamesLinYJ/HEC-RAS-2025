import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor private final class DeferredAttributeProvider: AttributeTableProvider {
    var loads: [(URL, CheckedContinuation<AttributeTableData, any Error>)] = []
    var edits: [(AttributeTableData, AttributeMutation, CheckedContinuation<AttributeTableData, any Error>)] = []
    func load(_ url: URL) async throws -> AttributeTableData { try await withCheckedThrowingContinuation { loads.append((url, $0)) } }
    func transform(_ table: AttributeTableData, mutation: AttributeMutation) async throws -> AttributeTableData {
        try await withCheckedThrowingContinuation { edits.append((table, mutation, $0)) }
    }
}
@MainActor private final class CancellableAttributeProvider: AttributeTableProvider {
    var started = 0
    var cancelled = 0
    func load(_ url: URL) async throws -> AttributeTableData {
        started += 1
        do { try await Task.sleep(for: .seconds(30)); throw BackendServiceError(code: "unexpected", message: "Expected cancellation") }
        catch { if error is CancellationError { cancelled += 1 }; throw error }
    }
    func transform(_ table: AttributeTableData, mutation: AttributeMutation) async throws -> AttributeTableData { throw CancellationError() }
}
@MainActor private final class AttributeFileServices: WorkspaceSystemServices {
    var exportURL: URL?
    var closeDecision = AttributeTableCloseDecision.cancel
    var duringExportChoice: (() -> Void)?
    func chooseProject() -> URL? { nil }
    func chooseProjectDestination(name: String) -> URL? { nil }
    func chooseExportDestination(name: String, extensions: [String], title: String) -> URL? { duringExportChoice?(); return exportURL }
    func chooseFolder(title: String) -> URL? { nil }
    func chooseVectorLayer() -> URL? { nil }
    func chooseConnectionFile() -> URL? { nil }
    func chooseInputFiles() -> [URL] { [] }
    func chooseImageFiles() -> [URL] { [] }
    func chooseProjectionFile() -> URL? { nil }
    func confirmAttributeTableClose(name: String) -> AttributeTableCloseDecision { closeDecision }
    func reveal(_ url: URL) {}
    func copy(_ text: String) {}
    func openWebsite(_ url: URL) {}
}
struct AttributeTableTests {
    private func table(_ path: String = "/source.shp") -> AttributeTableData {
        .init(sourcePath: path, shapeType: "Point", columns: [.init(id: "name", name: "原始名称", type: "String"), .init(id: "depth", name: "Depth", type: "Double")], rows: [.init(id: "feature/0", values: ["name": "中文\t样本", "depth": "2.5"]), .init(id: "feature/1", values: ["name": .some("quoted\"text\nline"), "depth": nil])])
    }
    @MainActor private func wait(_ test: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !test(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(test())
    }
    @Test func csvAndClipboardUseRawColumnNamesAndQuoteActualCells() throws {
        let source = table(); try source.validate()
        #expect(source.text(rows: source.rows, delimiter: "\t") == "原始名称\tDepth\r\n\"中文\t样本\"\t2.5\r\n\"quoted\"\"text\nline\"\t\r\n")
        #expect(source.rows[1].values.keys.contains("depth") && source.rows[1].value("depth") == nil)
        var invalid = source; invalid.rows.append(source.rows[0]); #expect(throws: (any Error).self) { try invalid.validate() }
        invalid = source; invalid.rows[0].values.removeValue(forKey: "depth"); #expect(throws: (any Error).self) { try invalid.validate() }
    }
    @Test @MainActor func sourceSortingDistinguishesNullAndUsesNumericValues() {
        let rows = [AttributeRow(id: "null", values: ["c": nil]), .init(id: "large", values: ["c": "12"]), .init(id: "small", values: ["c": "2"])]
        #expect(rows.sorted(using: AttributeTableSort(columnID: "c", numeric: true)).map(\.id) == ["null", "small", "large"])
        #expect(rows.sorted(using: AttributeTableSort(order: .reverse, columnID: "c", numeric: true)).map(\.id) == ["large", "small", "null"])
    }
    @Test @MainActor func newerLoadAndClosedWindowRejectOldSourceReplies() async throws {
        let provider = DeferredAttributeProvider(), session = AttributeTableSession(provider: provider)
        let a = Task { await session.load(URL(filePath: "/old.shp")) }; try await wait { provider.loads.count == 1 }
        let b = Task { await session.load(URL(filePath: "/new.shp")) }; try await wait { provider.loads.count == 2 }
        provider.loads[0].1.resume(returning: table("/old.shp")); await a.value; #expect(session.data == nil)
        provider.loads[1].1.resume(returning: table("/new.shp")); await b.value; #expect(session.data?.sourcePath == "/new.shp")
        session.setDraft(row: "feature/0", column: "depth", value: "3")
        let edit = Task { await session.flushDrafts() }; try await wait { provider.edits.count == 1 }
        session.invalidate(); provider.edits[0].2.resume(returning: table("/new.shp")); #expect(await edit.value == false)
        #expect(session.drafts[.init(row: "feature/0", column: "depth")] == "3")
    }
    @Test @MainActor func failedTypedEditRetainsDraftAndExportCancelCannotCloseIt() async throws {
        let provider = DeferredAttributeProvider(), session = AttributeTableSession(provider: provider), system = AttributeFileServices()
        let load = Task { await session.load(URL(filePath: "/source.shp")) }; try await wait { provider.loads.count == 1 }; provider.loads[0].1.resume(returning: table()); await load.value
        session.setDraft(row: "feature/0", column: "depth", value: "invalid")
        let flush = Task { await session.flushDrafts() }; try await wait { provider.edits.count == 1 }
        provider.edits[0].2.resume(throwing: BackendServiceError(code: "invalidInput", message: "A cell value is not valid for its column type.")); #expect(await flush.value == false)
        #expect(session.modified && session.error != nil && session.drafts.count == 1 && session.data?.rows[0].value("depth") == "2.5")
        #expect(await session.confirmClose(using: system) == false)
        session.clearDraft(row: "feature/0", column: "depth"); #expect(!session.modified)
        let mutation = Task { await session.perform(.init(operation: "renameColumn", columnId: "name", name: "更名")) }; try await wait { provider.edits.count == 2 }
        var changed = table(); changed.columns[0] = .init(id: "name", name: "更名", type: "String")
        provider.edits[1].2.resume(returning: changed); #expect(await mutation.value)
        system.closeDecision = .export
        #expect(await session.confirmClose(using: system) == false && session.modified)
        system.closeDecision = .discard; #expect(await session.confirmClose(using: system) && !session.modified)
    }
    @Test @MainActor func csvExportWritesActualWorkingTableAndAcknowledgesOnlySuccess() async throws {
        let provider = DeferredAttributeProvider(), session = AttributeTableSession(provider: provider), system = AttributeFileServices()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: directory) }
        let load = Task { await session.load(URL(filePath: "/source.shp")) }; try await wait { provider.loads.count == 1 }; provider.loads[0].1.resume(returning: table()); await load.value
        let edit = Task { await session.perform(.init(operation: "removeColumn", columnId: "depth")) }; try await wait { provider.edits.count == 1 }
        var changed = table(); changed.columns.removeLast(); for i in changed.rows.indices { changed.rows[i].values.removeValue(forKey: "depth") }
        provider.edits[0].2.resume(returning: changed); #expect(await edit.value && session.modified)
        system.exportURL = directory.appendingPathComponent("not-a-csv.shp")
        #expect(await session.export(using: system) == false && session.modified)
        system.exportURL = directory.appendingPathComponent("中文表.csv")
        #expect(await session.export(using: system) && !session.modified)
        #expect(try String(contentsOf: #require(system.exportURL), encoding: .utf8) == changed.text(rows: changed.rows, delimiter: ","))
    }
    @Test @MainActor func exportFlushesImmediateBooleanIntentAndFreezesEditsWhileChoosingFile() async throws {
        let provider = DeferredAttributeProvider(), session = AttributeTableSession(provider: provider), system = AttributeFileServices()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: directory) }
        var source = table(); let flag = AttributeColumn(id: "flag", name: "Active", type: "Boolean")
        source.columns.append(flag); for i in source.rows.indices { source.rows[i].values.updateValue(nil, forKey: flag.id) }
        let load = Task { await session.load(URL(filePath: "/source.shp")) }; try await wait { provider.loads.count == 1 }
        provider.loads[0].1.resume(returning: source); await load.value
        session.setDraft(row: "feature/0", column: flag.id, value: "True")
        system.exportURL = directory.appendingPathComponent("settled.csv")
        system.duringExportChoice = {
            #expect(session.exporting && session.isBusy)
            session.setDraft(row: "feature/0", column: "depth", value: "99")
        }
        let exporting = Task { await session.export(using: system) }; try await wait { provider.edits.count == 1 }
        #expect(provider.edits[0].1.cells?.first?.value == "True")
        var accepted = source; accepted.rows[0].values[flag.id] = "True"
        provider.edits[0].2.resume(returning: accepted)
        #expect(await exporting.value && session.data == accepted && !session.modified && !session.isBusy)
        #expect(try String(contentsOf: #require(system.exportURL), encoding: .utf8) == accepted.text(rows: accepted.rows, delimiter: ","))
        session.setDraft(row: "feature/0", column: flag.id, value: nil)
        #expect(session.drafts.keys.contains(.init(row: "feature/0", column: flag.id)) && session.value(row: accepted.rows[0], column: flag) == nil)
        let nulling = Task { await session.flushDrafts() }; try await wait { provider.edits.count == 2 }
        #expect(provider.edits[1].1.cells?.first?.value == nil)
        accepted.rows[0].values.updateValue(nil, forKey: flag.id)
        provider.edits[1].2.resume(returning: accepted)
        #expect(await nulling.value && session.drafts.isEmpty && session.modified)
    }
    @Test @MainActor func cancelAndClosingLoadingWindowsCancelTheActualProviderTask() async throws {
        let provider = CancellableAttributeProvider(), session = AttributeTableSession(provider: provider), system = AttributeFileServices()
        let first = Task { await session.load(URL(filePath: "/first.shp")) }; try await wait { provider.started == 1 }
        session.cancelCurrentWork(); await first.value
        #expect(provider.cancelled == 1 && !session.busy && session.error == nil && session.data == nil)
        let second = Task { await session.load(URL(filePath: "/second.shp")) }; try await wait { provider.started == 2 }
        #expect(await session.confirmClose(using: system))
        await second.value; #expect(provider.cancelled == 2 && !session.busy && session.error == nil)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_ATTRIBUTE_TABLE_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor func actualBundledShapefileReaderAndSourceColumnOperations() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = try #require(ProcessInfo.processInfo.environment["HECRAS_ATTRIBUTE_TABLE_ACCEPTANCE_DIRECTORY"])
        let provider = BackendAttributeTableProvider(client: .init(executableURL: URL(filePath: executable))), path = URL(filePath: fixture).appendingPathComponent("属性.shp")
        let loaded = try await provider.load(path); try loaded.validate()
        #expect(loaded.rows.count == 3 && loaded.shapeType == "Point")
        let renamed = try await provider.transform(loaded, mutation: .init(operation: "renameColumn", columnId: loaded.columns[0].id, name: "中文列名"))
        #expect(renamed.columns[0].name == "中文列名" && renamed.columns[0].id == loaded.columns[0].id)
        let fresh = try await provider.load(path); #expect(fresh == loaded)
        let session = AttributeTableSession(provider: provider), system = AttributeFileServices()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: output) }
        await session.load(path)
        let logical = try #require(loaded.columns.first { $0.type == "Boolean" })
        session.setDraft(row: loaded.rows[2].id, column: logical.id, value: "True")
        system.exportURL = output.appendingPathComponent("actual-source.csv")
        #expect(await session.export(using: system) && !session.modified)
        #expect(try String(contentsOf: #require(system.exportURL), encoding: .utf8).contains("空值,,,True\r\n"))
        #expect(try await provider.load(path) == loaded)
    }
}
