import Foundation
import RASWorkspaceCore
import SwiftUI

struct ClassificationClipboardPolygon: Codable, Equatable, Sendable {
    let vertices: [ClassificationVertex]
    let hasZ: Bool
    let hasM: Bool
    let classification: String
}

/// A feature clipboard, independent of catalog whole-layer copying. Ordinate
/// strings preserve source Z/M NaN values without invalid JSON numbers.
struct ClassificationFeatureClipboard: Codable, Sendable {
    static let type = "org.hecras2025.classification-polygons"
    static let textType = "public.utf8-plain-text"
    let schema: String
    let features: [ClassificationClipboardPolygon]

    init(features: [ClassificationClipboardPolygon]) {
        schema = "hecras-classification-polygons-v1"; self.features = features
    }

    func validate() throws {
        guard schema == "hecras-classification-polygons-v1", !features.isEmpty else {
            throw ProjectFileError.invalid("The clipboard does not have polygons copied to it.")
        }
        for feature in features {
            guard feature.vertices.count >= 3,
                  feature.vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                  Set(feature.vertices.map { [$0.x, $0.y] }).count >= 3,
                  !feature.hasZ || feature.vertices.allSatisfy({ $0.z.flatMap { Double($0) } != nil }),
                  !feature.hasM || feature.vertices.allSatisfy({ $0.m.flatMap { Double($0) } != nil }) else {
                throw ProjectFileError.invalid("The copied polygon geometry is invalid.")
            }
        }
    }

    @MainActor static func read(system: any WorkspaceSystemServices) throws -> Self {
        for item in system.readClipboard(types: [type, textType]) {
            for representation in [type, textType] {
                if let data = item.representations[representation],
                   let payload = try? JSONDecoder().decode(Self.self, from: data) {
                    try payload.validate(); return payload
                }
            }
        }
        throw ProjectFileError.invalid("The clipboard does not have polygons copied to it.")
    }

    @MainActor static func copy(_ polygons: [ClassificationMapPolygon], session: ModelEditorSession,
                                system: any WorkspaceSystemServices) throws {
        let payload = Self(features: polygons.map {
            .init(vertices: $0.item.vertices, hasZ: $0.item.hasZ, hasM: $0.item.hasM,
                  classification: session.fields[$0.item.fieldID] ?? $0.item.classification)
        })
        try payload.validate()
        let data = try JSONEncoder().encode(payload)
        guard system.writeClipboard([.init(representations: [type: data, textType: data])]) else {
            throw ProjectFileError.invalid("The polygon features could not be copied to the clipboard.")
        }
    }
}

struct ClassificationPasteFeaturesButton: View {
    let inputID: String?
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @State private var request: PasteRequest?
    @State private var error: String?

    private struct PasteRequest: Identifiable {
        let id = UUID()
        let projectSessionID: UUID
        let editorID: UUID
        let identity: String
        let inputID: String
        let features: [ClassificationClipboardPolygon]
    }

    private var hasTarget: Bool {
        guard let inputID, session.fields[ClassificationEditorContract.sourceField] == inputID else { return false }
        return session.sourceCollections[ClassificationEditorContract.sourceField]?.itemDetails[inputID]?.polygons != nil
    }

    var body: some View {
        Button("Paste Features…", systemImage: "doc.on.clipboard") {
            guard let inputID, hasTarget else { return }
            do {
                let clipboard = try ClassificationFeatureClipboard.read(system: store.system)
                request = .init(projectSessionID: store.projectSessionID, editorID: session.id,
                    identity: session.classificationMapIdentity, inputID: inputID, features: clipboard.features)
                error = nil
            } catch { self.error = L10n.text(error.localizedDescription) }
        }
        .disabled(!hasTarget || !session.canEdit || session.isBusy || session.hasIncompleteEditorInput)
        .sheet(item: $request) { capture in
            ClassificationPasteFeaturesSheet(features: capture.features,
                classes: session.sourceCollections[ClassificationEditorContract.sourceField]?.classificationTools?.classes ?? [],
                isCurrent: {
                    store.projectSessionID == capture.projectSessionID && session.id == capture.editorID
                        && session.classificationMapIdentity == capture.identity && hasTarget
                        && session.fields[ClassificationEditorContract.sourceField] == capture.inputID
                }, paste: { features in
                    await session.perform(.editClassificationGeometry(.init(operation: "paste",
                        inputId: capture.inputID, features: features)))
                }, failureMessage: { session.error })
        }
        .alert("Paste Features", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
}

private struct ClassificationPasteFeaturesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var features: [ClassificationClipboardPolygon]
    let classes: [String]
    let isCurrent: () -> Bool
    let paste: ([ClassificationClipboardPolygon]) async -> Bool
    let failureMessage: () -> String?
    @State private var isPasting = false
    @State private var error: String?
    private var points: [MapPoint] { features.flatMap { $0.vertices.map(\.point) } }

    var body: some View {
        VStack(spacing: 12) {
            Text("Paste Features").font(.title2).frame(maxWidth: .infinity, alignment: .leading)
            HSplitView {
                List(features.indices, id: \.self) { index in
                    VStack(alignment: .leading) {
                        Text(L10n.format("%d vertices", features[index].vertices.count)).font(.caption).foregroundStyle(.secondary)
                        TextField("Classification", text: Binding(get: { features[index].classification }, set: { value in
                            let old = features[index]
                            features[index] = .init(vertices: old.vertices, hasZ: old.hasZ, hasM: old.hasM, classification: value)
                        }))
                        .textInputSuggestions { ForEach(classes, id: \.self) { Text($0).textInputCompletion($0) } }
                    }
                }.frame(minWidth: 200)
                Canvas { context, size in
                    let transform = MapTransform(points: points, size: size, scale: 1, offset: .zero)
                    for feature in features {
                        let geometry = MapFeature(id: 0, kind: .polygon, paths: [feature.vertices.map(\.point)], attributes: [:])
                        let path = transform.path(geometry)
                        context.fill(path, with: .color(.accentColor.opacity(0.18)))
                        context.stroke(path, with: .color(.accentColor), lineWidth: 1)
                    }
                }.frame(minWidth: 260, minHeight: 220).background(.background)
            }
            if !isCurrent() { Label("The selected classification input changed. Reopen Paste Features.", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Text(L10n.format("%d polygons", features.count)).font(.caption)
                Spacer()
                if isPasting { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isPasting)
                Button("Paste Features") {
                    guard isCurrent(), !isPasting else { return }
                    isPasting = true
                    Task {
                        if await paste(features) { dismiss() }
                        else { error = failureMessage().map { L10n.text($0) } ?? L10n.text("The polygon features could not be pasted.") }
                        isPasting = false
                    }
                }.keyboardShortcut(.defaultAction).disabled(isPasting || !isCurrent())
            }
        }.padding(20).frame(minWidth: 620, idealWidth: 760, minHeight: 360)
            .interactiveDismissDisabled(isPasting)
    }
}
