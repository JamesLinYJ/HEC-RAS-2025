import SwiftUI

struct TableExpressionFilterBar: View {
    @ObservedObject var session: TableExpressionFilterSession
    let capture: TableFilterCapture
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Length > 1000 AND Name LIKE 'Reach%'", text: $session.draft)
                    .textFieldStyle(.roundedBorder).focused($focused).onSubmit { apply() }
                    .accessibilityLabel(Text("Filter Expression"))
                Button("Apply Filter") { apply() }.disabled(session.isBusy)
                Button("Clear Filter", systemImage: "line.3.horizontal.decrease.circle") { session.clear() }
                if session.isBusy { ProgressView().controlSize(.small) }
            }
            if let error = session.error {
                HStack(alignment: .top) {
                    Label("Filter could not be applied", systemImage: "exclamationmark.triangle")
                    Text(verbatim: error).textSelection(.enabled)
                }.foregroundStyle(.secondary)
            } else if !session.appliedExpression.isEmpty {
                HStack {
                    Text(verbatim: session.appliedExpression).textSelection(.enabled)
                    Spacer()
                    Text(L10n.format("%d of %d rows", matchedCount, capture.rows.count))
                }.foregroundStyle(.secondary)
            }
        }.font(.caption).padding(.horizontal, 12).padding(.bottom, 8)
            .task(id: capture) { await session.refresh(capture) }
            .onChange(of: focused) { _, value in if !value { apply() } }
    }

    private var matchedCount: Int {
        guard let matching = session.matchingRowIDs else { return capture.rows.count }
        return capture.rows.filter { matching.contains($0.id) }.count
    }
    private func apply() {
        let input = capture
        Task { await session.apply(input) }
    }
}
