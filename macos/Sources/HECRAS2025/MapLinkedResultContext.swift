import Combine
import CryptoKit
import Foundation
import RASWorkspaceCore

/// Identity captured from the exact saved Result selection slot in the owning
/// map. Labels are presentation only; path, content revision, source token,
/// project session, and map workflow identity guard every asynchronous step.
struct MapLinkedResultCapture: Hashable, Sendable, Identifiable {
    let projectSessionID: UUID
    let mapID: UUID
    let mapWorkflowIdentity: String
    let projectPath: String
    let projectXML: String
    let projectXMLSHA: String
    let contextToken: String
    let sourceIdentity: String
    let resultNodeIdentity: String
    let selectionIndex: Int
    let anchorPath: String
    let anchorRevision: String
    let coreLayerContext: CoreLayerRequestContext?

    init(projectSessionID: UUID, mapID: UUID, mapWorkflowIdentity: String,
         projectPath: URL, projectXML: String, contextToken: String,
         sourceIdentity: String, resultNodeIdentity: String, selectionIndex: Int,
         anchorPath: String, anchorRevision: String,
         coreLayerContext: CoreLayerRequestContext? = nil) throws {
        guard !mapWorkflowIdentity.isEmpty, !contextToken.isEmpty, !sourceIdentity.isEmpty,
              !resultNodeIdentity.isEmpty, selectionIndex >= 0, !anchorRevision.isEmpty else {
            throw BackendServiceError(code: "invalidInput", message: "Choose an exact saved Result map slot before linking plans.")
        }
        self.projectSessionID = projectSessionID
        self.mapID = mapID
        self.mapWorkflowIdentity = mapWorkflowIdentity
        self.projectPath = projectPath.standardizedFileURL.path
        self.projectXML = projectXML
        self.projectXMLSHA = Self.sha256(Data(projectXML.utf8))
        self.contextToken = contextToken
        self.sourceIdentity = sourceIdentity
        self.resultNodeIdentity = resultNodeIdentity
        self.selectionIndex = selectionIndex
        self.anchorPath = Self.canonical(anchorPath)
        self.anchorRevision = anchorRevision
        self.coreLayerContext = coreLayerContext
    }

    var id: String {
        let value = [projectSessionID.uuidString, mapID.uuidString, mapWorkflowIdentity,
            projectPath, projectXMLSHA, contextToken, sourceIdentity, resultNodeIdentity,
            String(selectionIndex), anchorPath, anchorRevision,
            coreLayerContext?.identityToken ?? ""].joined(separator: "\n")
        return Self.sha256(Data(value.utf8))
    }

    var sourceContextIdentity: String { "linked-results|\(mapID.uuidString)|\(id)" }

