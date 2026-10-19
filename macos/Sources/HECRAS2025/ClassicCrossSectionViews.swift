import Charts
import RASWorkspaceCore
import SwiftUI
import UniformTypeIdentifiers

struct ClassicCrossSectionBrowser: View {
    @ObservedObject var store: WorkspaceStore
    @StateObject private var model: ClassicCrossSectionBrowserSession
    @State private var choosingSource = false
    @State private var editActionTask: Task<Void, Never>?
    @State private var editActionError: String?
    @Environment(\.openWindow) private var openWindow

    init(store: WorkspaceStore) {
        self.store = store
        let client = (store.modelProvider as? BackendModelProvider)?.client
            ?? BackendProcessClient(executableURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
        _model = StateObject(wrappedValue: ClassicCrossSectionBrowserSession(
            provider: BackendClassicCrossSectionProvider(client: client), projectSessionID: store.projectSessionID))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Open Classic Geometry…", systemImage: "folder") { choosingSource = true }
                Button("Reload", systemImage: "arrow.clockwise") {
                    if let url = model.sourceURL { model.open(url) }
                }.disabled(model.sourceURL == nil || model.isLoading)
                if model.isLoading || model.isSelecting {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.cancel() }
                }
                Spacer()
                Button("Open Linked Profile Window", systemImage: "macwindow.on.rectangle") {
                    guard editActionTask == nil, let selected = model.selection else { return }
                    let project = store.projectSessionID
                    editActionError = nil
                    editActionTask = Task { @MainActor in
                        defer { editActionTask = nil }
                        do {
                            let route = try await ClassicCrossSectionEditActionDispatcher().dispatch(
                                actionID: ClassicCrossSectionEditActionDispatcher.actionID,
                                selection: selected, projectSessionID: project,
                                currentProjectSessionID: store.projectSessionID, provider: model.provider,
                                selectionIsCurrent: {
                                    project == store.projectSessionID
                                        && model.projectSessionID == project
                                        && ClassicCrossSectionEditActionDispatcher.isSameSelection(model.selection, as: selected)
                                })
                            guard !Task.isCancelled, project == store.projectSessionID,
                                  let route else { return }
                            openWindow(value: route)
                        } catch {
                            if !Task.isCancelled, project == store.projectSessionID {
                                editActionError = L10n.text(error.localizedDescription)
                            }
                        }
                    }
                }.disabled(model.selection == nil || editActionTask != nil || store.isRunningProjectTool)
            }
            if let url = model.sourceURL {
                Text(verbatim: url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                Text("Choose a ClassicGeometry HDF file containing cross sections.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Table(model.rows, selection: Binding(get: { model.selectedOrdinal }, set: { model.select($0) })) {
                TableColumn("Name") { Text(verbatim: $0.nodeName) }
                TableColumn("River") { Text(verbatim: $0.riverName) }
                TableColumn("Reach") { Text(verbatim: $0.reachName) }
                TableColumn("River Station") { Text(verbatim: $0.riverStation) }
            }
            .frame(minHeight: 100, idealHeight: 170, maxHeight: 220)
            .disabled(model.isLoading)
            .overlay {
                if model.sourceURL != nil && model.rows.isEmpty && !model.isLoading {
                    Text("No cross sections are present in this source.").foregroundStyle(.secondary)
                }
            }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let editActionError { Text(editActionError).foregroundStyle(.red).textSelection(.enabled) }
            ClassicCrossSectionPlot(profile: model.selection?.profile)
        }
        .padding(16)
        .disabled(model.projectSessionID != store.projectSessionID)
        .fileImporter(isPresented: $choosingSource,
            allowedContentTypes: [UTType(filenameExtension: "h5") ?? .data,
                                  UTType(filenameExtension: "hdf5") ?? .data,
                                  UTType(filenameExtension: "hdf") ?? .data]) { result in
            switch result {
            case .success(let url): model.open(url)
            case .failure(let failure): model.reportFileSelectionError(failure)
            }
        }
        .onChange(of: store.projectSessionID) { _, _ in model.invalidate() }
        .onDisappear { model.cancel(); editActionTask?.cancel(); editActionTask = nil }
    }
}

