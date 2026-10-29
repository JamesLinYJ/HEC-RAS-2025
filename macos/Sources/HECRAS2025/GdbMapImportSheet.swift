import SwiftUI

@MainActor
struct GdbMapImportPresentation: ViewModifier {
    @ObservedObject var store: WorkspaceStore
    let mapID: UUID
    @State private var presentedSession: GdbMapImportSession?

    func body(content: Content) -> some View {
        content
            .sheet(item: $presentedSession) { session in
                GdbMapImportSheet(store: store, session: session)
            }
            .onChange(of: store.pendingGdbMapImport?.id, initial: true) { _, _ in reconcile() }
            .onChange(of: store.projectSessionID) { _, _ in reconcile() }
            .onChange(of: store.mapWorkflowIdentity(mapID)) { _, _ in reconcile() }
    }

    private func reconcile() {
        let candidate = store.pendingGdbMapImport
        let next: GdbMapImportSession? = candidate.flatMap { session in
            session.mapID == mapID && session.isCurrent(in: store) ? session : nil
        }
        if presentedSession?.id != next?.id { presentedSession = next }
    }
}

@MainActor
struct GdbMapImportSheet: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var session: GdbMapImportSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("Import File Geodatabase"))
                .font(.title2.weight(.semibold))
            Text(verbatim: session.sourceURL.path)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Table(session.catalog) {
                TableColumn(L10n.text("Name")) { item in
                    Label {
                        Text(verbatim: item.name)
                    } icon: {
                        Image(systemName: item.kind == "Raster" ? "square.grid.3x3" : "point.3.connected.trianglepath.dotted")
                    }
                }
                TableColumn(L10n.text("Type")) { item in
                    Text(L10n.text(item.kind))
                }
                .width(min: 70, ideal: 90, max: 120)
                TableColumn(L10n.text("Details")) { item in
                    Text(verbatim: item.detail)
                        .foregroundStyle(.secondary)
                }
                TableColumn(L10n.text("Status")) { item in
                    Image(systemName: item.canImport ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(item.canImport ? Color.secondary : Color.orange)
                        .accessibilityLabel(L10n.text(item.canImport ? "Ready to import" : "Unavailable"))
                        .help(L10n.text(item.unsupportedReason ?? "Ready to import"))
                }
                .width(55)
            }
            .tableStyle(.inset)
            .overlay {
                if session.catalog.isEmpty && !session.isBusy {
                    ContentUnavailableView(L10n.text("No supported layers are available."),
                        systemImage: "square.stack.3d.up.slash")
                }
            }
            .frame(minHeight: 240)

            if let error = session.errorMessage {
                ScrollView {
                    Text(L10n.text(error))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 80)
                .accessibilityLabel(L10n.text("Import error"))
            }

            HStack(spacing: 12) {
                if session.isBusy { ProgressView().controlSize(.small) }
                Text(L10n.text("All available layers will be added to the current map."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("Cancel"), role: .cancel) {
                    session.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(session.isImporting)
                Button(L10n.text("Import Available Layers")) {
                    Task {
                        if await session.importSelected() { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(session.isBusy || !session.canImport || !session.isCurrent(in: store))
            }
        }
        .padding(24)
        .frame(minWidth: 680, idealWidth: 780, minHeight: 420, idealHeight: 500)
        .interactiveDismissDisabled(session.isImporting)
        .task { await session.loadCatalog() }
        .onChange(of: store.projectSessionID) { _, _ in
            if !session.isCurrent(in: store) { session.cancel(); dismiss() }
        }
        .onDisappear { session.cancel() }
    }
}
