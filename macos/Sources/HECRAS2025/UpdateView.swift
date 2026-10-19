import SwiftUI

struct AppRelease: Identifiable, Sendable {
    let id: String
    let version: String
    let publicationDate: Date?
    let notes: String
    let notesURL: URL?
    let platform: String
    let architecture: String
    let packageFilename: String?
    let packageSHA256: String?
    let packageLength: Int64?
    let packageManifestKey: String?
    let packageStatus: String
    let channel: String
    let branch: String
    init(id: String, version: String, publicationDate: Date?, notes: String, notesURL: URL?,
         platform: String, architecture: String, packageFilename: String? = nil,
         packageSHA256: String? = nil, packageLength: Int64? = nil,
         packageManifestKey: String? = nil, packageStatus: String = "unavailable",
         channel: String = "Beta", branch: String = "master") {
        self.id = id; self.version = version; self.publicationDate = publicationDate
        self.notes = notes; self.notesURL = notesURL; self.platform = platform
        self.architecture = architecture; self.packageFilename = packageFilename
        self.packageSHA256 = packageSHA256; self.packageLength = packageLength
        self.packageManifestKey = packageManifestKey; self.packageStatus = packageStatus
        self.channel = channel; self.branch = branch
    }
    var isCompatible: Bool {
        packageStatus == "available" && platform == "macOS" && ["arm64", "universal"].contains(architecture)
    }
}

/// The renamed updater validates developer credentials against the selected
/// release bucket. Keep that result separate from the mere presence of saved
/// credentials so the native InfoBar never labels unchecked credentials as
/// authenticated or invalid.
enum UpdateCredentialStatus: Sendable {
    case unknown
    case notConfigured
    case authenticated(account: String)
    case invalid
}

struct UpdateSnapshot: Sendable {
    let channels: [EditorChoice]
    let branches: [String]
    let selectedChannel: String
    let selectedBranch: String
    let canChangeChannel: Bool
    let hasDeveloperCredentials: Bool
    let credentialStatus: UpdateCredentialStatus
    let releases: [AppRelease]
    let isUpToDate: Bool?

    init(channels: [EditorChoice], branches: [String], selectedChannel: String, selectedBranch: String,
         canChangeChannel: Bool, hasDeveloperCredentials: Bool, releases: [AppRelease], isUpToDate: Bool?,
         credentialStatus: UpdateCredentialStatus = .unknown) {
        self.channels = channels
        self.branches = branches
        self.selectedChannel = selectedChannel
        self.selectedBranch = selectedBranch
        self.canChangeChannel = canChangeChannel
        self.hasDeveloperCredentials = hasDeveloperCredentials
        self.credentialStatus = credentialStatus
        self.releases = releases
        self.isUpToDate = isUpToDate
    }
}
@MainActor
protocol UpdateProvider {
    func check(channel: String, branch: String) async throws -> UpdateSnapshot
    func install(_ release: AppRelease, progress: @escaping @MainActor @Sendable (Double) -> Void) async throws
    func cancel() async throws
    func clearCredentials() async throws
}

