import SwiftUI

struct TestingPlanChoice: Identifiable, Sendable {
    let id: String
    let name: String
    let geometry: String?
    let boundaryCondition: String?
    var exportable: Bool { geometry != nil && boundaryCondition != nil }
}
struct TestingUploadSnapshot: Sendable {
    let sourceURL: URL?
    let suggestedName: String
    let folder: String
    let description: String
    let plans: [TestingPlanChoice]
    let selectedPlanIDs: Set<String>
    let geometries: [EditorChoice]
    let selectedGeometryID: String?
    let serverObjectID: String?
    let existingNames: Set<String>
    let pointEditor: TestingSnapshot?
    var sourceGeometryValid = false
    var projectName = ""
    var commits: [EditorChoice] = []
}
struct TestingUploadRequest: Sendable {
    let kind: ToolKind
    let sourceURL: URL?
    let geometryID: String?
    let serverObjectID: String?
    let name: String
    let folder: String
    let description: String
    let planIDs: [String]
    let points: [InterestPoint]
    var queueRunAfterUpload = false
    var runCommit: String? = nil
    var runTag = ""
    var runIterations = 1
}
struct TestingUploadOutcome: Decodable, Sendable {
    let message: String
    let serverObjectID: String?
    let runQueued: Bool
    let cancelled: Bool
    let uploadCompleted: Bool
    let continuationError: String?

    init(message: String, serverObjectID: String?, runQueued: Bool,
         cancelled: Bool = false, uploadCompleted: Bool = true, continuationError: String? = nil) {
        self.message = message; self.serverObjectID = serverObjectID; self.runQueued = runQueued
        self.cancelled = cancelled; self.uploadCompleted = uploadCompleted; self.continuationError = continuationError
    }
}
@MainActor
protocol TestingUploadProvider {
    func prepare(sourceURL: URL?, kind: ToolKind, geometryID: String?) async throws -> TestingUploadSnapshot
    func upload(_ request: TestingUploadRequest, progress: @escaping @MainActor (Double?, String) -> Void) async throws -> TestingUploadOutcome
    func cancelUpload()
}

@MainActor
extension TestingUploadProvider {
    func cancelUpload() {}
}

