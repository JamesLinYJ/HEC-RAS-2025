import AppKit
import SwiftUI

enum CredentialStatus: String, Sendable {
    case waiting = "Logged Out", trying = "Logging In...", authenticated = "Logged In", rejected = "Invalid Credentials"
}
struct ReportComponent: Identifiable, Sendable {
    let id: String
    let name: String
    let attachesGeometry: Bool
}
struct ReportDatum: Identifiable, Sendable {
    let id: String
    let label: String
    let value: String
}
struct SupportPresentation: Sendable {
    var credentialStatus = CredentialStatus.waiting
    var canLogin = false
    var canClearCredentials = false
    var components: [ReportComponent] = []
    var geometryChoices: [EditorChoice] = []
    var knownIssuesURL: URL? = nil
    var dataSent: [ReportDatum] = []
    var updateAvailable = false
    var showsModelForm = false
    // The renamed JiraBugModelForm.UploadModel is a Task.CompletedTask stub.
    // A source adapter must implement actual upload before enabling Submit.
    var modelUploadImplemented = false
}

struct ReportSystemInfo: Sendable {
    let os: String
    let cores: String
    let timezone: String
    init() {
        #if os(macOS)
        os = "macOS (" + ProcessInfo.processInfo.operatingSystemVersionString + ")"
        #elseif os(Windows)
        os = "Windows (" + ProcessInfo.processInfo.operatingSystemVersionString + ")"
        #elseif os(Linux)
        os = "Linux (" + ProcessInfo.processInfo.operatingSystemVersionString + ")"
        #else
        os = ProcessInfo.processInfo.operatingSystemVersionString
        #endif
        cores = String(ProcessInfo.processInfo.processorCount); timezone = TimeZone.current.identifier
    }
}

enum BugReportLimits {
    static let email = 1000, summary = 100, description = 3000
    static let screenshots = 4, screenshotBytes = 16 * 1024 * 1024
    static let imageField = "JiraBugReportForm/Files"
    static let defaultDescription = "1. Describe the bug.\n\n\n2. Provide specific steps to reproduce the issue (if relevant).\n\n\n3. Is this a recent regression? Did it work in a prior version?\n\n\n4. Do you know any workarounds for this bug?\n\n"
    static func valid(fields: [String: String]) -> Bool {
        let title = fields["JiraBugReportForm/Report_Summary"] ?? ""
        let details = fields["JiraBugReportForm/Report_Description"] ?? ""
        return !title.isEmpty && !details.isEmpty && title.utf16.count <= summary && details.utf16.count <= description
            && (fields["JiraBugReportForm/Report_Email"] ?? "").utf16.count <= email
    }
}

struct CredentialsContent: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var state: DataToolSession
    @ObservedObject var editor: ModelEditorSession
    let clear: @MainActor () -> Void
    private var source: SupportPresentation { state.presentation.support ?? .init() }
    private var status: CredentialStatus { state.executingOperation == .login ? .trying : source.credentialStatus }
    var body: some View {
        Form {
            Section("Credentials") {
                TextField("Username", text: text("Key"))
                SecureField("Password", text: text("Secret"))
                SecureField("GPU-Hub Token", text: text("Ras_Interface_WinUI_AppData_RasApplicationData_Instance_DevAppData_GpuHubToken"))
                TextField("Testing Utility URL", text: text("Ras_Interface_WinUI_AppData_RasApplicationData_Instance_DevAppData_TestingUtilityUrl"))
            }.disabled(!editor.canEdit)
            Section {
                HStack {
                    if status == .trying { ProgressView().controlSize(.small) }
                    Label(LocalizedStringKey(status.rawValue), systemImage: status == .authenticated ? "checkmark.circle.fill" : status == .rejected ? "xmark.circle.fill" : "person.crop.circle")
                        .foregroundStyle(status == .authenticated ? .green : status == .rejected ? .red : .secondary)
                    Spacer()
                    Button("Clear", role: .destructive, action: clear).disabled(!source.canClearCredentials || state.busy)
                }
            }
        }.formStyle(.grouped)
    }
    private func text(_ id: String) -> Binding<String> {
        let key = "CredentialsPage/" + id
        return Binding(get: { editor.fields[key] ?? "" }, set: { editor.set(key, $0) })
    }
}

