import SwiftUI

enum GeometryTopologyMetadataColumnKind: String, CaseIterable, Sendable {
    case arc
    case region

    init?(tableID: String) {
        switch tableID {
        case "Arcs": self = .arc
        case "Regions": self = .region
        default: return nil
        }
    }

    var featureKind: String { rawValue }
}

enum GeometryTopologyMetadataColumnOperation: String, Equatable, Sendable {
    case add = "addMetadataColumn"
    case rename = "renameMetadataColumn"
    case delete = "deleteMetadataColumn"
}

enum GeometryTopologyMetadataColumnType: String, CaseIterable, Identifiable, Hashable, Sendable {
    case string = "String"
    case integer = "Integer"
    case numeric = "Numeric"
    case boolean = "Boolean"

    var id: String { rawValue }
}

private struct GeometryTopologyMetadataColumnRequest: Identifiable {
    let id = UUID()
    let operation: GeometryTopologyMetadataColumnOperation
    let originalName: String?
}

/// Immutable handoff from a real Geometry attribute table to the global tool
/// route. The parent editor identity is required so the route can never create
/// a second, empty editor as a substitute for the current model draft.
private struct GeometryTopologyMetadataColumnPresentationCapture: Equatable {
    let projectSessionID: UUID
    let parentEditorSessionID: UUID
    let assetID: String
    let tableID: String
    let operation: GeometryTopologyMetadataColumnOperation
    let columnID: String?

    init?(kind: ToolKind, context: AttributeToolContext?) {
        guard let context,
              let projectSessionID = context.projectSessionID,
              let parentEditorSessionID = context.parentEditorSessionID,
              GeometryTopologyMetadataColumnKind(tableID: context.tableID) != nil else { return nil }
        let operation: GeometryTopologyMetadataColumnOperation
        switch kind {
        case .addAttribute:
            guard context.columnID == nil else { return nil }
            operation = .add
        case .renameAttribute:
            guard let columnID = context.columnID, !columnID.isEmpty else { return nil }
            operation = .rename
        default:
            return nil
        }
        self.projectSessionID = projectSessionID
        self.parentEditorSessionID = parentEditorSessionID
        self.assetID = context.modelAssetID
        self.tableID = context.tableID
        self.operation = operation
        self.columnID = context.columnID
    }
}

/// Typed replacement for the generic Add/Rename Attribute route. It resolves
/// the exact existing parent editor captured by the source table; it does not
/// instantiate a ModelEditorSession or bypass the Geometry child draft.
struct GeometryTopologyMetadataColumnToolRoute: View {
    @ObservedObject var store: WorkspaceStore
    let kind: ToolKind
    @State private var capture: GeometryTopologyMetadataColumnPresentationCapture?
    @Environment(\.dismiss) private var dismiss

    init(store: WorkspaceStore, kind: ToolKind, context: AttributeToolContext?) {
        self.store = store
        self.kind = kind
        _capture = State(initialValue: GeometryTopologyMetadataColumnPresentationCapture(kind: kind, context: context))
    }

