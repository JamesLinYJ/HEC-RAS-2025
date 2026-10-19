import AppKit
import Combine
import CryptoKit
import Foundation
import RASWorkspaceCore
import SwiftUI

struct ResultPlanSettingsRequest: Encodable, Sendable {
    let projectPath: String
    let projectXml: String
    let resultPath: String
    let revision: String
}

struct ResultPlanSettingsImage: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let description: String?
    let dateLastModified: String?
    let x: Double
    let y: Double
    let byteCount: Int
    let data: Data
}

struct ResultPlanSettingsSnapshot: Decodable, Sendable {
    let projectPath: String
    let projectRevision: String
    let resultPath: String
    let revision: String
    let resultName: String
    let hasPlan: Bool
    let planName: String?
    let planDescription: String?
    let geometryName: String?
    let boundaryConditionName: String?
    let embeddedPlanGroups: [ResultPlanPropertyGroup]
    let images: [ResultPlanSettingsImage]
}

/// The owner is supplied by the exact selected Result context. A Plan HDF
/// path is never accepted as an implicit substitute for this Result identity.
struct PlanSettingsResultOwner: Equatable, Sendable {
    let projectSessionID: UUID
    let resultAssetID: String
    let resultPath: String
    let resultRevision: String
    let sourceContextID: String
}

struct PlanSettingsResultCapture: Equatable, Sendable {
    let owner: PlanSettingsResultOwner
    let resultName: String
    let assetsRevision: Int
    let projectPath: String
    let projectRevision: String
    let projectXML: String

