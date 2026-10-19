import RASWorkspaceCore
import SwiftUI

struct ProfileStep: Identifiable, Sendable {
    let id: Int // Actual source profile index; slider position is a separate value.
    let label: String
    var date: Date? = nil
    var sourceTime: String? = nil
}
struct MapProfilePresentation: Sendable {
    let sourceID: String
    let steps: [ProfileStep]
    let selectedID: Int?
}
struct MapProfileContext: Equatable, Sendable {
    let projectSessionID: UUID
    let mapID: UUID
    let sourceID: String
}
@MainActor
protocol ProfileProvider { func selectProfile(_ index: Int) async throws -> MapUpdate }

@MainActor
final class MapProfileSession: ObservableObject {
    @Published private(set) var steps: [ProfileStep] = []
    @Published private(set) var currentID: Int?
    @Published private(set) var requestedPosition: Int?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var isReadSuspended = false
    @Published private(set) var isMetadataOnly = false
    @Published private(set) var availabilityMessage: String?
    private var context: MapProfileContext?
    private var provider: (any ProfileProvider)?
    private var generation = 0
    private var task: Task<Void, Never>?
    var didSelect: ((MapUpdate, MapProfileContext) -> Void)?
    /// Called only for a user-selected frame. Viewport refreshes use
    /// `reloadCurrent()` and must not write persistent map state.
    var didSelectPersistableProfile: ((Int, MapProfileContext) -> Void)?
    private var requestedSelectionShouldPersist = false
    var canSelect: Bool { provider != nil && !steps.isEmpty }
    var canChoosePosition: Bool { !isReadSuspended && !steps.isEmpty && (provider != nil || isMetadataOnly) }
    var hasProvider: Bool { provider != nil }
    var isConfigured: Bool { context != nil }
    var position: Int? { requestedPosition ?? steps.firstIndex { $0.id == currentID } }
    var currentStep: ProfileStep? { position.flatMap { steps.indices.contains($0) ? steps[$0] : nil } }
    func configure(_ presentation: MapProfilePresentation, provider: (any ProfileProvider)?, context: MapProfileContext) throws {
        try Self.validate(presentation, context: context)
        invalidate()
        self.context = context; self.provider = provider; steps = presentation.steps; currentID = presentation.selectedID
        isReadSuspended = false
    }
    func configureMetadataOnly(_ presentation: MapProfilePresentation,
                               context: MapProfileContext,
                               availabilityMessage: String) throws {
        try Self.validate(presentation, context: context)
        invalidate()
        self.context = context
        provider = nil
        steps = presentation.steps
        currentID = presentation.selectedID
        isMetadataOnly = true
        self.availabilityMessage = availabilityMessage
    }
    func replaceMetadataOnlySteps(_ presentation: MapProfilePresentation,
                                  context: MapProfileContext,
                                  availabilityMessage: String) throws {
        guard isMetadataOnly, self.context == context else {
            try configureMetadataOnly(presentation, context: context,
                availabilityMessage: availabilityMessage)
            return
        }
        try Self.validate(presentation, context: context)
        let previousID = requestedPosition.flatMap { steps.indices.contains($0) ? steps[$0].id : nil } ?? currentID
        steps = presentation.steps
        currentID = previousID.flatMap { id in steps.contains(where: { $0.id == id }) ? id : nil }
            ?? presentation.selectedID
        requestedPosition = nil
        error = nil
        self.availabilityMessage = availabilityMessage
    }
    /// Adds a reader for historical slots while retaining the live writer's
    /// source-reported profile timeline. The timeline remains metadata-only;
    /// the provider can render only the other, stable Result selections.
    @discardableResult
    func attachProviderToMetadataOnlyTimeline(_ provider: any ProfileProvider,
                                              context: MapProfileContext) -> Bool {
        guard isMetadataOnly, self.context == context, !isReadSuspended else { return false }
        generation += 1
        task?.cancel()
        task = nil
        requestedPosition = nil
        requestedSelectionShouldPersist = false
        busy = false
        self.provider = provider
        return true
    }
    func updateMetadataAvailability(_ message: String?) {
        guard isMetadataOnly, availabilityMessage != message else { return }
        availabilityMessage = message
    }
    func suspendSourceReads() {
        guard !isReadSuspended else { return }
        generation += 1
        task?.cancel()
        task = nil
        requestedPosition = nil
        requestedSelectionShouldPersist = false
        busy = false
        isReadSuspended = true
    }
    func resumeSourceReads() {
        isReadSuspended = false
    }
    func reloadCurrent() { if let position { enqueue(position: position, force: true, persistSelection: false) } }
    func select(position: Int, force: Bool = false) {
        enqueue(position: position, force: force, persistSelection: !force)
    }
    private func enqueue(position: Int, force: Bool, persistSelection: Bool) {
        guard canChoosePosition, steps.indices.contains(position) else { return }
        if isMetadataOnly && provider == nil {
            let id = steps[position].id
            guard force || id != currentID else { return }
            currentID = id
            requestedPosition = nil
            if let context { didChooseMetadataOnlyProfile?(id, context) }
            return
        }
        if !force, !busy, steps[position].id == currentID { return }
        requestedPosition = position; error = nil
        requestedSelectionShouldPersist = requestedSelectionShouldPersist || persistSelection
        guard task == nil else { return }
        let revision = generation
        busy = true
        task = Task { [weak self] in await self?.drain(revision) }
    }
    private func drain(_ revision: Int) async {
        defer { if revision == generation { task = nil; busy = false } }
        var confirmed: (Int, MapUpdate, MapProfileContext, Bool)?
        while revision == generation, let position = requestedPosition, steps.indices.contains(position), let provider, let context {
            let id = steps[position].id
            let shouldPersist = requestedSelectionShouldPersist
            do {
                let update = try await provider.selectProfile(id)
                guard !Task.isCancelled, revision == generation else { return }
                // Serialize source changes and coalesce rapid scrubs. A reply
                // for an intermediate frame never replaces the requested one.
                if requestedPosition != position { confirmed = (id, update, context, shouldPersist); continue }
                currentID = id; requestedPosition = nil
                requestedSelectionShouldPersist = false
                didSelect?(update, context)
                if shouldPersist { didSelectPersistableProfile?(id, context) }
            } catch {
                guard revision == generation, !Task.isCancelled else { return }
                if requestedPosition != position { continue }
                requestedPosition = nil; self.error = L10n.text(error.localizedDescription)
                requestedSelectionShouldPersist = false
                if let confirmed {
                    currentID = confirmed.0
                    didSelect?(confirmed.1, confirmed.2)
                    if confirmed.3 { didSelectPersistableProfile?(confirmed.0, confirmed.2) }
                }
            }
        }
    }
    func invalidate() {
        generation += 1; task?.cancel(); task = nil
        context = nil; provider = nil; steps = []; currentID = nil; requestedPosition = nil
        requestedSelectionShouldPersist = false; busy = false; error = nil
        isReadSuspended = false; isMetadataOnly = false; availabilityMessage = nil
    }