struct BugReportContent: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var state: DataToolSession
    @ObservedObject var editor: ModelEditorSession
    @State private var showingUpdate = false
    private var source: SupportPresentation { state.presentation.support ?? .init() }
    private var attachesGeometry: Bool { source.components.contains { state.reportComponentIDs.contains($0.id) && $0.attachesGeometry } }
    private var images: [ImageAttachment] { editor.images[BugReportLimits.imageField] ?? [] }
    var body: some View {
        if source.showsModelForm { modelForm }
        else {
            Form {
                if source.updateAvailable {
                    Section {
                        HStack { Label("Update Available", systemImage: "arrow.down.circle"); Spacer(); Button("View Update") { showingUpdate = true } }
                    }
                }
                Section("Bug Report") {
                    HStack { Spacer(); Button("Known Issues") { if let url = source.knownIssuesURL { store.system.openWebsite(url) } }.disabled(source.knownIssuesURL == nil) }
                    TextField("Title", text: text("Report_Summary"))
                    counter("Report_Summary", limit: BugReportLimits.summary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Description").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: text("Report_Description")).frame(minHeight: 140).accessibilityLabel("Description")
                        counter("Report_Description", limit: BugReportLimits.description)
                    }
                }
                Section("Tags (check all that apply)") {
                    ForEach(source.components) { component in
                        Toggle(isOn: Binding(get: { state.reportComponentIDs.contains(component.id) }, set: { selected in
                            if selected { state.reportComponentIDs.insert(component.id) } else { state.reportComponentIDs.remove(component.id) }
                        })) { Text(verbatim: component.name) }
                    }
                    if source.components.isEmpty { Text("No report categories available.").foregroundStyle(.secondary) }
                }
                Section("Email (optional)") {
                    TextField("Email", text: text("Report_Email"))
                    counter("Report_Email", limit: BugReportLimits.email)
                }
                Section("Screenshots") {
                    HStack {
                        Text("Up to 4 images, 16 MB each.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Browse", action: importScreenshots).disabled(images.count >= BugReportLimits.screenshots)
                        Button("Clear") { for image in images { editor.removeImage(BugReportLimits.imageField, id: image.id) } }.disabled(images.isEmpty)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))]) {
                        ForEach(images) { attachment in
                            VStack(spacing: 8) {
                                if let image = NSImage(data: attachment.data) { Image(nsImage: image).resizable().scaledToFit().frame(height: 110) }
                                Text(attachment.name).font(.caption).lineLimit(1)
                            }.contextMenu { Button("Remove") { editor.removeImage(BugReportLimits.imageField, id: attachment.id) } }
                        }
                    }
                }
                if attachesGeometry {
                    Section("Geometry") {
                        Picker("Geometry", selection: text("SelectedGeometry")) {
                            Text("None").tag("")
                            ForEach(source.geometryChoices) { choice in Text(verbatim: choice.title).tag(choice.id) }
                        }
                    }
                }
                Section("Data sent with report") {
                    ForEach(source.dataSent.filter { !["Os", "Cores", "Timezone"].contains($0.id) }) { datum in LabeledContent(LocalizedStringKey(datum.label), value: datum.value).textSelection(.enabled) }
                    let system = ReportSystemInfo()
                    LabeledContent("Operating System", value: system.os)
                    LabeledContent("Processor Cores", value: system.cores)
                    LabeledContent("Time Zone", value: system.timezone)
                }
            }.formStyle(.grouped).disabled(!editor.canEdit)
                .sheet(isPresented: $showingUpdate) { UpdateView(store: store, onClose: { showingUpdate = false }) }
        }
    }
    private var modelForm: some View {
        Form {
            Section("Send Your Model") { TextField("Developer Provided Key", text: Binding(get: { editor.fields["JiraBugModelForm/Key"] ?? "" }, set: { editor.set("JiraBugModelForm/Key", $0) })) }
        }.formStyle(.grouped)
    }
    private func text(_ id: String) -> Binding<String> {
        let key = "JiraBugReportForm/" + id
        return Binding(get: { editor.fields[key] ?? "" }, set: { editor.set(key, $0) })
    }
    private func counter(_ id: String, limit: Int) -> some View {
        let length = (editor.fields["JiraBugReportForm/" + id] ?? "").utf16.count
        return Text("\(length) / \(limit)").font(.caption).foregroundStyle(length > limit ? .red : .secondary).frame(maxWidth: .infinity, alignment: .trailing)
    }
    private func importScreenshots() {
        let files = store.system.chooseBugScreenshots()
        guard files.count + images.count <= BugReportLimits.screenshots else { state.error = L10n.text("A maximum of 4 screenshots can be attached."); return }
        do {
            var attachments: [ImageAttachment] = []
            for file in files {
                let scoped = file.startAccessingSecurityScopedResource()
                defer { if scoped { file.stopAccessingSecurityScopedResource() } }
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= BugReportLimits.screenshotBytes else { throw ReportAttachmentError.tooLarge }
                let data = try Data(contentsOf: file)
                guard data.count <= BugReportLimits.screenshotBytes, NSImage(data: data) != nil else { throw ReportAttachmentError.invalid }
                attachments.append(.init(id: UUID().uuidString, name: file.lastPathComponent, data: data))
            }
            for image in attachments { editor.addImage(BugReportLimits.imageField, image: image) }
        } catch { state.error = L10n.text(error.localizedDescription) }
    }
}

private enum ReportAttachmentError: LocalizedError {
    case tooLarge, invalid
    var errorDescription: String? { self == .tooLarge ? "Each screenshot must be 16 MB or smaller." : "The screenshot is not a readable image." }
}
