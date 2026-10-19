import Foundation
import RASWorkspaceCore
import SwiftUI

private struct MapParticleRandomNumberGenerator: RandomNumberGenerator {
    var source: any RandomNumberGenerator
    mutating func next() -> UInt64 { source.next() }
}

typealias MapResultVelocityFieldSampler = @MainActor
    (_ requestID: String, _ profileIndex: Int, _ profileTime: String?,
     _ viewport: RasterMapViewExtent) async throws -> MapResultVelocityGrid

struct MapResultVelocityParticleTargetIdentity: Equatable {
    let sourceKind: MapVelocityFieldSourceKind
    let targetID: String?
    let sourceGeneration: Int
    let projectSessionID: UUID
    let mapID: UUID
    let contextToken: String
    let nodeID: String
    let node: CatalogTreeNodeLocator
    let resultPath: String?
    let resultRevision: String?
    let runID: String?
    let profileIndex: Int
    let profileName: String
    let time: String
    let viewport: RasterMapViewExtent

    init(sourceKind: MapVelocityFieldSourceKind = .result, targetID: String? = nil,
         sourceGeneration: Int, projectSessionID: UUID, mapID: UUID,
         contextToken: String, nodeID: String, node: CatalogTreeNodeLocator,
         resultPath: String?, resultRevision: String?, runID: String? = nil,
         profileIndex: Int, profileName: String, time: String,
         viewport: RasterMapViewExtent) {
        self.sourceKind = sourceKind
        self.targetID = targetID
        self.sourceGeneration = sourceGeneration
        self.projectSessionID = projectSessionID
        self.mapID = mapID
        self.contextToken = contextToken
        self.nodeID = nodeID
        self.node = node
        self.resultPath = resultPath
        self.resultRevision = resultRevision
        self.runID = runID
        self.profileIndex = profileIndex
        self.profileName = profileName
        self.time = time
        self.viewport = viewport
    }

    func replacing(profileIndex: Int, profileName: String, time: String) -> Self {
        Self(sourceKind: sourceKind, targetID: targetID, sourceGeneration: sourceGeneration,
            projectSessionID: projectSessionID, mapID: mapID, contextToken: contextToken,
            nodeID: nodeID, node: node, resultPath: resultPath, resultRevision: resultRevision,
            runID: runID, profileIndex: profileIndex, profileName: profileName,
            time: time, viewport: viewport)
    }
}

struct MapResultVelocityParticleTarget {
    let identity: MapResultVelocityParticleTargetIdentity
    let sample: MapResultVelocityFieldSampler
}

struct MapResultVelocityParticleSettings: Equatable {
    var isEnabled = false
    var velocityMode = ParticleVelocityModeOption.perPixel
    var velocityScalar = 25.0
    var maxParticleLifetime = 0.5
    var maxParticles = 2_500
}

struct MapResultVelocityParticleTrace {
    let lastPosition: MapPoint
    let position: MapPoint
    let lineWidth: CGFloat
    let opacity: Double
}

@MainActor
final class MapResultVelocityParticleSession: ObservableObject {
    private enum SampleState {
        case unavailable(String)
        case idle
        case loading
        case ready
        case empty
        case failed(String)
    }

    private struct Particle {
        var x = 0.0
        var y = 0.0
        var lastX = 0.0
        var lastY = 0.0
        var lifetime = 0.0
        var isAlive = false
    }

    @Published var settings = MapResultVelocityParticleSettings() {
        didSet { settingsDidChange(from: oldValue) }
    }
    @Published private(set) var profileOptions: [MapVelocityParticleProfile] = []
    @Published private(set) var renderRevision = 0