    var didChooseMetadataOnlyProfile: ((Int, MapProfileContext) -> Void)?

    private static func validate(_ presentation: MapProfilePresentation,
                                 context: MapProfileContext) throws {
        guard !presentation.sourceID.isEmpty, presentation.sourceID == context.sourceID,
              Set(presentation.steps.map(\.id)).count == presentation.steps.count,
              presentation.steps.allSatisfy({ $0.id >= 0 && ($0.date.map { $0.timeIntervalSince1970.isFinite } ?? true) }),
              presentation.selectedID.map({ id in presentation.steps.contains { $0.id == id } }) ?? presentation.steps.isEmpty else {
            throw ProjectFileError.invalid("The source profile timeline contains invalid identities or selection.")
        }
    }
}

struct ProfileTimeline: View {
    @ObservedObject var mapState: MapState
    @ObservedObject private var session: MapProfileSession
    init(mapState: MapState) { self.mapState = mapState; session = mapState.profiles }
    init(mapState: MapState, session: MapProfileSession) { self.mapState = mapState; self.session = session }
    private var position: Int { session.position ?? 0 }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button { session.select(position: 0) } label: { Label("First", systemImage: "backward.end") }.disabled(position == 0 || !session.canChoosePosition)
                    .accessibilityLabel(Text("First profile"))
                Button { session.select(position: position - 1) } label: { Label("Previous", systemImage: "backward.frame") }.disabled(position == 0 || session.steps.isEmpty)
                    .accessibilityLabel(Text("Previous profile"))
                Slider(value: Binding(get: { Double(position) }, set: { session.select(position: Int($0.rounded())) }),
                    in: 0...Double(max(session.steps.count - 1, 1)), step: 1)
                    .disabled(session.steps.count < 2 || !session.canChoosePosition)
                    .accessibilityLabel("Time Frame")
                    .accessibilityValue(Text(L10n.format("%d of %d", session.steps.isEmpty ? 0 : position + 1, session.steps.count)))
                Button { session.select(position: position + 1) } label: { Label("Next", systemImage: "forward.frame") }
                    .disabled(!session.canChoosePosition || position >= session.steps.count - 1)
                    .accessibilityLabel(Text("Next profile"))
                Button { session.select(position: session.steps.count - 1) } label: { Label("Last", systemImage: "forward.end") }
                    .disabled(!session.canChoosePosition || position >= session.steps.count - 1)
                    .accessibilityLabel(Text("Last profile"))
                if session.busy { ProgressView().controlSize(.small) }
                Text(L10n.format("%d of %d", session.steps.isEmpty ? 0 : position + 1, session.steps.count))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if let step = session.currentStep {
                    if let date = step.date { Text(date, format: .dateTime.year().month().day().hour().minute().second()).font(.caption.monospacedDigit()) }
                    else { Text(step.label).font(.caption.monospacedDigit()).lineLimit(1).textSelection(.enabled) }
                }
            }.labelStyle(.iconOnly).buttonStyle(.borderless)
            if session.steps.isEmpty { Text("No profile states are available.").font(.caption).foregroundStyle(.secondary) }
            if let availabilityMessage = session.availabilityMessage {
                Text(L10n.text(availabilityMessage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else if !session.hasProvider && !session.isMetadataOnly {
                Text("Profile selection is unavailable because a source provider is not connected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let error = session.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(10).workspaceGlass().padding(12)
    }
}
