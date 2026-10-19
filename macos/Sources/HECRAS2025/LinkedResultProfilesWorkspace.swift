import Combine
import CryptoKit
import Foundation
import RASWorkspaceCore
import SwiftUI

struct LinkedResultProfileStep: Decodable, Identifiable, Sendable {
    let profileIndex: Int
    let name: String
    let time: String
    var id: Int { profileIndex }
}
struct LinkedResultProfileFrame: Decodable, Identifiable, Sendable {
    let resultPath: String
    let revision: String
    let name: String
    let outputBlockName: String?
    let profileIndex: Int?
    let nearestProfileIndex: Int?
    let time: String?
    let unavailableReason: String?
    var id: String { resultPath }
}
struct LinkedResultProfilesSnapshot: Decodable, Sendable {
    let projectPath: String
    let projectRevision: String
    let anchorPath: String
    let profileIndex: Int
    let steps: [LinkedResultProfileStep]
    let frames: [LinkedResultProfileFrame]
}
struct LinkedResultProfilesRequest: Encodable, Sendable {
    let projectPath: String
    let projectXml: String
    let projectRevision: String
    let anchor: ResultPlanCandidate
    let selectedGroups: [ResultPlanCandidateGroup]
    let profileIndex: Int
    var coreLayerContext: CoreLayerRequestContext? = nil
}

@MainActor
final class LinkedResultProfilesSession: ObservableObject {
    @Published private(set) var snapshot: LinkedResultProfilesSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private let client: BackendProcessClient
    private var generation = 0
    private var requestTask: Task<LinkedResultProfilesSnapshot, Error>?
    init(client: BackendProcessClient) { self.client = client }

    func load(_ selection: LinkedResultSelection, projectXML: String, profileIndex: Int) async {
        requestTask?.cancel()
        generation += 1
        let capture = generation
        isLoading = true; error = nil
        // A previous frame must not masquerade as the requested timestamp.
        snapshot = nil
        let request = LinkedResultProfilesRequest(projectPath: selection.projectPath,
            projectXml: projectXML, projectRevision: selection.projectRevision,
            anchor: selection.anchor, selectedGroups: selection.selectedGroups, profileIndex: profileIndex,
            coreLayerContext: selection.coreLayerContext)
        let client = self.client
        let task = Task {
            try await client.request("result.linkedProfiles", parameters: request, as: LinkedResultProfilesSnapshot.self)
        }
        requestTask = task
        defer { if generation == capture { isLoading = false; requestTask = nil } }
        do {
            let loaded = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard generation == capture, !Task.isCancelled else { return }
            try Self.validate(loaded, selection: selection, profileIndex: profileIndex)
            snapshot = loaded
        } catch {
            guard generation == capture, !Task.isCancelled, !(error is CancellationError) else { return }
            self.error = L10n.text(error.localizedDescription)
        }
    }
    static func validate(_ loaded: LinkedResultProfilesSnapshot, selection: LinkedResultSelection, profileIndex: Int) throws {
        let expected = Dictionary(selection.results.map { ($0.resultPath, $0.revision) }, uniquingKeysWith: { first, _ in first })
        guard SourceFilePaths.canonical(URL(fileURLWithPath: loaded.projectPath)) == SourceFilePaths.canonical(URL(fileURLWithPath: selection.projectPath)),
              loaded.projectRevision == selection.projectRevision, loaded.anchorPath == selection.anchor.resultPath,
              loaded.profileIndex == profileIndex,
              loaded.frames.count == expected.count, Set(loaded.frames.map(\.resultPath)).count == expected.count,
              loaded.frames.allSatisfy({ expected[$0.resultPath] == $0.revision }),
              loaded.steps.enumerated().allSatisfy({ $0.offset == $0.element.profileIndex }) else {
            throw BackendServiceError(code: "sourceChanged", message: L10n.text("The linked Result context changed. Reopen Link Plans."))
        }
        if !loaded.steps.isEmpty, !loaded.steps.indices.contains(profileIndex) {
            throw BackendServiceError(code: "invalidInput", message: L10n.text("Choose an available linked result profile."))
        }
    }
    func cancel() {
        generation += 1; requestTask?.cancel(); requestTask = nil
        isLoading = false; snapshot = nil; error = nil
    }
}

