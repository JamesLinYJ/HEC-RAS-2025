import SwiftUI

/// The native shell presents the live WorkspaceMessage queue over its work
/// surface; the Messages pane continues to retain the complete history.
struct AppShellWindowContent: View {
    @ObservedObject var store: WorkspaceStore
    let launchConfiguration: WorkspaceLaunchConfiguration
    @State private var postCrashRecovery: AppShellPostCrashRecoveryContext?
    @State private var showsSpreadsheet = false

    init(store: WorkspaceStore, launchConfiguration: WorkspaceLaunchConfiguration = .currentProcess) {
        self.store = store
        self.launchConfiguration = launchConfiguration
        _postCrashRecovery = State(initialValue: nil)
    }

    var body: some View {
        Group {
            if let pipe = launchConfiguration.streamPipeName {
                StreamModeView(session: store.streamMode, initialPipeName: pipe)
            } else {
                WorkspaceView(store: store)
            }
        }
            .focusedSceneValue(\.workspaceSpreadsheetAction, { showsSpreadsheet = true })
            .overlay(alignment: .topTrailing) {
                AppToastView(messages: store.messages) { message in
                    if let action = message.defaultAction {
                        Button(L10n.text(action.titleKey), systemImage: action.systemImage) {
                            _ = store.performMessageDefaultAction(message)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .sheet(item: $postCrashRecovery) { context in
                AppShellPostCrashRecoveryView(store: store, context: context) { _ in
                    store.requestReportIssue(fromCrash: true)
                    postCrashRecovery = nil
                } onContinue: {
                    postCrashRecovery = nil
                }
                .environment(\.locale, store.interfaceLocale)
            }
            .onAppear {
                guard !launchConfiguration.hasStreamMode,
                      launchConfiguration.postCrashLaunch, postCrashRecovery == nil else { return }
                postCrashRecovery = AppShellPostCrashRecoveryContext(
                    summary: L10n.text("The previous HEC-RAS session stopped unexpectedly."),
                    errorLogURL: AppShellPostCrashRecoveryContext.existingDefaultErrorLogURL())
            }
            .sheet(isPresented: $showsSpreadsheet) {
                WorkspaceSpreadsheetView()
                    .environment(\.locale, store.interfaceLocale)
            }
    }
}

/// Native counterpart to the Project Explorer update banner. It is only
/// presented for a compatible release returned by the configured provider.
struct AppShellUpdateAvailableBanner: View {
    let release: AppRelease
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Update Available").font(.headline)
                Text(release.version).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("View Update", action: onOpen)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.thinMaterial)
        .accessibilityElement(children: .contain)
    }
}

/// A real error context supplied by the caller that observed a failure. The
/// recovery view deliberately has no process-wide crash detection of its own.
struct AppShellPostCrashRecoveryContext: Identifiable {
    let id: UUID
    let summary: String
    let errorLogURL: URL?

    /// Matches LogHelper.DefaultLogLocation("ras-errors.log") under the
    /// platform's Application Support directory, but only returns an existing
    /// readable file and never creates one.
    static func existingDefaultErrorLogURL(fileManager: FileManager = .default) -> URL? {
        guard let supportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let logURL = supportDirectory
            .appendingPathComponent("HEC", isDirectory: true)
            .appendingPathComponent("RAS", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("ras-errors.log", isDirectory: false)
        guard fileManager.isReadableFile(atPath: logURL.path) else { return nil }
        return logURL
    }

    init(error: Error, errorLogURL: URL? = Self.existingDefaultErrorLogURL()) {
        self.id = UUID()
        self.summary = error.localizedDescription
        self.errorLogURL = errorLogURL
    }

    init(summary: String, errorLogURL: URL? = Self.existingDefaultErrorLogURL()) {
        self.id = UUID()
        self.summary = summary
        self.errorLogURL = errorLogURL
    }
}

/// Native counterpart to PostCrashControl. A caller presents this view only
/// after it has a real error context and passes the logger's actual local URL.
struct AppShellPostCrashRecoveryView: View {
    @ObservedObject var store: WorkspaceStore
    let context: AppShellPostCrashRecoveryContext
    let onReportBug: (AppShellPostCrashRecoveryContext) -> Void
    let onContinue: () -> Void

    private var readableErrorLogURL: URL? {
        guard let url = context.errorLogURL,
              url.isFileURL,
              FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("HEC-RAS stopped unexpectedly", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.orange)

            Text(context.summary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let logURL = readableErrorLogURL {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Error Log").font(.headline)
                    Text(logURL.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            } else {
                Label("The error log is not available at the supplied local file URL.", systemImage: "doc.questionmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Open Error Log", systemImage: "doc.text.magnifyingglass") {
                    guard let url = readableErrorLogURL else { return }
                    store.system.reveal(url)
                    store.system.openFile(url)
                }
                .disabled(readableErrorLogURL == nil)

                Spacer()

                Button("Report Bug", systemImage: "square.and.pencil") {
                    onReportBug(context)
                }

                Button("Continue", systemImage: "arrow.right") {
                    onContinue()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 460, idealWidth: 560, maxWidth: 680, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