    private(set) var grid: MapResultVelocityGrid?
    private var state: SampleState = .idle
    private var target: MapResultVelocityParticleTarget?
    private var streamingTargetIdentity: MapResultVelocityParticleTargetIdentity?
    private var requestTask: Task<Void, Never>?
    private var requestGeneration = 0
    private var particles: [Particle] = []
    private var lastAdvance: Date?
    private var fieldReceivedAt: Date?
    private var transitionStartedAt: Date?
    private var transitionTraces: [MapResultVelocityParticleTrace] = []
    private var lastPresentedTraces: [MapResultVelocityParticleTrace] = []
    private var trailFrames: [(date: Date, traces: [MapResultVelocityParticleTrace])] = []
    private var lastTrailFrameAt: Date?
    private var pendingParticleResizeAt: Date?
    private var random: MapParticleRandomNumberGenerator
    var targetConfigurationDidChange: (@MainActor () -> Void)?

    init(random: any RandomNumberGenerator = SystemRandomNumberGenerator()) {
        self.random = MapParticleRandomNumberGenerator(source: random)
    }

    var canEnable: Bool { target != nil || streamingTargetIdentity != nil }
    var canSelectWindProfile: Bool {
        target?.identity.sourceKind == .wind && profileOptions.count > 1
    }
    var selectedProfileIndex: Int? { target?.identity.profileIndex ?? streamingTargetIdentity?.profileIndex }
    var selectedSourceKind: MapVelocityFieldSourceKind? { target?.identity.sourceKind ?? streamingTargetIdentity?.sourceKind }

    /// Returns the user's current Wind profile only when it still belongs to
    /// this exact Wind child, map context, and Boundary Condition revision.
    /// The caller performs the stronger map-workflow/project-session check.
    func selectedWindProfile(matching source: MapWindVelocityParticleSource)
        -> (index: Int, time: String?)? {
        guard let identity = target?.identity,
              identity.sourceKind == .wind,
              identity.projectSessionID == source.projectSessionID,
              UUID(uuidString: source.map.mapID) == identity.mapID,
              identity.contextToken == source.contextToken,
              identity.nodeID == source.selectionIdentity,
              identity.node == source.windNode,
              identity.node.sourceIdentity == source.windNode.sourceIdentity,
              let resultPath = identity.resultPath,
              SourceFilePaths.canonical(URL(fileURLWithPath: resultPath))
                == SourceFilePaths.canonical(URL(fileURLWithPath: source.boundaryPath)),
              let resultRevision = identity.resultRevision,
              resultRevision.caseInsensitiveCompare(source.boundaryRevision) == .orderedSame else {
            return nil
        }
        if !profileOptions.isEmpty,
           !profileOptions.contains(where: { $0.index == identity.profileIndex }) {
            return nil
        }
        let time = profileOptions.first(where: { $0.index == identity.profileIndex })?.time
            ?? (identity.time.isEmpty ? nil : identity.time)
        return (identity.profileIndex, time)
    }

    var isSampling: Bool { if case .loading = state { true } else { false } }
    var statusMessage: String? {
        switch state {
        case .unavailable(let message), .failed(let message): message
        case .loading:
            switch target?.identity.sourceKind ?? streamingTargetIdentity?.sourceKind {
            case .wind: L10n.text("Sampling Wind velocity…")
            case .liveResult: L10n.text("Sampling live Result velocity…")
            default: L10n.text("Sampling Result velocity…")
            }
        case .empty: L10n.text("No valid velocity cells are visible in this viewport.")
        case .idle, .ready: nil
        }
    }

    func setTarget(_ target: MapResultVelocityParticleTarget?, unavailableMessage: String? = nil) {
        if target?.identity.sourceKind != .liveResult { streamingTargetIdentity = nil }
        guard self.target?.identity != target?.identity else {
            if let target { self.target = target }
            else if let unavailableMessage {
                state = .unavailable(L10n.text(unavailableMessage))
                renderRevision &+= 1
            }
            return
        }
        if !Self.sameWindSource(self.target?.identity, target?.identity) {
            profileOptions = []
        }
        beginOverlayTransition(at: Date())
        requestGeneration &+= 1
        requestTask?.cancel(); requestTask = nil
        self.target = target
        grid = nil
        particles = []
        lastAdvance = nil
        fieldReceivedAt = nil
        renderRevision &+= 1
        if let target {
            state = .idle
            if settings.isEnabled { sample(target) }
        } else if let unavailableMessage {
            state = .unavailable(L10n.text(unavailableMessage))
        } else {
            state = .idle
        }
    }

