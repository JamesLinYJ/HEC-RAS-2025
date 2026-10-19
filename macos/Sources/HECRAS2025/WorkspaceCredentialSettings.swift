import Security
import SwiftUI

/// Keeps the original developer credentials, Testing Utility endpoint, and
/// GPU Hub token in one native settings route. Authentication and URL
/// persistence go through the providers injected by WorkspaceStore.
@MainActor
struct CredentialsSettingsView: View {
    @ObservedObject var store: WorkspaceStore
    @StateObject private var developerSession: DeveloperSession
    @State private var accessKey = ""
    @State private var secretKey = ""
    @State private var utilityURL = ""
    @State private var gpuHubToken = ""
    @State private var configurationMessage: String?
    @State private var configurationError: String?
    @State private var tokenMessage: String?
    @State private var tokenError: String?

    init(store: WorkspaceStore) {
        self.store = store
        _developerSession = StateObject(wrappedValue: DeveloperSession(provider: store.developerProvider))
    }

    private var authenticated: Bool { developerSession.snapshot?.authenticated == true }

    var body: some View {
        Form {
            Section("S3 Storage Credentials") {
                LabeledContent("Authentication") {
                    if developerSession.isCheckingAuthentication {
                        Label("Checking authentication", systemImage: "hourglass")
                    } else if authenticated {
                        Label("Authenticated", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if developerSession.available {
                        Label("Not authenticated", systemImage: "xmark.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Authentication unavailable", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }

                TextField("S3 Access Key", text: $accessKey)
                    .textContentType(.username)
                    .disabled(!developerSession.available || developerSession.busy)
                SecureField("S3 Secret Key", text: $secretKey)
                    .textContentType(.password)
                    .disabled(!developerSession.available || developerSession.busy)

                HStack {
                    Button("Authenticate") { authenticate() }
                        .disabled(!developerSession.available || developerSession.busy || accessKey.isEmpty || secretKey.isEmpty)
                    Button("Clear Credentials", role: .destructive) { clearS3Credentials() }
                        .disabled(developerSession.busy || store.developerCredentialStore.load() == nil)
                }
                if developerSession.busy { ProgressView().controlSize(.small) }
                if let error = developerSession.error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                Text("Testing Utility file transfers use these authenticated S3 credentials.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Testing Utility") {
                TextField("Testing Utility URL", text: $utilityURL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                HStack {
                    Button("Save URL") { saveUtilityURL() }
                    Button("Use Default") {
                        utilityURL = ""
                        saveUtilityURL()
                    }
                }
                if let configurationMessage {
                    Label(configurationMessage, systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let configurationError {
                    Text(configurationError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                if store.suppressesAppDataIO {
                    Text("Settings are kept for this launch only.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("GPU-Hub Token") {
                SecureField("GPU-Hub Token", text: $gpuHubToken)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                HStack {
                    Button("Save Token") { saveGPUHubToken() }
                        .disabled(gpuHubToken.isEmpty)
                    Button("Clear Token", role: .destructive) { clearGPUHubToken() }
                        .disabled(!WorkspaceGpuHubTokenVault.hasToken(
                            applicationUID: store.applicationUID,
                            persistentStorageAllowed: !store.suppressesAppDataIO
                        ))
                }
                if let tokenMessage {
                    Label(tokenMessage, systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let tokenError {
                    Text(tokenError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                if store.suppressesAppDataIO {
                    Text("The token is held in memory only for this launch and is not sent by this settings screen.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("The token is stored in Keychain and is not sent by this settings screen.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("GPU Hub compute is not registered in the active native app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 620, idealWidth: 760, minHeight: 580, idealHeight: 700)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Spacer()
                Button("Done") { store.activeTool = nil }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            .background(.bar)
        }
        .task {
            utilityURL = store.testingUtilityBaseURL
            accessKey = store.developerCredentialStore.load()?.accessKey ?? ""
            gpuHubToken = WorkspaceGpuHubTokenVault.load(
                applicationUID: store.applicationUID,
                persistentStorageAllowed: !store.suppressesAppDataIO
            ) ?? ""
            await developerSession.load()
        }
        .onDisappear { developerSession.invalidate() }
    }

    private func authenticate() {
        let key = accessKey
        let secret = secretKey
        Task {
            await developerSession.authenticate(key: key, secret: secret)
            if authenticated { secretKey = "" }
        }
    }

    private func clearS3Credentials() {
        do {
            try store.developerCredentialStore.delete()
            accessKey = ""
            secretKey = ""
            Task { await developerSession.load() }
        } catch {
            developerSession.error = L10n.text(error.localizedDescription)
        }
    }

    private func saveUtilityURL() {
        do {
            try store.setTestingUtilityBaseURL(utilityURL)
            utilityURL = store.testingUtilityBaseURL
            configurationError = nil
            configurationMessage = store.suppressesAppDataIO
                ? L10n.text("Saved for this launch") : L10n.text("Saved")
        } catch {
            configurationMessage = nil
            configurationError = L10n.text(error.localizedDescription)
        }
    }

    private func saveGPUHubToken() {
        do {
            try WorkspaceGpuHubTokenVault.save(
                gpuHubToken,
                applicationUID: store.applicationUID,
                persistentStorageAllowed: !store.suppressesAppDataIO
            )
            tokenError = nil
            tokenMessage = store.suppressesAppDataIO
                ? L10n.text("Saved for this launch") : L10n.text("Saved securely in Keychain")
        } catch {
            tokenMessage = nil
            tokenError = L10n.text(error.localizedDescription)
        }
    }

    private func clearGPUHubToken() {
        do {
            try WorkspaceGpuHubTokenVault.delete(
                applicationUID: store.applicationUID,
                persistentStorageAllowed: !store.suppressesAppDataIO
            )
            gpuHubToken = ""
            tokenError = nil
            tokenMessage = L10n.text("Token cleared")
        } catch {
            tokenMessage = nil
            tokenError = L10n.text(error.localizedDescription)
        }
    }
}

/// The source only exposed GpuHubToken as an AppData field; the native app has
/// no registered IGpuHubCredentialProvider. Keep the editable token private to
/// Keychain and never put it in backend request, progress, or log payloads.
@MainActor
private enum WorkspaceGpuHubTokenVault {
    private static let service = "org.hecras2025.gpu-hub"
    private static let account = "token"
    private static var sessionTokens: [String: String] = [:]

    static func load(applicationUID: String, persistentStorageAllowed: Bool) -> String? {
        guard persistentStorageAllowed else { return sessionTokens[applicationUID] }
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func hasToken(applicationUID: String, persistentStorageAllowed: Bool) -> Bool {
        guard let token = load(applicationUID: applicationUID,
                               persistentStorageAllowed: persistentStorageAllowed) else { return false }
        return !token.isEmpty
    }

    static func save(_ token: String, applicationUID: String,
                     persistentStorageAllowed: Bool) throws {
        guard !token.isEmpty else { throw WorkspaceGpuHubTokenError.empty }
        guard persistentStorageAllowed else {
            sessionTokens[applicationUID] = token
            return
        }
        let query = baseQuery
        let data = Data(token.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
                throw WorkspaceGpuHubTokenError.keychain
            }
        } else if status != errSecSuccess {
            throw WorkspaceGpuHubTokenError.keychain
        }
    }

    static func delete(applicationUID: String, persistentStorageAllowed: Bool) throws {
        guard persistentStorageAllowed else {
            sessionTokens.removeValue(forKey: applicationUID)
            return
        }
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw WorkspaceGpuHubTokenError.keychain
        }
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

private enum WorkspaceGpuHubTokenError: LocalizedError {
    case empty
    case keychain

    var errorDescription: String? {
        switch self {
        case .empty: "Enter a GPU-Hub token before saving."
        case .keychain: "The GPU-Hub token could not be saved in Keychain."
        }
    }
}
