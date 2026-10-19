import RASWorkspaceCore
import SwiftUI

struct ExternalRecord: Identifiable, Sendable {
    let path: String
    let dataType: String
    let units: String
    let recordType: String
    let parts: [String]
    let comprisingPaths: [String]
    let sourcePath: String?
    let sourceRevision: String?
    var id: String { path }

    init(path: String, dataType: String = "", units: String = "", recordType: String = "",
         parts: [String] = [], comprisingPaths: [String] = [], sourcePath: String? = nil,
         sourceRevision: String? = nil) {
        self.path = path
        self.dataType = dataType
        self.units = units
        self.recordType = recordType
        self.parts = parts
        self.comprisingPaths = comprisingPaths
        self.sourcePath = sourcePath
        self.sourceRevision = sourceRevision
    }
}
@MainActor
protocol ExternalRecordProvider {
    func records(connection: ProjectConnection, directory: URL, mappings: [PathMapping]) async throws -> [ExternalRecord]
    func read(_ request: DSSRecordReadRequest) async throws -> [DSSRecordReadResult]
}

extension ExternalRecordProvider {
    func read(_ request: DSSRecordReadRequest) async throws -> [DSSRecordReadResult] {
        throw BackendServiceError(code: "unsupported", message: L10n.text("This record provider does not support DSS record reads."))
    }
}

// ExternalConnectionLinker and WellKnownExternalPathEditor use a connection
// name and an internal data path. A DSS record path is never a Finder path.
struct ExternalConnectionField: View {
    let field: SourceEditorField
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @State private var showNewConnection = false
    var body: some View {
        HStack {
            Picker(LocalizedStringKey(field.title), selection: Binding(
                get: { field.hasMixedDraft(in: session) ? "__mixed__" : (session.fields[field.storageID] ?? "") },
                set: { field.setDraftValue($0, in: session) })) {
                if field.hasMixedDraft(in: session) { Text("Mixed values").tag("__mixed__").disabled(true) }
                Text("None").tag("")
                ForEach(store.document?.connections ?? []) { Text($0.name).tag($0.name) }
                if let current = session.fields[field.storageID], !current.isEmpty,
                   store.document?.connections.contains(where: { $0.name == current }) != true { Text(current).tag(current) }
            }
            .disabled(!field.canEditDraft(in: session) || store.isSavingAll)
            Button { showNewConnection = true } label: { Label("Add Connection…", systemImage: "plus") }.disabled(!store.hasProject)
        }.sheet(isPresented: $showNewConnection) { ConnectionEditorSheet(store: store) }
    }
}

struct ExternalPathField: View {
    let field: SourceEditorField
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @State private var showRecords = false
    @State private var browsingConnectionIdentity: String?
    private var isReadOnly: Bool {
        field.readOnly || field.isReadOnly == true || session.readOnlyFieldIDs.contains(field.storageID)
    }
    private var canEdit: Bool {
        !isReadOnly && field.canEditDraft(in: session) && !store.isSavingAll
    }
    private var connection: ProjectConnection? {
        guard let route = field.connectionBy, let name = session.fields[field.scoped(route)] else { return nil }
        return store.document?.connections.first { $0.name == name }
    }
    private var connectionIdentity: String? {
        guard let connection else { return nil }
        return [connection.id, connection.name, connection.type, connection.relativePath,
                connection.absolutePath, connection.searchPattern, String(connection.recurse),
                connection.description].joined(separator: "\u{0}")
    }
    private var recordPickerIdentity: String? {
        connectionIdentity.map {
            [session.id.uuidString, String(session.loadRevision), session.modelAssetID ?? "",
             session.sourceFileRevision ?? "", field.storageID, $0].joined(separator: "\u{0}")
        }
    }
    private var isDSS: Bool {
        guard let connection, connection.type == "File" else { return false }
        return [connection.relativePath, connection.absolutePath].contains { $0.lowercased().hasSuffix(".dss") }
    }
    var body: some View {
        Group {
            if isReadOnly {
                OriginalTextPropertyItem(title: field.title, value: session.fields[field.storageID] ?? "")
            } else {
                HStack {
                    TextField(LocalizedStringKey(field.title), text: Binding(get: { session.fields[field.storageID] ?? "" }, set: { session.set(field.storageID, $0) }))
                        .disabled(!canEdit)
                    if isDSS {
                        Button("Browse Records…") {
                            browsingConnectionIdentity = recordPickerIdentity
                            showRecords = true
                        }
                            .disabled(!canEdit || connection == nil)
                    }
                }
            }
        }
        .sheet(isPresented: $showRecords, onDismiss: { browsingConnectionIdentity = nil }) {
            if canEdit, let connection,
               let capture = browsingConnectionIdentity,
               capture == recordPickerIdentity {
                ExternalRecordPicker(store: store, connection: connection) { path in
                    guard canEdit, recordPickerIdentity == capture,
                          session.fields[field.storageID] != nil else { return }
                    session.set(field.storageID, path)
                    showRecords = false
                }
            }
        }
        .onChange(of: recordPickerIdentity) { _, value in
            if value != browsingConnectionIdentity { showRecords = false }
        }
        .onChange(of: isReadOnly) { _, value in
            if value { showRecords = false }
        }
    }
}