    func invalidate(unavailableMessage: String? = nil) {
        setTarget(nil, unavailableMessage: unavailableMessage)
    }

    func toggleEnabled() { setEnabled(!settings.isEnabled) }

    func setEnabled(_ enabled: Bool) {
        guard enabled == settings.isEnabled else {
            settings.isEnabled = enabled
            return
        }
    }

    func setVelocityMode(_ mode: ParticleVelocityModeOption) {
        settings.velocityMode = mode
    }

    func setVelocityScalar(_ value: Double) {
        guard value.isFinite, value > 0 else {
            state = .failed(L10n.text("Velocity scalar must be finite and greater than zero."))
            renderRevision &+= 1
            return
        }
        settings.velocityScalar = value
        restoreValidationErrorIfPossible()
    }

    func setMaximumLifetime(_ value: Double) {
        guard value.isFinite, value > 0 else {
            state = .failed(L10n.text("Particle lifetime must be finite and greater than zero."))
            renderRevision &+= 1
            return
        }
        settings.maxParticleLifetime = value
        restoreValidationErrorIfPossible()
    }

    func setMaximumParticles(_ value: Int) {
        guard (1...10_000).contains(value) else {
            state = .failed(L10n.text("The native map accepts between 1 and 10,000 particles."))
            renderRevision &+= 1
            return
        }
        settings.maxParticles = value
        restoreValidationErrorIfPossible()
    }

    func setProfileOptions(_ options: [MapVelocityParticleProfile]) {
        let valid = options.sorted { $0.index < $1.index }
        guard Set(valid.map(\.index)).count == valid.count,
              valid.allSatisfy({ $0.index >= 0 && !$0.time.isEmpty }) else { return }
        profileOptions = valid
    }

    func selectWindProfile(_ index: Int) {
        guard let target, target.identity.sourceKind == .wind,
              let profile = profileOptions.first(where: { $0.index == index }),
              target.identity.profileIndex != index else { return }
        let identity = target.identity.replacing(profileIndex: index,
            profileName: profile.time, time: profile.time)
        setTarget(MapResultVelocityParticleTarget(identity: identity, sample: target.sample))
    }

    func refresh() {
        guard settings.isEnabled, let target else { return }
        sample(target)
    }