    func matches(projectSessionID currentProjectSessionID: UUID,
                 mapWorkflowIdentity currentMapWorkflowIdentity: String,
                 projectPath currentProjectPath: URL?, projectXML currentProjectXML: String?,
                 sourceIdentity currentSourceIdentity: String,
                 coreLayerContext currentCoreLayerContext: CoreLayerRequestContext?,
                 sources: MapResultSourcesSnapshot?) -> Bool {
        guard currentProjectSessionID == projectSessionID,
              currentMapWorkflowIdentity == mapWorkflowIdentity,
              let currentProjectPath,
              Self.canonical(currentProjectPath.standardizedFileURL.path) == Self.canonical(projectPath),
              let currentProjectXML,
              Self.sha256(Data(currentProjectXML.utf8)) == projectXMLSHA,
              currentCoreLayerContext == coreLayerContext,
              currentSourceIdentity == sourceIdentity,
              let sources,
              sources.sources.contextToken == contextToken,
              sources.sources.mapID.caseInsensitiveCompare(mapID.uuidString) == .orderedSame,
              let node = sources.sources.activeNodes.first(where: { $0.id == resultNodeIdentity }),
              let slot = node.selections.first(where: { $0.selectionIndex == selectionIndex }),
              let selected = slot.selectedResult else { return false }
        return Self.canonical(selected.resultPath) == anchorPath
            && selected.revision.caseInsensitiveCompare(anchorRevision) == .orderedSame
            && !selected.isComputing
    }

    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum MapLinkedResultSelectionBuilder {
    static func build(context: ResultPlanContextSnapshot, capture: MapLinkedResultCapture,
                      selectedGroupIDs: Set<String>) throws -> LinkedResultSelection {
        guard !selectedGroupIDs.isEmpty,
              MapLinkedResultCapture.canonical(context.resultPath) == capture.anchorPath,
              context.revision.caseInsensitiveCompare(capture.anchorRevision) == .orderedSame,
              MapLinkedResultCapture.canonical(context.projectPath) == MapLinkedResultCapture.canonical(capture.projectPath),
              !context.projectRevision.isEmpty,
              context.anchor.resultPath == context.resultPath,
              context.anchor.revision == context.revision,
              context.candidateGroups.allSatisfy({ !$0.results.isEmpty }),
              Set(context.candidateGroups.map(\.id)).count == context.candidateGroups.count else {
            throw BackendServiceError(code: "sourceChanged", message: "The map Result selection changed. Reopen Link Plans.")
        }

        var exactPaths = Set([capture.anchorPath])
        for group in context.candidateGroups {
            guard group.hasPlan ? group.planName != nil : group.planName == nil,
                  group.results.allSatisfy({ $0.hasPlan == group.hasPlan && $0.planName == group.planName }) else {
                throw BackendServiceError(code: "protocolFailure", message: "The linked Result plan groups do not match their source identities.")
            }
            for result in group.results {
                guard !result.revision.isEmpty,
                      exactPaths.insert(MapLinkedResultCapture.canonical(result.resultPath)).inserted else {
                    throw BackendServiceError(code: "protocolFailure", message: "The linked Result groups contain an ambiguous source file.")
                }
            }
        }

        let selected = context.candidateGroups.filter { selectedGroupIDs.contains($0.id) }
        guard selected.count == selectedGroupIDs.count else {
            throw BackendServiceError(code: "sourceChanged", message: "The selected Plan groups changed. Reopen Link Plans.")
        }
        let selection = LinkedResultSelection(projectPath: context.projectPath,
            projectRevision: context.projectRevision, anchor: context.anchor,
            selectedGroups: selected, coreLayerContext: capture.coreLayerContext)
        guard selection.results.count == 1 + selected.reduce(0, { $0 + $1.results.count }) else {
            throw BackendServiceError(code: "protocolFailure", message: "The linked Result selection contains duplicate files.")
        }
        return selection
    }
}

/// Map-owned composite result context. The original .vis rows and their
/// selection overrides remain stored in MapState; this state only supplies a
/// transient synthetic context row, one common profile timeline, and the
/// source-backed linked-map layers for the same map canvas.
@MainActor
final class MapLinkedResultContextSession: ObservableObject {
    @Published private(set) var capture: MapLinkedResultCapture?
    @Published private(set) var selection: LinkedResultSelection?
    @Published private(set) var profileSnapshot: LinkedResultProfilesSnapshot?
    @Published private(set) var mapSnapshot: LinkedResultMapSnapshot?
    @Published private(set) var rasters: [MapRasterLayer] = []
    @Published private(set) var legends: [MapLegend] = []
    @Published private(set) var profileIndex = 0
    @Published private(set) var mapType: LinkedResultMapType = .depth
    @Published private(set) var frameMode: LinkedResultMapFrameMode = .profile
    @Published private(set) var isActive = false
    @Published private(set) var isProfileLoading = false
    @Published private(set) var isMapLoading = false
    @Published private(set) var profileError: String?
    @Published private(set) var mapErrorCode: String?

    let client: BackendProcessClient
    var didRetire: (@MainActor (String?) -> Void)?
    private var profileRuntime: LinkedResultProfilesSession?
    private var mapRuntime: LinkedResultMapSession?
    private var ownerIsCurrent: (@MainActor () -> Bool)?
    private var generation = 0

    init(client: BackendProcessClient) { self.client = client }

    var sourceContextIdentity: String? { capture?.sourceContextIdentity }
    var steps: [LinkedResultProfileStep] { profileSnapshot?.steps ?? [] }
    var currentStep: LinkedResultProfileStep? { steps.first { $0.profileIndex == profileIndex } }
    var sourceFrames: [LinkedResultProfileFrame] { profileSnapshot?.frames ?? [] }
    var mapSourceStatuses: [LinkedResultMapSourceStatus] { mapSnapshot?.sources ?? [] }