@MainActor
final class ExternalRecordSession: ObservableObject {
    @Published private(set) var records: [ExternalRecord] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var readResults: [DSSRecordReadResult]?
    @Published private(set) var readError: String?
    @Published private(set) var reading = false
    private var revision = UUID()
    private var readRevision = UUID()
    private var readTask: Task<[DSSRecordReadResult], Error>?

    func load(_ request: ConnectionPreviewRequest, provider: (any ExternalRecordProvider)?) async {
        cancelRead()
        let revision = UUID(); self.revision = revision; records = []; error = nil; loading = true
        defer { if self.revision == revision { loading = false } }
        guard let provider else { error = L10n.text("The DSS catalog service is unavailable."); return }
        do {
            let result = try await provider.records(connection: request.connection, directory: request.directory, mappings: request.mappings)
            guard self.revision == revision, !Task.isCancelled else { return }
            guard Set(result.map(\.id)).count == result.count, result.allSatisfy({ !$0.path.isEmpty }) else {
                throw ProjectFileError.invalid("The DSS catalog returned invalid record identities.")
            }
            records = result
        } catch {
            if self.revision == revision, !Task.isCancelled { self.error = L10n.text(error.localizedDescription) }
        }
    }

    func read(_ selectedRecords: [ExternalRecord], provider: (any ExternalRecordProvider)?) async {
        cancelRead()
        let actionRevision = UUID()
        readRevision = actionRevision
        readResults = nil
        readError = nil
        reading = true
        defer {
            if readRevision == actionRevision {
                reading = false
                readTask = nil
            }
        }
        guard let provider else {
            readError = L10n.text("The DSS record service is unavailable.")
            return
        }
        guard !selectedRecords.isEmpty,
              let sourcePath = selectedRecords.first?.sourcePath,
              let sourceRevision = selectedRecords.first?.sourceRevision,
              selectedRecords.allSatisfy({ $0.sourcePath == sourcePath && $0.sourceRevision == sourceRevision }),
              Set(selectedRecords.map(\.path)).count == selectedRecords.count,
              Set(selectedRecords.map(\.path)).isSubset(of: Set(records
                .filter { $0.sourcePath == sourcePath && $0.sourceRevision == sourceRevision }
                .map(\.path))) else {
            readError = L10n.text("The selected DSS records do not share one catalog source revision.")
            return
        }

        let request = DSSRecordReadRequest(sourcePath: sourcePath, sourceRevision: sourceRevision,
                                           recordPaths: selectedRecords.map(\.path))
        let task = Task { try await provider.read(request) }
        readTask = task
        do {
            let result = try await task.value
            guard readRevision == actionRevision, !Task.isCancelled else { return }
            let returnedPaths = result.map(\.path)
            guard returnedPaths.count == request.recordPaths.count,
                  Set(returnedPaths).count == returnedPaths.count,
                  Set(returnedPaths) == Set(request.recordPaths) else {
                throw BackendServiceError(code: "protocolFailure", message: L10n.text("The DSS read response does not match the selected records."))
            }
            let byPath = Dictionary(uniqueKeysWithValues: result.map { ($0.path, $0) })
            readResults = request.recordPaths.compactMap { byPath[$0] }
        } catch {
            if readRevision == actionRevision, !Task.isCancelled {
                readError = L10n.text(error.localizedDescription)
            }
        }
    }