    func advance(at date: Date) -> [MapResultVelocityParticleTrace] {
        let transition = currentTransitionTraces(at: date)
        guard settings.isEnabled, case .ready = state, let grid,
              grid.width > 0, grid.height > 0,
              settings.maxParticleLifetime.isFinite, settings.maxParticleLifetime > 0,
              settings.velocityScalar.isFinite, settings.velocityScalar > 0 else { return transition }

        if let pendingParticleResizeAt, date.timeIntervalSince(pendingParticleResizeAt) >= 0.5 {
            self.pendingParticleResizeAt = nil
            resizeParticleBuffer(to: settings.maxParticles)
            if let target { sample(target) }
            return transition
        }

        let elapsed = lastAdvance.map { date.timeIntervalSince($0) } ?? (1.0 / 60.0)
        let delta = min(max(elapsed.isFinite ? elapsed : 0, 0), 0.05)
        lastAdvance = date
        if particles.isEmpty { resizeParticleBuffer(to: settings.maxParticles) }

        let spawnCount = min(particles.count,
            Int(ceil(Double(particles.count) * 0.025 * delta * 60)))
        var spawned = 0
        for index in particles.indices where !particles[index].isAlive && spawned < spawnCount {
            particles[index] = Particle(x: Double.random(in: 0..<Double(grid.width), using: &random),
                y: Double.random(in: 0..<Double(grid.height), using: &random), isAlive: true)
            spawned += 1
        }

        let pixelScale = settings.velocityMode == .perDistance ? 1 / grid.cellSize : 1
        for index in particles.indices where particles[index].isAlive {
            if particles[index].lifetime > settings.maxParticleLifetime {
                particles[index].isAlive = false
                continue
            }
            let positionX = particles[index].x, positionY = particles[index].y
            guard positionX.isFinite, positionY.isFinite,
                  positionX >= 0, positionY >= 0,
                  positionX < Double(grid.width), positionY < Double(grid.height) else {
                particles[index].isAlive = false
                continue
            }
            let x = Int(positionX), y = Int(positionY)
            let cell = y * grid.width + x
            let magnitude = grid.magnitude[cell]
            let vx = grid.velocityX[cell], vy = grid.velocityY[cell]
            guard vx.isFinite, vy.isFinite, magnitude.isFinite,
                  grid.noDataValue.map({ magnitude != $0 }) ?? true,
                  magnitude >= 1e-5 else {
                particles[index].isAlive = false
                continue
            }
            particles[index].lastX = particles[index].x
            particles[index].lastY = particles[index].y
            let nextX = particles[index].x + Double(vx) * pixelScale * delta * settings.velocityScalar
            let nextY = particles[index].y - Double(vy) * pixelScale * delta * settings.velocityScalar
            guard nextX.isFinite, nextY.isFinite,
                  nextX >= 0, nextY >= 0,
                  nextX < Double(grid.width), nextY < Double(grid.height) else {
                particles[index].isAlive = false
                continue
            }
            particles[index].x = nextX
            particles[index].y = nextY
            particles[index].lifetime += delta
        }

        let fadeIn = min(max(date.timeIntervalSince(fieldReceivedAt ?? date) / 0.1, 0), 1)
        let current: [MapResultVelocityParticleTrace] = particles.compactMap { particle
            -> MapResultVelocityParticleTrace? in
            guard particle.isAlive,
                  let width = Self.strokeWidth(lifetime: particle.lifetime,
                    maximumLifetime: settings.maxParticleLifetime) else { return nil }
            return MapResultVelocityParticleTrace(
                lastPosition: Self.mapPoint(x: particle.lastX, y: particle.lastY, grid: grid),
                position: Self.mapPoint(x: particle.x, y: particle.y, grid: grid),
                lineWidth: width, opacity: 0.6 * fadeIn)
        }
        appendTrailFrame(current, at: date)
        let trails = currentTrailTraces(at: date)
        lastPresentedTraces = current
        return transition + trails
    }

    private func settingsDidChange(from oldValue: MapResultVelocityParticleSettings) {
        if oldValue.maxParticles != settings.maxParticles,
           !(1...10_000).contains(settings.maxParticles) {
            settings = oldValue
            return
        }
        if oldValue.velocityScalar != settings.velocityScalar,
           (!settings.velocityScalar.isFinite || settings.velocityScalar <= 0) {
            settings = oldValue
            return
        }
        if oldValue.maxParticleLifetime != settings.maxParticleLifetime,
           (!settings.maxParticleLifetime.isFinite || settings.maxParticleLifetime <= 0) {
            settings = oldValue
            return
        }
        if oldValue.isEnabled != settings.isEnabled {
            if settings.isEnabled, let target { sample(target) }
            else if settings.isEnabled, streamingTargetIdentity != nil { state = .loading }
            else {
                beginOverlayTransition(at: Date())
                requestGeneration &+= 1
                requestTask?.cancel(); requestTask = nil
                grid = nil; particles = []; lastAdvance = nil
                state = .idle
                renderRevision &+= 1
            }
            targetConfigurationDidChange?()
        } else if oldValue.maxParticles != settings.maxParticles {
            beginOverlayTransition(at: Date())
            pendingParticleResizeAt = Date()
            renderRevision &+= 1
            restoreValidationErrorIfPossible()
        }
    }

