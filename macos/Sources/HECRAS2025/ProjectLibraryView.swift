import RASWorkspaceCore
import SwiftUI

struct LibraryProject: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let description: String
    let publishDate: Date?
    let tags: [String]
    var thumbnail: Data? = nil
    var thumbnailURL: URL? = nil
}

enum LibraryProjectOrigin: String, CaseIterable, Identifiable {
    case example = "Example Projects", synthetic = "Synthetic Projects"
    var id: String { rawValue }
}
struct LibraryProjectSelection: Hashable {
    let origin: LibraryProjectOrigin
    let projectID: String
}

@MainActor
protocol ProjectLibraryProvider {
    func examples() async throws -> [LibraryProject]
    func syntheticProjects() async throws -> [LibraryProject]
    func openProject(_ project: LibraryProject, synthetic: Bool) async throws -> URL
    func openProject(_ project: LibraryProject, synthetic: Bool, progress: @escaping @MainActor (Job) -> Void) async throws -> URL
}
extension ProjectLibraryProvider {
    func syntheticProjects() async throws -> [LibraryProject] { [] }
    func openProject(_ project: LibraryProject, synthetic: Bool, progress: @escaping @MainActor (Job) -> Void) async throws -> URL {
        try await openProject(project, synthetic: synthetic)
    }
}

@MainActor
final class ProjectLibrarySession: ObservableObject {
    @Published private(set) var examples: [LibraryProject] = []
    @Published private(set) var synthetic: [LibraryProject] = []
    @Published private(set) var loading = false
    @Published private(set) var opening: LibraryProjectSelection?
    @Published private(set) var currentJob: Job?
    @Published private(set) var error: String?
    private var loadRevision = 0
    private var openRevision = 0
    private var openTask: Task<URL, any Error>?
    private var presentationActive = true

    func projects(_ origin: LibraryProjectOrigin) -> [LibraryProject] { origin == .example ? examples : synthetic }
    func project(_ selection: LibraryProjectSelection?) -> LibraryProject? {
        guard let selection else { return nil }
        return projects(selection.origin).first { $0.id == selection.projectID }
    }
    func load(provider: (any ProjectLibraryProvider)?, debugMode: Bool) async {
        loadRevision += 1; let revision = loadRevision
        presentationActive = true
        loading = true; error = nil
        do {
            guard let provider else { throw ProjectFileError.invalid("The project library service is unavailable.") }
            let remote = try await provider.examples()
            let local = debugMode ? try await provider.syntheticProjects() : []
            try Task.checkCancellation()
            guard revision == loadRevision else { return }
            guard Set(remote.map(\.id)).count == remote.count else {
                throw ProjectFileError.invalid("The project library contains duplicate project identifiers.")
            }
            guard Set(local.map(\.id)).count == local.count else {
                throw ProjectFileError.invalid("The project library contains duplicate project identifiers.")
            }
            synthetic = local; examples = remote; loading = false
        } catch {
            guard revision == loadRevision else { return }
            loading = false
            if !(error is CancellationError) { self.error = L10n.text(error.localizedDescription) }
        }
    }
    // Compatibility entry point for tests and in-app callers without a launch
    // configuration. The production view always passes the actual debug flag.
    func load(provider: (any ProjectLibraryProvider)?) async {
        await load(provider: provider, debugMode: true)
    }
    func open(_ selection: LibraryProjectSelection, provider: (any ProjectLibraryProvider)?) async -> URL? {
        guard opening == nil, let provider, let project = project(selection) else { return nil }
        openRevision += 1; let revision = openRevision
        presentationActive = true
        opening = selection; currentJob = nil; error = nil
        let task = Task { [weak self] in
            try await provider.openProject(project, synthetic: selection.origin == .synthetic) { [weak self] job in
                guard let self, self.presentationActive, self.openRevision == revision, self.opening == selection else { return }
                self.currentJob = job
            }
        }
        openTask = task
        do {
            let url = try await task.value
            guard !Task.isCancelled, !task.isCancelled, revision == openRevision else { return nil }
            opening = nil; currentJob = nil; openTask = nil
            return url
        } catch {
            guard revision == openRevision else { return nil }
            opening = nil; currentJob = nil; openTask = nil
            if !(error is CancellationError) { self.error = L10n.text(error.localizedDescription) }
            return nil
        }
    }
    func cancelOpening() {
        guard currentJob?.isCancellable == true, currentJob?.isComplete == false else { return }
        invalidateOpening()
    }
    private func invalidateOpening() {
        openRevision += 1; openTask?.cancel(); openTask = nil; opening = nil; currentJob = nil
    }
    func invalidate() {
        loadRevision += 1; loading = false
        presentationActive = false
        currentJob = nil
        if opening == nil {
            openTask = nil
        }
    }
}