    func cancelRead() {
        readRevision = UUID()
        readTask?.cancel()
        readTask = nil
        reading = false
        readResults = nil
        readError = nil
    }

    func invalidate() {
        revision = UUID()
        cancelRead()
        records = []
        loading = false
        error = nil
    }
}

struct ExternalRecordBrowser: View {
    @ObservedObject var store: WorkspaceStore
    let connection: ProjectConnection
    @Binding var selection: String?
    var select: ((String) -> Void)? = nil
    var showsVisualizationActions = false
    var refreshToken: UUID? = nil
    @StateObject private var session = ExternalRecordSession()
    @State private var query = ""
    @State private var refresh = UUID()
    @State private var selectedPaths: Set<String> = []
    @State private var filterState = DSSRecordBrowserFilterState()
    @State private var presentation: DSSRecordPresentation?
    private let partNames = ["A", "B", "C", "D", "E", "F"]
    private var partChoices: [[String]] {
        var values = Array(repeating: Set<String>(), count: 6)
        for record in session.records {
            for (index, part) in (record.parts.count == 6 ? record.parts : dssPathParts(record.path)).enumerated() {
                values[index].insert(part)
            }
        }
        return values.map { $0.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } }
    }
    private var visible: [ExternalRecord] {
        session.records.filter { record in
            guard query.isEmpty || [record.path, record.recordType, L10n.text(record.recordType), record.dataType, record.units].contains(where: { $0.localizedCaseInsensitiveContains(query) }),
                  filterState.includesRecordType(record.recordType) else { return false }
            let parts = record.parts.count == 6 ? record.parts : dssPathParts(record.path)
            return filterState.matchesParts(parts)
        }
    }
    private var selectedRecords: [ExternalRecord] { visible.filter { selectedPaths.contains($0.id) } }
    private var request: ConnectionPreviewRequest? {
        guard let directory = store.document?.directory else { return nil }
        return .init(projectID: store.projectSessionID, connection: connection, directory: directory, mappings: store.pathMappings)
    }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("Search record paths", text: $query).textFieldStyle(.roundedBorder).disabled(session.reading)
                if session.loading { ProgressView().controlSize(.small) }
                Button("Refresh") { session.invalidate(); refresh = UUID() }
            }
            LazyVGrid(columns: [GridItem(.flexible(minimum: 120)), GridItem(.flexible(minimum: 120)), GridItem(.flexible(minimum: 120))], alignment: .leading, spacing: 8) {
                ForEach(partNames.indices, id: \.self) { index in
                    Picker(L10n.format("DSS Part %@", partNames[index]), selection: Binding(
                        get: { filterState.partSelections[index] },
                        set: { filterState.setPartSelection($0, at: index) }
                    )) {
                        Text("All").tag(DSSPartFilterSelection.all)
                        let values = partChoices[index]
                        if values.contains("") || values.contains("(blank)") || filterState.partSelections[index] == .blank {
                            Text("(blank)").tag(DSSPartFilterSelection.blank)
                        }
                        ForEach(values.filter { !$0.isEmpty && $0 != "(blank)" }, id: \.self) { value in
                            Text(value).tag(DSSPartFilterSelection.value(value))
                        }
                        if case .value(let current) = filterState.partSelections[index], !values.contains(current) {
                            Text(current).tag(DSSPartFilterSelection.value(current))
                        }
                    }
                    .pickerStyle(.menu)
                }
                Menu {
                    Button {
                        filterState.toggleAllRecordTypes()
                    } label: {
                        Text(filterState.allRecordTypesSelected ? "Uncheck All" : "Check All")
                    }
                    .disabled(filterState.recordTypeOptions.isEmpty)
                    Divider()
                    ForEach(filterState.recordTypeOptions, id: \.self) { recordType in
                        Toggle(isOn: Binding(
                            get: { filterState.includesRecordType(recordType) },
                            set: { filterState.setRecordType(recordType, selected: $0) }
                        )) {
                            if recordType.isEmpty { Text("(blank)") }
                            else { Text(L10n.text(recordType)) }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("Record Type")
                        Text(verbatim: "\(filterState.selectedRecordTypeCount)/\(filterState.recordTypeOptions.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }.disabled(session.reading)
            Table(visible, selection: $selectedPaths) {
                TableColumn(L10n.text("Record Path")) { Text($0.path).textSelection(.enabled) }
                TableColumn(L10n.text("Record Type")) { Text(L10n.text($0.recordType)) }
                TableColumn(L10n.text("Data Type")) { Text($0.dataType) }
                TableColumn(L10n.text("Units")) { Text($0.units) }
            }.disabled(session.reading)
            if let error = session.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
            else if !session.loading, session.records.isEmpty { Text("No DSS records.").foregroundStyle(.secondary) }
            else if !session.loading, visible.isEmpty { Text("No records match the current filters.").foregroundStyle(.secondary) }
            if let error = session.readError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
            if showsVisualizationActions {
                HStack {
                    Button("Open Graph") { open(.graph) }
                        .disabled(selectedRecords.isEmpty || session.reading)
                    Button("Open Table") { open(.table) }
                        .disabled(selectedRecords.isEmpty || session.reading)
                    if session.reading {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { session.cancelRead() }
                    }
                }
            }
            HStack {
                Button("Copy Record Path") {
                    let paths = selectedRecords.map(\.path)
                    if !paths.isEmpty { store.system.copy(paths.joined(separator: "\n")) }
                }
                .disabled(selectedRecords.isEmpty)
                Spacer()
                Text("\(visible.count) records").font(.caption).foregroundStyle(.secondary)
                if let select {
                    Button("Select") { if let path = selectedRecords.first?.path { select(path) } }
                        .keyboardShortcut(.defaultAction).disabled(selectedRecords.isEmpty)
                }
            }
        }.padding(12)
            .sheet(item: $presentation) { DSSRecordResultView(presentation: $0) }
            .task(id: RecordLoadKey(request: request, refresh: refresh, refreshToken: refreshToken)) {
                selection = nil; selectedPaths = []
                filterState.resetForCatalogLoad()
                if let request {
                    await session.load(request, provider: store.externalRecordProvider)
                    guard !Task.isCancelled else { return }
                    filterState.updateRecordTypeOptions(session.records.map(\.recordType))
                } else {
                    session.invalidate()
                }
            }
            .onChange(of: session.records.map(\.recordType)) { _, values in
                guard !session.loading else { return }
                filterState.updateRecordTypeOptions(values)
            }
            .onChange(of: request) { _, _ in
                presentation = nil
                session.invalidate()
                selection = nil
                selectedPaths = []
            }
            .onChange(of: refreshToken) { _, _ in
                presentation = nil
                session.invalidate()
            }
            .onChange(of: selectedPaths) { _, ids in selection = ids.first }
            .onChange(of: selection) { _, id in selectedPaths = id.map { [$0] } ?? [] }
            .onChange(of: visible.map(\.id)) { _, ids in
                selectedPaths.formIntersection(ids)
                if let selection, !ids.contains(selection) { self.selection = nil }
            }
            .onDisappear { presentation = nil; session.invalidate() }
    }
    private func open(_ mode: DSSRecordPresentation.Mode) {
        let capture = selectedRecords
        Task {
            await session.read(capture, provider: store.externalRecordProvider)
            guard let results = session.readResults else { return }
            presentation = DSSRecordPresentation(mode: mode, records: results)
        }
    }
    private func dssPathParts(_ path: String) -> [String] {
        var value = path
        if value.first == "/" { value.removeFirst() }
        if value.last == "/" { value.removeLast() }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return Array(parts.prefix(6)) + Array(repeating: "", count: max(0, 6 - parts.count))
    }
}
private struct RecordLoadKey: Hashable { let request: ConnectionPreviewRequest?; let refresh: UUID; let refreshToken: UUID? }
struct ExternalRecordPicker: View {
    @ObservedObject var store: WorkspaceStore
    let connection: ProjectConnection
    let select: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(connection.name).font(.title2); Spacer(); Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction) }.padding()
            ExternalRecordBrowser(store: store, connection: connection, selection: $selection) { path in select(path); dismiss() }
        }.frame(width: 820, height: 520)
            .onChange(of: store.projectSessionID) { _, _ in dismiss() }
    }
}