    func activate(_ selection: LinkedResultSelection, capture: MapLinkedResultCapture,
                  projectXML: String, viewport: RasterMapViewExtent?,
                  ownerIsCurrent: @escaping @MainActor () -> Bool) async throws -> Bool {
        guard !capture.mapWorkflowIdentity.isEmpty,
              MapLinkedResultCapture.canonical(selection.projectPath) == MapLinkedResultCapture.canonical(capture.projectPath),
              MapLinkedResultCapture.canonical(selection.anchor.resultPath) == capture.anchorPath,
              selection.anchor.revision.caseInsensitiveCompare(capture.anchorRevision) == .orderedSame,
              selection.coreLayerContext == capture.coreLayerContext,
              !selection.selectedGroups.isEmpty, ownerIsCurrent() else {
            throw BackendServiceError(code: "sourceChanged", message: "The map Result selection changed. Reopen Link Plans.")
        }

        generation += 1
        let currentGeneration = generation
        let stagedProfiles = LinkedResultProfilesSession(client: client)
        await stagedProfiles.load(selection, projectXML: projectXML, profileIndex: 0)
        guard generation == currentGeneration, !Task.isCancelled, ownerIsCurrent() else {
            stagedProfiles.cancel()
            if !Task.isCancelled { throw BackendServiceError(code: "sourceChanged", message: "The map Result context changed while linking.") }
            return false
        }
        guard let stagedProfileSnapshot = stagedProfiles.snapshot else {
            throw BackendServiceError(code: "requestFailed",
                message: stagedProfiles.error ?? L10n.text("The shared Result profile could not be loaded."))
        }

        let stagedMap = LinkedResultMapSession(client: client)
        await stagedMap.render(selection, projectXML: projectXML, profileIndex: 0,
            mapType: mapType, frameMode: .profile, viewport: viewport)
        guard generation == currentGeneration, !Task.isCancelled, ownerIsCurrent() else {
            stagedProfiles.cancel(); stagedMap.cancel()
            if !Task.isCancelled { throw BackendServiceError(code: "sourceChanged", message: "The map Result context changed while linking.") }
            return false
        }

        profileRuntime?.cancel(); mapRuntime?.cancel()
        profileRuntime = stagedProfiles
        mapRuntime = stagedMap
        self.capture = capture
        self.selection = selection
        profileSnapshot = stagedProfileSnapshot
        mapSnapshot = stagedMap.snapshot
        rasters = stagedMap.rasters
        legends = Self.makeLegends(from: stagedMap.snapshot)
        profileIndex = 0
        frameMode = .profile
        profileError = nil
        mapErrorCode = stagedMap.errorCode
        self.ownerIsCurrent = ownerIsCurrent
        isActive = true
        return true
    }

    func selectProfile(_ index: Int, viewport: RasterMapViewExtent?) async {
        guard isActive, steps.contains(where: { $0.profileIndex == index }),
              let selection, let capture, let profileRuntime else { return }
        guard ownerIsCurrent?() == true else { retire(); return }
        generation += 1
        let currentGeneration = generation
        profileIndex = index
        frameMode = .profile
        isProfileLoading = true
        profileError = nil
        await profileRuntime.load(selection, projectXML: capture.projectXML, profileIndex: index)
        guard generation == currentGeneration, isActive else { return }
        guard ownerIsCurrent?() == true else { retire(); return }
        isProfileLoading = false
        guard let loaded = profileRuntime.snapshot else {
            profileSnapshot = nil
            profileError = profileRuntime.error ?? L10n.text("The shared Result profile could not be loaded.")
            clearRenderedMap()
            return
        }
        profileSnapshot = loaded
        await renderMap(viewport: viewport)
    }

