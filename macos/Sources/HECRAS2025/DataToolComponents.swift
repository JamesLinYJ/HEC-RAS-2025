import RASWorkspaceCore
import SwiftUI

struct DataToolField: View {
    let schema: String
    let id: String
    var scope: String? = nil
    @ObservedObject var editor: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    var body: some View {
        if let field = SourceEditorLibrary.shared.schema(schema)?.fields.first(where: { $0.id == id }) {
            SourceField(field: field.inScope(scope), session: editor, store: store)
        }
    }
}

struct DataToolPreviewView: View {
    let preview: DataToolPreview
    let loading: Bool
    let isCurrent: Bool
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var drag: CGSize = .zero
    private var points: [MapPoint] {
        if let extent = preview.extent { return [extent.lowerLeft, extent.upperRight] }
        return preview.rasters.flatMap(\.points) + preview.vectors.flatMap { $0.layer.points }
    }
    var body: some View {
        GeometryReader { proxy in
            let currentOffset = CGSize(width: offset.width + drag.width, height: offset.height + drag.height)
            let transform = MapTransform(points: points, size: proxy.size, scale: scale, offset: currentOffset)
            ZStack {
                Color(nsColor: .textBackgroundColor)
                RasterCanvas(layers: preview.rasters, points: points, scale: scale, offset: currentOffset,
                    revision: preview.revision.hashValue)
                Canvas { drawing, _ in
                    for item in preview.vectors {
                        for feature in item.layer.features {
                            let path = transform.path(feature)
                            if feature.kind != .line { drawing.fill(path, with: .color(EditorColor.decode(item.fillColor)), style: FillStyle(eoFill: true)) }
                            drawing.stroke(path, with: .color(EditorColor.decode(item.lineColor)), lineWidth: item.lineWidth)
                        }
                    }
                }.allowsHitTesting(false)
                if preview.isEmpty && !loading {
                    ContentUnavailableView("No preview available", systemImage: "map")
                }
                if loading { ProgressView().controlSize(.large) }
            }
            .contentShape(Rectangle()).clipped()
            .gesture(DragGesture().updating($drag) { value, state, _ in state = value.translation }.onEnded { value in
                offset.width += value.translation.width; offset.height += value.translation.height
            })
            .simultaneousGesture(MagnifyGesture().onEnded { value in scale = min(1e6, max(1e-6, scale * value.magnification)) })
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 14) {
                    Button { scale = min(1e6, scale * 1.3) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom In")
                    Button { scale = max(1e-6, scale / 1.3) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom Out")
                    Button { scale = 1; offset = .zero } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Zoom to Full Extent")
                }.buttonStyle(.borderless).padding(12).glassEffect(.regular, in: .capsule).padding(12)
                .disabled(preview.isEmpty)
            }
            .overlay(alignment: .bottomLeading) {
                if !preview.isEmpty && !isCurrent && !loading {
                    Label("Update preview to reflect changed settings.", systemImage: "arrow.clockwise")
                        .font(.caption).padding(10).glassEffect(.regular, in: .rect(cornerRadius: 10)).padding(12)
                }
            }
        }
        .onChange(of: preview.revision) { _, _ in scale = 1; offset = .zero }
    }
}

struct DataLayerList: View {
    let title: String
    @ObservedObject var state: DataToolSession
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(LocalizedStringKey(title)).font(.headline).padding(12)
            List(selection: $state.selectedSettingsLayerID) {
                ForEach(state.presentation.layers) { layer in
                    HStack {
                        Toggle(isOn: Binding(get: { state.selectedLayerIDs.contains(layer.id) }, set: { selected in
                            if selected { state.selectedLayerIDs.insert(layer.id) } else { state.selectedLayerIDs.remove(layer.id) }
                        })) { EmptyView() }.labelsHidden().toggleStyle(.checkbox)
                        VStack(alignment: .leading) {
                            Text(layer.name).lineLimit(1)
                            if !layer.detail.isEmpty { Text(layer.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                    }.tag(layer.id)
                }
            }.overlay { if state.presentation.layers.isEmpty { Text("No layers loaded").foregroundStyle(.secondary) } }
        }.disabled(state.busy)
    }
}

struct DataFileList: View {
    @ObservedObject var state: DataToolSession
    @ObservedObject var store: WorkspaceStore
    let changed: () -> Void
    var multiple = true
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Input Files").font(.headline)
                Spacer()
                Button("Add Files…") {
                    let chosen = multiple ? store.system.chooseInputFiles() : store.system.chooseConnectionFile().map { [$0] } ?? []
                    add(chosen)
                }
            }
            ForEach(state.inputFiles, id: \.standardizedFileURL) { file in
                HStack {
                    Text(file.lastPathComponent).lineLimit(1).help(file.path)
                    Spacer()
                    Button { state.inputFiles.removeAll { $0.standardizedFileURL == file.standardizedFileURL }; changed() } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Remove File")
                }
            }
            if state.inputFiles.isEmpty { Text("Choose files or drop them here.").font(.caption).foregroundStyle(.secondary) }
        }.padding(12).disabled(state.busy)
        .dropDestination(for: URL.self) { files, _ in
            guard !state.busy else { return false }; add(files); return true
        }
    }
    private func add(_ files: [URL]) {
        let valid = files.filter(\.isFileURL)
        guard !valid.isEmpty else { return }
        if multiple {
            for file in valid where !state.inputFiles.contains(where: { $0.standardizedFileURL == file.standardizedFileURL }) { state.inputFiles.append(file) }
        } else { state.inputFiles = Array(valid.prefix(1)) }
        changed()
    }
}
