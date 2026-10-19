import Combine
import Foundation
import RASWorkspaceCore

/// A per-saved-map runtime control and exact Result-profile read session.
/// Particle controls do not mutate .vis or HDF; a new MapState starts disabled
/// with the retained VelocityScalar default.
@MainActor
final class StoredCulvertProfileSession: ObservableObject {
    @Published private(set) var capture: StoredCulvertProfileCapture?
    @Published private(set) var snapshot: MapResultCulvertProfileSnapshot?
    @Published private(set) var selectedProfileIndex: Int?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var renderRevision: UInt64 = 0
    @Published private(set) var animationEpoch = Date()
    @Published var isAnimationEnabled = false {
        didSet {
            if oldValue != isAnimationEnabled {
                if isAnimationEnabled { animationEpoch = Date() }
                renderRevision &+= 1
            }
        }
    }
    @Published var velocityScalar = 25.0 {
        didSet {
            let clamped = Self.clampVelocityScalar(velocityScalar)
            if velocityScalar != clamped { velocityScalar = clamped }
            if oldValue != velocityScalar { renderRevision &+= 1 }
        }
    }

    private var provider: (any StoredCulvertProfileProvider)?
    private var timelineSubscription: AnyCancellable?
    private var currentOwnerCheck: (@MainActor () -> Bool)?
    private var loadTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    var sourceContextIdentity: String? { capture?.sourceContextIdentity }
    var isConfigured: Bool { capture != nil && provider != nil }
    var canAnimate: Bool {
        guard let snapshot, snapshot.geometryAvailable, snapshot.outputAvailable,
              snapshot.barrels.count == snapshot.flow.count,
              snapshot.flow.count == snapshot.outletVelocity.count,
              snapshot.outsideDepth.count == snapshot.flow.count * 2 else { return false }
        return snapshot.barrels.allSatisfy { $0.coordinates.count >= 2 }
    }
    /// Geometry points are valid camera references even when the selected
    /// output profile has no stored culvert arrays.
    var visiblePoints: [MapPoint] {
        guard snapshot?.geometryAvailable == true else { return [] }
        return (snapshot?.barrels ?? []).flatMap(\.coordinates)
            .filter { $0.x.isFinite && $0.y.isFinite }
            .map { MapPoint(x: $0.x, y: $0.y) }
    }
    var currentProfileName: String? {
        guard let snapshot, snapshot.profileNames.indices.contains(snapshot.profileIndex) else { return nil }
        return snapshot.profileNames[snapshot.profileIndex]
    }
    var diagnostic: String? { errorMessage ?? snapshot?.diagnostic }

    func configure(capture newCapture: StoredCulvertProfileCapture,
                   provider newProvider: any StoredCulvertProfileProvider,
                   timeline: MapProfileSession?,
                   isCurrent: @escaping @MainActor () -> Bool) {
        let ownerChanged = capture?.identity != newCapture.identity
        if ownerChanged {
            generation &+= 1
            loadTask?.cancel()
            loadTask = nil
            snapshot = nil
            selectedProfileIndex = nil
            isLoading = false
            errorMessage = nil
            renderRevision &+= 1
        }

        capture = newCapture
        provider = newProvider
        currentOwnerCheck = isCurrent
        timelineSubscription?.cancel()
        timelineSubscription = nil
        if let timeline {
            timelineSubscription = timeline.$currentID.dropFirst().sink { [weak self] profileIndex in
                guard let profileIndex else { return }
                Task { @MainActor [weak self] in self?.load(profileIndex: profileIndex) }
            }
        }

        let target = timeline?.currentID ?? newCapture.initialProfileIndex
        guard ownerChanged || selectedProfileIndex != target else { return }
        load(profileIndex: target)
    }

    func load(profileIndex: Int) {
        guard profileIndex >= 0,
              let capture, let provider,
              currentOwnerCheck?() == true else {
            if capture != nil {
                errorMessage = L10n.text(StoredCulvertProfileError.staleContext.localizedDescription)
                snapshot = nil
                selectedProfileIndex = nil
                renderRevision &+= 1
            }
            return
        }
        if snapshot?.profileIndex == profileIndex, !isLoading { return }

        generation &+= 1
        let requestGeneration = generation
        let requestCapture = capture
        loadTask?.cancel()
        snapshot = nil
        selectedProfileIndex = nil
        errorMessage = nil
        isLoading = true
        renderRevision &+= 1
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.performLoad(profileIndex: profileIndex,
                capture: requestCapture, provider: provider,
                generation: requestGeneration)
        }
    }

    private func performLoad(profileIndex: Int,
                             capture requestCapture: StoredCulvertProfileCapture,
                             provider: any StoredCulvertProfileProvider,
                             generation requestGeneration: UInt64) async {
        defer {
            if requestGeneration == generation {
                loadTask = nil
                isLoading = false
            }
        }
        do {
            let value = try await provider.load(capture: requestCapture, profileIndex: profileIndex)
            guard !Task.isCancelled,
                  requestGeneration == generation,
                  capture?.identity == requestCapture.identity,
                  currentOwnerCheck?() == true else { return }
            snapshot = value
            selectedProfileIndex = value.profileIndex
            animationEpoch = Date()
            renderRevision &+= 1
        } catch {
            guard !Task.isCancelled,
                  requestGeneration == generation,
                  capture?.identity == requestCapture.identity,
                  currentOwnerCheck?() == true else { return }
            errorMessage = L10n.text(error.localizedDescription)
            renderRevision &+= 1
        }
    }

    /// Call when a map is removed or its project owner is discarded. Changing
    /// a Result within the same map reconfigures the source but deliberately
    /// preserves this map's runtime enable/scalar settings.
    func invalidate() {
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
        timelineSubscription?.cancel()
        timelineSubscription = nil
        currentOwnerCheck = nil
        provider = nil
        capture = nil
        snapshot = nil
        selectedProfileIndex = nil
        isLoading = false
        errorMessage = nil
        renderRevision &+= 1
    }

    nonisolated static func clampVelocityScalar(_ value: Double) -> Double {
        guard value.isFinite else { return 25 }
        return min(max(value, 1), 1_000)
    }
}