    private func restoreValidationErrorIfPossible() {
        guard let grid else { return }
        guard case .failed = state else { return }
        state = grid.magnitude.contains { magnitude in
            magnitude.isFinite && (grid.noDataValue.map { magnitude != $0 } ?? true) && magnitude >= 1e-5
        } ? .ready : .empty
        renderRevision &+= 1
    }

    private func sample(_ target: MapResultVelocityParticleTarget) {
        guard settings.isEnabled else { return }
        beginOverlayTransition(at: Date())
        requestGeneration &+= 1
        let generation = requestGeneration
        let requestID = UUID().uuidString.lowercased()
        requestTask?.cancel()
        grid = nil
        particles = []
        lastAdvance = nil
        state = .loading
        renderRevision &+= 1
        requestTask = Task { [weak self] in
            do {
                let field = try await target.sample(requestID, target.identity.profileIndex,
                    target.identity.time.isEmpty ? nil : target.identity.time,
                    target.identity.viewport)
                guard let self, !Task.isCancelled,
                      self.requestGeneration == generation,
                      self.target?.identity == target.identity,
                      self.settings.isEnabled,
                      field.sourceKind == target.identity.sourceKind,
                      field.profileIndex == target.identity.profileIndex,
                      target.identity.profileName.isEmpty || field.profileName == target.identity.profileName,
                      target.identity.time.isEmpty || field.time == target.identity.time,
                      target.identity.sourceKind != .liveResult else { return }
                self.grid = field
                if !field.profileOptions.isEmpty { self.setProfileOptions(field.profileOptions) }
                self.fieldReceivedAt = Date()
                self.particles = Array(repeating: Particle(), count: self.settings.maxParticles)
                self.pendingParticleResizeAt = nil
                self.state = field.magnitude.contains { magnitude in
                    magnitude.isFinite && (field.noDataValue.map { magnitude != $0 } ?? true) && magnitude >= 1e-5
                } ? .ready : .empty
                self.renderRevision &+= 1
            } catch {
                guard let self, !Task.isCancelled,
                      self.requestGeneration == generation,
                      self.target?.identity == target.identity else { return }
                self.grid = nil
                self.particles = []
                self.state = .failed(L10n.text(error.localizedDescription))
                self.renderRevision &+= 1
            }
            if let self, self.requestGeneration == generation { self.requestTask = nil }
        }
    }

    /// Installs a real writer-owned field on the duplex callback. There is no
    /// second file reader and no synthetic Result revision in this path.
    func setStreamingTarget(_ identity: MapResultVelocityParticleTargetIdentity?) {
        let next = identity?.sourceKind == .liveResult ? identity : nil
        guard streamingTargetIdentity != next || target?.identity.sourceKind == .liveResult else { return }
        beginOverlayTransition(at: Date())
        requestGeneration &+= 1
        requestTask?.cancel(); requestTask = nil
        if target?.identity.sourceKind == .liveResult { target = nil }
        if next != nil { target = nil }
        streamingTargetIdentity = next
        grid = nil
        particles = []
        lastAdvance = nil
        fieldReceivedAt = nil
        state = next == nil ? .idle : (settings.isEnabled ? .loading : .idle)
        if let next, !next.profileName.isEmpty, !next.time.isEmpty {
            setProfileOptions([MapVelocityParticleProfile(index: next.profileIndex, time: next.time)])
        } else if next == nil { profileOptions = [] }
        renderRevision &+= 1
    }

