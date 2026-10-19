import Combine
import Foundation
import RASWorkspaceCore

struct TableFilterColumnInput: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let sourceType: String
    let filterable: Bool
}

struct TableFilterRowInput: Codable, Equatable, Sendable {
    let id: String
    let values: [String: String]
}

struct TableFilterCapture: Equatable, Sendable {
    let owner: String
    let columns: [TableFilterColumnInput]
    let rows: [TableFilterRowInput]
}

struct TableFilterEvaluation: Codable, Sendable {
    let valid: Bool
    let rowIds: [String]
    let error: String?
    let clearActiveFilter: Bool
}

@MainActor
protocol TableExpressionFilterProvider {
    func evaluate(_ expression: String, capture: TableFilterCapture) async throws -> TableFilterEvaluation
}

@MainActor
struct BackendTableExpressionFilterProvider: TableExpressionFilterProvider {
    let client: BackendProcessClient

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func evaluate(_ expression: String, capture: TableFilterCapture) async throws -> TableFilterEvaluation {
        struct Request: Encodable, Sendable {
            let expression: String
            let columns: [TableFilterColumnInput]
            let rows: [TableFilterRowInput]
        }
        return try await client.request("table.filter", parameters: Request(expression: expression,
            columns: capture.columns, rows: capture.rows), as: TableFilterEvaluation.self)
    }
}

/// Filtering changes the row view only. Identity includes the owner, columns
/// and draft cells, so an old reply cannot filter a new model or newer edits.
@MainActor
final class TableExpressionFilterSession: ObservableObject {
    @Published var draft = ""
    @Published private(set) var appliedExpression = ""
    @Published private(set) var matchingRowIDs: Set<String>?
    @Published private(set) var error: String?
    @Published private(set) var isBusy = false
    private let provider: any TableExpressionFilterProvider
    private var capture: TableFilterCapture?
    private var revision = 0

    init(provider: any TableExpressionFilterProvider = BackendTableExpressionFilterProvider()) {
        self.provider = provider
    }

    func refresh(_ input: TableFilterCapture) async {
        guard !Task.isCancelled else { return }
        if let capture, capture.owner != input.owner { clear() }
        capture = input
        guard !appliedExpression.isEmpty else {
            revision += 1; matchingRowIDs = nil; isBusy = false
            return
        }
        await evaluate(appliedExpression, input: input, refreshing: true)
    }

    func apply(_ input: TableFilterCapture) async {
        // A queued submit from a disappearing page must not become the owner
        // again after the replacement page has already refreshed this session.
        guard !Task.isCancelled, capture == input else { return }
        let expression = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty else { clear(); capture = input; return }
        await evaluate(expression, input: input, refreshing: false)
    }

    func clear() {
        revision += 1; draft = ""; appliedExpression = ""
        matchingRowIDs = nil; error = nil; isBusy = false
    }

    private func evaluate(_ expression: String, input: TableFilterCapture, refreshing: Bool) async {
        revision += 1
        let requestRevision = revision
        isBusy = true; error = nil
        defer { if revision == requestRevision { isBusy = false } }
        do {
            let result = try await provider.evaluate(expression, capture: input)
            guard !Task.isCancelled, revision == requestRevision, capture == input else { return }
            guard result.valid else {
                error = result.error ?? "The filter expression is invalid."
                if result.clearActiveFilter {
                    matchingRowIDs = nil; appliedExpression = ""
                }
                return
            }
            let identities = Set(result.rowIds)
            guard identities.count == result.rowIds.count,
                  identities.isSubset(of: Set(input.rows.map(\.id))) else {
                throw BackendServiceError(code: "protocolFailure", message: "The filter returned rows outside the captured table.")
            }
            matchingRowIDs = identities
            // A refresh uses the already accepted expression; it never consumes
            // or overwrites an unsubmitted text draft.
            if !refreshing { appliedExpression = expression }
        } catch {
            guard !Task.isCancelled, revision == requestRevision, capture == input else { return }
            self.error = error.localizedDescription
        }
    }
}