    var body: some View {
        if let capture,
           capture.projectSessionID == store.projectSessionID,
           let parent = store.editorSession(capture.parentEditorSessionID),
           parent.modelAssetID == capture.assetID,
           store.assets.contains(where: { $0.id == capture.assetID && $0.section == .geometries && $0.isModelFile }) {
            GeometryTopologyMetadataColumnToolEditor(store: store, capture: capture, parent: parent)
        } else {
            VStack(spacing: 12) {
                ContentUnavailableView(L10n.text("Open this command from an Arc or Region table."),
                    systemImage: "tablecells",
                    description: Text(L10n.text("Choose the target in the current Geometry editor so the column change uses its existing draft.")))
                Button(L10n.text("Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
                .frame(minWidth: 460, minHeight: 250)
        }
    }
}

@MainActor
private struct GeometryTopologyMetadataColumnToolEditor: View {
    @ObservedObject var store: WorkspaceStore
    let capture: GeometryTopologyMetadataColumnPresentationCapture
    @ObservedObject var parent: ModelEditorSession
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @State private var issue: String?
    @State private var expectedGeometryIdentity: String?

    private var tableKind: GeometryTopologyMetadataColumnKind? {
        GeometryTopologyMetadataColumnKind(tableID: capture.tableID)
    }
    private var topology: GeometryTopologySession? { parent.geometryTopology }
    private var currentParentMatchesCapture: Bool {
        store.projectSessionID == capture.projectSessionID
            && store.editorSession(capture.parentEditorSessionID) === parent
            && parent.modelAssetID == capture.assetID
            && store.assets.contains(where: {
                $0.id == capture.assetID && $0.section == .geometries && $0.isModelFile
            })
    }
    private var currentParentIsRegistered: Bool {
        currentParentMatchesCapture && parent.loaded && parent.geometryTopology != nil
    }
    private var captureIsCurrent: Bool {
        guard currentParentIsRegistered,
              expectedGeometryIdentity == parent.geometryTopologyIdentity,
              let topology,
              topology.mapAssetIdentity == capture.assetID,
              topology.snapshot != nil else { return false }
        return true
    }

    var body: some View {
        Group {
            if !currentParentMatchesCapture {
                unavailable("The captured Geometry editor is no longer available.")
            } else if !parent.loaded {
                ProgressView(L10n.text("Loading Geometry editor…"))
                    .frame(minWidth: 460, minHeight: 240)
            } else if !currentParentIsRegistered {
                unavailable("The captured Geometry editor is no longer available.")
            } else if !parent.canEdit {
                unavailable("This Geometry model cannot be edited for the requested column action.")
            } else if isLoading {
                ProgressView(L10n.text("Loading topology table…"))
                    .frame(minWidth: 460, minHeight: 240)
            } else if let issue {
                unavailable(issue)
            } else if !captureIsCurrent {
                unavailable("The Geometry source changed while the column action was open.")
            } else if let tableKind, let topology, topology.snapshot != nil {
                let table = topology.table(for: tableKind.featureKind)
                if capture.operation == .rename && !table.columns.contains(where: {
                    $0.id == capture.columnID && $0.isUserDefined == true
                }) {
                    unavailable("The selected column is no longer user-defined or is no longer available.")
                } else {
                    GeometryTopologyMetadataColumnEditorSheet(
                        request: .init(operation: capture.operation,
                            originalName: capture.operation == .rename ? capture.columnID : nil),
                        columns: table.columns,
                        featureKind: tableKind,
                        session: topology,
                        captureIsCurrent: { captureIsCurrent })
                }
            } else {
                unavailable("Custom columns are supported only on Arc and Region tables.")
            }
        }
        .task(id: capture.tableID + "|" + capture.assetID + "|" + capture.parentEditorSessionID.uuidString) {
            await loadCapturedTable()
        }
        .onChange(of: store.projectSessionID) { _, _ in
            isLoading = false
            issue = "The project changed while the column action was open."
        }
        .onChange(of: parent.modelAssetID) { _, _ in
            isLoading = false
            issue = "The Geometry model changed while the column action was open."
        }
        .onChange(of: parent.loaded) { _, loaded in
            guard loaded, issue == nil else { return }
            Task { await loadCapturedTable() }
        }
        .frame(minWidth: 460, minHeight: 260)
    }

    private func loadCapturedTable() async {
        guard currentParentMatchesCapture, let tableKind else {
            isLoading = false
            issue = "Open this command from an Arc or Region table."
            return
        }
        guard parent.loaded else { isLoading = true; return }
        guard currentParentIsRegistered, parent.canEdit, let topology else {
            isLoading = false
            issue = "The captured Geometry editor is no longer available."
            return
        }
        isLoading = true
        issue = nil
        await parent.ensureGeometryTopologyLoaded()
        guard currentParentIsRegistered,
              topology.mapAssetIdentity == capture.assetID,
              topology.snapshot != nil else {
            isLoading = false
            issue = topology.error ?? "The captured topology table could not be loaded."
            return
        }
        let table = topology.table(for: tableKind.featureKind)
        if capture.operation == .rename {
            guard let columnID = capture.columnID,
                  table.columns.contains(where: { $0.id == columnID && $0.isUserDefined == true }) else {
                isLoading = false
                issue = "The selected column is no longer user-defined or is no longer available."
                return
            }
        }
        expectedGeometryIdentity = parent.geometryTopologyIdentity
        isLoading = false
    }

    private func unavailable(_ message: String) -> some View {
        VStack(spacing: 12) {
            ContentUnavailableView(L10n.text(message), systemImage: "tablecells",
                description: Text(L10n.text("Open the Arc or Region table in the same Geometry editor and start the action there.")))
            Button(L10n.text("Close")) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }
}

struct GeometryTopologyMetadataColumnMenu: View {
    let featureKind: GeometryTopologyMetadataColumnKind
    let columns: [GeometryTopologyColumn]
    @ObservedObject var session: GeometryTopologySession
    var openGlobalTool: ((ToolKind, String?) -> Void)? = nil
    @State private var editorRequest: GeometryTopologyMetadataColumnRequest?
    @State private var pendingDeletion: GeometryTopologyColumn?
    @State private var showingDeleteConfirmation = false

    private var userColumns: [GeometryTopologyColumn] {
        columns.filter { $0.isUserDefined == true }
    }

    var body: some View {
        Menu {
            Button {
                if let openGlobalTool {
                    openGlobalTool(.addAttribute, nil)
                } else {
                    editorRequest = .init(operation: .add, originalName: nil)
                }
            } label: {
                Label(L10n.text("Add Column"), systemImage: "plus")
            }

            Menu(L10n.text("Rename Column")) {
                if userColumns.isEmpty {
                    Text(L10n.text("No user-defined columns"))
                }
                ForEach(userColumns) { column in
                    Button(column.title) {
                        if let openGlobalTool {
                            openGlobalTool(.renameAttribute, column.id)
                        } else {
                            editorRequest = .init(operation: .rename, originalName: column.id)
                        }
                    }
                }
            }
            .disabled(userColumns.isEmpty)

            Menu(L10n.text("Delete Column")) {
                if userColumns.isEmpty {
                    Text(L10n.text("No user-defined columns"))
                }
                ForEach(userColumns) { column in
                    Button(column.title, role: .destructive) {
                        pendingDeletion = column
                        showingDeleteConfirmation = true
                    }
                }
            }
            .disabled(userColumns.isEmpty)
        } label: {
            Label(L10n.text("Columns"), systemImage: "tablecells")
        }
        .disabled(!session.canMutateTopology)
        .sheet(item: $editorRequest) { request in
            GeometryTopologyMetadataColumnEditorSheet(request: request,
                columns: columns, featureKind: featureKind, session: session)
        }
        .confirmationDialog(L10n.text("Delete Column?"), isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible) {
            Button(L10n.text("Delete"), role: .destructive) {
                guard let pendingDeletion else { return }
                Task {
                    _ = await session.editMetadataColumn(operation: .delete,
                        featureKind: featureKind, fieldID: pendingDeletion.id)
                    self.pendingDeletion = nil
                }
            }
            Button(L10n.text("Cancel"), role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(L10n.format("Delete column %@?", pendingDeletion?.title ?? ""))
        }
    }
}

private struct GeometryTopologyMetadataColumnEditorSheet: View {
    let request: GeometryTopologyMetadataColumnRequest
    let columns: [GeometryTopologyColumn]
    let featureKind: GeometryTopologyMetadataColumnKind
    @ObservedObject var session: GeometryTopologySession
    let captureIsCurrent: () -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var type: GeometryTopologyMetadataColumnType = .string
    @State private var isSubmitting = false

    init(request: GeometryTopologyMetadataColumnRequest, columns: [GeometryTopologyColumn],
         featureKind: GeometryTopologyMetadataColumnKind, session: GeometryTopologySession,
         captureIsCurrent: @escaping () -> Bool = { true }) {
        self.request = request
        self.columns = columns
        self.featureKind = featureKind
        self.session = session
        self.captureIsCurrent = captureIsCurrent
        _name = State(initialValue: request.originalName ?? "")
    }

    private var isAdding: Bool { request.operation == .add }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var duplicatesExistingName: Bool {
        columns.contains { column in
            guard column.id != request.originalName else { return false }
            return column.id.compare(name, options: [.caseInsensitive]) == .orderedSame
        }
    }
    private var canSubmit: Bool {
        !trimmedName.isEmpty && !duplicatesExistingName && !isSubmitting
            && session.canMutateTopology
            && captureIsCurrent()
            && (isAdding || name != request.originalName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text(isAdding ? "Add Column" : "Rename Column"))
                .font(.headline)

            Form {
                TextField(L10n.text("Column Name"), text: $name)
                if isAdding {
                    Picker(L10n.text("Column Type"), selection: $type) {
                        ForEach(GeometryTopologyMetadataColumnType.allCases) { item in
                            Text(L10n.text(item.rawValue)).tag(item)
                        }
                    }
                }
            }

            if duplicatesExistingName {
                Text(L10n.text("A column with that name already exists."))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let error = session.error {
                Text(L10n.text(error))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            HStack {
                Spacer()
                Button(L10n.text("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("Save")) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func submit() {
        guard canSubmit, captureIsCurrent() else { return }
        isSubmitting = true
        Task {
            let didApply = await session.editMetadataColumn(operation: request.operation,
                featureKind: featureKind,
                fieldID: isAdding ? name : (request.originalName ?? ""),
                value: isAdding ? type.rawValue : name)
            if didApply {
                dismiss()
            } else {
                isSubmitting = false
            }
        }
    }
}