/// The accepted picker result is consumed here. One source-backed timestamp
/// request sets every selected Result's profile state; each Result retains its
/// own embedded geometry, output block, element selection and readable series.
struct LinkedResultProfilesWorkspace: View {
    let selection: LinkedResultSelection
    let projectXML: String
    let projectContextID: String
    let client: BackendProcessClient
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: LinkedResultProfilesSession
    @StateObject private var mapSession: LinkedResultMapSession
    @State private var profileIndex = 0
    @State private var mapType: LinkedResultMapType = .depth
    @State private var mapFrameMode: LinkedResultMapFrameMode = .profile
    @State private var mapViewport: RasterMapViewExtent?
    @State private var steps: [LinkedResultProfileStep] = []
    @State private var selectedResultPath: String?
    @State private var activeSelectionIdentity: String?

    init(selection: LinkedResultSelection, projectXML: String, projectContextID: String, client: BackendProcessClient) {
        self.selection = selection; self.projectXML = projectXML
        self.projectContextID = projectContextID; self.client = client
        _session = StateObject(wrappedValue: LinkedResultProfilesSession(client: client))
        _mapSession = StateObject(wrappedValue: LinkedResultMapSession(client: client))
    }
    private var selectedResult: ResultPlanCandidate { selection.results.first { $0.resultPath == selectedResultPath } ?? selection.anchor }
    private var currentFrame: LinkedResultProfileFrame? { session.snapshot?.frames.first { $0.resultPath == selectedResult.resultPath } }
    private var selectionIdentity: String {
        let xmlHash = SHA256.hash(data: Data(projectXML.utf8)).map { String(format: "%02x", $0) }.joined()
        let resultIdentity = selection.results.map {
            SourceFilePaths.canonical(URL(fileURLWithPath: $0.resultPath)) + "|" + $0.revision
        }.joined(separator: "\n")
        let groupsIdentity = selection.selectedGroups.map { group in
            let identities = group.results.map {
                SourceFilePaths.canonical(URL(fileURLWithPath: $0.resultPath)) + "|" + $0.revision
            }.joined(separator: "\n")
            return "\(group.hasPlan)|\(group.planName ?? "")|\(identities)"
        }.joined(separator: "\n--group--\n")
        return selection.projectPath + "|" + selection.projectRevision + "|" + projectContextID +
            "|" + (selection.coreLayerContext?.identityToken ?? "") +
            "|" + xmlHash + "|" + resultIdentity + "|" + groupsIdentity
    }
    private var taskIdentity: String {
        selectionIdentity + "|" + String(profileIndex)
    }
    private var mapTaskIdentity: String {
        taskIdentity + "|" + mapType.rawValue + "|" + mapFrameMode.rawValue
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(L10n.text("Linked Results"), systemImage: "link").font(.title3.bold())
                Text(selection.anchor.name).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                Button(L10n.text("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            HStack {
                Button { selectProfile(profileIndex - 1) } label: { Image(systemName: "backward.frame") }
                    .disabled(profileIndex == 0 || steps.isEmpty)
                    .accessibilityLabel(L10n.text("Previous Profile"))
                Picker(L10n.text("Profile"), selection: Binding(get: { profileIndex }, set: selectProfile)) {
                    ForEach(steps) { Text($0.name).tag($0.profileIndex) }
                }.disabled(steps.isEmpty)
                Button { selectProfile(profileIndex + 1) } label: { Image(systemName: "forward.frame") }
                    .disabled(steps.isEmpty || profileIndex >= steps.count - 1)
                    .accessibilityLabel(L10n.text("Next Profile"))
                Button { mapFrameMode = .profile } label: {
                    Label(L10n.text("Profile"), systemImage: "clock")
                }
                .disabled(mapFrameMode == .profile)
                Button { mapFrameMode = .minimum } label: {
                    Label(L10n.text("Minimum"), systemImage: "arrow.down.to.line")
                }
                .disabled(true)
                .help(L10n.text("Minimum map is unavailable for the selected Results."))
                Button { mapFrameMode = .maximum } label: {
                    Label(L10n.text("Maximum"), systemImage: "arrow.up.to.line")
                }
                .disabled(mapFrameMode == .maximum || mapSession.snapshot?.maximumAvailable != true || mapSession.isLoading)
                .help(L10n.text("Maximum map is unavailable for the selected Results."))
                if session.isLoading { ProgressView().controlSize(.small) }
                if let step = steps.first(where: { $0.profileIndex == profileIndex }) {
                    Text(step.time).font(.caption.monospaced()).textSelection(.enabled)
                }
            }.padding(.horizontal).padding(.bottom)
            if let error = session.error {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Button(L10n.text("Retry")) { Task { await session.load(selection, projectXML: projectXML, profileIndex: profileIndex) } }
                }.padding(.horizontal).padding(.bottom)
            }
            Divider()
            VSplitView {
                HSplitView {
                    List(selection.results, selection: $selectedResultPath) { result in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.name).font(.headline)
                            Text(result.hasPlan ? (result.planName ?? "") : L10n.text("(no plan)"))
                                .font(.caption).foregroundStyle(.secondary)
                            if let frame = session.snapshot?.frames.first(where: { $0.resultPath == result.resultPath }) {
                                if let time = frame.time { Text(time).font(.caption.monospaced()) }
                                if let reason = frame.unavailableReason { Text(L10n.text(reason)).font(.caption).foregroundStyle(.secondary) }
                            }
                        }.tag(result.resultPath)
                    }.listStyle(.sidebar).frame(minWidth: 200, idealWidth: 260, maxWidth: 360)
                    LinkedResultProfileDetail(result: selectedResult, frame: currentFrame,
                        projectPath: selection.projectPath, projectXML: projectXML,
                        projectContextID: projectContextID, client: client)
                        .id(selectedResult.id)
                }
                linkedMapPanel
                    .frame(minHeight: 190, idealHeight: 290)
            }
        }
        .frame(minWidth: 880, idealWidth: 1100, minHeight: 650, idealHeight: 780)
        .task(id: taskIdentity) {
            if activeSelectionIdentity != selectionIdentity {
                activeSelectionIdentity = selectionIdentity
                mapViewport = nil
                mapFrameMode = .profile
                let needsProfileReset = profileIndex != 0
                profileIndex = 0
                steps = []
                selectedResultPath = nil
                if needsProfileReset { return }
            }
            await session.load(selection, projectXML: projectXML, profileIndex: profileIndex)
            if let snapshot = session.snapshot { steps = snapshot.steps }
        }
        .onDisappear { session.cancel(); mapSession.cancel() }
    }

    private var linkedMapPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L10n.text("Shared Result Map"), systemImage: "map")
                    .font(.headline)
                Picker(L10n.text("Map Type"), selection: $mapType) {
                    ForEach(LinkedResultMapType.allCases) { type in
                        Text(L10n.text(type.labelKey)).tag(type)
                    }
                }
                .frame(width: 190)
                Spacer()
                if mapSession.isLoading {
                    ProgressView(L10n.text("Rendering linked Result map…"))
                        .controlSize(.small)
                } else if let errorCode = mapSession.errorCode {
                    Text(mapErrorText(errorCode)).foregroundStyle(.red).font(.caption)
                } else if let snapshot = mapSession.snapshot, mapSession.rasters.isEmpty {
                    Text(mapErrorText(snapshot.unavailableReason ?? "noMapData"))
                        .foregroundStyle(.secondary).font(.caption)
                } else if mapSession.snapshot?.sources.contains(where: { !$0.available }) == true {
                    Text(L10n.text("Some linked Results have no map data for this frame."))
                        .foregroundStyle(.secondary).font(.caption)
                }
            }
            if mapSession.rasters.isEmpty {
                ContentUnavailableView(L10n.text("No linked Result map is available for this frame."),
                    systemImage: "map")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                RasterCanvas(layers: mapSession.rasters,
                    points: mapSession.rasters.flatMap(\.points), scale: 1,
                    offset: .zero, revision: mapSession.renderRevision)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(10)
        .task(id: mapTaskIdentity) {
            await mapSession.render(selection, projectXML: projectXML,
                profileIndex: profileIndex, mapType: mapType,
                frameMode: mapFrameMode, viewport: mapViewport)
            if let viewport = mapSession.snapshot?.viewport { mapViewport = viewport }
        }
    }

    private func selectProfile(_ index: Int) {
        guard steps.indices.contains(index) else { return }
        profileIndex = index
        mapFrameMode = .profile
    }

    private func mapErrorText(_ code: String) -> String {
        switch code {
        case "minimumUnavailable": L10n.text("Minimum map is unavailable for the selected Results.")
        case "maximumUnavailable": L10n.text("Maximum map is unavailable for the selected Results.")
        case "noProfileFrames": L10n.text("No profile frames are available for the anchor Result.")
        case "noMatchingFrame": L10n.text("This Result has no matching profile within the 10 ms MultiResult timestamp tolerance.")
        case "noAssociatedTerrain", "terrainUnavailable": L10n.text("An associated terrain source is missing or unsupported.")
        case "renderUnavailable": L10n.text("The map renderer could not produce data for this Result.")
        case "noMapData": L10n.text("No map data is available for this Result and frame.")
        case "mapTypeUnsupported": L10n.text("Select a supported map type.")
        default: L10n.text("Unable to render the linked Result map.")
        }
    }
}