@MainActor
final class UpdateSession: ObservableObject {
    enum State { case idle, unavailable, checking, current, available, failed, installing, packageOpened }
    enum CredentialNotice { case cleared }
    @Published private(set) var state = State.idle
    @Published var channel = "Beta"
    @Published var branch = "master"
    @Published private(set) var snapshot: UpdateSnapshot?
    @Published private(set) var progress: Double?
    @Published private(set) var error: String?
    @Published private(set) var credentialNotice: CredentialNotice?
    private let provider: (any UpdateProvider)?
    private var revision = 0
    init(provider: (any UpdateProvider)?) { self.provider = provider }
    var busy: Bool { state == .checking || state == .installing }
    var canCheck: Bool { provider != nil && !busy }
    func check(preservingCredentialNotice: Bool = false) async {
        if !preservingCredentialNotice { credentialNotice = nil }
        guard let provider else { state = .unavailable; return }
        guard !busy else { return }
        revision += 1; let current = revision
        state = .checking; error = nil
        do {
            let result = try await provider.check(channel: channel, branch: branch)
            guard current == revision else { return }
            snapshot = result; channel = result.selectedChannel; branch = result.selectedBranch
            if let upToDate = result.isUpToDate { state = upToDate ? .current : .available }
            else { state = .failed }
        } catch { if current == revision { self.error = error.localizedDescription; state = .failed } }
    }
    func install(_ release: AppRelease) async {
        guard let provider, !busy, release.isCompatible else { return }
        revision += 1; let current = revision
        state = .installing; progress = nil; error = nil
        do {
            try await provider.install(release) { [weak self] value in
                guard let self, revision == current, value.isFinite else { return }
                progress = min(max(value, 0), 1)
            }
            guard current == revision else { return }
            state = .packageOpened
        } catch { if current == revision { self.error = error.localizedDescription; state = .failed } }
    }
    func cancel() async {
        guard let provider, state == .installing else { return }
        do { try await provider.cancel(); revision += 1; state = .idle; progress = nil }
        catch { self.error = error.localizedDescription }
    }
    func clearCredentials() async {
        guard let provider, !busy else { return }
        do {
            try await provider.clearCredentials()
            channel = "Beta"
            branch = "master"
            credentialNotice = .cleared
            await check(preservingCredentialNotice: true)
        }
        catch { self.error = error.localizedDescription }
    }
}

