import Foundation
import Testing
@testable import HECRAS2025

struct WorkspaceNotificationTests {
    @Test
    func automaticHideUsesRetainedNotifierTimeoutBoundsAndUTF16Length() {
        #expect(WorkspaceNotificationAutoHide.duration(for: "") == .milliseconds(2_500))
        #expect(WorkspaceNotificationAutoHide.duration(for: String(repeating: "a", count: 50)) == .seconds(5))
        #expect(WorkspaceNotificationAutoHide.duration(for: String(repeating: "a", count: 100)) == .seconds(10))
        #expect(WorkspaceNotificationAutoHide.duration(for: String(repeating: "a", count: 250)) == .seconds(10))
        #expect(WorkspaceNotificationAutoHide.duration(for: "工程🌊") == .milliseconds(2_500))
    }

    @Test @MainActor
    func hoverReducesThePreviewWithoutPausingRecentMessageExpiry() async {
        let clock = ManualWorkspaceNotificationClock()
        let queue = WorkspaceNotificationQueueState(autoHideOverride: .milliseconds(80), clock: clock)
        let message = WorkspaceMessage(operation: "Project", text: "Recent message", isError: true)

        queue.receive([message], now: message.time)
        await Task.yield()
        #expect(queue.visibleMessages.map(\.id) == [message.id])
        #expect(message.notificationSeverity == .error)
        #expect(queue.isReduced == false)

        clock.advance(by: .milliseconds(30))
        queue.setPointerIsOverList(true)
        #expect(queue.isReduced)

        clock.advance(by: .milliseconds(50))
        await drainNotifications { queue.visibleMessages.isEmpty }
        #expect(queue.visibleMessages.isEmpty)
        #expect(queue.isReduced == false)
    }

    @Test @MainActor
    func pointerPressClearsOnlyRecentNotificationsAndKeepsHistoryIdentifiersSeen() {
        let queue = WorkspaceNotificationQueueState(autoHideOverride: .seconds(10))
        let first = WorkspaceMessage(operation: "Map", text: "First message", isError: false)
        let second = WorkspaceMessage(operation: "Project", text: "Second message", isError: true)
        let history = [first, second]

        queue.receive(history, now: second.time)
        queue.setPointerIsOverList(true)
        #expect(queue.visibleMessages.map(\.id) == history.map(\.id))
        #expect(queue.isReduced)

        queue.clearRecentMessagesFromPointerPress()
        #expect(queue.visibleMessages.isEmpty)
        #expect(queue.isReduced)
        #expect(history.map(\.id) == [first.id, second.id])

        queue.receive(history, now: second.time)
        #expect(queue.visibleMessages.isEmpty)

        let later = WorkspaceMessage(operation: "Compute", text: "Later message", isError: false)
        queue.receive(history + [later], now: later.time)
        #expect(queue.visibleMessages.map(\.id) == [later.id])
    }

    @Test @MainActor
    func pointerPressDoesNotClearWhenReductionBehaviorIsDisabled() {
        let queue = WorkspaceNotificationQueueState(autoHideOverride: .seconds(10))
        let message = WorkspaceMessage(operation: "Map", text: "Keep visible", isError: false)
        queue.receive([message], now: message.time)

        queue.clearRecentMessagesFromPointerPress(reduceOnPointerOver: false)

        #expect(queue.visibleMessages.map(\.id) == [message.id])
    }

    @Test @MainActor
    func pointerExitReplenishesThePreviewAfterHoverReduction() {
        let queue = WorkspaceNotificationQueueState(autoHideOverride: .seconds(10))
        let message = WorkspaceMessage(operation: "Map", text: "Hover state", isError: false)
        queue.receive([message], now: message.time)

        queue.setPointerIsOverList(true)
        #expect(queue.isReduced)

        queue.setPointerIsOverList(false)
        #expect(queue.isReduced == false)
    }

    @Test @MainActor
    func dismissingOneRecentMessageLeavesOtherNotificationsAndHistoryAlone() {
        let queue = WorkspaceNotificationQueueState(autoHideOverride: .seconds(10))
        let first = WorkspaceMessage(operation: "Map", text: "First message", isError: false)
        let second = WorkspaceMessage(operation: "Project", text: "Second message", isError: true)
        let history = [first, second]

        queue.receive(history, now: second.time)
        queue.dismiss(first.id)

        #expect(queue.visibleMessages.map(\.id) == [second.id])
        #expect(history.map(\.id) == [first.id, second.id])
        queue.receive(history, now: second.time)
        #expect(queue.visibleMessages.map(\.id) == [second.id])
    }

    @Test @MainActor
    func aDelayedTimerTaskUsesTheOriginalDeadline() async {
        let clock = ManualWorkspaceNotificationClock()
        let queue = WorkspaceNotificationQueueState(autoHideOverride: .milliseconds(80), clock: clock)
        let message = WorkspaceMessage(operation: "Map", text: "Busy UI", isError: false)
        queue.receive([message], now: message.time)
        // Advance before yielding: the queued timer has not started. It must
        // expire immediately on its first turn instead of adding another 80ms.
        clock.advance(by: .milliseconds(120))
        await drainNotifications { queue.visibleMessages.isEmpty }
        #expect(clock.requestedDeadlines == [clock.origin.advanced(by: .milliseconds(80))])
        #expect(queue.visibleMessages.isEmpty)
    }

    @Test @MainActor
    func historicalMessagesOutsideTheRecentWindowAreNotReplayed() {
        let queue = WorkspaceNotificationQueueState(autoHideOverride: .milliseconds(80))
        let old = WorkspaceMessage(operation: "Project", text: "Already expired", isError: false)

        queue.receive([old], now: old.time.addingTimeInterval(1))
        #expect(queue.visibleMessages.isEmpty)
        queue.receive([old])
        #expect(queue.visibleMessages.isEmpty)
    }
}


@MainActor
private final class ManualWorkspaceNotificationClock: WorkspaceNotificationClock {
    let origin: ContinuousClock.Instant
    private(set) var now: ContinuousClock.Instant
    private(set) var requestedDeadlines: [ContinuousClock.Instant] = []
    private var sleepers: [(ContinuousClock.Instant, CheckedContinuation<Void, Never>)] = []

    init() {
        let initial = ContinuousClock().now
        origin = initial
        now = initial
    }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        try Task.checkCancellation()
        requestedDeadlines.append(deadline)
        if deadline > now {
            await withCheckedContinuation { continuation in
                sleepers.append((deadline, continuation))
            }
        }
        try Task.checkCancellation()
    }

    func advance(by duration: Duration) {
        now = now.advanced(by: duration)
        let ready = sleepers.filter { $0.0 <= now }
        sleepers.removeAll { $0.0 <= now }
        for (_, continuation) in ready { continuation.resume() }
    }
}

@MainActor
private func drainNotifications(until complete: @MainActor () -> Bool) async {
    for _ in 0..<100 {
        if complete() { return }
        await Task.yield()
    }
}