struct ClassicCrossSectionWindow: View {
    @ObservedObject var store: WorkspaceStore
    let route: ClassicCrossSectionWindowRoute?
    @ObservedObject private var windows = ClassicCrossSectionWindows.shared
    var body: some View {
        Group {
            if let route, route.projectSessionID == store.projectSessionID,
               let session = windows.sessions[route.id] {
                CrossSectionEditorWindowView(session: session)
                    .onDisappear { windows.close(route.id) }
            } else {
                ContentUnavailableView("Profile Closed", systemImage: "chart.xyaxis.line",
                    description: Text("The cross-section source or project is no longer open."))
            }
        }
        .frame(minWidth: 620, minHeight: 420)
        .environment(\.locale, store.interfaceLocale)
        .preferredColorScheme(store.theme == "Dark" ? .dark : store.theme == "Light" ? .light : nil)
    }
}

/// The retained LINKED window follows cross-section selection until pinned.
/// It displays the source computation profile and sampled bank stations only.
struct CrossSectionEditorWindowView: View {
    @ObservedObject var session: ClassicCrossSectionViewerSession
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: session.selection?.profile.row.nodeName ?? L10n.text("Cross Section"))
                    .font(.headline).textSelection(.enabled)
                Spacer()
                Toggle("Dynamically Linked", isOn: $session.isDynamicallyLinked).toggleStyle(.switch)
                Button("Reload", systemImage: "arrow.clockwise") { session.reload() }
                    .disabled(session.selection == nil || session.isLoading)
                if session.isLoading { ProgressView().controlSize(.small) }
            }.padding(16)
            if let error = session.error { Text(error).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal, 16) }
            Divider()
            ClassicCrossSectionPlot(profile: session.selection?.profile)
        }
    }
}

struct ClassicCrossSectionPlot: View {
    let profile: ClassicCrossSectionProfile?
    private struct Sample: Identifiable {
        let id: String; let station: Double; let elevation: Double; let series: String; let segment: String
    }
    private var samples: [Sample] {
        func points(_ values: [ClassicCrossSectionPoint], series: String) -> [Sample] {
            var segment = 0, result: [Sample] = []
            for point in values {
                guard let x = point.station, let y = point.elevation, x.isFinite, y.isFinite else {
                    segment += 1; continue
                }
                result.append(.init(id: series + ":" + String(point.ordinal), station: x, elevation: y,
                    series: series, segment: series + ":" + String(segment)))
            }
            return result
        }
        return points(profile?.points ?? [], series: "Cross Section") + points(profile?.banks ?? [], series: "Bank")
    }
    var body: some View {
        Chart(samples) { sample in
            LineMark(x: .value(L10n.text("Stations"), sample.station),
                y: .value(L10n.text("Elevations"), sample.elevation),
                series: .value("Segment", sample.segment))
                .foregroundStyle(by: .value("Series", L10n.text(sample.series)))
                .lineStyle(StrokeStyle(lineWidth: 2))
        }
        .chartForegroundStyleScale(domain: [L10n.text("Cross Section"), L10n.text("Bank")],
            range: [Color(red: 0, green: 1, blue: 0), Color(red: 1, green: 0, blue: 0)])
        .chartXAxisLabel(L10n.text("Stations"))
        .chartYAxisLabel(L10n.text("Elevations"))
        .overlay {
            if samples.isEmpty {
                Label(L10n.text(profile == nil ? "Select a cross section to view its profile." : "No profile samples are available from the source calculation."),
                    systemImage: "chart.xyaxis.line")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
            }
        }
        .frame(minHeight: 220)
        .padding(20)
    }
}
