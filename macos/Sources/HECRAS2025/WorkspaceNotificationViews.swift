import AppKit
import SwiftUI

enum WorkspaceNotificationAutoHide {
    /// RasMainWindow configures a 10-second base timeout. The notifier scales
    /// it by message length, clamped to 25%...100%.
    static func duration(for message: String) -> Duration {
        let ratio = min(max(Double(message.utf16.count) / 100, 0.25), 1)
        return .milliseconds(Int64((10_000 * ratio).rounded(.down)))
    }
}

extension WorkspaceMessage {
    var notificationSeverity: SharedVisualMessageSeverity { severity.visualSeverity }

    var sharedVisualToastMessage: SharedVisualToastMessage {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "hh:mm"
        return SharedVisualToastMessage(
            id: id.uuidString,
            title: operation,
            message: text,
            severity: notificationSeverity,
            timeRequested: formatter.string(from: time)
        )
    }
}

@MainActor
protocol WorkspaceNotificationClock {
    var now: ContinuousClock.Instant { get }
    func sleep(until deadline: ContinuousClock.Instant) async throws
}

private struct SystemWorkspaceNotificationClock: WorkspaceNotificationClock {
    private let clock = ContinuousClock()
    var now: ContinuousClock.Instant { clock.now }
    func sleep(until deadline: ContinuousClock.Instant) async throws {
        try await clock.sleep(until: deadline)
    }
}

@MainActor
final class WorkspaceNotificationQueueState: ObservableObject {
    @Published private(set) var visibleMessages: [WorkspaceMessage] = []
    @Published private(set) var isReduced = false

    private struct TimerState {
        var remaining: Duration
        var deadline: ContinuousClock.Instant?
        var task: Task<Void, Never>?
        var generation = UUID()
    }

    private let clock: any WorkspaceNotificationClock
    private let autoHideOverride: Duration?
    private var timers: [UUID: TimerState] = [:]
    private var seenMessageIDs: Set<UUID> = []
    private var pointerIsOverList = false

    init(autoHideOverride: Duration? = nil, clock: (any WorkspaceNotificationClock)? = nil) {
        self.autoHideOverride = autoHideOverride
        self.clock = clock ?? SystemWorkspaceNotificationClock()
    }

    func receive(_ messages: [WorkspaceMessage], now: Date = Date()) {
        for message in messages {
            guard seenMessageIDs.insert(message.id).inserted else { continue }
            let timeout = autoHideOverride ?? WorkspaceNotificationAutoHide.duration(for: message.text)
            let age = max(0, now.timeIntervalSince(message.time))
            let elapsed = Duration.milliseconds(Int64((age * 1_000).rounded(.up)))
            let remaining = timeout - elapsed
            guard remaining > .zero else { continue }

            visibleMessages.append(message)
            timers[message.id] = TimerState(remaining: remaining)
        }

        schedulePendingTimers()
    }

    func dismiss(_ id: UUID) {
        timers[id]?.task?.cancel()
        timers.removeValue(forKey: id)
        visibleMessages.removeAll { $0.id == id }
        if visibleMessages.isEmpty {
            pointerIsOverList = false
            isReduced = false
        }
    }

    func dismissAll() {
        for timer in timers.values { timer.task?.cancel() }
        timers.removeAll()
        visibleMessages.removeAll()
    }

    func setPointerIsOverList(_ isOver: Bool) {
        guard pointerIsOverList != isOver else { return }
        pointerIsOverList = isOver
        isReduced = isOver
    }

    /// The retained preview is bound to `RecentMessages`, not message history.
    /// Pointer press clears that transient queue while the workspace history
    /// remains available to the Messages pane.
    func clearRecentMessagesFromPointerPress(reduceOnPointerOver: Bool = true) {
        guard reduceOnPointerOver else { return }
        dismissAll()
    }

