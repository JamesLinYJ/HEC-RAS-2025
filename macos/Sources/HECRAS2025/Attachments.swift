import AppKit
import SwiftUI

struct ImageAttachment: Identifiable, Sendable {
    let id: String
    let name: String
    let data: Data
}

/// EmbededImageControl equivalent: the source image rises slightly above its
/// neighbors while hovered. Attachments supplies the image bytes and identity.
struct OriginalEmbeddedImagePreview: View {
    let item: ImageAttachment
    @State private var isHovered = false

    var body: some View {
        Group {
            if let image = NSImage(data: item.data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 120)
                    .scaleEffect(isHovered ? 1.075 : 1)
                    .zIndex(isHovered ? 100_000 : 0)
                    .onHover { isHovered = $0 }
                    .accessibilityLabel(Text(item.name))
            }
        }
    }
}

struct Attachments: View {
    let field: SourceEditorField
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    private var items: [ImageAttachment] { session.images[field.storageID] ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Images").font(.headline)
                Spacer()
                Button("Add Image…") { Task { await importImages() } }
                    .disabled(!canEdit)
                Button("Paste Image") { pasteImage() }
                    .disabled(!canEdit)
            }
            if !items.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 12) {
                    ForEach(items) { item in
                        VStack(spacing: 6) {
                            OriginalEmbeddedImagePreview(item: item)
                            Text(item.name).font(.caption).lineLimit(1)
                        }
                        .padding(8)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .topTrailing) {
                            Button(role: .destructive) {
                                session.removeImage(field.storageID, id: item.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .secondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(!canEdit)
                            .accessibilityLabel(Text("Remove Image"))
                            .padding(4)
                        }
                        .contextMenu {
                            Button("Copy Image") {
                                if let image = NSImage(data: item.data) { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image]) }
                            }
                            Button("Remove", role: .destructive) { session.removeImage(field.storageID, id: item.id) }.disabled(!canEdit)
                        }
                    }
                }
            } else {
                Text("No images attached.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var canEdit: Bool { session.canEdit && !session.isBusy && !store.isSavingAll }
    private func importImages() async {
        guard canEdit else { return }
        let files = store.system.chooseImageFiles()
        for file in files {
            do {
                let data = try await Task.detached { try Data(contentsOf: file) }.value
                guard NSImage(data: data) != nil else { throw CocoaError(.fileReadCorruptFile) }
                session.addImage(field.storageID, image: ImageAttachment(id: UUID().uuidString, name: file.lastPathComponent, data: data))
            } catch { session.error = error.localizedDescription }
        }
    }
    private func pasteImage() {
        guard canEdit else { return }
        guard let images = NSPasteboard.general.readObjects(forClasses: [NSImage.self]) as? [NSImage] else { return }
        for image in images {
            if let data = image.tiffRepresentation {
                session.addImage(field.storageID, image: ImageAttachment(id: UUID().uuidString, name: L10n.text("Clipboard Image"), data: data))
            }
        }
    }
}