@MainActor
final class TestingUploadSession: ObservableObject {
    @Published private(set) var snapshot: TestingUploadSnapshot?
    @Published var name = ""
    @Published var folder = ""
    @Published var description = ""
    @Published var selectedPlans: Set<String> = []
    @Published var selectedGeometry: String?
    @Published var queueRunAfterUpload = false
    @Published var runCommit = ""
    @Published var runTag = ""
    @Published var runIterations = 1
    @Published private(set) var points: [InterestPoint] = []
    @Published private(set) var busy = false
    @Published private(set) var progress: Double?
    @Published private(set) var message = ""
    @Published private(set) var uploadCompleted = false
    @Published var error: String?
    private let provider: (any TestingUploadProvider)?
    let kind: ToolKind
    private var revision = 0
    init(provider: (any TestingUploadProvider)?, kind: ToolKind) { self.provider = provider; self.kind = kind }
    var available: Bool { provider != nil }
    var exportablePlans: [String] { (snapshot?.plans ?? []).filter { $0.exportable && selectedPlans.contains($0.id) }.map(\.id) }
    var pointsOnly: Bool { kind == .testingProjectUpload && snapshot?.serverObjectID != nil && exportablePlans.isEmpty }
    var canCancelUpload: Bool { kind == .testingProjectUpload && !pointsOnly }
    var canUpload: Bool {
        guard available, !busy, !uploadCompleted, snapshot != nil, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if queueRunAfterUpload && runCommit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if kind == .testingProjectUpload { return pointsOnly || !exportablePlans.isEmpty }
        return snapshot?.geometries.contains { $0.id == selectedGeometry } == true || snapshot?.sourceGeometryValid == true
    }
    func prepare(sourceURL: URL?, geometryID: String? = nil) async {
        guard let provider, !busy else { return }
        revision += 1; let captured = revision
        busy = true; error = nil
        defer { if captured == revision { busy = false } }
        do {
            let value = try await provider.prepare(sourceURL: sourceURL, kind: kind, geometryID: geometryID)
            guard captured == revision, !Task.isCancelled else { return }
            snapshot = value; name = value.suggestedName; folder = value.folder; description = value.description
            selectedPlans = value.selectedPlanIDs; selectedGeometry = value.selectedGeometryID; points = value.pointEditor?.points ?? []
            if let firstCommit = value.commits.first { runCommit = firstCommit.id }
            queueRunAfterUpload = false; runTag = ""; runIterations = 1; uploadCompleted = false; message = ""
        } catch { if captured == revision, !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func toggleAllPlans() {
        let eligible = Set((snapshot?.plans ?? []).filter(\.exportable).map(\.id))
        if eligible.isSubset(of: selectedPlans) { selectedPlans.subtract(eligible) } else { selectedPlans.formUnion(eligible) }
    }
    func setPoints(_ points: [InterestPoint]) { self.points = points }
    func selectGeometry(_ id: String?) {
        guard let option = snapshot?.geometries.first(where: { $0.id == id }) else { name = ""; return }
        let project = snapshot?.projectName ?? ""
        name = project.isEmpty ? option.title : project + " " + option.title
    }
    func upload() async -> Bool {
        guard let provider, canUpload else { return false }
        revision += 1; let captured = revision
        let trimmedRunCommit = runCommit.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = TestingUploadRequest(kind: kind, sourceURL: snapshot?.sourceURL, geometryID: selectedGeometry,
            serverObjectID: snapshot?.serverObjectID, name: name, folder: folder, description: description,
            planIDs: exportablePlans, points: points, queueRunAfterUpload: queueRunAfterUpload,
            runCommit: trimmedRunCommit.isEmpty ? nil : trimmedRunCommit,
            runTag: runTag, runIterations: runIterations)
        busy = true; error = nil; progress = nil; message = ""
        defer { if captured == revision { busy = false; progress = nil } }
        do {
            let outcome = try await provider.upload(request) { [weak self = self] value, message in
                guard let self, captured == self.revision else { return }
                self.progress = value.flatMap { $0.isFinite ? min(max($0, 0), 100) : nil }; self.message = message
            }
            guard captured == revision, !Task.isCancelled else { return false }
            message = outcome.message
            error = outcome.continuationError
            uploadCompleted = outcome.uploadCompleted
            return outcome.uploadCompleted
        } catch { if captured == revision, !Task.isCancelled { self.error = error.localizedDescription }; return false }
    }
    func invalidate() { revision += 1; provider?.cancelUpload(); busy = false; progress = nil }
}

// PoiImporter edits a copy and its OK callback updates the uploader PointSet.
// This local draft adapter has no server/filesystem write and reports no upload.
@MainActor
final class UploadPointDraft: TestingProvider {
    private var snapshot: TestingSnapshot
    private let sourceImporter: (any TestingProvider)?
    let didSave: ([InterestPoint]) -> Void
    init(snapshot: TestingSnapshot, sourceImporter: (any TestingProvider)?, didSave: @escaping ([InterestPoint]) -> Void) {
        self.snapshot = snapshot; self.sourceImporter = sourceImporter; self.didSave = didSave
    }
    func load(projectURL: URL?) async throws -> TestingSnapshot { snapshot }
    func perform(_ action: TestingAction) async throws -> TestingResult {
        guard case .savePoints(let points) = action else { throw CocoaError(.featureUnsupported) }
        snapshot = TestingSnapshot(objects: snapshot.objects, commits: snapshot.commits, points: points, canEditPoints: true,
            vectors: snapshot.vectors, status: snapshot.status, log: snapshot.log, hintExtent: snapshot.hintExtent,
            rasters: snapshot.rasters, pointOwnerID: snapshot.pointOwnerID)
        didSave(points)
        return TestingResult(snapshot: snapshot, projectURL: nil)
    }
    func importPoints(_ shapefile: URL) async throws -> [InterestPoint] {
        guard let sourceImporter else { throw CocoaError(.featureUnsupported) }
        return try await sourceImporter.importPoints(shapefile)
    }
}

struct TestingUploader: View {
    @ObservedObject var store: WorkspaceStore
    let kind: ToolKind
    @StateObject private var session: TestingUploadSession
    @State private var pointSession: TestingSession?
    @State private var showPoints = false
    init(store: WorkspaceStore, kind: ToolKind) {
        self.store = store; self.kind = kind
        _session = StateObject(wrappedValue: TestingUploadSession(provider: store.testingUploadProvider, kind: kind))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(verbatim: kind.localizedTitle).font(.title2); Spacer() }.padding(20)
            Divider()
            Form {
                Section("Source") {
                    LabeledContent("File", value: session.snapshot?.sourceURL?.path ?? "—").textSelection(.enabled)
                    HStack {
                        Button("Use Current Project") { Task { await session.prepare(sourceURL: store.document?.url) } }.disabled(store.document?.url == nil)
                        Button("Browse…") { browse() }
                    }.disabled(!session.available || session.busy)
                    if kind == .testingGeometryUpload {
                        Picker("Geometry", selection: $session.selectedGeometry) {
                            Text("From File").tag(nil as String?)
                            ForEach(session.snapshot?.geometries ?? []) { Text($0.title).tag(Optional($0.id)) }
                        }
                        .onChange(of: session.selectedGeometry) { _, id in session.selectGeometry(id) }
                    }
                }
                Section("Upload Details") {
                    TextField("Upload Name", text: $session.name).disabled(session.snapshot?.serverObjectID != nil)
                    TextField("Upload Folder", text: $session.folder)
                    TextEditor(text: $session.description).frame(minHeight: 80).accessibilityLabel("Upload Description")
                    if !session.name.isEmpty {
                        if session.pointsOnly { Text("Editing the server project’s POIs; project files are preserved.").foregroundStyle(.secondary) }
                        else if session.snapshot?.serverObjectID != nil || session.snapshot?.existingNames.contains(session.name) == true {
                            Text("This upload replaces existing content; history remains under the same entry.").foregroundStyle(.orange)
                        } else { Text("A new entry will be created in the testing repository.").foregroundStyle(.secondary) }
                    }
                }
                if !session.pointsOnly {
                    Section("Run on Server") {
                        Toggle("Queue Run", isOn: $session.queueRunAfterUpload)
                        if session.queueRunAfterUpload {
                            HStack {
                                TextField("Commit", text: $session.runCommit, prompt: Text("Paste a commit hash"))
                                Menu("Recent Commits") {
                                    ForEach(session.snapshot?.commits ?? []) { commit in
                                        Button(commit.title) { session.runCommit = commit.id }
                                    }
                                }
                            }
                            TextField("Run Tag", text: $session.runTag)
                            Stepper(value: $session.runIterations, in: 1...20) {
                                LabeledContent("Iterations", value: session.runIterations.formatted())
                            }
                        }
                    }
                }
                if kind == .testingProjectUpload {
                    Section("Plans") {
                        Button("Select / Deselect All", action: session.toggleAllPlans)
                        ForEach(session.snapshot?.plans ?? []) { plan in
                            VStack(alignment: .leading, spacing: 4) {
                                Toggle(plan.name, isOn: Binding(get: { session.selectedPlans.contains(plan.id) }, set: { if $0 { session.selectedPlans.insert(plan.id) } else { session.selectedPlans.remove(plan.id) } })).disabled(!plan.exportable)
                                if plan.geometry == nil { Label("No geometry attached — can’t export.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                                else if plan.boundaryCondition == nil { Label("No boundary condition attached — can’t export.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                                else { Text([plan.geometry, plan.boundaryCondition].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    Section("Points of Interest") {
                        LabeledContent("Points", value: session.points.count.formatted())
                        Button("Edit POIs…", action: editPoints).disabled(session.snapshot?.pointEditor == nil)
                    }
                }
            }.formStyle(.grouped).disabled(session.busy)
            Divider()
            HStack {
                if session.busy { ProgressView(value: session.progress, total: 100).frame(width: 140) }
                Text(session.message).font(.caption).lineLimit(2)
                Spacer()
                Button(session.uploadCompleted ? "Done" : "Cancel") { store.activeTool = nil }
                    .keyboardShortcut(.cancelAction).disabled(session.busy && !session.canCancelUpload)
                Button(LocalizedStringKey(session.uploadCompleted ? "Done" : (session.pointsOnly ? "Save POIs" : "Upload"))) {
                    if session.uploadCompleted { store.activeTool = nil }
                    else { Task { _ = await session.upload() } }
                }.keyboardShortcut(.defaultAction).disabled(!session.uploadCompleted && !session.canUpload)
            }.padding(16)
        }.frame(width: 780, height: 740)
            .task { await session.prepare(sourceURL: store.document?.url) }
            .onDisappear { session.invalidate() }
            .dropDestination(for: URL.self) { urls, _ in
                guard session.available, !session.busy, let url = urls.first, url.isFileURL else { return false }
                Task { await session.prepare(sourceURL: url) }; return true
            }
            .alert("HEC-RAS 2025", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
                Button("OK") { session.error = nil }
            } message: { Text(session.error ?? "") }
            .sheet(isPresented: $showPoints) {
                if let pointSession { TestingWorkspace(store: store, initialPage: .testingPOI, session: pointSession, title: L10n.format("POIs — %@", session.name)) { showPoints = false } }
            }
    }
    private func browse() {
        let file = kind == .testingProjectUpload ? store.system.chooseProject() : store.system.chooseConnectionFile()
        if let file { Task { await session.prepare(sourceURL: file) } }
    }
    private func editPoints() {
        guard var snapshot = session.snapshot?.pointEditor else { return }
        snapshot = TestingSnapshot(objects: snapshot.objects, commits: snapshot.commits, points: session.points, canEditPoints: true,
            vectors: snapshot.vectors, status: snapshot.status, log: snapshot.log, hintExtent: snapshot.hintExtent,
            rasters: snapshot.rasters, pointOwnerID: snapshot.pointOwnerID)
        let draft = UploadPointDraft(snapshot: snapshot, sourceImporter: store.testingProvider) { session.setPoints($0) }
        pointSession = TestingSession(provider: draft); showPoints = true
    }
}