    private func schedulePendingTimers() {
        for id in Array(timers.keys) { scheduleTimer(for: id) }
    }

    private func scheduleTimer(for id: UUID) {
        guard var timer = timers[id], timer.task == nil else { return }
        let delay = timer.remaining > .zero ? timer.remaining : .zero
        let generation = UUID()
        timer.remaining = delay
        let deadline = clock.now.advanced(by: delay)
        timer.deadline = deadline
        timer.generation = generation
        let clock = self.clock
        timer.task = Task { @MainActor [weak self] in
            // Scheduling can itself wait behind other UI work. The lifetime
            // starts when the notification is scheduled, not when this task
            // eventually gets its first turn on the main actor.
            do { try await clock.sleep(until: deadline) } catch { return }
            guard !Task.isCancelled else { return }
            self?.expire(id, generation: generation)
        }
        timers[id] = timer
    }

    private func expire(_ id: UUID, generation: UUID) {
        guard timers[id]?.generation == generation else { return }
        dismiss(id)
    }
}

struct AppToastView<ActionContent: View>: View {
    let messages: [WorkspaceMessage]
    @ViewBuilder let actionContent: (WorkspaceMessage) -> ActionContent
    private let reduceOnPointerOver = true
    @StateObject private var queue = WorkspaceNotificationQueueState()

    var body: some View {
        Group {
            if !queue.visibleMessages.isEmpty {
                VStack(alignment: .trailing, spacing: 8) {
                    if queue.visibleMessages.count > 1 {
                        Button(L10n.text("Dismiss All"), systemImage: "xmark.circle") {
                            queue.dismissAll()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel(L10n.text("Dismiss All Notifications"))
                    }
                    SharedVisualToastNotificationList(
                        messages: queue.visibleMessages.map(\.sharedVisualToastMessage),
                        isReversed: false,
                        onDismiss: { id in
                            if let messageID = UUID(uuidString: id) { queue.dismiss(messageID) }
                        },
                        cardContent: { preview, dismiss in
                            guard let message = queue.visibleMessages.first(where: { $0.id.uuidString == preview.id }) else {
                                return AnyView(EmptyView())
                            }
                            return AnyView(AppShellAlertBanner(message: message, dismiss: dismiss) {
                                actionContent(message)
                            }.scaleEffect(queue.isReduced ? 0.94 : 1, anchor: .topTrailing))
                        }
                    )
                    .frame(maxWidth: 430, alignment: .trailing)
                    .animation(.easeInOut(duration: 0.18), value: queue.isReduced)
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0, maximumDistance: .infinity)
                            .onChanged { isPressed in
                                guard isPressed else { return }
                                queue.clearRecentMessagesFromPointerPress(
                                    reduceOnPointerOver: reduceOnPointerOver)
                            })
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                .frame(maxWidth: 430, alignment: .trailing)
                .padding(.top, 14)
                .padding(.trailing, 16)
                .onHover {
                    if reduceOnPointerOver { queue.setPointerIsOverList($0) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .animation(.easeInOut(duration: 0.2), value: queue.visibleMessages.map(\.id))
                .accessibilityElement(children: .contain)
            }
        }
        .onAppear {
            queue.receive(messages)
        }
        .onChange(of: messages.map(\.id)) { _, _ in queue.receive(messages) }
    }
}

/// SwiftUI composition of AlertBanner's severity, heading, description, and
/// caller-owned ActionContent with ToastMessagePreview's timestamp and close.
struct AppShellAlertBanner<ActionContent: View>: View {
    let message: WorkspaceMessage
    let dismiss: () -> Void
    @ViewBuilder let actionContent: () -> ActionContent

    private var previewMessage: SharedVisualToastMessage { message.sharedVisualToastMessage }

    var body: some View {
        SharedVisualToastMessagePreview(message: previewMessage, onDismiss: dismiss, onCopy: copyMessage) {
            actionContent()
        }
    }

    private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
    }
}