    @discardableResult
    func installLiveGrid(_ field: MapResultVelocityGrid,
                         identity: MapResultVelocityParticleTargetIdentity) -> Bool {
        guard let expected = MapVelocityRasterGeometry.normalizedBounds(identity.viewport, maximumSide: 384) else { return false }
        guard identity.sourceKind == .liveResult, streamingTargetIdentity == identity,
              field.sourceKind == .liveResult,
              field.runID == identity.runID,
              identity.profileIndex == field.profileIndex,
              identity.profileName == field.profileName,
              identity.time == field.time,
              field.width == expected.width,
              field.height == expected.height else { return false }
        guard
              Self.approximately(field.minX, expected.minX),
              Self.approximately(field.minY, expected.minY),
              Self.approximately(field.maxX, expected.maxX),
              Self.approximately(field.maxY, expected.maxY),
              Self.approximately(field.cellSize, expected.cellSize) else { return false }
        if let old = grid, old.sourceKind == .liveResult,
           old.runID == field.runID,
           old.profileIndex == field.profileIndex,
           old.profileName == field.profileName,
           old.time == field.time,
           old.width == field.width, old.height == field.height,
           old.cellSize == field.cellSize,
           old.minX == field.minX, old.minY == field.minY,
           old.maxX == field.maxX, old.maxY == field.maxY {
            // New TimestepAdded events may redraw the exact active writer
            // target without restarting particles against unchanged bounds.
            grid = field
        } else {
            beginOverlayTransition(at: Date())
            grid = field
            particles = Array(repeating: Particle(), count: settings.maxParticles)
            lastAdvance = nil
        }
        fieldReceivedAt = Date()
        profileOptions = [MapVelocityParticleProfile(index: field.profileIndex, time: field.time)]
        state = field.magnitude.contains { magnitude in
            magnitude.isFinite && (field.noDataValue.map { magnitude != $0 } ?? true) && magnitude >= 1e-5
        } ? .ready : .empty
        renderRevision &+= 1
        return true
    }

    @discardableResult
    func installLiveUnavailable(_ message: String,
                                identity: MapResultVelocityParticleTargetIdentity) -> Bool {
        guard identity.sourceKind == .liveResult, streamingTargetIdentity == identity else { return false }
        beginOverlayTransition(at: Date())
        requestGeneration &+= 1
        requestTask?.cancel(); requestTask = nil
        grid = nil
        particles = []
        lastAdvance = nil
        fieldReceivedAt = nil
        state = .failed(L10n.text(message))
        renderRevision &+= 1
        return true
    }

    private func resizeParticleBuffer(to count: Int) {
        guard count >= 0 else { return }
        if particles.count > count { particles.removeLast(particles.count - count) }
        else if particles.count < count {
            particles.append(contentsOf: repeatElement(Particle(), count: count - particles.count))
        }
    }

    private func beginOverlayTransition(at date: Date) {
        let current = lastPresentedTraces.isEmpty ? currentTrailTraces(at: date) : lastPresentedTraces
        if !current.isEmpty {
            transitionTraces = current.map { trace in
                MapResultVelocityParticleTrace(lastPosition: trace.lastPosition,
                    position: trace.position, lineWidth: trace.lineWidth, opacity: trace.opacity)
            }
            transitionStartedAt = date
        }
        trailFrames = []
        lastTrailFrameAt = nil
        lastPresentedTraces = []
    }

    private func currentTransitionTraces(at date: Date) -> [MapResultVelocityParticleTrace] {
        guard let transitionStartedAt else { return [] }
        let elapsed = max(0, date.timeIntervalSince(transitionStartedAt))
        guard elapsed < 0.5 else {
            self.transitionStartedAt = nil
            transitionTraces = []
            return []
        }
        let opacityFactor = max(0, 1 - elapsed / 0.25)
        return transitionTraces.map { trace in
            MapResultVelocityParticleTrace(lastPosition: trace.lastPosition,
                position: trace.position, lineWidth: trace.lineWidth,
                opacity: trace.opacity * opacityFactor)
        }.filter { $0.opacity > 0 }
    }

