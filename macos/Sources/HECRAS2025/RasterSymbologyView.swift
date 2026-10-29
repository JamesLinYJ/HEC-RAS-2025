import SwiftUI

struct RasterSymbologyView: View {
    @ObservedObject var store: WorkspaceStore
    @StateObject private var session = RasterSymbologySession()
    @State private var search = ""
    @State private var showSave = false
    @State private var saveName = ""
    @State private var mapID: UUID
    @State private var assetID: String?
    init(store: WorkspaceStore) {
        self.store = store
        _mapID = State(initialValue: store.lastActiveMapID)
        _assetID = State(initialValue: store.rasterMapSourcesForActiveMap.first?.id)
    }
    private var context: RasterSymbologyContext {
        .init(projectSessionID: store.projectSessionID, mapID: mapID, assetID: assetID,
              sourceContextRevision: store.assetsRevision)
    }
    private var shownPalettes: [RasterPalette] {
        session.palettes.filter { !$0.name.hasPrefix("__") && (search.isEmpty || (!$0.isCustom && L10n.text($0.name).localizedCaseInsensitiveContains(search)) || $0.name.localizedCaseInsensitiveContains(search)) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Raster Symbology", systemImage: "paintpalette").font(.title2)
                Spacer()
                if session.busy { ProgressView().controlSize(.small) }
            }.padding(20)
            sourcePicker.padding(.horizontal, 20).padding(.bottom, 12)
            Divider()
            HSplitView {
                paletteList.frame(minWidth: 220, idealWidth: 270, maxWidth: 380)
                editor.frame(minWidth: 350, maxWidth: .infinity)
            }
            Divider()
            HStack {
                Button("Reset") { Task { await session.reset(provider: store.rasterSymbologyProvider) } }
                    .disabled(session.draft == nil || store.rasterSymbologyProvider == nil || session.busy || store.isRunningRasterMutation)
                Spacer()
                Button("Cancel", role: .cancel) { store.activeTool = nil }.keyboardShortcut(.cancelAction).disabled(session.busy || store.isRunningRasterMutation)
                Button("Apply") {
                    Task {
                        if await session.apply(provider: store.rasterSymbologyProvider) { store.activeTool = nil; store.mapRevision += 1 }
                    }
                }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(session.draft == nil || store.rasterSymbologyProvider == nil || session.busy || store.isRunningRasterMutation)
            }.padding(16)
        }
        .frame(minWidth: 700, idealWidth: 820, maxWidth: 1100, minHeight: 480, idealHeight: 650, maxHeight: 900)
        .interactiveDismissDisabled(session.busy || store.isRunningRasterMutation)
        .task(id: context) { await session.load(context: context, provider: store.rasterSymbologyProvider) }
        .onChange(of: store.lastActiveMapID) { _, value in
            mapID = value
            assetID = store.rasterMapSourcesForActiveMap.first?.id
        }
        .onChange(of: store.rasterMapSources.map(\.id)) { _, _ in
            if !store.rasterMapSourcesForActiveMap.contains(where: { $0.id == assetID }) {
                assetID = store.rasterMapSourcesForActiveMap.first?.id
            }
        }
        .onDisappear { session.invalidate() }
        .alert("HEC-RAS 2025", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
            Button("OK") { session.error = nil }
        } message: { Text(L10n.text(session.error ?? "")) }
        .sheet(isPresented: $showSave) { savePaletteSheet }
    }
    private var sourcePicker: some View {
        let sources = store.rasterMapSourcesForActiveMap
        return HStack {
            Picker("Raster Layer", selection: Binding(get: { assetID ?? "" }, set: { assetID = $0.isEmpty ? nil : $0 })) {
                Text("Select Raster Layer").tag("")
                ForEach(sources) { source in
                    Text("\(source.nodeName) — \(source.mapName)").tag(source.id)
                }
            }
            .disabled(sources.isEmpty || session.busy || store.isRunningRasterMutation)
            Spacer(minLength: 0)
        }
    }
    private var paletteList: some View {
        VStack(spacing: 0) {
            TextField("Search Color Palettes", text: $search).textFieldStyle(.roundedBorder).padding(12)
            List {
                ForEach([false, true], id: \.self) { custom in
                    Section(custom ? "Custom" : "Default") {
                        ForEach(shownPalettes.filter { $0.isCustom == custom }) { palette in
                            Button {
                                Task { await session.choose(palette.id, provider: store.rasterSymbologyProvider) }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        paletteName(palette)
                                        Spacer()
                                        if palette.id == session.selectedPaletteID { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                    }
                                    RasterPalettePreview(colors: palette.colors).frame(height: 16)
                                }.padding(.vertical, 4).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .contextMenu {
                                    if palette.isCustom {
                                        Button("Delete", role: .destructive) { Task { await session.delete(palette.id, provider: store.rasterSymbologyProvider) } }
                                            .disabled(store.rasterSymbologyProvider == nil)
                                    }
                                }
                        }
                    }
                }
            }.disabled(session.busy || store.isRunningRasterMutation)
        }
    }
    @ViewBuilder
    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let context = session.interpolatedSurfaceFillContext {
                    InterpolatedSurfaceFillEditorView(context: context)
                }
                RasterPalettePreview(colors: session.previewColors).frame(height: 30)
                    .accessibilityLabel("Color Palette Preview")
                if let draft = session.draft {
                    Form {
                        Section("Symbology") {
                            Toggle("Grayscale", isOn: flag(\.grayscale))
                            Toggle("Edit Symbology", isOn: flag(\.isEditing))
                            Toggle("Update Histogram With View", isOn: flag(\.updateHistogramWithView))
                                .disabled(!draft.canComputeHistogram)
                            Picker("Value Source", selection: Binding(get: { session.draft?.valueSource ?? .manual }, set: { value in
                                Task { await session.setSource(value, provider: store.rasterSymbologyProvider) }
                            })) {
                                ForEach(RasterValueSource.allCases, id: \.self) { mode in
                                    Text(LocalizedStringKey(mode.rawValue)).tag(mode).disabled(mode == .histogram && !draft.canComputeHistogram)
                                }
                            }.disabled(!draft.isEditing)
                        }
                        if !session.additionalOptions.isEmpty {
                            Section("Additional Options") {
                                ForEach(session.additionalOptions) { option in
                                    if option.isBoolean {
                                        Toggle(L10n.text(option.title), isOn: Binding(
                                            get: { option.value.lowercased() == "true" },
                                            set: { session.setAdditional(option.id, value: String($0)) }
                                        ))
                                        .disabled(!option.isEnabled)
                                        .help(L10n.text(option.description ?? ""))
                                    } else {
                                        Picker(L10n.text(option.title), selection: Binding(
                                            get: { option.value },
                                            set: { session.setAdditional(option.id, value: $0) }
                                        )) {
                                            ForEach(option.choices) { choice in
                                                Text(L10n.text(choice.title)).tag(choice.id)
                                            }
                                        }
                                        .disabled(!option.isEnabled)
                                        .help(L10n.text(option.description ?? ""))
                                    }
                                }
                            }
                        }
                    }.formStyle(.grouped)
                    Text(LocalizedStringKey(modeHelp(draft.valueSource))).font(.caption).foregroundStyle(.secondary)
                    VStack(spacing: 8) {
                        HStack { Text("Color"); Spacer(); Text("Value").frame(width: 130); Color.clear.frame(width: 62, height: 1) }.font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(draft.stops.enumerated()), id: \.element.id) { index, stop in
                            stopRow(stop, index: index, draft: draft)
                        }
                    }
                    HStack {
                        Button { Task { await session.refreshHistogram(provider: store.rasterSymbologyProvider) } } label: {
                            Label("Update For View", systemImage: "arrow.clockwise")
                        }.disabled(!draft.canComputeHistogram || !draft.isEditing)
                        Spacer()
                        Button("Save Symbology…") { saveName = session.uniqueCustomName; showSave = true }.disabled(!draft.isEditing)
                    }
                } else {
                    if store.rasterSymbologyProvider == nil {
                        ContentUnavailableView("Raster Symbology Unavailable", systemImage: "exclamationmark.icloud", description: Text("The source raster symbology provider is not connected."))
                    } else {
                        ContentUnavailableView("No Raster Selected", systemImage: "square.3.layers.3d", description: Text("Select a raster layer to edit its symbology."))
                    }
                }
            }.padding(18).disabled(session.busy || store.isRunningRasterMutation)
        }
    }
    private func stopRow(_ stop: RasterColorStop, index: Int, draft: RasterSymbologyDraft) -> some View {
        HStack(spacing: 8) {
            ColorPicker("Color", selection: Binding(get: { EditorColor.decode(stop.color) }, set: { color in
                session.edit { value in
                    if let row = value.stops.firstIndex(where: { $0.id == stop.id }) { value.stops[row].color = EditorColor.encode(color) }
                }
            }), supportsOpacity: false).labelsHidden().disabled(!draft.isEditing)
            Spacer()
            TextField("Value", value: Binding(get: { stop.value }, set: { number in
                guard number.isFinite else { return }
                session.edit { value in
                    if let row = value.stops.firstIndex(where: { $0.id == stop.id }) { value.stops[row].value = number }
                }
            }), format: .number.precision(.significantDigits(1...12)))
                .textFieldStyle(.roundedBorder).frame(width: 130).disabled(!draft.valueIsEditable(at: index))
                .foregroundStyle(draft.valueIsIncreasing(at: index) ? Color.primary : Color.red)
                .help(draft.valueIsIncreasing(at: index) ? "" : L10n.text("Each value should be greater than the previous value."))
            Button { Task { await session.changeRows(at: stop.id, adding: true, provider: store.rasterSymbologyProvider) } } label: { Image(systemName: "plus") }
                .help("Add Below").disabled(!draft.isEditing || draft.valueSource == .histogram && !draft.canComputeHistogram)
            Button { Task { await session.changeRows(at: stop.id, adding: false, provider: store.rasterSymbologyProvider) } } label: { Image(systemName: "minus") }
                .help("Delete Row").disabled(!draft.isEditing || draft.stops.count <= 1 || draft.valueSource == .histogram && !draft.canComputeHistogram)
        }
    }
    private func flag(_ keyPath: WritableKeyPath<RasterSymbologyDraft, Bool>) -> Binding<Bool> {
        Binding(get: { session.draft?[keyPath: keyPath] ?? false }, set: { newValue in session.edit { $0[keyPath: keyPath] = newValue } })
    }
    @ViewBuilder private func paletteName(_ palette: RasterPalette) -> some View {
        if palette.isCustom { Text(palette.name) } else { Text(LocalizedStringKey(palette.name)) }
    }
    private func modeHelp(_ mode: RasterValueSource) -> String {
        switch mode {
        case .histogram: "Use a computed histogram from the layer to fill in values."
        case .linear: "Linear interpolate from the first value to the last value."
        case .manual: "Manually enter each value for each color."
        }
    }
    private var savePaletteSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save Symbology").font(.title2)
            TextField("Name", text: $saveName).textFieldStyle(.roundedBorder)
            if let error = session.error { Text(L10n.text(error)).foregroundStyle(.red).font(.caption) }
            if !session.nameIsValid(saveName) { Text("Enter a name that is not reserved or a default palette name.").foregroundStyle(.red).font(.caption) }
            else if session.overwritesCustom(saveName) { Text("Custom symbology already exists. This will overwrite the existing symbology.").foregroundStyle(.orange).font(.caption) }
            HStack {
                if session.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { showSave = false }.keyboardShortcut(.cancelAction).disabled(session.busy)
                Button("Save") { Task { if await session.save(name: saveName, provider: store.rasterSymbologyProvider) { showSave = false } } }
                    .keyboardShortcut(.defaultAction).disabled(!session.nameIsValid(saveName) || session.busy || store.rasterSymbologyProvider == nil)
            }
        }.padding(24).frame(width: 440).interactiveDismissDisabled(session.busy || store.isRunningRasterMutation)
    }
}

enum RasterPaletteOrientation: Equatable {
    case horizontal
    case vertical
}

struct RasterPalettePreview: View {
    let colors: [String]
    var orientation: RasterPaletteOrientation = .horizontal
    var showNameBox = true

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(LinearGradient(
                colors: colors.map(EditorColor.decode),
                startPoint: orientation == .horizontal ? .leading : .bottom,
                endPoint: orientation == .horizontal ? .trailing : .top
            ))
            .background(.quaternary, in: .rect(cornerRadius: 3))
            .overlay {
                if showNameBox {
                    RoundedRectangle(cornerRadius: 3).strokeBorder(.separator, lineWidth: 0.5)
                }
            }
    }
}