struct ProjectLibraryView: View {
    @ObservedObject var store: WorkspaceStore
    @StateObject private var state = ProjectLibrarySession()
    @State private var selection: LibraryProjectSelection?
    @State private var search = ""
    private func filtered(_ projects: [LibraryProject]) -> [LibraryProject] {
        projects.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.description.localizedCaseInsensitiveContains(search) || $0.tags.contains { $0.localizedCaseInsensitiveContains(search) } }
    }
    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section(LocalizedStringKey(LibraryProjectOrigin.example.rawValue)) {
                    ForEach(filtered(state.projects(.example))) { project in
                        Label(project.title, systemImage: "folder")
                            .tag(LibraryProjectSelection(origin: .example, projectID: project.id))
                    }
                }
                if store.launchConfiguration.debugMode {
                    Section(LocalizedStringKey(LibraryProjectOrigin.synthetic.rawValue)) {
                        ForEach(filtered(state.projects(.synthetic))) { project in
                            Label(project.title, systemImage: "function")
                                .tag(LibraryProjectSelection(origin: .synthetic, projectID: project.id))
                        }
                    }
                }
            }
            .disabled(state.opening != nil)
            .listStyle(.sidebar).searchable(text: $search, placement: .sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            if let opening = state.opening, let project = state.project(opening) {
                OpeningProjectPage(project: project, job: state.currentJob, cancel: state.cancelOpening)
            } else if let project = state.project(selection), let selection {
                Form {
                    Section {
                        LibraryProjectThumbnail(project: project)
                        Text(project.title).font(.title2)
                        Text(project.description).textSelection(.enabled)
                        if let date = project.publishDate { LabeledContent("Publish Date", value: date.formatted(date: .long, time: .omitted)) }
                        if !project.tags.isEmpty { LabeledContent("Tags", value: project.tags.joined(separator: ", ")) }
                    }
                    Section {
                        Button("Open Project") {
                            let projectSession = store.projectSessionID
                            Task {
                                if let url = await state.open(selection, provider: store.libraryProvider), projectSession == store.projectSessionID {
                                    store.requestOpenFromLibrary(url)
                                }
                            }
                        }.buttonStyle(.glassProminent).disabled(store.libraryProvider == nil || state.loading)
                        if store.libraryProvider == nil { Text("The project library service is unavailable.").foregroundStyle(.secondary) }
                    }
                    if let error = state.error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) } }
                }.formStyle(.grouped)
            } else {
                VStack(spacing: 16) {
                    if state.loading { ProgressView("Loading Projects…") }
                    else if let error = state.error {
                        ContentUnavailableView { Label("Project Library", systemImage: "exclamationmark.triangle") } description: { Text(error) } actions: {
                            Button("Retry") { Task { await state.load(provider: store.libraryProvider, debugMode: store.launchConfiguration.debugMode) } }
                        }
                    } else { ContentUnavailableView("Select a Project", systemImage: "folder") }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await state.load(provider: store.libraryProvider, debugMode: store.launchConfiguration.debugMode) }
        .onDisappear { state.invalidate() }
        .interactiveDismissDisabled(state.opening != nil)
    }
}

struct LibraryProjectThumbnail: View {
    let project: LibraryProject
    var body: some View {
        if let data = project.thumbnail, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 220).accessibilityLabel(project.title)
        } else if let url = project.thumbnailURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit().frame(maxHeight: 220).accessibilityLabel(project.title)
            } placeholder: {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160, maxHeight: 220)
            }
        } else {
            ContentUnavailableView("Preview Image Unavailable", systemImage: "photo")
                .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 220)
        }
    }
}

// The original OpeningProjectPage follows Project.CurrentJob and Project.Image;
// it returns to the selected project on failure. It never manufactures progress.
struct OpeningProjectPage: View {
    let project: LibraryProject
    let job: Job?
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            LibraryProjectThumbnail(project: project)
            Text(project.title).font(.title)
            OperationProgressView(title: "Opening Project…", message: job?.showStatusMessage == true ? job?.message ?? "" : "",
                fraction: job.flatMap { $0.progress.isFinite ? $0.progress / 100 : nil }, cancelling: job?.isCancelling == true,
                cancel: job?.isCancellable == true && job?.isComplete == false ? cancel : nil)
            Text(project.description).foregroundStyle(.secondary).textSelection(.enabled)
            Spacer(minLength: 0)
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
