import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ResultPlanSettingsEmbeddedEditorDetails: View {
    @ObservedObject var session: ResultPlanSettingsEditorSession
    let capture: PlanSettingsResultCapture?
    @State private var showImageImporter = false

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
                Text(L10n.text("Changes apply to the Plan stored in this Result."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if session.hasUnsavedChanges {
                    Label(L10n.text("Unsaved changes"), systemImage: "pencil.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Button {
                    Task { await session.refresh() }
                } label: {
                    Label(L10n.text("Refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(capture == nil || session.isBusy || session.hasUnsavedChanges)
            }

            if capture == nil {
                Label(L10n.text("Open a saved project Result to edit its embedded Plan."),
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let capture {
                Text(verbatim: capture.owner.resultPath)
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(verbatim: capture.owner.resultRevision)
                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }

            if capture != nil && session.isLoading {
                ProgressView(L10n.text("Loading embedded Plan settings…"))
                    .controlSize(.small)
            } else if capture != nil && !captureIsCurrent && session.error == nil {
                Text(L10n.text("The selected Result Plan context has changed. Reload or discard the pending draft."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = session.error {
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
                    descriptionEditor(snapshot)
                    imagesEditor(snapshot)
                } else {
                    Text(L10n.text("No embedded Plan is stored in this Result."))
                        .foregroundStyle(.secondary)
                }
            } else if captureIsCurrent && !session.isLoading && session.error == nil && capture != nil {
                Text(L10n.text("No embedded Plan computation details are available."))
                    .foregroundStyle(.secondary)
            }
        }
        .fileImporter(isPresented: $showImageImporter,
            allowedContentTypes: [.png, .jpeg], allowsMultipleSelection: true) { result in
                guard let capture else { return }
                switch result {
                case .success(let urls): Task { await session.addImages(urls, for: capture) }
                case .failure(let error): session.setError(error.localizedDescription)
                }
            }
        .accessibilityIdentifier("planSettingsEmbeddedResultEditor")
    }

    @ViewBuilder private func descriptionEditor(_ snapshot: PlanSettingsEmbeddedResultSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("Plan Description")).font(.subheadline.weight(.semibold))
            TextEditor(text: Binding(get: { session.draftDescription }, set: { session.draftDescription = $0 }))
                .frame(minHeight: 90, idealHeight: 130)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .disabled(!canEdit(snapshot))
                .accessibilityIdentifier("resultPlanDescriptionDraft")
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private func imagesEditor(_ snapshot: PlanSettingsEmbeddedResultSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.text("Embedded Images")).font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    showImageImporter = true
                } label: {
                    Label(L10n.text("Add Images"), systemImage: "plus")
                }
                .disabled(!canEdit(snapshot))
                .accessibilityIdentifier("resultPlanAddImages")
            }
            if session.draftImages.isEmpty {
                Text(L10n.text("No images are stored on the embedded Plan."))
                    .foregroundStyle(.secondary)
            }
            ForEach(session.draftImages) { image in
                ResultPlanDraftImageView(image: image)
            }
            Text(L10n.text("PNG and JPG images are added to the Result when you save the Result editor."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private func canEdit(_ snapshot: PlanSettingsEmbeddedResultSnapshot) -> Bool {
        guard let capture else { return false }
        return session.canEdit(capture) && snapshot.settings.hasPlan
    }
}

private struct ResultPlanDraftImageView: View {
    let image: ResultPlanSettingsImageDraft

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
            Text("\(image.data.count) bytes")
                .font(.caption2).foregroundStyle(.tertiary)
            if let preview = NSImage(data: image.data) {
                Image(nsImage: preview)
                    .resizable().scaledToFit()
                    .frame(maxWidth: 420, maxHeight: 260)
                    .accessibilityLabel(image.name)
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