    var identity: String {
        let values = [owner.projectSessionID.uuidString, owner.resultAssetID,
            SourceFilePaths.canonical(URL(fileURLWithPath: owner.resultPath)),
            owner.resultRevision, owner.sourceContextID, resultName,
            String(assetsRevision), SourceFilePaths.canonical(URL(fileURLWithPath: projectPath)),
            projectRevision, SHA256.hash(data: Data(projectXML.utf8))
                .map { String(format: "%02x", $0) }.joined()]
        return SHA256.hash(data: Data(values.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

struct PlanSettingsEmbeddedResultSnapshot: Sendable {
    let settings: ResultPlanSettingsSnapshot

    var context: ResultPlanContextSnapshot {
        ResultPlanContextSnapshot(projectPath: settings.projectPath,
            projectRevision: settings.projectRevision, resultPath: settings.resultPath,
            revision: settings.revision, anchorName: settings.resultName,
            anchorPlanName: settings.planName, anchorHasPlan: settings.hasPlan,
            embeddedPlanGroups: settings.embeddedPlanGroups, candidateGroups: [])
    }

    var associations: PlanResultAssociationSnapshot {
        PlanResultAssociationSnapshot(projectPath: settings.projectPath,
            projectRevision: settings.projectRevision, resultPath: settings.resultPath,
            revision: settings.revision, hasPlan: settings.hasPlan, planName: settings.planName,
            geometryName: settings.geometryName,
            boundaryConditionName: settings.boundaryConditionName)
    }

    init(settings: ResultPlanSettingsSnapshot) {
        self.settings = settings
    }
}

@MainActor
protocol PlanSettingsEmbeddedResultInspecting {
    func inspect(_ capture: PlanSettingsResultCapture) async throws -> PlanSettingsEmbeddedResultSnapshot
}

@MainActor
struct BackendPlanSettingsEmbeddedResultProvider: ResultPlanSettingsEditing {
    let client: BackendProcessClient

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func inspect(_ capture: PlanSettingsResultCapture) async throws -> PlanSettingsEmbeddedResultSnapshot {
        let request = ResultPlanSettingsRequest(
            projectPath: SourceFilePaths.canonical(URL(fileURLWithPath: capture.projectPath)),
            projectXml: capture.projectXML,
            resultPath: SourceFilePaths.canonical(URL(fileURLWithPath: capture.owner.resultPath)),
            revision: capture.owner.resultRevision)
        let settings = try await client.request("result.planSettings", parameters: request,
            as: ResultPlanSettingsSnapshot.self)
        let loaded = PlanSettingsEmbeddedResultSnapshot(settings: settings)
        guard PlanSettingsResultSession.accepts(loaded, capture: capture) else {
            throw BackendServiceError(code: "protocolFailure",
                message: L10n.text("The embedded Plan details no longer match the selected Result."))
        }
        return loaded
    }

    func save(_ capture: ResultPlanSettingsDraftCapture) async throws -> ResultPlanSettingsSaveReceipt {
        let request = ResultPlanSettingsSaveRequest(capture)
        let receipt = try await client.request("result.planSettings.save", parameters: request,
            as: ResultPlanSettingsSaveReceipt.self)
        guard ResultPlanSettingsEditorSession.accepts(receipt, capture: capture) else {
            throw BackendServiceError(code: "protocolFailure",
                message: L10n.text("The saved Result Plan does not match this draft."))
        }
        return receipt
    }
}

@MainActor
final class PlanSettingsResultSession: ObservableObject {
    @Published private(set) var snapshot: PlanSettingsEmbeddedResultSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    private let provider: any PlanSettingsEmbeddedResultInspecting
    private var generation = 0
    private var acceptedIdentity: String?
    private var lastCapture: PlanSettingsResultCapture?

    init(provider: any PlanSettingsEmbeddedResultInspecting) {
        self.provider = provider
    }

    func load(_ capture: PlanSettingsResultCapture, force: Bool = false) async {
        let identity = capture.identity
        lastCapture = capture
        guard force || acceptedIdentity != identity || snapshot == nil else { return }

        generation &+= 1
        let current = generation
        acceptedIdentity = nil
        snapshot = nil
        error = nil
        isLoading = true
        defer { if generation == current { isLoading = false } }

        do {
            let loaded = try await provider.inspect(capture)
            guard generation == current, !Task.isCancelled else { return }
            guard Self.accepts(loaded, capture: capture) else {
                throw BackendServiceError(code: "protocolFailure",
                    message: L10n.text("The embedded Plan details no longer match the selected Result."))
            }
            snapshot = loaded
            acceptedIdentity = identity
        } catch {
            guard generation == current, !Task.isCancelled else { return }
            if !(error is CancellationError) { self.error = L10n.text(error.localizedDescription) }
        }
    }

    func refresh() async {
        guard let lastCapture else { return }
        await load(lastCapture, force: true)
    }

    func isCurrent(_ capture: PlanSettingsResultCapture) -> Bool {
        lastCapture?.identity == capture.identity
    }

    func invalidate() {
        generation &+= 1
        acceptedIdentity = nil
        lastCapture = nil
        snapshot = nil
        error = nil
        isLoading = false
    }

    static func accepts(_ snapshot: PlanSettingsEmbeddedResultSnapshot,
                        capture: PlanSettingsResultCapture) -> Bool {
        let context = snapshot.context
        let associations = snapshot.associations
        let settings = snapshot.settings
        func canonical(_ path: String) -> String {
            SourceFilePaths.canonical(URL(fileURLWithPath: path))
        }

        guard canonical(context.projectPath) == canonical(capture.projectPath),
              canonical(associations.projectPath) == canonical(capture.projectPath),
              canonical(context.resultPath) == canonical(capture.owner.resultPath),
              canonical(associations.resultPath) == canonical(capture.owner.resultPath),
              context.anchorName == capture.resultName,
              context.revision.caseInsensitiveCompare(capture.owner.resultRevision) == .orderedSame,
              associations.revision.caseInsensitiveCompare(capture.owner.resultRevision) == .orderedSame,
              context.projectRevision.caseInsensitiveCompare(capture.projectRevision) == .orderedSame,
              associations.projectRevision.caseInsensitiveCompare(capture.projectRevision) == .orderedSame,
              settings.projectRevision.caseInsensitiveCompare(capture.projectRevision) == .orderedSame,
              settings.resultName == capture.resultName,
              context.anchorHasPlan == associations.hasPlan,
              context.anchorPlanName == associations.planName,
              settings.hasPlan == context.anchorHasPlan,
              settings.planName == context.anchorPlanName,
              settings.geometryName == associations.geometryName,
              settings.boundaryConditionName == associations.boundaryConditionName else { return false }

        if context.anchorHasPlan {
            guard context.anchorPlanName?.isEmpty == false,
                  context.embeddedPlanGroups.map(\.title) == ["Time Window", "Computation Options"],
                  settings.images.count <= 256 else { return false }
            var totalBytes = 0
            var imageIDs = Set<String>()
            for image in settings.images {
                guard image.id.hasPrefix("/Plan Data/Images/"),
                      !image.name.contains("/"), !image.name.contains("\\"),
                      image.id == "/Plan Data/Images/" + image.name,
                      image.byteCount == image.data.count,
                      image.byteCount <= 12 * 1024 * 1024,
                      imageIDs.insert(image.id).inserted else { return false }
                totalBytes += image.byteCount
                if totalBytes > 64 * 1024 * 1024 { return false }
            }
            return true
        }
        return context.anchorPlanName == nil && context.embeddedPlanGroups.isEmpty
            && associations.planName == nil && associations.geometryName == nil
            && associations.boundaryConditionName == nil && settings.planDescription == nil
            && settings.geometryName == nil && settings.boundaryConditionName == nil
            && settings.images.isEmpty
    }
}

struct PlanSettingsEmbeddedResultDetails: View {
    @ObservedObject var session: PlanSettingsResultSession
    let capture: PlanSettingsResultCapture?

    private var captureIsCurrent: Bool {
        guard let capture else { return false }
        return session.isCurrent(capture)
    }
    private var visibleSnapshot: PlanSettingsEmbeddedResultSnapshot? {
        guard captureIsCurrent, let capture, let snapshot = session.snapshot,
              PlanSettingsResultSession.accepts(snapshot, capture: capture) else { return nil }
        return snapshot
    }

    var body: some View {
        Section(L10n.text("Embedded Plan Context")) {
            HStack {
                Text(L10n.text("Associations stored in this Result's Plan"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await session.refresh() }
                } label: {
                    Label(L10n.text("Refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(capture == nil || session.isLoading)
            }

            Text(L10n.text("Result plans are read-only."))
                .font(.caption).foregroundStyle(.secondary)

            if capture == nil {
                Label(L10n.text("Open a saved project result to inspect its embedded plan."),
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let capture {
                Text(verbatim: capture.owner.resultPath)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(verbatim: capture.owner.resultRevision)
                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }

            if capture != nil && (session.isLoading || !captureIsCurrent) {
                ProgressView(L10n.text("Loading embedded plan context…"))
                    .controlSize(.small)
            }
            if captureIsCurrent, let error = session.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let snapshot = visibleSnapshot {
                if snapshot.context.anchorHasPlan {
                    LabeledContent(L10n.text("Plan"), value: snapshot.context.anchorPlanName ?? "—")
                        .textSelection(.enabled)
                    if let name = snapshot.associations.geometryName {
                        LabeledContent(L10n.text("Geometry"), value: name).textSelection(.enabled)
                    }
                    if let name = snapshot.associations.boundaryConditionName {
                        LabeledContent(L10n.text("Boundary Condition"), value: name).textSelection(.enabled)
                    }
                    if snapshot.associations.geometryName == nil || snapshot.associations.boundaryConditionName == nil {
                        Text(L10n.text("One or more associations are not stored on the embedded Plan."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(snapshot.context.embeddedPlanGroups) { group in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L10n.text(group.title)).font(.subheadline.weight(.semibold))
                            ForEach(group.items) { item in
                                LabeledContent(L10n.text(item.label),
                                    value: item.isLocalizedValue ? L10n.text(item.value) : item.value)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text("Plan Description")).font(.subheadline.weight(.semibold))
                        if let description = snapshot.settings.planDescription, !description.isEmpty {
                            Text(description).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(L10n.text("No description is stored on the embedded Plan."))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.text("Embedded Images")).font(.subheadline.weight(.semibold))
                        if snapshot.settings.images.isEmpty {
                            Text(L10n.text("No images are stored on the embedded Plan."))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(snapshot.settings.images) { image in
                            ResultPlanEmbeddedImageView(image: image)
                        }
                    }
                    .padding(.vertical, 3)
                } else {
                    Text(L10n.text("No embedded Plan is stored in this Result."))
                        .foregroundStyle(.secondary)
                }
            } else if captureIsCurrent && !session.isLoading && session.error == nil && capture != nil {
                Text(L10n.text("No embedded Plan computation details are available."))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("planSettingsEmbeddedResultContext")
    }
}

private struct ResultPlanEmbeddedImageView: View {
    let image: ResultPlanSettingsImage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(image.name).font(.body.weight(.medium))
            if let description = image.description, !description.isEmpty {
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            if let modified = image.dateLastModified, !modified.isEmpty {
                LabeledContent(L10n.text("Date Last Modified"), value: modified)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(verbatim: image.id)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary).textSelection(.enabled)
            Text("\(image.byteCount) bytes")
                .font(.caption2).foregroundStyle(.tertiary)
            if let image = NSImage(data: image.data) {
                Image(nsImage: image)
                    .resizable().scaledToFit()
                    .frame(maxWidth: 420, maxHeight: 260)
                    .accessibilityLabel(self.image.name)
            } else {
                Label(L10n.text("Image data could not be decoded."), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}