    func renderMap(viewport: RasterMapViewExtent?) async {
        guard isActive, let selection, let capture, let mapRuntime else { return }
        guard ownerIsCurrent?() == true else { retire(); return }
        generation += 1
        let currentGeneration = generation
        isMapLoading = true
        mapErrorCode = nil
        mapSnapshot = nil
        rasters = []
        legends = []
        await mapRuntime.render(selection, projectXML: capture.projectXML,
            profileIndex: profileIndex, mapType: mapType, frameMode: frameMode,
            viewport: viewport)
        guard generation == currentGeneration, isActive else { return }
        guard ownerIsCurrent?() == true else { retire(); return }
        isMapLoading = false
        mapSnapshot = mapRuntime.snapshot
        rasters = mapRuntime.rasters
        legends = Self.makeLegends(from: mapRuntime.snapshot)
        mapErrorCode = mapRuntime.errorCode
    }

    func retire() {
        guard isActive || capture != nil else { return }
        generation += 1
        let identity = sourceContextIdentity
        profileRuntime?.cancel(); mapRuntime?.cancel()
        profileRuntime = nil; mapRuntime = nil; ownerIsCurrent = nil
        capture = nil; selection = nil; profileSnapshot = nil; mapSnapshot = nil
        rasters = []; legends = []; profileIndex = 0
        mapType = .depth; frameMode = .profile
        isProfileLoading = false; isMapLoading = false
        profileError = nil; mapErrorCode = nil; isActive = false
        didRetire?(identity)
    }

    private func clearRenderedMap() {
        mapRuntime?.cancel()
        mapSnapshot = nil; rasters = []; legends = []; mapErrorCode = nil
        isMapLoading = false
    }

    func setMapType(_ value: LinkedResultMapType, viewport: RasterMapViewExtent?) async {
        guard isActive, mapType != value else { return }
        mapType = value
        await renderMap(viewport: viewport)
    }

    func setFrameMode(_ value: LinkedResultMapFrameMode, viewport: RasterMapViewExtent?) async {
        guard isActive, let mapSnapshot else { return }
        if value == .maximum, !mapSnapshot.maximumAvailable { return }
        guard value == .profile || value == .maximum, frameMode != value else { return }
        frameMode = value
        await renderMap(viewport: viewport)
    }

    private static func makeLegends(from snapshot: LinkedResultMapSnapshot?) -> [MapLegend] {
        guard let snapshot else { return [] }
        return snapshot.layers.map { layer in
            let count = layer.legendStops.count
            let stops = layer.legendStops.enumerated().map { index, stop in
                MapLegend.Stop(id: "\(layer.id)|\(index)",
                    position: count <= 1 ? 1 : Double(index) / Double(count - 1),
                    color: stop.color,
                    label: stop.value.formatted(.number.precision(.significantDigits(1...4))))
            }
            return MapLegend(id: layer.id, title: layer.resultName + " · " + layer.mapType,
                units: layer.units, stops: stops)
        }
    }
}

extension MapState {
    var linkedResultSourceIdentity: String {
        guard let snapshot = resultSources.snapshot else { return "unavailable|\(id.uuidString)" }
        let source = snapshot.sources
        let overrides = snapshot.selectionOverrides.sorted {
            ($0.nodeIdentity, $0.selectionIndex) < ($1.nodeIdentity, $1.selectionIndex)
        }.map { item in
            [item.nodeIdentity, String(item.selectionIndex), item.mode.rawValue,
             item.resultPath.map(MapLinkedResultCapture.canonical) ?? "",
             item.resultRevision?.uppercased() ?? ""].joined(separator: ":")
        }.joined(separator: "\u{1e}")
        let slots = source.activeNodes.sorted { $0.id < $1.id }.flatMap { node in
            node.selections.sorted { $0.selectionIndex < $1.selectionIndex }.map { slot in
                [node.id, String(slot.selectionIndex), slot.selectionMode.rawValue,
                 slot.selectedResult.map { MapLinkedResultCapture.canonical($0.resultPath) } ?? "",
                 slot.selectedResult?.revision.uppercased() ?? "",
                 slot.selectedResult?.isComputing == true ? "running" : "saved"].joined(separator: ":")
            }
        }.joined(separator: "\u{1e}")
        return [source.contextToken, source.mapID, source.projectXmlSHA,
            source.visualizationRevision, overrides, slots].joined(separator: "|")
    }
}
