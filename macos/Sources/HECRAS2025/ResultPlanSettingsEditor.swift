import Combine
import CryptoKit
import Foundation
import UniformTypeIdentifiers
import RASWorkspaceCore

struct ResultPlanSettingsImageDraft: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var description: String?
    var dateLastModified: String?
    var x: Double
    var y: Double
    var data: Data
}

struct ResultPlanSettingsDraftCapture: Equatable, Sendable {
    let result: PlanSettingsResultCapture
    let planName: String
    let planDescription: String
    let images: [ResultPlanSettingsImageDraft]
    let generation: Int

    var identity: String {
        var values = [result.identity, planName, planDescription, String(generation)]
        for image in images {
            let digest = SHA256.hash(data: image.data).map { String(format: "%02x", $0) }.joined()
            values.append([image.id, image.name, image.description ?? "<nil>",
                image.dateLastModified ?? "<nil>", String(image.x), String(image.y), digest]
                .joined(separator: "\u{1f}"))
        }
        return SHA256.hash(data: Data(values.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

struct ResultPlanSettingsSaveRequest: Encodable, Sendable {
    let projectPath: String
    let projectXml: String
    let projectRevision: String
    let resultPath: String
    let revision: String
    let planName: String
    let planDescription: String
    let images: [ResultPlanSettingsImageDraft]

    init(_ capture: ResultPlanSettingsDraftCapture) {
        projectPath = SourceFilePaths.canonical(URL(fileURLWithPath: capture.result.projectPath))
        projectXml = capture.result.projectXML
        projectRevision = capture.result.projectRevision
        resultPath = SourceFilePaths.canonical(URL(fileURLWithPath: capture.result.owner.resultPath))
        revision = capture.result.owner.resultRevision
        planName = capture.planName
        planDescription = capture.planDescription
        images = capture.images
    }
}

struct ResultPlanSettingsSaveReceipt: Decodable, Sendable {
    let resultPath: String
    let previousRevision: String
    let revision: String
    let planName: String
    let planDescription: String
    let snapshot: ResultPlanSettingsSnapshot
}

private struct ResultPlanSettingsLoadedImage: Sendable {
    let name: String
    let path: String
    let dateLastModified: String?
    let data: Data
}

@MainActor
protocol ResultPlanSettingsEditing: PlanSettingsEmbeddedResultInspecting {
    func save(_ capture: ResultPlanSettingsDraftCapture) async throws -> ResultPlanSettingsSaveReceipt
}

/// Long-lived child editor owned by the Result ModelEditorSession. Its draft
/// survives page changes, and its save capture always names the exact Result
/// and embedded Plan revision that was inspected.
@MainActor
final class ResultPlanSettingsEditorSession: ObservableObject {
    @Published private(set) var snapshot: PlanSettingsEmbeddedResultSnapshot? {
        didSet { notifyParentDraftChange() }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var isImporting = false
    @Published private(set) var error: String?
    @Published var draftDescription = "" {
        didSet {
            if oldValue != draftDescription {
                generation &+= 1
                notifyParentDraftChange()
            }
        }
    }
    @Published private(set) var draftImages: [ResultPlanSettingsImageDraft] = [] {
        didSet { if oldValue != draftImages { notifyParentDraftChange() } }
    }
    var onParentDraftChange: (@MainActor (Bool) -> Void)? {
        didSet { notifyParentDraftChange() }
    }

    private let provider: any ResultPlanSettingsEditing
    private var generation = 0
    private var loadGeneration = 0
    private var draftEpoch = 0
    private var activeImports = 0
    private var acceptedIdentity: String?
    private var lastCapture: PlanSettingsResultCapture?

    init(provider: any ResultPlanSettingsEditing) {
        self.provider = provider
    }

    private func notifyParentDraftChange() {
        onParentDraftChange?(hasUnsavedChanges)
    }

    var isBusy: Bool { isLoading || isSaving || isImporting }
    var currentOwnerCapture: PlanSettingsResultCapture? {
        guard let lastCapture, acceptedIdentity == lastCapture.identity else { return nil }
        return lastCapture
    }
    var canSave: Bool {
        guard !isBusy, let lastCapture, acceptedIdentity == lastCapture.identity,
              let snapshot, snapshot.settings.hasPlan else { return false }
        return hasUnsavedChanges
    }
    var hasUnsavedChanges: Bool {
        guard let snapshot, snapshot.settings.hasPlan else { return false }
        return draftDescription != (snapshot.settings.planDescription ?? "")
            || draftImages.contains(where: { $0.id.hasPrefix("draft:") })
    }

    func load(_ capture: PlanSettingsResultCapture, force: Bool = false) async {
        if hasUnsavedChanges {
            if lastCapture?.identity != capture.identity {
                error = L10n.text("The Result or project context changed while this Result Plan draft is pending. Discard the draft before loading the new selection.")
            } else if force {
                error = L10n.text("Discard the pending Result Plan changes before refreshing from the Result file.")
            }
            return
        }
        let identity = capture.identity
        if !force, acceptedIdentity == identity, snapshot != nil {
            lastCapture = capture
            return
        }
        draftEpoch &+= 1
        lastCapture = capture

        loadGeneration &+= 1
        let requestGeneration = loadGeneration
        acceptedIdentity = nil
        snapshot = nil
        error = nil
        isLoading = true
        defer { if loadGeneration == requestGeneration { isLoading = false } }

        do {
            let loaded = try await provider.inspect(capture)
            guard loadGeneration == requestGeneration, !Task.isCancelled else { return }
            guard PlanSettingsResultSession.accepts(loaded, capture: capture) else {
                throw BackendServiceError(code: "protocolFailure",
                    message: L10n.text("The embedded Plan details no longer match the selected Result."))
            }
            snapshot = loaded
            draftDescription = loaded.settings.planDescription ?? ""
            draftImages = Self.imageDrafts(loaded.settings.images)
            acceptedIdentity = identity
            error = nil
        } catch {
            guard loadGeneration == requestGeneration, !Task.isCancelled else { return }
            if !(error is CancellationError) { self.error = L10n.text(error.localizedDescription) }
        }
    }

    func refresh() async {
        guard let lastCapture else { return }
        guard !hasUnsavedChanges else {
            error = L10n.text("Discard the pending Result Plan changes before refreshing from the Result file.")
            return
        }
        await load(lastCapture, force: true)
    }

    func isCurrent(_ capture: PlanSettingsResultCapture) -> Bool {
        lastCapture?.identity == capture.identity && acceptedIdentity == capture.identity
    }

    func canEdit(_ capture: PlanSettingsResultCapture) -> Bool {
        isCurrent(capture) && !isBusy && snapshot?.settings.hasPlan == true
    }

    func captureDraft() -> ResultPlanSettingsDraftCapture? {
        guard canSave, let capture = lastCapture,
              let planName = snapshot?.settings.planName else { return nil }
        return ResultPlanSettingsDraftCapture(result: capture, planName: planName,
            planDescription: draftDescription, images: draftImages, generation: generation)
    }

    func captureDraft(for currentOwner: PlanSettingsResultCapture) -> ResultPlanSettingsDraftCapture? {
        guard isCurrent(currentOwner) else { return nil }
        return captureDraft()
    }

    func addImages(_ urls: [URL], for capture: PlanSettingsResultCapture) async {
        guard canEdit(capture), !urls.isEmpty else { return }
        let identity = capture.identity
        let operationEpoch = draftEpoch
        activeImports += 1
        isImporting = true
        defer {
            activeImports -= 1
            isImporting = activeImports > 0
        }
        do {
            var added: [ResultPlanSettingsImageDraft] = []
            for url in urls {
                let ext = url.pathExtension.lowercased()
                guard ext == "png" || ext == "jpg" else {
                    throw BackendServiceError(code: "invalidInput",
                        message: L10n.text("Only PNG and JPG images can be added to the embedded Plan."))
                }
                let didAccess = url.startAccessingSecurityScopedResource()
                let loaded: ResultPlanSettingsLoadedImage
                do {
                    loaded = try await Task.detached(priority: .userInitiated) {
                        let data = try Data(contentsOf: url, options: .mappedIfSafe)
                        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                        let dateLastModified: String?
                        if let modified = values?.contentModificationDate {
                            let formatter = DateFormatter()
                            formatter.locale = Locale(identifier: "en_US_POSIX")
                            formatter.timeZone = .current
                            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                            dateLastModified = formatter.string(from: modified)
                        } else {
                            dateLastModified = nil
                        }
                        return ResultPlanSettingsLoadedImage(name: url.deletingPathExtension().lastPathComponent,
                            path: url.path,
                            dateLastModified: dateLastModified,
                            data: data)
                    }.value
                    if didAccess { url.stopAccessingSecurityScopedResource() }
                } catch {
                    if didAccess { url.stopAccessingSecurityScopedResource() }
                    throw error
                }
                let data = loaded.data
                guard !data.isEmpty, data.count <= 12 * 1024 * 1024 else {
                    throw BackendServiceError(code: "invalidInput",
                        message: L10n.text("Each embedded image must contain data and fit within 12 MiB."))
                }
                let name = loaded.name
                guard !name.isEmpty, !name.contains("/"), !name.contains("\\") else {
                    throw BackendServiceError(code: "invalidInput",
                        message: L10n.text("The selected image has an invalid name."))
                }
                guard !draftImages.contains(where: { $0.name == name }),
                      !added.contains(where: { $0.name == name }) else {
                    throw BackendServiceError(code: "invalidInput",
                        message: L10n.text("An embedded image with this name already exists."))
                }
                added.append(ResultPlanSettingsImageDraft(
                    id: "draft:" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                    name: name, description: "Imported from \(loaded.path)",
                    dateLastModified: loaded.dateLastModified,
                    x: 0, y: 0, data: data))
                guard draftImages.count + added.count <= 256,
                      draftImages.reduce(Int64(0), { $0 + Int64($1.data.count) })
                        + added.reduce(Int64(0), { $0 + Int64($1.data.count) }) <= 64 * 1024 * 1024 else {
                    throw BackendServiceError(code: "invalidInput",
                        message: L10n.text("The embedded Plan images exceed the 64 MiB total limit."))
                }
            }
            guard draftEpoch == operationEpoch, lastCapture?.identity == identity,
                  acceptedIdentity == identity, !Task.isCancelled else { return }
            let newImages = draftImages + added
            guard newImages.count <= 256,
                  newImages.reduce(Int64(0), { $0 + Int64($1.data.count) }) <= 64 * 1024 * 1024 else {
                throw BackendServiceError(code: "invalidInput",
                    message: L10n.text("The embedded Plan images exceed the 64 MiB total limit."))
            }
            draftImages = newImages
            generation &+= 1
            error = nil
        } catch {
            guard draftEpoch == operationEpoch, lastCapture?.identity == identity,
                  !Task.isCancelled, !(error is CancellationError) else { return }
            self.error = L10n.text(error.localizedDescription)
        }
    }

    func save(_ capture: ResultPlanSettingsDraftCapture) async throws -> ResultPlanSettingsSaveReceipt {
        guard canSave, capture.generation == generation,
              lastCapture?.identity == capture.result.identity,
              captureDraft()?.identity == capture.identity else {
            throw BackendServiceError(code: "sourceChanged",
                message: L10n.text("The Result Plan draft changed or its source is no longer current."))
        }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            let receipt = try await provider.save(capture)
            guard Self.accepts(receipt, capture: capture) else {
                throw BackendServiceError(code: "protocolFailure",
                    message: L10n.text("The saved Result Plan does not match this draft."))
            }
            return receipt
        } catch {
            saveFailed(capture, message: error.localizedDescription)
            throw error
        }
    }

    func accept(_ capture: ResultPlanSettingsDraftCapture, savedSnapshot: ResultPlanSettingsSnapshot) {
        guard lastCapture?.identity == capture.result.identity,
              PlanSettingsResultSession.accepts(
                PlanSettingsEmbeddedResultSnapshot(settings: savedSnapshot),
                capture: capture.result.withResultRevision(savedSnapshot.revision)) else {
            error = L10n.text("The saved Result Plan no longer matches the selected Result.")
            return
        }
        let nextCapture = capture.result.withResultRevision(savedSnapshot.revision)
        draftEpoch &+= 1
        let wrapped = PlanSettingsEmbeddedResultSnapshot(settings: savedSnapshot)
        let changedWhileSaving = generation != capture.generation
        let currentDescription = draftDescription
        let currentImages = draftImages
        snapshot = wrapped
        lastCapture = nextCapture
        acceptedIdentity = nextCapture.identity
        if changedWhileSaving {
            if currentDescription == capture.planDescription {
                draftDescription = savedSnapshot.planDescription ?? ""
            } else {
                draftDescription = currentDescription
            }
            let savedByID = Dictionary(uniqueKeysWithValues: savedSnapshot.images.map { ($0.id, Self.imageDraft($0)) })
            let savedByContent = Dictionary(grouping: savedSnapshot.images, by: { $0.name })
            let capturedIDs = Set(capture.images.map(\.id))
            draftImages = currentImages.map { item in
                if let exact = savedByID[item.id] { return exact }
                guard capturedIDs.contains(item.id) else { return item }
                guard let matching = savedByContent[item.name]?.first(where: { $0.data == item.data }) else { return item }
                return Self.imageDraft(matching)
            }
        } else {
            draftDescription = savedSnapshot.planDescription ?? ""
            draftImages = Self.imageDrafts(savedSnapshot.images)
        }
        generation &+= 1
        error = nil
    }

    func accept(_ capture: ResultPlanSettingsDraftCapture, receipt: ResultPlanSettingsSaveReceipt) {
        guard Self.accepts(receipt, capture: capture) else {
            saveFailed(capture, message: L10n.text("The saved Result Plan does not match this draft."))
            return
        }
        accept(capture, savedSnapshot: receipt.snapshot)
    }

    func saveFailed(_ capture: ResultPlanSettingsDraftCapture, message: String) {
        guard lastCapture?.identity == capture.result.identity else { return }
        error = L10n.text(message)
    }

    func setError(_ message: String) {
        error = L10n.text(message)
    }

    func discard() {
        draftEpoch &+= 1
        if let snapshot, snapshot.settings.hasPlan {
            draftDescription = snapshot.settings.planDescription ?? ""
            draftImages = Self.imageDrafts(snapshot.settings.images)
        } else {
            draftDescription = ""
            draftImages = []
        }
        generation &+= 1
        error = nil
    }

    func invalidateOwner() {
        guard !hasUnsavedChanges else {
            error = L10n.text("Discard the pending Result Plan changes before closing this Result editor.")
            return
        }
        generation &+= 1
        draftEpoch &+= 1
        loadGeneration &+= 1
        acceptedIdentity = nil
        lastCapture = nil
        snapshot = nil
        draftImages = []
        error = nil
        isLoading = false
        isSaving = false
    }

    static func accepts(_ receipt: ResultPlanSettingsSaveReceipt,
                        capture: ResultPlanSettingsDraftCapture) -> Bool {
        SourceFilePaths.canonical(URL(fileURLWithPath: receipt.resultPath))
            == SourceFilePaths.canonical(URL(fileURLWithPath: capture.result.owner.resultPath))
            && receipt.previousRevision.caseInsensitiveCompare(capture.result.owner.resultRevision) == .orderedSame
            && receipt.revision.caseInsensitiveCompare(receipt.snapshot.revision) == .orderedSame
            && receipt.planName == capture.planName
            && receipt.planDescription == capture.planDescription
            && receipt.snapshot.planName == capture.planName
            && receipt.snapshot.planDescription == capture.planDescription
    }

    private static func imageDrafts(_ images: [ResultPlanSettingsImage]) -> [ResultPlanSettingsImageDraft] {
        images.map(imageDraft)
    }

    private static func imageDraft(_ image: ResultPlanSettingsImage) -> ResultPlanSettingsImageDraft {
        ResultPlanSettingsImageDraft(id: image.id, name: image.name,
            description: image.description, dateLastModified: image.dateLastModified,
            x: image.x, y: image.y, data: image.data)
    }

}

private extension PlanSettingsResultCapture {
    func withResultRevision(_ revision: String) -> PlanSettingsResultCapture {
        let updatedOwner = PlanSettingsResultOwner(projectSessionID: owner.projectSessionID,
            resultAssetID: owner.resultAssetID, resultPath: owner.resultPath,
            resultRevision: revision, sourceContextID: owner.sourceContextID)
        return PlanSettingsResultCapture(owner: updatedOwner, resultName: resultName,
            assetsRevision: assetsRevision, projectPath: projectPath,
            projectRevision: projectRevision, projectXML: projectXML)
    }
}
