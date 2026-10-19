import Combine
import Foundation

@MainActor
final class AssociatedRasterStyleSession: ObservableObject {
    @Published private(set) var context: AssociatedRasterStyleContext?
    @Published private(set) var snapshot: AssociatedRasterStyleSnapshot?
    @Published var draft: AssociatedRasterStyleDraft?
    @Published private(set) var isLoading = false
    @Published private(set) var isApplying = false
    @Published private(set) var isInvalidated = false
    @Published private(set) var errorMessage: String?

    private let provider: any AssociatedRasterStyleProvider
    private var generation: UInt64 = 0
    private var loadTask: Task<Void, Never>?

    init(context: AssociatedRasterStyleContext,
         provider: any AssociatedRasterStyleProvider) {
        self.context = context
        self.provider = provider
    }

    func load() async {
        guard let context, !isInvalidated else { return }
        generation &+= 1
        let requestedGeneration = generation
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.generation == requestedGeneration {
                    self.isLoading = false
                    self.loadTask = nil
                }
            }
            do {
                let loaded = try await self.provider.load(context, contextToken: nil)
                guard !Task.isCancelled, self.generation == requestedGeneration,
                      self.context == context, !self.isInvalidated else { return }
                self.snapshot = loaded
                self.draft = loaded.draft
            } catch is CancellationError {
                return
            } catch {
                guard self.generation == requestedGeneration,
                      self.context == context, !self.isInvalidated else { return }
                self.errorMessage = L10n.text(error.localizedDescription)
            }
        }
        loadTask = task
        await task.value
    }

    /// Cancels only an in-flight read. A submitted Apply owns a separate
    /// mutation task; dismissing the editor must not invalidate its accepted
    /// visualization receipt or prevent it from refreshing this session.
    func cancelPendingLoad() {
        guard let task = loadTask else { return }
        generation &+= 1
        task.cancel()
        loadTask = nil
        isLoading = false
    }

    @discardableResult
    func apply(paletteMutation: AssociatedRasterStylePaletteMutation? = nil) async -> Bool {
        guard let context, let snapshot, let draft, !isInvalidated,
              !isLoading, !isApplying else { return false }
        generation &+= 1
        let requestedGeneration = generation
        isApplying = true
        errorMessage = nil
        defer {
            if generation == requestedGeneration { isApplying = false }
        }
        do {
            let loaded = try await provider.apply(context, snapshot: snapshot,
                draft: draft, paletteMutation: paletteMutation)
            guard generation == requestedGeneration, self.context == context,
                  !isInvalidated else { return false }
            self.context = loaded.context
            self.snapshot = loaded.snapshot
            self.draft = loaded.snapshot.draft
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard generation == requestedGeneration, !isInvalidated else { return false }
            errorMessage = L10n.text(error.localizedDescription)
            return false
        }
    }

    func reset() {
        guard let snapshot, !isApplying, !isInvalidated else { return }
        draft = snapshot.resetDraft
        errorMessage = nil
    }

    func invalidate() {
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
        context = nil
        snapshot = nil
        draft = nil
        isLoading = false
        isApplying = false
        isInvalidated = true
        errorMessage = L10n.text("The selected map or source layer changed. Refresh the style editor.")
    }
}