    private func appendTrailFrame(_ traces: [MapResultVelocityParticleTrace], at date: Date) {
        guard !traces.isEmpty, date != lastTrailFrameAt else { return }
        trailFrames.append((date, traces))
        lastTrailFrameAt = date
        trailFrames.removeAll { date.timeIntervalSince($0.date) > 0.5 }
        if trailFrames.count > 16 { trailFrames.removeFirst(trailFrames.count - 16) }
    }

    private func currentTrailTraces(at date: Date) -> [MapResultVelocityParticleTrace] {
        trailFrames.removeAll { date.timeIntervalSince($0.date) > 0.5 }
        return trailFrames.flatMap { frame in
            let age = max(0, date.timeIntervalSince(frame.date))
            let fade = max(0, 1 - age / 0.5)
            return frame.traces.map { trace in
                MapResultVelocityParticleTrace(lastPosition: trace.lastPosition,
                    position: trace.position, lineWidth: trace.lineWidth,
                    opacity: trace.opacity * fade * 0.55)
            }.filter { $0.opacity > 0 }
        }
    }

    private static func normalizedRasterBounds(_ viewport: RasterMapViewExtent)
        -> (cellSize: Double, minX: Double, minY: Double, maxX: Double, maxY: Double)? {
        guard [viewport.minX, viewport.minY, viewport.maxX, viewport.maxY].allSatisfy(\.isFinite),
              viewport.minX < viewport.maxX, viewport.minY < viewport.maxY,
              viewport.pixelWidth > 0, viewport.pixelHeight > 0 else { return nil }
        let cell = max((viewport.maxX - viewport.minX) / Double(viewport.pixelWidth),
                       (viewport.maxY - viewport.minY) / Double(viewport.pixelHeight))
        let maxX = viewport.minX + Double(viewport.pixelWidth) * cell
        let minY = viewport.maxY - Double(viewport.pixelHeight) * cell
        guard cell.isFinite, cell > 0, maxX.isFinite, minY.isFinite else { return nil }
        return (cell, viewport.minX, minY, maxX, viewport.maxY)
    }

    private static func sameWindSource(_ first: MapResultVelocityParticleTargetIdentity?,
                                       _ second: MapResultVelocityParticleTargetIdentity?) -> Bool {
        guard let first, let second else { return false }
        return first.sourceKind == .wind && second.sourceKind == .wind
            && first.sourceGeneration == second.sourceGeneration
            && first.projectSessionID == second.projectSessionID
            && first.mapID == second.mapID
            && first.contextToken == second.contextToken
            && first.nodeID == second.nodeID
            && first.node.sourceIdentity == second.node.sourceIdentity
            && first.resultPath == second.resultPath
            && first.resultRevision == second.resultRevision
    }

    private static func approximately(_ actual: Double, _ expected: Double) -> Bool {
        actual.isFinite && expected.isFinite
            && abs(actual - expected) <= max(1e-9, abs(expected) * 1e-12)
    }

    private static func mapPoint(x: Double, y: Double, grid: MapResultVelocityGrid) -> MapPoint {
        MapPoint(x: grid.minX + (x + 0.5) * grid.cellSize,
                 y: grid.maxY - (y + 0.5) * grid.cellSize)
    }

    private static func strokeWidth(lifetime: Double, maximumLifetime: Double) -> CGFloat? {
        let widthLifetime = min(maximumLifetime, 0.25)
        guard widthLifetime > 0 else { return nil }
        let lifetimeRatio = min(lifetime / widthLifetime, 1)
        let taperStart = maximumLifetime - maximumLifetime * 0.15
        let taperRange = maximumLifetime * 0.15
        guard taperRange > 0 else { return nil }
        let clamped = min(max(lifetime, taperStart), maximumLifetime)
        let taper = 1 - (clamped - taperStart) / taperRange
        let width = lifetimeRatio * taper * 2
        guard width.isFinite, width > 0 else { return nil }
        return CGFloat(width)
    }
}

