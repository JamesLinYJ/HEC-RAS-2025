import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct TableExpressionFilterTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil))
    @MainActor
    func bundledSourceParserFiltersActualCapturedDraftValuesAndKeepsIDs() async throws {
        let executable = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"]))
        let provider = BackendTableExpressionFilterProvider(client: BackendProcessClient(executableURL: executable))
        let input = capture(rows: [row("reach", name: "Reach A", length: "1200"),
            row("small", name: "Reach B", length: "80"), row("other", name: "渠段一", length: "2500")])
        let result = try await provider.evaluate("Length > 1000 AND (Name LIKE 'reach%' OR Name = '渠段一')", capture: input)
        #expect(result.valid && result.rowIds == ["reach", "other"])
        let invalid = try await provider.evaluate("Length > AND Name", capture: input)
        #expect(!invalid.valid && !invalid.clearActiveFilter && invalid.error != nil)
        let absent = try await provider.evaluate("Missing = 10", capture: input)
        #expect(!absent.valid && absent.clearActiveFilter)
        let cleared = try await provider.evaluate("", capture: input)
        #expect(cleared.valid && cleared.rowIds == ["reach", "small", "other"])
    }

    @Test @MainActor
    func lateFilterCannotInstallAfterOwnerOrDraftRowsChange() async throws {
        let provider = DeferredTableFilterProvider()
        let session = TableExpressionFilterSession(provider: provider)
        let original = capture(rows: [row("a", name: "Reach A", length: "1200")])
        await session.refresh(original)
        session.draft = "Length > 1000"
        let old = Task { await session.apply(original) }
        await waitForRequest(provider, count: 1)
        let replacement = capture(owner: "new-model", rows: [row("b", name: "Reach B", length: "20")])
        await session.refresh(replacement)
        provider.finish(0, result: .init(valid: true, rowIds: ["a"], error: nil, clearActiveFilter: false))
        await old.value
        #expect(session.appliedExpression.isEmpty && session.matchingRowIDs == nil && !session.isBusy)
        session.draft = "Length > 0"
        await session.apply(original)
        #expect(provider.expressions.count == 1 && session.matchingRowIDs == nil)

        session.draft = "Length > 10"
        let pending = Task { await session.apply(replacement) }
        await waitForRequest(provider, count: 2)
        let edited = capture(owner: "new-model", rows: [row("b", name: "Reach B", length: "0")])
        await session.refresh(edited)
        provider.finish(1, result: .init(valid: true, rowIds: ["b"], error: nil, clearActiveFilter: false))
        await pending.value
        #expect(session.matchingRowIDs == nil && session.appliedExpression.isEmpty)
    }

    @Test @MainActor
    func invalidSyntaxKeepsAcceptedFilterAndRefreshDoesNotConsumeNewText() async throws {
        let provider = DeferredTableFilterProvider()
        let session = TableExpressionFilterSession(provider: provider)
        let original = capture(rows: [row("a", name: "A", length: "1200"), row("b", name: "B", length: "20")])
        await session.refresh(original)
        session.draft = "Length > 1000"
        let accepted = Task { await session.apply(original) }
        await waitForRequest(provider, count: 1)
        provider.finish(0, result: .init(valid: true, rowIds: ["a"], error: nil, clearActiveFilter: false))
        await accepted.value
        session.draft = "Length > AND"
        let invalid = Task { await session.apply(original) }
        await waitForRequest(provider, count: 2)
        provider.finish(1, result: .init(valid: false, rowIds: [], error: "syntax", clearActiveFilter: false))
        await invalid.value
        #expect(session.appliedExpression == "Length > 1000" && session.matchingRowIDs == ["a"])
        #expect(session.draft == "Length > AND" && session.error == "syntax")
        let edited = capture(rows: [row("a", name: "A", length: "0"), row("b", name: "B", length: "2000")])
        let refresh = Task { await session.refresh(edited) }
        await waitForRequest(provider, count: 3)
        #expect(provider.expressions[2] == "Length > 1000")
        provider.finish(2, result: .init(valid: true, rowIds: ["b"], error: nil, clearActiveFilter: false))
        await refresh.value
        #expect(session.matchingRowIDs == ["b"] && session.draft == "Length > AND")
        let missing = Task { await session.apply(edited) }
        await waitForRequest(provider, count: 4)
        provider.finish(3, result: .init(valid: false, rowIds: [], error: "removed column", clearActiveFilter: true))
        await missing.value
        #expect(session.matchingRowIDs == nil && session.appliedExpression.isEmpty && session.error == "removed column")
    }

    @Test @MainActor
    func forgedOrDuplicateReplyRowsAreRejectedAndClearInvalidatesPendingReply() async {
        let provider = DeferredTableFilterProvider()
        let session = TableExpressionFilterSession(provider: provider)
        let input = capture(rows: [row("a", name: "A", length: "12")])
        await session.refresh(input)
        session.draft = "Length > 0"
        let forged = Task { await session.apply(input) }
        await waitForRequest(provider, count: 1)
        provider.finish(0, result: .init(valid: true, rowIds: ["foreign"], error: nil, clearActiveFilter: false))
        await forged.value
        #expect(session.error != nil && session.matchingRowIDs == nil)
        let duplicate = Task { await session.apply(input) }
        await waitForRequest(provider, count: 2)
        provider.finish(1, result: .init(valid: true, rowIds: ["a", "a"], error: nil, clearActiveFilter: false))
        await duplicate.value
        #expect(session.error != nil && session.matchingRowIDs == nil)
        let pending = Task { await session.apply(input) }
        await waitForRequest(provider, count: 3)
        session.clear()
        provider.finish(2, result: .init(valid: true, rowIds: ["a"], error: nil, clearActiveFilter: false))
        await pending.value
        #expect(session.error == nil && session.matchingRowIDs == nil && session.draft.isEmpty && !session.isBusy)
    }

    private func row(_ id: String, name: String, length: String) -> TableFilterRowInput {
        .init(id: id, values: ["name": name, "length": length])
    }
    private func capture(owner: String = "editor", rows: [TableFilterRowInput]) -> TableFilterCapture {
        .init(owner: owner, columns: [.init(id: "name", name: "Name", sourceType: "string", filterable: true),
            .init(id: "length", name: "Length", sourceType: "double", filterable: true)], rows: rows)
    }
    @MainActor private func waitForRequest(_ provider: DeferredTableFilterProvider, count: Int) async {
        while provider.expressions.count < count { await Task.yield() }
    }
}

@MainActor
private final class DeferredTableFilterProvider: TableExpressionFilterProvider {
    private(set) var expressions: [String] = []
    private var continuations: [Int: CheckedContinuation<TableFilterEvaluation, any Error>] = [:]
    func evaluate(_ expression: String, capture: TableFilterCapture) async throws -> TableFilterEvaluation {
        let index = expressions.count
        expressions.append(expression)
        return try await withCheckedThrowingContinuation { continuations[index] = $0 }
    }
    func finish(_ index: Int, result: TableFilterEvaluation) {
        continuations.removeValue(forKey: index)?.resume(returning: result)
    }
}