// UpdaterMainPage's channels/branches, release history and progress states.
// A platform-neutral update boundary replaces the Windows installer route.
struct UpdateView: View {
    @ObservedObject var store: WorkspaceStore
    @StateObject private var session: UpdateSession
    @State private var selection: String?
    private let onClose: (@MainActor () -> Void)?
    init(store: WorkspaceStore, onClose: (@MainActor () -> Void)? = nil, session suppliedSession: UpdateSession? = nil) {
        self.store = store
        self.onClose = onClose
        let session = suppliedSession ?? UpdateSession(provider: store.updateProvider)
        if session.state == .idle { session.channel = store.updateInitialChannel }
        _session = StateObject(wrappedValue: session)
    }
    private var selected: AppRelease? {
        guard let snapshot = session.snapshot,
              snapshot.selectedChannel == session.channel,
              snapshot.selectedBranch == session.branch else { return nil }
        return snapshot.releases.first { $0.id == selection }
    }
    var body: some View {
        VStack(spacing: 0) {
            credentialInfoBar
            Form {
                Section("Software Update") {
                    LabeledContent("Installed Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                    Picker("Release Channel", selection: $session.channel) {
                        ForEach(session.snapshot?.channels ?? []) { channel in Text(L10n.text(channel.title)).tag(channel.id) }
                        if session.snapshot?.channels.contains(where: { $0.id == session.channel }) != true { Text(L10n.text(session.channel)).tag(session.channel) }
                    }.disabled(session.snapshot?.canChangeChannel != true || session.busy)
                    if let branches = session.snapshot?.branches, branches.count > 1 {
                        Picker("Branch", selection: $session.branch) { ForEach(branches, id: \.self) { Text($0).tag($0) } }.disabled(session.busy)
                    }
                    status
                    if let error = session.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
            }.formStyle(.grouped).frame(height: 230)
            Divider()
            HSplitView {
                List(session.snapshot?.releases ?? [], selection: $selection) { release in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(release.version).font(.headline)
                        if let date = release.publicationDate { Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) }
                        if !release.isCompatible { Text(packageAvailability(release)).font(.caption).foregroundStyle(.secondary) }
                    }.tag(release.id)
                }.listStyle(.sidebar).frame(minWidth: 150, idealWidth: 200)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let selected {
                            Text(selected.version).font(.title2)
                            Text(selected.notes).textSelection(.enabled)
                            if let url = selected.notesURL { Button("Release Notes") { store.system.openWebsite(url) } }
                        } else { ContentUnavailableView("Release History", systemImage: "clock.arrow.circlepath", description: Text("Select a release to read its notes.")) }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minWidth: 300)
            }
            Divider()
            HStack {
                Spacer()
                if session.state == .installing { Button("Cancel") { Task { await session.cancel() } } }
                Button("Check for Updates") { Task { await session.check() } }.disabled(!session.canCheck)
                Button("Open Installer Package") { if let selected { Task { await session.install(selected) } } }
                    .disabled(selected?.isCompatible != true || session.busy || session.state == .unavailable)
                Button("Done") { if let onClose { onClose() } else { store.showUpdates = false } }.keyboardShortcut(.cancelAction).disabled(session.state == .installing)
            }.padding(16)
        }.frame(minWidth: 650, minHeight: 520)
            .interactiveDismissDisabled(session.state == .installing)
        .task { if session.state == .idle { await session.check() } }
            .onChange(of: session.channel) { old, new in
                guard old != new else { return }
                store.updateInitialChannel = new
                if !session.busy { Task { await session.check() } }
            }
            .onChange(of: session.branch) { old, new in if old != new, !session.busy { Task { await session.check() } } }
    }
    @ViewBuilder private var credentialInfoBar: some View {
        if case .some(.cleared) = session.credentialNotice {
            credentialInfoRow(
                title: "Credentials cleared",
                message: L10n.text("Developer credentials have been removed. Using Beta update channel."),
                symbol: "checkmark.circle.fill",
                tint: .green
            )
        } else if let snapshot = session.snapshot {
            switch snapshot.credentialStatus {
            case .unknown where snapshot.hasDeveloperCredentials:
                credentialInfoRow(
                    title: "Developer credentials are configured",
                    message: L10n.text("The update source has not confirmed whether these credentials are valid."),
                    symbol: "key.fill",
                    tint: .secondary,
                    showsClear: true
                )
            case .authenticated(let account):
                credentialInfoRow(
                    title: "Using Developer Credentials",
                    message: L10n.format("Authenticated as %@", account),
                    symbol: "checkmark.seal.fill",
                    tint: .green
                )
            case .invalid:
                credentialInfoRow(
                    title: "Developer credentials are invalid",
                    message: L10n.text("Showing Beta releases instead. Re-authenticate in Dev Tools or clear your credentials."),
                    symbol: "exclamationmark.triangle.fill",
                    tint: .orange,
                    showsClear: true,
                    showsDeveloperTools: true
                )
            case .unknown, .notConfigured:
                EmptyView()
            }
        }
    }

    private func credentialInfoRow(title: String, message: String, symbol: String, tint: Color,
                                   showsClear: Bool = false, showsDeveloperTools: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(tint).font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text(title)).font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if showsDeveloperTools {
                Button("Developer Tools…") {
                    store.showUpdates = false
                    Task { @MainActor in
                        await Task.yield()
                        store.showDeveloperTools = true
                    }
                }
            }
            if showsClear {
                Button("Clear Credentials", role: .destructive) { Task { await session.clearCredentials() } }
                    .disabled(session.busy)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    @ViewBuilder private var status: some View {
        switch session.state {
        case .idle: LabeledContent("Status", value: "—")
        case .unavailable: Label("Update source unavailable", systemImage: "externaldrive.badge.questionmark")
        case .checking: ProgressView("Checking for Updates…")
        case .current: Label("Up to Date", systemImage: "checkmark.circle").foregroundStyle(.green)
        case .available: Label("Update Available", systemImage: "arrow.down.circle")
        case .failed: Label("Unable to Check for Updates", systemImage: "exclamationmark.triangle")
        case .installing:
            if let progress = session.progress { ProgressView("Preparing Installer…", value: progress, total: 1) }
            else { ProgressView("Preparing Installer…") }
        case .packageOpened:
            VStack(alignment: .leading, spacing: 4) {
                Label("Installer Package Opened", systemImage: "shippingbox")
                Text("Follow the opened package to finish the update.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func packageAvailability(_ release: AppRelease) -> String {
        switch release.packageStatus {
        case "manifestUnavailable": "Release package details are unavailable."
        case "invalidManifest": "The release package information could not be verified."
        default: "No compatible macOS installer package."
        }
    }
}
