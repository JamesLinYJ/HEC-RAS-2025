import AppKit
import SwiftUI

/// Source-backed LiveMessageList presentation. Callers provide the evaluated
/// message text and optional key/value context from their actual message model.
struct SharedVisualLiveMessage: Identifiable, Hashable, Sendable {
    let id: String
    let timestamp: Date
    let operation: String
    let text: String
    let severity: WorkspaceMessageSeverity
    var context: [SharedVisualMetadataProperty] = []

    var visualSeverity: SharedVisualMessageSeverity { severity.visualSeverity }
    var severityTitleKey: String { severity.localizationKey }
    var isError: Bool { severity.isError }

    init(
        id: String,
        timestamp: Date,
        operation: String,
        text: String,
        severity: WorkspaceMessageSeverity,
        context: [SharedVisualMetadataProperty] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.operation = operation
        self.text = text
        self.severity = severity
        self.context = context
    }

    /// Compatibility for history callers that still have a two-level flag.
    init(
        id: String,
        timestamp: Date,
        operation: String,
        text: String,
        isError: Bool = false,
        context: [SharedVisualMetadataProperty] = []
    ) {
        self.init(
            id: id,
            timestamp: timestamp,
            operation: operation,
            text: text,
            severity: isError ? .error : .information,
            context: context
        )
    }
}

extension WorkspaceMessage {
    var sharedVisualLiveMessage: SharedVisualLiveMessage {
        SharedVisualLiveMessage(
            id: id.uuidString,
            timestamp: time,
            operation: operation,
            text: text,
            severity: severity
        )
    }
}

struct SharedVisualLiveMessageList: View {
    let messages: [SharedVisualLiveMessage]
    @Binding var showTimestamps: Bool
    var emptyTitle = "No messages"
    var copyToClipboard: ((String) -> Void)? = nil
    @State private var followsLatest = true
    @State private var expandedMessageIDs: Set<String> = []
    @State private var copyStatus: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Toggle(L10n.text("Show Timestamps"), isOn: $showTimestamps)
                    .toggleStyle(.button)
                Spacer()
                Button {
                    copyMessages()
                } label: {
                    Label(L10n.text("Copy Messages"), systemImage: "doc.on.doc")
                }
                Button {
                    followsLatest.toggle()
                } label: {
                    Label(L10n.text(followsLatest ? "Pause Follow" : "Follow Latest"), systemImage: followsLatest ? "pause" : "arrow.down.to.line")
                }
                .help(L10n.text(followsLatest ? "Pause following new messages" : "Follow the latest message"))
                if let copyStatus {
                    Text(L10n.text(copyStatus)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(messages) { message in
                            messageRow(message)
                                .id(message.id)
                            Divider().padding(.leading, 10)
                        }
                        Color.clear.frame(height: 1).id("shared-live-message-tail")
                    }
                }
                .overlay {
                    if messages.isEmpty {
                        ContentUnavailableView(L10n.text(emptyTitle), systemImage: "text.bubble")
                    }
                }
                .onAppear { scrollToTail(using: proxy, animated: false) }
                .onChange(of: messages.map(\.id)) { _, _ in
                    if followsLatest { scrollToTail(using: proxy) }
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting || phase == .tracking { followsLatest = false }
                }
                .onChange(of: followsLatest) { _, isFollowing in
                    if isFollowing { scrollToTail(using: proxy) }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func messageRow(_ message: SharedVisualLiveMessage) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SharedVisualErrorWarningInfoIcon(severity: message.visualSeverity, showInfoIcon: true)
                Text(L10n.text(message.severityTitleKey))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(message.visualSeverity.isError ? .red : message.visualSeverity.isWarning ? .orange : .secondary)
                if showTimestamps {
                    Text(message.timestamp, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 66, alignment: .leading)
                }
                Text(verbatim: message.operation).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text(verbatim: message.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !message.context.isEmpty {
                DisclosureGroup(
                    L10n.text("Details"),
                    isExpanded: Binding(
                        get: { expandedMessageIDs.contains(message.id) },
                        set: { isExpanded in
                            if isExpanded { expandedMessageIDs.insert(message.id) }
                            else { expandedMessageIDs.remove(message.id) }
                        }
                    )
                ) {
                    SharedVisualMetadataPropertiesRepeater(properties: message.context)
                        .padding(.leading, 8)
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { followsLatest = false }
        .accessibilityElement(children: .contain)
    }

    private func scrollToTail(using proxy: ScrollViewProxy, animated: Bool = true) {
        let action = { proxy.scrollTo("shared-live-message-tail", anchor: .bottom) }
        if animated { withAnimation(.easeOut(duration: 0.15), action) }
        else { action() }
    }

    private func copyMessages() {
        guard !messages.isEmpty else {
            copyStatus = "No messages to copy."
            return
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        let text = messages.map { message in
            let timestamp = showTimestamps ? formatter.string(from: message.timestamp) + "\t" : ""
            return timestamp + message.text + "\n"
        }.joined()
        if let copyToClipboard {
            copyToClipboard(text)
            copyStatus = "Copied to clipboard."
            return
        }
        NSPasteboard.general.clearContents()
        copyStatus = NSPasteboard.general.setString(text, forType: .string) ? "Copied to clipboard." : "Could not copy messages."
    }
}