struct MapResultVelocityParticlesCanvas: View {
    @ObservedObject var session: MapResultVelocityParticleSession
    let points: [MapPoint]
    let scale: CGFloat
    let offset: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !session.settings.isEnabled || reduceMotion)) { timeline in
            Canvas { context, size in
                guard !reduceMotion, session.settings.isEnabled,
                      size.width > 0, size.height > 0 else { return }
                let transform = MapTransform(points: points, size: size,
                    scale: scale, offset: offset)
                for trace in session.advance(at: timeline.date) {
                    let start = transform.screen(trace.lastPosition)
                    let end = transform.screen(trace.position)
                    guard start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite else { continue }
                    var path = Path()
                    path.move(to: start); path.addLine(to: end)
                    context.stroke(path, with: .color(.white.opacity(trace.opacity)),
                        style: StrokeStyle(lineWidth: trace.lineWidth, lineCap: .round))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct MapResultVelocityParticlesButton: View {
    @ObservedObject var session: MapResultVelocityParticleSession
    @State private var settingsPresented = false

    var body: some View {
        HStack(spacing: 4) {
            Button { session.toggleEnabled() } label: {
                Label(L10n.text("Velocity Particles"), systemImage: session.settings.isEnabled ? "wind" : "wind.circle")
            }
            .disabled(!session.canEnable && !session.settings.isEnabled)
            .help(L10n.text(session.settings.isEnabled
                ? "Hide velocity particles" : "Show velocity particles"))

            Button { settingsPresented.toggle() } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .help(L10n.text("Velocity particle settings"))
            .popover(isPresented: $settingsPresented) {
                settingsForm.frame(width: 340).padding(12)
            }
            if session.isSampling {
                ProgressView().controlSize(.small)
                    .help(session.statusMessage ?? L10n.text("Sampling Result velocity…"))
            } else if let statusMessage = session.statusMessage {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .help(statusMessage)
            }
        }
    }

    private var settingsForm: some View {
        Form {
            Toggle(L10n.text("Enable Velocity Particles"), isOn: Binding(
                get: { session.settings.isEnabled }, set: session.setEnabled))
                .disabled(!session.canEnable && !session.settings.isEnabled)
            if session.canSelectWindProfile {
                Picker(L10n.text("Wind Profile"), selection: Binding(
                    get: { session.selectedProfileIndex ?? session.profileOptions[0].index },
                    set: session.selectWindProfile)) {
                    ForEach(session.profileOptions) { profile in
                        Text(profile.time).tag(profile.index)
                    }
                }
                .disabled(session.isSampling)
            }
            Picker(L10n.text("Velocity Mode"), selection: Binding(
                get: { session.settings.velocityMode }, set: session.setVelocityMode)) {
                ForEach(ParticleVelocityModeOption.allCases) { mode in
                    Text(L10n.text(mode.title)).tag(mode)
                }
            }
            TextField(L10n.text("Velocity Scalar"), value: Binding(
                get: { session.settings.velocityScalar }, set: session.setVelocityScalar), format: .number)
            TextField(L10n.text("Maximum Particle Lifetime"), value: Binding(
                get: { session.settings.maxParticleLifetime }, set: session.setMaximumLifetime), format: .number)
            TextField(L10n.text("Maximum Particles"), value: Binding(
                get: { session.settings.maxParticles }, set: session.setMaximumParticles), format: .number)
            Text(L10n.text("The native map accepts between 1 and 10,000 particles."))
                .font(.caption).foregroundStyle(.secondary)
            if let message = session.statusMessage {
                Label(message, systemImage: session.isSampling ? "hourglass" : "info.circle")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Button(L10n.text("Resample Velocity Field"), action: session.refresh)
                .disabled(!session.settings.isEnabled || !session.canEnable || session.isSampling)
        }
        .formStyle(.grouped)
    }
}