private struct LinkedResultProfileDetail: View {
    let result: ResultPlanCandidate
    let frame: LinkedResultProfileFrame?
    let projectPath: String
    let projectXML: String
    let projectContextID: String
    @StateObject private var profiles: ResultProfileSession
    init(result: ResultPlanCandidate, frame: LinkedResultProfileFrame?, projectPath: String,
         projectXML: String, projectContextID: String, client: BackendProcessClient) {
        self.result = result; self.frame = frame; self.projectPath = projectPath
        self.projectXML = projectXML; self.projectContextID = projectContextID
        _profiles = StateObject(wrappedValue: ResultProfileSession(provider: BackendResultProfileProvider(client: client)))
    }
    private var currentPoint: ResultProfilePoint? {
        guard let frame, let index = frame.profileIndex, let series = profiles.series,
              series.outputBlockName == frame.outputBlockName else { return nil }
        return series.points.first { $0.profileIndex == index }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let reason = frame?.unavailableReason {
                    Label(L10n.text(reason), systemImage: "clock.badge.questionmark").foregroundStyle(.secondary).padding()
                } else if let frame, let index = frame.profileIndex {
                    HStack {
                        LabeledContent(L10n.text("Profile"), value: String(index))
                        if let time = frame.time { Text(time).font(.caption.monospaced()).textSelection(.enabled) }
                        if let point = currentPoint {
                            Text(point.value.map { String(format: "%.8g", $0) } ?? L10n.text("No Data"))
                            Text(profiles.series?.units ?? "").foregroundStyle(.secondary)
                        }
                    }.padding()
                }
                ResultProfilePanel(identity: .init(resultPath: result.resultPath, revision: result.revision),
                    projectPath: projectPath, projectXML: projectXML,
                    projectContextID: projectContextID, session: profiles)
            }
        }
        .task(id: profiles.selection) {
            if profiles.selection != nil { await profiles.readSelectedSeries() }
        }
        .onDisappear { profiles.clear() }
    }
}
